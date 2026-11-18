import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/models/live/trail_live_models.dart' show SosReason;
import 'package:wanderer/services/ble/ble_mesh_protocol.dart';
import 'package:wanderer/services/ble/sos_crypto_and_outbox.dart';

void main() {
  group('Lamport Preimage & SosOriginCredentials', () {
    test('matches exact cross-language SHA-256 / HMAC-SHA256 Go test vector', () {
      const deviceToken =
          'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
      const clientSosId = '0123456789abcdef';

      final creds = SosOriginCredentials.derive(
        deviceToken: deviceToken,
        clientSosId: clientSosId,
      );

      expect(creds.clientSosId, '0123456789abcdef');
      expect(creds.sosClaimSecret, '03ba16195db20cae6968533b254ba0e5');
      expect(creds.sosClaimHash, '9eb067d1e6b03560');
      expect(creds.sosSecretBytes, hasLength(16));
      expect(creds.sosClaimHashBytes, hasLength(8));

      expect(
        verifyPreimageHex(creds.sosClaimSecret, creds.sosClaimHash),
        isTrue,
      );
      expect(
        verifyPreimageBytes(creds.sosSecretBytes, creds.sosClaimHashBytes),
        isTrue,
      );

      // Single-bit flip in secret preimage must fail verification.
      final tampered = creds.sosSecretBytes;
      tampered[15] ^= 0x01;
      expect(verifyPreimageBytes(tampered, creds.sosClaimHashBytes), isFalse);
      expect(
        verifyPreimageHex(
          '03ba16195db20cae6968533b254ba0e4',
          creds.sosClaimHash,
        ),
        isFalse,
      );
      expect(verifyPreimageHex('not-hex', creds.sosClaimHash), isFalse);
    });

    test('mint produces valid credentials reproducibly re-derived from token', () {
      final minted = SosOriginCredentials.mint(
        'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb',
        random: math.Random(42),
      );
      expect(minted.clientSosId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(minted.sosClaimSecret, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(minted.sosClaimHash, matches(RegExp(r'^[0-9a-f]{16}$')));

      final rederived = SosOriginCredentials.derive(
        deviceToken:
            'deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb',
        clientSosId: minted.clientSosId.toUpperCase(),
      );
      expect(rederived.sosClaimSecret, minted.sosClaimSecret);
      expect(rederived.sosClaimHash, minted.sosClaimHash);
    });
  });

  group('truncateUtf8RuneSafe', () {
    test('never splits Romanian diacritics or 4-byte emojis at byte boundaries', () {
      // Each of Ș, ț, ă, î, â is 2 UTF-8 bytes.
      const roName = 'ȘtefănuțĂâî';
      for (var limit = 1; limit <= 16; limit++) {
        final bytes = truncateUtf8RuneSafe(roName, limit);
        expect(bytes.length, lessThanOrEqualTo(limit));
        // Strict utf8.decode (allowMalformed: false) throws if any rune was split!
        final decoded = utf8.decode(bytes);
        expect(roName.startsWith(decoded), isTrue);
      }

      // 47 ASCII bytes + 4-byte 🆘 emoji under 48-byte limit -> must stop at 47 bytes.
      final msgWithEmoji = '${'A' * 47}🆘';
      final truncated = truncateUtf8RuneSafe(msgWithEmoji, 48);
      expect(truncated.length, 47);
      expect(utf8.decode(truncated), 'A' * 47);
    });
  });

  group('Binary Wire Protocol (0x01..0x04)', () {
    test('0x01 BleGroupPosPacket (48B) roundtrips and rejects wrong group code', () {
      final cipherA = GroupBleCipher.fromGroupCode(' buceg7 ');
      final cipherAUpper = GroupBleCipher.fromGroupCode('BUCEG7');
      final cipherWrong = GroupBleCipher.fromGroupCode('PIATR2');

      final orig = BleGroupPosPacket(
        memberIdHex: 'a1b2c3d4e5f6',
        lat: 45.4058123,
        lon: 25.4519876,
        eleM: 2505,
        accuracyM: 6,
        inNavigation: true,
        lowBattery: true,
        memberLeft: false,
        headingDeg: 274.0,
        speedMps: 1.4,
        displayName: 'Ștefănuț-Drumeț',
        timestampSec: 1795000123,
        nonceSalt: 0x12345678,
      );

      final raw = orig.encode(cipherA);
      expect(raw.length, 48);
      expect(raw[0], 0x54);
      expect(raw[1], 0x01);
      expect(raw[2], 0x03);
      expect(raw[3], 44);

      // Wrong group code must fail MAC verification cleanly.
      expect(BleGroupPosPacket.decode(raw, cipher: cipherWrong), isNull);

      final decoded = BleGroupPosPacket.decode(
        raw,
        cipher: cipherAUpper,
        rssi: -68,
        peerId: 'peer-1',
      );
      expect(decoded, isNotNull);
      final pkt = decoded!;
      expect(pkt.memberIdHex, 'a1b2c3d4e5f6');
      expect(pkt.lat, closeTo(45.4058123, 1e-7));
      expect(pkt.lon, closeTo(25.4519876, 1e-7));
      expect(pkt.eleM, 2505);
      expect(pkt.accuracyM, 6);
      expect(pkt.inNavigation, isTrue);
      expect(pkt.lowBattery, isTrue);
      expect(pkt.memberLeft, isFalse);
      expect(pkt.headingDeg, 274.0);
      expect(pkt.speedMps, closeTo(1.4, 0.01));
      expect(pkt.timestampSec, 1795000123);
      expect(pkt.hopCount, 0);
      expect(pkt.ttlRemaining, 3);
      expect(pkt.rssi, -68);
      expect(pkt.peerId, 'peer-1');
      // Truncated rune-safely to <= 12 UTF-8 bytes.
      expect(utf8.encode(pkt.displayName).length, lessThanOrEqualTo(12));
      expect('Ștefănuț-Drumeț'.startsWith(pkt.displayName), isTrue);
      expect(pkt.colorHex, isIn(kBleGroupMemberPalette));

      // Tampering with ciphertext invalidates MAC.
      final tampered = Uint8List.fromList(raw);
      tampered[20] ^= 0x80;
      expect(BleGroupPosPacket.decode(tampered, cipher: cipherA), isNull);
    });

    test('0x02 BleSosAlertPacket (40..88B) roundtrips and survives 5 relay hops', () {
      final creds = SosOriginCredentials.mint(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        random: math.Random(7),
      );

      // Minimal 40B alert (empty message).
      final minimal = BleSosAlertPacket(
        clientSosId: creds.clientSosId,
        sosClaimHash: creds.sosClaimHash,
        reason: SosReason.lost,
        lat: 45.5412,
        lon: 25.2198,
        eleM: 1980,
        createdEpochSec: 1795001000,
      );
      final minRaw = minimal.encode();
      expect(minRaw.length, 40);

      // Full alert with Romanian diacritics exceeding 48B -> truncated to exact 88B frame.
      final shortMsg = BleSosAlertPacket.composeShortMsg(
        requesterName: 'Andrei',
        message: 'Entorsă gravă sub Șaua Caprei, ceață densă și vânt puternic',
      );
      final full = BleSosAlertPacket(
        clientSosId: creds.clientSosId,
        sosClaimHash: creds.sosClaimHash,
        reason: SosReason.injury,
        batteryCritical: true,
        isStationary: true,
        lat: 45.6034567,
        lon: 24.6178901,
        eleM: 2260,
        createdEpochSec: 1795002000,
        shortMsg: shortMsg,
      );
      var currentFrame = full.encode();
      expect(currentFrame.length, lessThanOrEqualTo(88));
      expect(currentFrame[2], 0x05); // hop=0, ttl=5

      // Relay across all 5 hops; byte[2] changes while integrityHash4B stays valid!
      for (var expectedHop = 1; expectedHop <= 5; expectedHop++) {
        final nextFrame = decrementTtlForRelay(currentFrame);
        expect(nextFrame, isNotNull);
        currentFrame = nextFrame!;
        final hopDecoded = BleSosAlertPacket.decode(currentFrame);
        expect(hopDecoded, isNotNull);
        final d = hopDecoded!;
        expect(d.hopCount, expectedHop);
        expect(d.ttlRemaining, 5 - expectedHop);
        expect(d.clientSosId, creds.clientSosId);
        expect(d.sosClaimHash, creds.sosClaimHash);
        expect(d.reason, SosReason.injury);
        expect(d.batteryCritical, isTrue);
        expect(d.isStationary, isTrue);
        expect(d.eleM, 2260);
        final split = d.splitRequesterAndMessage();
        expect(split.requesterName, 'Andrei');
        expect(split.message, startsWith('Entorsă gravă'));
      }

      // At ttlRemaining == 0, decrementTtlForRelay must stop returning a frame.
      expect(decrementTtlForRelay(currentFrame), isNull);
    });

    test('0x03 BleSosAckPacket (30B) and 0x04 BleSosResolvedPacket (37B) roundtrip', () {
      final creds = SosOriginCredentials.mint(
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
        random: math.Random(11),
      );
      final respId = deriveBleResponderIdHex(
        clientSosId: creds.clientSosId,
        responderDeviceToken: 'responder-token-1234',
      );

      final ack = BleSosAckPacket(
        clientSosId: creds.clientSosId,
        responderIdHex: respId,
        etaMin: 18,
        distM: 640,
        comingToHelp: true,
        uploadedToServer: true,
        ackEpochSec: 1795003000,
      );
      final ackRaw = ack.encode();
      expect(ackRaw.length, 30);
      final ackDecoded = BleSosAckPacket.decode(ackRaw);
      expect(ackDecoded, isNotNull);
      expect(ackDecoded!.clientSosId, creds.clientSosId);
      expect(ackDecoded.responderIdHex, respId);
      expect(ackDecoded.etaMin, 18);
      expect(ackDecoded.distM, 640);
      expect(ackDecoded.comingToHelp, isTrue);
      expect(ackDecoded.uploadedToServer, isTrue);
      expect(ackDecoded.cancelled, isFalse);

      // Unknown ETA/distance encoded as 255 / 65535 -> decoded back to null.
      final unknownAck = BleSosAckPacket.decode(
        BleSosAckPacket(
          clientSosId: creds.clientSosId,
          responderIdHex: respId,
          uploadedToServer: true,
          ackEpochSec: 1795003010,
        ).encode(),
      );
      expect(unknownAck, isNotNull);
      expect(unknownAck!.etaMin, isNull);
      expect(unknownAck.distM, isNull);

      final resolved = BleSosResolvedPacket.fromHexSecret(
        clientSosId: creds.clientSosId,
        status: BleSosResolvedPacket.statusResolved,
        resolvedEpochSec: 1795004000,
        sosClaimSecretHex: creds.sosClaimSecret,
      );
      final resRaw = resolved.encode();
      expect(resRaw.length, 37);
      final resDecoded = BleSosResolvedPacket.decode(resRaw);
      expect(resDecoded, isNotNull);
      expect(resDecoded!.clientSosId, creds.clientSosId);
      expect(resDecoded.sosRevealTokenHex, creds.sosClaimSecret);
      expect(
        verifyPreimageHex(resDecoded.sosRevealTokenHex, creds.sosClaimHash),
        isTrue,
      );
    });

    test('packSyncBuffer orders by emergency priority <= 180B and computeSyncDigest8B is hop-invariant', () {
      final cipher = GroupBleCipher.fromGroupCode('FAGAR9');
      final grpFrame = BleGroupPosPacket(
        memberIdHex: '112233445566',
        lat: 45.6,
        lon: 24.7,
        displayName: 'Maria',
        timestampSec: 1795000000,
        nonceSalt: 1,
      ).encode(cipher);

      final creds = SosOriginCredentials.mint(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        random: math.Random(3),
      );
      final ackFrame = BleSosAckPacket(
        clientSosId: creds.clientSosId,
        responderIdHex: 'aabbccddeeff',
        comingToHelp: true,
        ackEpochSec: 1795000010,
      ).encode();
      final sosFrame = BleSosAlertPacket(
        clientSosId: creds.clientSosId,
        sosClaimHash: creds.sosClaimHash,
        reason: SosReason.exhaustion,
        lat: 45.61,
        lon: 24.71,
        createdEpochSec: 1795000005,
        shortMsg: 'Fără apă pe creastă',
      ).encode();

      // Input in reverse priority order: Group -> ACK -> SOS.
      final packed = packSyncBuffer(<Uint8List>[grpFrame, ackFrame, sosFrame]);
      expect(packed.length, lessThanOrEqualTo(180));
      expect(packed[0], 3);

      final unpacked = unpackSyncBuffer(packed);
      expect(unpacked, hasLength(3));
      // Must come out ordered SOS_ALERT (0x02) -> SOS_ACK (0x03) -> GROUP_POS (0x01).
      expect(unpacked[0][1], BlePacketType.sosAlert.wireValue);
      expect(unpacked[1][1], BlePacketType.sosAck.wireValue);
      expect(unpacked[2][1], BlePacketType.groupPos.wireValue);

      final digestHop0 = computeSyncDigest8B(<Uint8List>[sosFrame, ackFrame, grpFrame]);
      expect(digestHop0, hasLength(8));
      expect(digestHop0[0], 0x07); // hasSos | hasAck | hasGroup

      final relayedSos = decrementTtlForRelay(sosFrame)!;
      final digestHop1 = computeSyncDigest8B(<Uint8List>[relayedSos, ackFrame, grpFrame]);
      expect(digestHop1, equals(digestHop0));

      // Empty buffer convention: [0] of length 1.
      final emptyPacked = packSyncBuffer(const <Uint8List>[]);
      expect(emptyPacked, equals(Uint8List.fromList(const <int>[0])));
      expect(unpackSyncBuffer(emptyPacked), isEmpty);
    });
  });

  group('BlePacketDeduplicator', () {
    test('enforces +30s superseding, rejects fake preimages, and tombstones for 6h', () {
      var nowSec = 1795010000;
      final dedup = BlePacketDeduplicator(nowEpochSec: () => nowSec);

      final victimCreds = SosOriginCredentials.mint(
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        random: math.Random(99),
      );
      final attackerCreds = SosOriginCredentials.mint(
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        random: math.Random(100),
      );

      final alertT0 = BleSosAlertPacket(
        clientSosId: victimCreds.clientSosId,
        sosClaimHash: victimCreds.sosClaimHash,
        reason: SosReason.injury,
        lat: 45.40,
        lon: 25.45,
        createdEpochSec: nowSec,
      );
      expect(dedup.evaluateSosAlert(alertT0).status, BleDedupStatus.acceptNew);

      // Duplicate echo 15s later -> dropped.
      final alertT15 = BleSosAlertPacket(
        clientSosId: victimCreds.clientSosId,
        sosClaimHash: victimCreds.sosClaimHash,
        reason: SosReason.injury,
        lat: 45.4001,
        lon: 25.4501,
        createdEpochSec: nowSec + 15,
      );
      expect(dedup.evaluateSosAlert(alertT15).accepted, isFalse);

      // Spoofed sosClaimHash for same clientSosId -> invalidAuth.
      final spoofedAlert = BleSosAlertPacket(
        clientSosId: victimCreds.clientSosId,
        sosClaimHash: attackerCreds.sosClaimHash,
        reason: SosReason.other,
        lat: 44.0,
        lon: 26.0,
        createdEpochSec: nowSec + 60,
      );
      expect(
        dedup.evaluateSosAlert(spoofedAlert).status,
        BleDedupStatus.invalidAuth,
      );

      // Genuine movement update at +30s -> superseded & relayed.
      final alertT30 = BleSosAlertPacket(
        clientSosId: victimCreds.clientSosId,
        sosClaimHash: victimCreds.sosClaimHash,
        reason: SosReason.injury,
        lat: 45.4010,
        lon: 25.4510,
        createdEpochSec: nowSec + 30,
      );
      final sup = dedup.evaluateSosAlert(alertT30);
      expect(sup.status, BleDedupStatus.superseded);
      expect(sup.shouldRelay, isTrue);

      // Rogue SOS_RESOLVED with attacker's secret -> rejected!
      final fakeResolved = BleSosResolvedPacket.fromHexSecret(
        clientSosId: victimCreds.clientSosId,
        resolvedEpochSec: nowSec + 45,
        sosClaimSecretHex: attackerCreds.sosClaimSecret,
      );
      expect(
        dedup.evaluateSosResolved(fakeResolved).status,
        BleDedupStatus.invalidAuth,
      );
      expect(dedup.isSosTombstoned(victimCreds.clientSosId), isFalse);

      // Genuine SOS_RESOLVED with victim's Lamport preimage -> accepted & tombstoned for 6h!
      final realResolved = BleSosResolvedPacket.fromHexSecret(
        clientSosId: victimCreds.clientSosId,
        resolvedEpochSec: nowSec + 50,
        sosClaimSecretHex: victimCreds.sosClaimSecret,
      );
      final resDec = dedup.evaluateSosResolved(realResolved);
      expect(resDec.accepted, isTrue);
      expect(resDec.shouldRelay, isTrue);
      expect(dedup.isSosTombstoned(victimCreds.clientSosId), isTrue);

      // Stale valley echo 1 hour later must stay blocked by the 6h tombstone.
      nowSec += 3600;
      final delayedEcho = BleSosAlertPacket(
        clientSosId: victimCreds.clientSosId,
        sosClaimHash: victimCreds.sosClaimHash,
        reason: SosReason.injury,
        lat: 45.402,
        lon: 25.452,
        createdEpochSec: nowSec,
      );
      expect(
        dedup.evaluateSosAlert(delayedEcho).status,
        BleDedupStatus.tombstoned,
      );

      // After > 6h total, tombstone expires cleanly.
      nowSec += 6 * 3600;
      expect(dedup.isSosTombstoned(victimCreds.clientSosId), isFalse);
    });

    test('caps LRU ring buffer at 256 slots and rejects future-skewed group packets', () {
      const nowSec = 1795020000;
      final dedup = BlePacketDeduplicator(
        maxSlots: 256,
        nowEpochSec: () => nowSec,
      );

      for (var i = 0; i < 300; i++) {
        final memberHex = i.toRadixString(16).padLeft(12, '0');
        final pkt = BleGroupPosPacket(
          memberIdHex: memberHex,
          lat: 45.5,
          lon: 25.5,
          displayName: 'M$i',
          timestampSec: nowSec,
        );
        expect(dedup.evaluateGroupPos(pkt).accepted, isTrue);
      }
      expect(dedup.length, 256);

      final futureSkewed = BleGroupPosPacket(
        memberIdHex: 'abcdef012345',
        lat: 45.5,
        lon: 25.5,
        displayName: 'Future',
        timestampSec: nowSec + 300,
      );
      expect(
        dedup.evaluateGroupPos(futureSkewed).status,
        BleDedupStatus.futureSkew,
      );
    });
  });

  group('SosOutboxAndRelayStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('wanderer_ble_outbox_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('persists myPendingSos, deduplicated relayQueue, and pendingResponderAction across restarts', () async {
      var nowSec = 1795050000;
      final outboxFile = File(
        '${tempDir.path}${Platform.pathSeparator}${SosOutboxAndRelayStore.fileName}',
      );

      final store1 = SosOutboxAndRelayStore(
        customFile: outboxFile,
        nowEpochSec: () => nowSec,
      );

      final myCreds = SosOriginCredentials.mint(
        '1111111111111111111111111111111111111111111111111111111111111111',
        random: math.Random(1),
      );
      final peerCreds = SosOriginCredentials.mint(
        '2222222222222222222222222222222222222222222222222222222222222222',
        random: math.Random(2),
      );

      await store1.setMyPendingSos(
        PendingMySosEntry(
          clientSosId: myCreds.clientSosId,
          sosClaimSecret: myCreds.sosClaimSecret,
          sosClaimHash: myCreds.sosClaimHash,
          trailId: 'trail_retezat',
          reason: SosReason.exhaustion,
          message: 'Epuizat la Lacul Bucura',
          requesterName: 'Radu',
          lat: 45.362,
          lon: 22.875,
          ele: 2040,
          createdEpochSec: nowSec,
        ),
      );

      await store1.upsertRelayedAlert(
        clientSosId: peerCreds.clientSosId,
        sosClaimHash: peerCreds.sosClaimHash,
        reason: SosReason.injury,
        message: 'Accidentare pe creastă',
        requesterName: 'Ioana',
        lat: 45.370,
        lon: 22.880,
        ele: 2150,
        packetEpochSec: nowSec + 10,
        hopCount: 2,
      );

      // Older or equal packetEpochSec does not overwrite newer coordinates.
      await store1.upsertRelayedAlert(
        clientSosId: peerCreds.clientSosId,
        sosClaimHash: peerCreds.sosClaimHash,
        reason: SosReason.injury,
        lat: 0.0,
        lon: 0.0,
        packetEpochSec: nowSec + 5,
        hopCount: 3,
      );
      expect(store1.relayQueue.single.lat, 45.370);

      await store1.setPendingResponderAction(
        PendingResponderAction(
          clientSosId: peerCreds.clientSosId,
          lat: 45.365,
          lon: 22.878,
          ele: 2090,
          distanceM: 610.0,
          etaSec: 960,
          createdEpochSec: nowSec + 12,
        ),
      );

      // Reload in a brand-new instance from disk!
      final store2 = SosOutboxAndRelayStore(
        customFile: outboxFile,
        nowEpochSec: () => nowSec,
      );
      await store2.ensureLoaded();

      expect(store2.myPendingSos?.clientSosId, myCreds.clientSosId);
      expect(store2.myPendingSos?.sosClaimSecret, myCreds.sosClaimSecret);
      expect(store2.pendingRelayUploads, hasLength(1));
      expect(
        store2.pendingResponderAction?.clientSosId,
        peerCreds.clientSosId,
      );

      // Mark active alert uploaded -> pendingRelayUploads becomes empty.
      await store2.markRelayedUploaded(
        peerCreds.clientSosId,
        serverSosId: 'pb_sos_99',
      );
      expect(store2.pendingRelayUploads, isEmpty);
      expect(store2.pendingResponderAction?.serverSosId, 'pb_sos_99');

      // Wrong preimage resolution must be rejected.
      final wrongRes = await store2.applyVerifiedResolution(
        clientSosId: peerCreds.clientSosId,
        sosRevealTokenHex: myCreds.sosClaimSecret,
        resolvedEpochSec: nowSec + 100,
      );
      expect(wrongRes, isFalse);

      // Valid preimage resolution transitions entry to resolved and queues upload!
      final okRes = await store2.applyVerifiedResolution(
        clientSosId: peerCreds.clientSosId,
        sosRevealTokenHex: peerCreds.sosClaimSecret,
        resolvedEpochSec: nowSec + 120,
      );
      expect(okRes, isTrue);
      expect(store2.pendingRelayUploads, hasLength(1));
      final relayJson = store2.pendingRelayUploads.single.toRelayApiJson();
      expect(relayJson['status'], 'resolved');
      expect(relayJson['sosClaimSecret'], peerCreds.sosClaimSecret);

      // Advance past 6h TTL -> auto-pruned cleanly.
      nowSec += SosOutboxAndRelayStore.kSosRelayTtlSec + 10;
      expect(store2.relayQueue, isEmpty);
      expect(store2.myPendingSos, isNull);
    });

    test('falls back gracefully to in-memory storage when directoryProvider throws', () async {
      final memoryStore = SosOutboxAndRelayStore(
        directoryProvider: () async =>
            throw const FileSystemException('unavailable in test'),
        nowEpochSec: () => 1795060000,
      );
      final creds = SosOriginCredentials.mint(
        '3333333333333333333333333333333333333333333333333333333333333333',
        random: math.Random(5),
      );
      final stored = await memoryStore.upsertRelayedAlert(
        clientSosId: creds.clientSosId,
        sosClaimHash: creds.sosClaimHash,
        lat: 45.5,
        lon: 25.5,
        packetEpochSec: 1795060000,
      );
      expect(stored, isNotNull);
      expect(memoryStore.pendingRelayUploads, hasLength(1));
    });
  });
}
