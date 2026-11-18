import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/models/live/trail_live_models.dart' show SosReason;
import 'package:wanderer/services/ble/ble_mesh_engine.dart';
import 'package:wanderer/services/ble/ble_mesh_protocol.dart';
import 'package:wanderer/services/ble/sos_crypto_and_outbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const eventsControlChannel = MethodChannel(
    'com.openwanderer.wanderer/ble_proximity/events',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final recordedCalls = <MethodCall>[];

  void mockBleChannels(
    Future<Object?> Function(MethodCall call) methodHandler,
  ) {
    messenger.setMockMethodCallHandler(bleProximityMethodChannel, (call) {
      recordedCalls.add(call);
      return methodHandler(call);
    });
    messenger.setMockMethodCallHandler(eventsControlChannel, (call) async {
      return null;
    });
  }

  Future<void> emitNativeEvent(Map<String, Object?> event) {
    final byteData = const StandardMethodCodec().encodeSuccessEnvelope(event);
    final completer = Completer<void>();
    messenger.handlePlatformMessage(
      bleProximityEventChannel.name,
      byteData,
      (_) => completer.complete(),
    );
    return completer.future;
  }

  setUp(() {
    recordedCalls.clear();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(bleProximityMethodChannel, null);
    messenger.setMockMethodCallHandler(eventsControlChannel, null);
  });

  group('Platform guard & permissions', () {
    test('isSupportedPlatform: false is a complete no-op with 0 channel calls', () async {
      mockBleChannels((_) async => true);
      final engine = BleMeshEngine(isSupportedPlatform: false);
      addTearDown(engine.dispose);

      final state = await engine.getState();
      expect(state.supported, isFalse);
      expect(await engine.checkPermissions(), isFalse);
      expect(await engine.requestPermissions(), isFalse);
      expect(await engine.setRadioMode(BleRadioMode.passiveTrailGuard), isFalse);
      expect(recordedCalls, isEmpty);
    });

    test('getState, checkPermissions, requestPermissions, and PlatformException safety', () async {
      mockBleChannels((call) async {
        switch (call.method) {
          case 'getState':
            return <String, Object?>{
              'supported': true,
              'adapterOn': true,
              'permissionsGranted': true,
              'running': false,
            };
          case 'checkPermissions':
            return true;
          case 'requestPermissions':
            return true;
          default:
            return true;
        }
      });

      final engine = BleMeshEngine(isSupportedPlatform: true);
      addTearDown(engine.dispose);

      final st = await engine.getState();
      expect(st.supported, isTrue);
      expect(st.adapterOn, isTrue);
      expect(st.permissionsGranted, isTrue);
      expect(engine.adapterOnListenable.value, isTrue);
      expect(await engine.checkPermissions(), isTrue);
      expect(await engine.requestPermissions(), isTrue);

      // PlatformException is caught gracefully without crashing.
      mockBleChannels((_) async => throw PlatformException(code: 'ble_err'));
      final fallbackState = await engine.getState();
      expect(fallbackState.supported, isFalse);
      expect(await engine.checkPermissions(), isFalse);
    });
  });

  group('Adaptive radio modes & 3-min burst -> sustained survival curve', () {
    test('transitions across passive_guard, group_normal, sos_emergency burst -> sustained, and idleOff', () async {
      mockBleChannels((_) async => true);

      final engine = BleMeshEngine(
        isSupportedPlatform: true,
        sosBurstDuration: const Duration(milliseconds: 50),
        sosProximityReburstDuration: const Duration(milliseconds: 60),
        random: math.Random(1),
      );
      addTearDown(engine.dispose);

      // 1. Passive guard starts dual role with empty [0] buffer.
      expect(await engine.setRadioMode(BleRadioMode.passiveTrailGuard), isTrue);
      expect(recordedCalls.last.method, 'startDualRole');
      final startArgs = Map<String, Object?>.from(
        recordedCalls.last.arguments as Map,
      );
      expect(startArgs['mode'], 'passive_guard');
      expect((startArgs['syncDigest'] as Uint8List).length, 8);
      expect(startArgs['syncBuffer'], Uint8List.fromList(const <int>[0]));

      // 2. Group mode updates to group_normal.
      expect(await engine.setRadioMode(BleRadioMode.groupMeshNormal), isTrue);
      expect(recordedCalls.last.method, 'updateLocalPayloads');
      expect(
        (recordedCalls.last.arguments as Map)['mode'],
        'group_normal',
      );

      // 3. Emergency mode enters burstLowLatency ('sos_emergency').
      expect(
        await engine.setRadioMode(BleRadioMode.sosEmergencyActive),
        isTrue,
      );
      expect(engine.sosPowerPhase, BleSosPowerPhase.burstLowLatency);
      expect(
        (recordedCalls.last.arguments as Map)['mode'],
        'sos_emergency',
      );

      // 4. After burst timer elapses, steps down to sustainedSurvival ('group_normal').
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(engine.sosPowerPhase, BleSosPowerPhase.sustainedSurvival);
      expect(recordedCalls.last.method, 'updateLocalPayloads');
      expect(
        (recordedCalls.last.arguments as Map)['mode'],
        'group_normal',
      );

      // 5. Peer frame detection boosts back to burstLowLatency ('sos_emergency')!
      final peerCreds = SosOriginCredentials.mint(
        '4444444444444444444444444444444444444444444444444444444444444444',
        random: math.Random(9),
      );
      final ackFromPeer = BleSosAckPacket(
        clientSosId: peerCreds.clientSosId,
        responderIdHex: '123456abcdef',
        comingToHelp: true,
        ackEpochSec: 1795000000,
        ttlRemaining: 0, // ttl=0 so no relay timer interferes
      ).encode();

      await emitNativeEvent(<String, Object?>{
        'type': 'frame',
        'bytes': ackFromPeer,
        'rssi': -72,
        'peerId': 'ios-peer-uuid',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(engine.sosPowerPhase, BleSosPowerPhase.burstLowLatency);
      expect(
        (recordedCalls.last.arguments as Map)['mode'],
        'sos_emergency',
      );

      // 6. Returning to idleOff calls stopDualRole and cancels timers cleanly.
      await engine.setRadioMode(BleRadioMode.idleOff);
      expect(engine.radioMode, BleRadioMode.idleOff);
      expect(engine.sosPowerPhase, BleSosPowerPhase.inactive);
      expect(recordedCalls.last.method, 'stopDualRole');
    });
  });

  group('Packet reception, deduplication, and jittered multi-hop relaying', () {
    test('decodes syncBuffer (Group + SOS), filters self-echo, and schedules jittered relays', () async {
      mockBleChannels((_) async => true);

      const nowSec = 1795100000;
      final engine = BleMeshEngine(
        isSupportedPlatform: true,
        random: math.Random(7),
        nowEpochSec: () => nowSec,
      );
      addTearDown(engine.dispose);

      final receivedGroups = <BleGroupPosPacket>[];
      final receivedSos = <BleSosAlertPacket>[];
      final subGrp = engine.onGroupPosReceived.listen(receivedGroups.add);
      final subSos = engine.onSosAlertReceived.listen(receivedSos.add);
      addTearDown(subGrp.cancel);
      addTearDown(subSos.cancel);

      engine.configureGroupSession(
        groupCode: 'BUCEG7',
        selfMemberIdHex: '111111111111',
      );
      await engine.setRadioMode(BleRadioMode.groupMeshNormal);
      recordedCalls.clear();

      final cipher = GroupBleCipher.fromGroupCode('BUCEG7');
      final selfEchoFrame = BleGroupPosPacket(
        memberIdHex: '111111111111',
        lat: 45.40,
        lon: 25.45,
        displayName: 'Eu',
        timestampSec: nowSec,
        nonceSalt: 10,
      ).encode(cipher);

      final peerGroupFrame = BleGroupPosPacket(
        memberIdHex: '222222222222',
        lat: 45.41,
        lon: 25.46,
        eleM: 2120,
        displayName: 'Elena',
        timestampSec: nowSec,
        nonceSalt: 20,
        ttlRemaining: 3,
      ).encode(cipher);

      final sosCreds = SosOriginCredentials.mint(
        '5555555555555555555555555555555555555555555555555555555555555555',
        random: math.Random(12),
      );
      final sosAlertFrame = BleSosAlertPacket(
        clientSosId: sosCreds.clientSosId,
        sosClaimHash: sosCreds.sosClaimHash,
        reason: SosReason.injury,
        lat: 45.42,
        lon: 25.47,
        eleM: 2210,
        createdEpochSec: nowSec,
        shortMsg: 'Mihai: Picior luxat',
        ttlRemaining: 5,
      ).encode();

      final syncBuf = packSyncBuffer(<Uint8List>[
        selfEchoFrame,
        peerGroupFrame,
        sosAlertFrame,
      ]);

      await emitNativeEvent(<String, Object?>{
        'type': 'syncBuffer',
        'bytes': syncBuf,
        'rssi': -64,
        'peerId': 'AA:BB:CC:DD:EE:FF',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Self-echo ignored; peer group & SOS alert delivered once with RSSI/peerId.
      expect(receivedGroups, hasLength(1));
      expect(receivedGroups.single.memberIdHex, '222222222222');
      expect(receivedGroups.single.displayName, 'Elena');
      expect(receivedGroups.single.rssi, -64);
      expect(receivedGroups.single.peerId, 'AA:BB:CC:DD:EE:FF');

      expect(receivedSos, hasLength(1));
      expect(receivedSos.single.clientSosId, sosCreds.clientSosId);
      expect(receivedSos.single.hopCount, 0);
      expect(receivedSos.single.ttlRemaining, 5);

      // Re-emitting exact same syncBuffer immediately -> deduplicated (0 duplicates).
      await emitNativeEvent(<String, Object?>{
        'type': 'syncBuffer',
        'bytes': syncBuf,
        'rssi': -66,
        'peerId': 'AA:BB:CC:DD:EE:FF',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(receivedGroups, hasLength(1));
      expect(receivedSos, hasLength(1));

      // Wait for both SOS jitter (80..350ms) and Group jitter (250..800ms) to complete.
      await Future<void>.delayed(const Duration(milliseconds: 850));

      final relayCalls = recordedCalls
          .where((c) => c.method == 'updateLocalPayloads')
          .toList();
      expect(relayCalls.length, greaterThanOrEqualTo(2));

      final pushedFrames = relayCalls
          .map((c) => (c.arguments as Map)['pushFrame'])
          .whereType<Uint8List>()
          .toList();
      expect(pushedFrames, hasLength(2));

      // Verify SOS relay decremented TTL from (hop=0, ttl=5) -> (hop=1, ttl=4).
      final relayedSos = pushedFrames.firstWhere(
        (f) => f[1] == BlePacketType.sosAlert.wireValue,
      );
      final decodedRelayedSos = BleSosAlertPacket.decode(relayedSos)!;
      expect(decodedRelayedSos.hopCount, 1);
      expect(decodedRelayedSos.ttlRemaining, 4);

      // Verify Group relay decremented TTL from (hop=0, ttl=3) -> (hop=1, ttl=2).
      final relayedGrp = pushedFrames.firstWhere(
        (f) => f[1] == BlePacketType.groupPos.wireValue,
      );
      final decodedRelayedGrp = BleGroupPosPacket.decode(
        relayedGrp,
        cipher: cipher,
      )!;
      expect(decodedRelayedGrp.hopCount, 1);
      expect(decodedRelayedGrp.ttlRemaining, 2);

      // Stop engine before tearDown so all state is clean.
      await engine.stop();
    });

    test('verifies Lamport preimage on incoming BleSosResolvedPacket and updates adapterState', () async {
      mockBleChannels((_) async => true);

      const nowSec = 1795200000;
      final engine = BleMeshEngine(
        isSupportedPlatform: true,
        random: math.Random(21),
        nowEpochSec: () => nowSec,
      );
      addTearDown(engine.dispose);

      final alerts = <BleSosAlertPacket>[];
      final resolvedList = <BleSosResolvedPacket>[];
      final subA = engine.onSosAlertReceived.listen(alerts.add);
      final subR = engine.onSosResolvedReceived.listen(resolvedList.add);
      addTearDown(subA.cancel);
      addTearDown(subR.cancel);

      await engine.setRadioMode(BleRadioMode.passiveTrailGuard);

      // Adapter state event updates adapterOnListenable.
      await emitNativeEvent(<String, Object?>{
        'type': 'adapterState',
        'adapterOn': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(engine.adapterOnListenable.value, isTrue);

      final victim = SosOriginCredentials.mint(
        '7777777777777777777777777777777777777777777777777777777777777777',
        random: math.Random(33),
      );
      final rogue = SosOriginCredentials.mint(
        '8888888888888888888888888888888888888888888888888888888888888888',
        random: math.Random(34),
      );

      // 1. Receive active SOS alert (ttl=0 to skip relay timer in this test).
      await emitNativeEvent(<String, Object?>{
        'type': 'frame',
        'bytes': BleSosAlertPacket(
          clientSosId: victim.clientSosId,
          sosClaimHash: victim.sosClaimHash,
          reason: SosReason.lost,
          lat: 45.5,
          lon: 25.3,
          createdEpochSec: nowSec,
          ttlRemaining: 0,
        ).encode(),
        'rssi': -70,
        'peerId': 'peer-sos',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(alerts, hasLength(1));

      // 2. Forged SOS_RESOLVED with rogue's secret is rejected!
      await emitNativeEvent(<String, Object?>{
        'type': 'frame',
        'bytes': BleSosResolvedPacket.fromHexSecret(
          clientSosId: victim.clientSosId,
          resolvedEpochSec: nowSec + 20,
          sosClaimSecretHex: rogue.sosClaimSecret,
          ttlRemaining: 0,
        ).encode(),
        'rssi': -70,
        'peerId': 'peer-rogue',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(resolvedList, isEmpty);

      // 3. Authentic SOS_RESOLVED with victim's Lamport preimage succeeds!
      await emitNativeEvent(<String, Object?>{
        'type': 'frame',
        'bytes': BleSosResolvedPacket.fromHexSecret(
          clientSosId: victim.clientSosId,
          resolvedEpochSec: nowSec + 25,
          sosClaimSecretHex: victim.sosClaimSecret,
          ttlRemaining: 0,
        ).encode(),
        'rssi': -69,
        'peerId': 'peer-victim',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(resolvedList, hasLength(1));
      expect(resolvedList.single.clientSosId, victim.clientSosId);
      expect(resolvedList.single.sosRevealTokenHex, victim.sosClaimSecret);

      await engine.stop();
    });
  });
}
