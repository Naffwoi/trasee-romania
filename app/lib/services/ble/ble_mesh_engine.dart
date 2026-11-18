import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ValueChanged, ValueListenable, ValueNotifier, debugPrint, kIsWeb;
import 'package:flutter/services.dart'
    show EventChannel, MethodChannel, MissingPluginException, PlatformException;
import 'package:wanderer/services/ble/ble_mesh_protocol.dart';

/// Shared platform channel names matching `BleProximityPlugin.kt` and
/// `BleProximityPlugin.swift`.
const MethodChannel bleProximityMethodChannel = MethodChannel(
  'com.openwanderer.wanderer/ble_proximity',
);

const EventChannel bleProximityEventChannel = EventChannel(
  'com.openwanderer.wanderer/ble_proximity/events',
);

/// Canonical GATT UUIDs & 16-bit ServiceData alias shared across Android, iOS, and Dart.
const String kTraseeMeshServiceUuid = '7a4e0001-8c3b-4f2d-9e1a-5b6c7d8e9f00';
const String kTraseeCharSyncReadUuid = '7a4e0002-8c3b-4f2d-9e1a-5b6c7d8e9f00';
const String kTraseeCharMeshIngressUuid =
    '7a4e0003-8c3b-4f2d-9e1a-5b6c7d8e9f00';
const int kTraseeServiceDataUuid16 = 0x7A4E;

/// Adaptive radio duty-cycle modes managed by [BleMeshEngine].
enum BleRadioMode {
  /// Completely off outside navigation when no SOS or group is active (`0%` battery).
  idleOff,

  /// Low-power listener during solo trail navigation (`~1.5%/h`), scanning for
  /// nearby offline SOS alerts and acting as a Store-and-Forward mule.
  passiveTrailGuard,

  /// Balanced advertise + scan cycle for active hiking groups (`~3%/h`).
  groupMeshNormal,

  /// High-power emergency SOS broadcast: starts with a 3-minute `100 ms`
  /// `LOW_LATENCY` burst (re-triggered for 60s on peer detection) and steps down
  /// automatically to `250 ms` sustained survival mode for 24h+ battery life.
  sosEmergencyActive,
}

/// Sub-phase of [BleRadioMode.sosEmergencyActive].
enum BleSosPowerPhase {
  inactive,
  burstLowLatency,
  sustainedSurvival,
}

/// Snapshot returned by native `getState`.
class BleNativeState {
  const BleNativeState({
    required this.supported,
    required this.adapterOn,
    required this.permissionsGranted,
    required this.running,
  });

  static const BleNativeState unsupported = BleNativeState(
    supported: false,
    adapterOn: false,
    permissionsGranted: false,
    running: false,
  );

  final bool supported;
  final bool adapterOn;
  final bool permissionsGranted;
  final bool running;

  factory BleNativeState.fromMap(Map<Object?, Object?>? map) {
    if (map == null) return unsupported;
    return BleNativeState(
      supported: map['supported'] == true,
      adapterOn: map['adapterOn'] == true,
      permissionsGranted: map['permissionsGranted'] == true,
      running: map['running'] == true,
    );
  }
}

/// Orchestrates dual-role BLE mesh transport, 4 adaptive radio power modes,
/// 256-slot packet deduplication, and jittered multi-hop relaying over
/// `com.openwanderer.wanderer/ble_proximity`.
class BleMeshEngine {
  BleMeshEngine({
    MethodChannel methodChannel = bleProximityMethodChannel,
    EventChannel eventChannel = bleProximityEventChannel,
    Stream<Object?>? eventStreamOverride,
    bool? isSupportedPlatform,
    BlePacketDeduplicator? deduplicator,
    String? Function(String clientSosId)? knownClaimHashLookup,
    math.Random? random,
    int Function()? nowEpochSec,
    this.sosBurstDuration = const Duration(minutes: 3),
    this.sosProximityReburstDuration = const Duration(seconds: 60),
    this.channelTimeout = const Duration(seconds: 5),
    this.onGroupPosCallback,
    this.onSosAlertCallback,
    this.onSosAckCallback,
    this.onSosResolvedCallback,
  }) : _methodChannel = methodChannel,
       _eventChannel = eventChannel,
       _eventStreamOverride = eventStreamOverride,
       _isSupportedPlatform =
           isSupportedPlatform ??
           (!kIsWeb && (Platform.isAndroid || Platform.isIOS)),
       _deduplicator =
           deduplicator ?? BlePacketDeduplicator(nowEpochSec: nowEpochSec),
       _knownClaimHashLookup = knownClaimHashLookup,
       _random = random ?? math.Random(),
       _nowEpochSec = nowEpochSec ?? _defaultNowSec;

  static const int minSosRelayJitterMs = 80;
  static const int maxSosRelayJitterMs = 350;
  static const int minGroupRelayJitterMs = 250;
  static const int maxGroupRelayJitterMs = 800;
  static const int _maxCachedRelayedFrames = 6;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Stream<Object?>? _eventStreamOverride;
  final bool _isSupportedPlatform;
  final BlePacketDeduplicator _deduplicator;
  final String? Function(String clientSosId)? _knownClaimHashLookup;
  final math.Random _random;
  final int Function() _nowEpochSec;

  final Duration sosBurstDuration;
  final Duration sosProximityReburstDuration;
  final Duration channelTimeout;

  final ValueChanged<BleGroupPosPacket>? onGroupPosCallback;
  final ValueChanged<BleSosAlertPacket>? onSosAlertCallback;
  final ValueChanged<BleSosAckPacket>? onSosAckCallback;
  final ValueChanged<BleSosResolvedPacket>? onSosResolvedCallback;

  final StreamController<BleGroupPosPacket> _groupPosCtrl =
      StreamController<BleGroupPosPacket>.broadcast();
  final StreamController<BleSosAlertPacket> _sosAlertCtrl =
      StreamController<BleSosAlertPacket>.broadcast();
  final StreamController<BleSosAckPacket> _sosAckCtrl =
      StreamController<BleSosAckPacket>.broadcast();
  final StreamController<BleSosResolvedPacket> _sosResolvedCtrl =
      StreamController<BleSosResolvedPacket>.broadcast();

  final ValueNotifier<bool> _adapterOn = ValueNotifier<bool>(false);
  final ValueNotifier<BleRadioMode> _radioMode = ValueNotifier<BleRadioMode>(
    BleRadioMode.idleOff,
  );
  final ValueNotifier<BleSosPowerPhase> _sosPowerPhase =
      ValueNotifier<BleSosPowerPhase>(BleSosPowerPhase.inactive);

  StreamSubscription<Object?>? _eventSubscription;
  Timer? _sosBurstTimer;
  Timer? _resolvedExpiryTimer;
  final Set<Timer> _pendingRelayTimers = <Timer>{};

  bool _nativeRunning = false;
  bool _disposed = false;

  GroupBleCipher? _groupCipher;
  String? _selfGroupMemberIdHex;

  Uint8List? _localGroupPosFrame;
  BleSosAlertPacket? _localSosAlert;
  Uint8List? _localSosAlertFrame;
  BleSosAckPacket? _localSosAck;
  Uint8List? _localSosAckFrame;
  BleSosResolvedPacket? _localSosResolved;
  Uint8List? _localSosResolvedFrame;

  final LinkedHashMap<String, Uint8List> _relayedSosFrames =
      LinkedHashMap<String, Uint8List>();
  final LinkedHashMap<String, Uint8List> _relayedAckFrames =
      LinkedHashMap<String, Uint8List>();
  final LinkedHashMap<String, Uint8List> _relayedGroupFrames =
      LinkedHashMap<String, Uint8List>();

  static int _defaultNowSec() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  bool get isSupportedPlatform => _isSupportedPlatform;

  BlePacketDeduplicator get deduplicator => _deduplicator;

  BleRadioMode get radioMode => _radioMode.value;

  BleSosPowerPhase get sosPowerPhase => _sosPowerPhase.value;

  ValueListenable<bool> get adapterOnListenable => _adapterOn;

  ValueListenable<BleRadioMode> get radioModeListenable => _radioMode;

  ValueListenable<BleSosPowerPhase> get sosPowerPhaseListenable =>
      _sosPowerPhase;

  Stream<BleGroupPosPacket> get onGroupPosReceived => _groupPosCtrl.stream;

  Stream<BleSosAlertPacket> get onSosAlertReceived => _sosAlertCtrl.stream;

  Stream<BleSosAckPacket> get onSosAckReceived => _sosAckCtrl.stream;

  Stream<BleSosResolvedPacket> get onSosResolvedReceived =>
      _sosResolvedCtrl.stream;

  String _nativeModeWireString() {
    switch (_radioMode.value) {
      case BleRadioMode.idleOff:
        return 'idle_off';
      case BleRadioMode.passiveTrailGuard:
        return 'passive_guard';
      case BleRadioMode.groupMeshNormal:
        return 'group_normal';
      case BleRadioMode.sosEmergencyActive:
        return _sosPowerPhase.value == BleSosPowerPhase.burstLowLatency
            ? 'sos_emergency'
            : 'group_normal';
    }
  }

  /// Queries native BLE support, adapter power state, and permission status.
  Future<BleNativeState> getState() async {
    if (!_isSupportedPlatform || _disposed) {
      return BleNativeState.unsupported;
    }
    try {
      final raw = await _methodChannel
          .invokeMethod<Map<Object?, Object?>>('getState')
          .timeout(channelTimeout);
      final parsed = BleNativeState.fromMap(raw);
      _adapterOn.value = parsed.adapterOn;
      return parsed;
    } catch (e) {
      debugPrint('BleMeshEngine.getState failed: $e');
      return BleNativeState.unsupported;
    }
  }

  /// Checks whether runtime Bluetooth permissions are already granted without
  /// triggering an OS permission dialog.
  Future<bool> checkPermissions() async {
    if (!_isSupportedPlatform || _disposed) return false;
    try {
      final granted = await _methodChannel
          .invokeMethod<bool>('checkPermissions')
          .timeout(channelTimeout);
      return granted ?? false;
    } catch (e) {
      debugPrint('BleMeshEngine.checkPermissions failed: $e');
      return false;
    }
  }

  /// Requests runtime Bluetooth permissions on Android 12+ / iOS CoreBluetooth.
  Future<bool> requestPermissions() async {
    if (!_isSupportedPlatform || _disposed) return false;
    try {
      final granted = await _methodChannel
          .invokeMethod<bool>(
            'requestPermissions',
          )
          .timeout(const Duration(seconds: 30));
      return granted ?? false;
    } catch (e) {
      debugPrint('BleMeshEngine.requestPermissions failed: $e');
      return false;
    }
  }

  /// Configures or clears the active group cipher (`HKDF-SHA256` from 6-char code)
  /// and self `memberId` (`12` hex chars) for `PKT_GROUP_POS` encryption/decryption.
  void configureGroupSession({
    String? groupCode,
    String? selfMemberIdHex,
  }) {
    final trimmed = groupCode?.trim().toUpperCase();
    if (trimmed == null || trimmed.isEmpty) {
      _groupCipher = null;
      _selfGroupMemberIdHex = null;
      _localGroupPosFrame = null;
      return;
    }
    _groupCipher = GroupBleCipher.fromGroupCode(trimmed);
    _selfGroupMemberIdHex = selfMemberIdHex?.trim().toLowerCase();
  }

  /// Transitions the BLE dual-role transport between the 4 radio power modes.
  Future<bool> setRadioMode(BleRadioMode mode) async {
    if (_disposed) return false;
    if (!_isSupportedPlatform) {
      _radioMode.value = BleRadioMode.idleOff;
      _sosPowerPhase.value = BleSosPowerPhase.inactive;
      return false;
    }

    if (mode == BleRadioMode.idleOff) {
      await stop();
      return true;
    }

    final previousMode = _radioMode.value;
    _radioMode.value = mode;

    if (mode == BleRadioMode.sosEmergencyActive) {
      if (previousMode != BleRadioMode.sosEmergencyActive ||
          _sosPowerPhase.value == BleSosPowerPhase.inactive) {
        _enterSosBurstPhase(sosBurstDuration);
      }
    } else {
      _cancelSosBurstTimer();
      _sosPowerPhase.value = BleSosPowerPhase.inactive;
    }

    _ensureEventSubscription();
    return _syncOrStartNative();
  }

  /// Stops scanning, advertising, and GATT server, returning to [BleRadioMode.idleOff].
  Future<void> stop() async {
    _cancelAllTimers();
    _radioMode.value = BleRadioMode.idleOff;
    _sosPowerPhase.value = BleSosPowerPhase.inactive;
    final wasRunning = _nativeRunning;
    _nativeRunning = false;

    final sub = _eventSubscription;
    _eventSubscription = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }

    if (!_isSupportedPlatform || !wasRunning) return;
    try {
      await _methodChannel
          .invokeMethod<Object?>('stopDualRole')
          .timeout(channelTimeout);
    } on MissingPluginException {
      // Safe in headless tests without a mock handler.
    } on PlatformException catch (e) {
      debugPrint('BleMeshEngine.stop failed: $e');
    } catch (e) {
      debugPrint('BleMeshEngine.stop error: $e');
    }
  }

  /// Encrypts and publishes the user's latest group position (`PKT_GROUP_POS`).
  Future<void> publishLocalGroupPosition(
    BleGroupPosPacket packet, {
    bool pushImmediately = true,
  }) async {
    if (_disposed || !_isSupportedPlatform) return;
    final cipher = _groupCipher;
    if (cipher == null) return;
    _selfGroupMemberIdHex ??= packet.memberIdHex.trim().toLowerCase();
    final encoded = packet.encode(cipher, random: _random);
    _localGroupPosFrame = encoded;
    if (_radioMode.value != BleRadioMode.idleOff) {
      await _syncOrStartNative(pushFrame: pushImmediately ? encoded : null);
    }
  }

  /// Publishes an active `PKT_SOS_ALERT` (`0x02`) and optionally switches
  /// immediately to [BleRadioMode.sosEmergencyActive].
  Future<void> publishLocalSosAlert(
    BleSosAlertPacket alert, {
    bool activateEmergencyMode = true,
  }) async {
    if (_disposed) return;
    _deduplicator.registerKnownSosCommitment(
      clientSosId: alert.clientSosId,
      sosClaimHash: alert.sosClaimHash,
      createdEpochSec: alert.createdEpochSec,
    );
    final prevResolved = _localSosResolved;
    if (prevResolved != null && prevResolved.clientSosId == alert.clientSosId) {
      _localSosResolved = null;
      _localSosResolvedFrame = null;
      _resolvedExpiryTimer?.cancel();
      _resolvedExpiryTimer = null;
    }

    final encoded = alert.encode();
    _localSosAlert = alert;
    _localSosAlertFrame = encoded;

    if (!_isSupportedPlatform) return;

    if (activateEmergencyMode &&
        _radioMode.value != BleRadioMode.sosEmergencyActive) {
      _radioMode.value = BleRadioMode.sosEmergencyActive;
      _enterSosBurstPhase(sosBurstDuration);
      _ensureEventSubscription();
    }
    if (_radioMode.value != BleRadioMode.idleOff) {
      await _syncOrStartNative(pushFrame: encoded);
    }
  }

  /// Clears the locally originated active SOS alert without emitting `0x04`.
  Future<void> clearLocalSosAlert() async {
    _localSosAlert = null;
    _localSosAlertFrame = null;
    if (!_disposed &&
        _isSupportedPlatform &&
        _radioMode.value != BleRadioMode.idleOff) {
      await _syncOrStartNative();
    }
  }

  /// Publishes a responder confirmation (`PKT_SOS_ACK`, `0x03`) back toward the victim.
  Future<void> publishLocalSosAck(BleSosAckPacket ack) async {
    if (_disposed) return;
    _deduplicator.evaluateSosAck(ack, nowEpochSec: _nowEpochSec());
    final encoded = ack.encode();
    _localSosAck = ack;
    _localSosAckFrame = encoded;

    if (!_isSupportedPlatform) return;
    if (_radioMode.value == BleRadioMode.idleOff) {
      await setRadioMode(BleRadioMode.passiveTrailGuard);
    }
    await _syncOrStartNative(pushFrame: encoded);
  }

  /// Broadcasts a preimage-authenticated `PKT_SOS_RESOLVED` (`0x04`) for
  /// [broadcastDuration] (3 minutes default) so nearby responders and mules
  /// cancel the alert and tombstone echoes for 6 hours.
  Future<void> publishLocalSosResolved(
    BleSosResolvedPacket resolved, {
    Duration broadcastDuration = const Duration(minutes: 3),
    BleRadioMode fallbackModeAfterBroadcast = BleRadioMode.passiveTrailGuard,
  }) async {
    if (_disposed) return;
    final id = resolved.clientSosId.trim().toLowerCase();

    final currentAlert = _localSosAlert;
    if (currentAlert != null &&
        currentAlert.clientSosId.trim().toLowerCase() == id) {
      _localSosAlert = null;
      _localSosAlertFrame = null;
    }
    _relayedSosFrames.remove(id);
    _relayedAckFrames.removeWhere((key, _) => key.startsWith('$id:'));

    _deduplicator.evaluateSosResolved(resolved, nowEpochSec: _nowEpochSec());

    final encoded = resolved.encode();
    _localSosResolved = resolved;
    _localSosResolvedFrame = encoded;

    _resolvedExpiryTimer?.cancel();
    _resolvedExpiryTimer = Timer(broadcastDuration, () {
      if (_disposed) return;
      final stillSame = _localSosResolved;
      if (stillSame != null &&
          stillSame.clientSosId.trim().toLowerCase() == id) {
        _localSosResolved = null;
        _localSosResolvedFrame = null;
      }
      if (_localSosAlert == null &&
          _radioMode.value == BleRadioMode.sosEmergencyActive) {
        unawaited(setRadioMode(fallbackModeAfterBroadcast));
      } else if (_radioMode.value != BleRadioMode.idleOff) {
        unawaited(_syncOrStartNative());
      }
    });

    if (!_isSupportedPlatform) return;
    if (_radioMode.value == BleRadioMode.idleOff) {
      await setRadioMode(fallbackModeAfterBroadcast);
    }
    await _syncOrStartNative(pushFrame: encoded);
  }

  List<Uint8List> _collectMailboxFrames() {
    final frames = <Uint8List>[];
    final sosFrame = _localSosAlertFrame;
    if (sosFrame != null) frames.add(sosFrame);

    final resFrame = _localSosResolvedFrame;
    if (resFrame != null) frames.add(resFrame);

    final ackFrame = _localSosAckFrame;
    if (ackFrame != null) frames.add(ackFrame);

    for (final f in _relayedSosFrames.values) {
      frames.add(f);
    }
    for (final f in _relayedAckFrames.values) {
      frames.add(f);
    }

    final grpFrame = _localGroupPosFrame;
    if (grpFrame != null) frames.add(grpFrame);

    for (final f in _relayedGroupFrames.values) {
      frames.add(f);
    }
    return frames;
  }

  Future<bool> _syncOrStartNative({Uint8List? pushFrame}) async {
    if (!_isSupportedPlatform ||
        _disposed ||
        _radioMode.value == BleRadioMode.idleOff) {
      return false;
    }

    final frames = _collectMailboxFrames();
    final syncBuffer = packSyncBuffer(frames);
    final syncDigest = computeSyncDigest8B(frames);
    final modeWire = _nativeModeWireString();

    final args = <String, Object?>{
      'mode': modeWire,
      'syncDigest': syncDigest,
      'syncBuffer': syncBuffer,
      if (pushFrame != null) 'pushFrame': pushFrame,
    };

    try {
      if (!_nativeRunning) {
        final ok = await _methodChannel
            .invokeMethod<bool>('startDualRole', args)
            .timeout(channelTimeout);
        _nativeRunning = ok ?? true;
        return _nativeRunning;
      } else {
        await _methodChannel
            .invokeMethod<Object?>('updateLocalPayloads', args)
            .timeout(channelTimeout);
        return true;
      }
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('BleMeshEngine native sync failed: $e');
      return false;
    } catch (e) {
      debugPrint('BleMeshEngine native sync error: $e');
      return false;
    }
  }

  void _enterSosBurstPhase(Duration duration) {
    _sosBurstTimer?.cancel();
    final changed = _sosPowerPhase.value != BleSosPowerPhase.burstLowLatency;
    _sosPowerPhase.value = BleSosPowerPhase.burstLowLatency;
    if (changed && _nativeRunning) {
      unawaited(_syncOrStartNative());
    }
    _sosBurstTimer = Timer(duration, () {
      _sosBurstTimer = null;
      if (_disposed || _radioMode.value != BleRadioMode.sosEmergencyActive) {
        return;
      }
      _sosPowerPhase.value = BleSosPowerPhase.sustainedSurvival;
      if (_nativeRunning) {
        unawaited(_syncOrStartNative());
      }
    });
  }

  void _cancelSosBurstTimer() {
    _sosBurstTimer?.cancel();
    _sosBurstTimer = null;
  }

  void _cancelAllTimers() {
    _cancelSosBurstTimer();
    _resolvedExpiryTimer?.cancel();
    _resolvedExpiryTimer = null;
    for (final t in _pendingRelayTimers) {
      t.cancel();
    }
    _pendingRelayTimers.clear();
  }

  void _ensureEventSubscription() {
    if (_eventSubscription != null || !_isSupportedPlatform || _disposed) {
      return;
    }
    final stream =
        _eventStreamOverride ?? _eventChannel.receiveBroadcastStream();
    _eventSubscription = stream.listen(
      _handleNativeEvent,
      onError: (Object error) {
        debugPrint('BleMeshEngine event stream error: $error');
      },
    );
  }

  /// Processes a raw event map from the native `EventChannel`.
  void handleRawNativeEventForTest(Map<Object?, Object?> event) {
    _handleNativeEvent(event);
  }

  void _handleNativeEvent(Object? rawEvent) {
    if (_disposed || rawEvent is! Map) return;
    final event = rawEvent;
    final type = event['type']?.toString();
    if (type == null) return;

    switch (type) {
      case 'adapterState':
        final isOn = event['adapterOn'] == true;
        _adapterOn.value = isOn;

      case 'frame':
      case 'packet':
        final bytes = _extractBytes(event['bytes']);
        if (bytes == null || bytes.isEmpty) return;
        final rssi = _extractInt(event['rssi']);
        final peerId = event['peerId']?.toString();
        _onPeerActivityDetected();
        _processIncomingFrame(bytes, rssi: rssi, peerId: peerId);

      case 'syncBuffer':
        final bytes = _extractBytes(event['bytes']);
        if (bytes == null || bytes.isEmpty) return;
        final rssi = _extractInt(event['rssi']);
        final peerId = event['peerId']?.toString();
        final frames = unpackSyncBuffer(bytes);
        if (frames.isNotEmpty) {
          _onPeerActivityDetected();
        }
        for (final f in frames) {
          _processIncomingFrame(f, rssi: rssi, peerId: peerId);
        }

      case 'error':
        debugPrint('BleMeshEngine native BLE error: ${event['message']}');
    }
  }

  void _onPeerActivityDetected() {
    if (_radioMode.value == BleRadioMode.sosEmergencyActive &&
        _sosPowerPhase.value == BleSosPowerPhase.sustainedSurvival) {
      _enterSosBurstPhase(sosProximityReburstDuration);
    }
  }

  void _processIncomingFrame(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    final pktType = inspectBleFrameType(raw);
    if (pktType == null) return;

    switch (pktType) {
      case BlePacketType.groupPos:
        _handleIncomingGroupPos(raw, rssi: rssi, peerId: peerId);
      case BlePacketType.sosAlert:
        _handleIncomingSosAlert(raw, rssi: rssi, peerId: peerId);
      case BlePacketType.sosAck:
        _handleIncomingSosAck(raw, rssi: rssi, peerId: peerId);
      case BlePacketType.sosResolved:
        _handleIncomingSosResolved(raw, rssi: rssi, peerId: peerId);
    }
  }

  void _handleIncomingGroupPos(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    final cipher = _groupCipher;
    if (cipher != null) {
      final decoded = BleGroupPosPacket.decode(
        raw,
        cipher: cipher,
        rssi: rssi,
        peerId: peerId,
      );
      if (decoded != null) {
        final selfId = _selfGroupMemberIdHex;
        if (selfId != null && decoded.memberIdHex == selfId) {
          return;
        }
        final decision = _deduplicator.evaluateGroupPos(
          decoded,
          nowEpochSec: _nowEpochSec(),
        );
        if (!decision.accepted) return;

        if (!_groupPosCtrl.isClosed) {
          _groupPosCtrl.add(decoded);
        }
        onGroupPosCallback?.call(decoded);

        if (decision.shouldRelay) {
          final relayed = decrementTtlForRelay(raw);
          if (relayed != null) {
            _scheduleRelay(
              relayed,
              isSosPriority: false,
              cacheTarget: _relayedGroupFrames,
              cacheKey: decoded.memberIdHex,
            );
          }
        }
        return;
      }
    }

    // Opaque relay for another hiking group's encrypted beacon when active mesh is running.
    if (_radioMode.value == BleRadioMode.groupMeshNormal ||
        _radioMode.value == BleRadioMode.sosEmergencyActive) {
      if (_deduplicator.shouldAcceptRawGroupFrame(
        raw,
        nowEpochSec: _nowEpochSec(),
      )) {
        final relayed = decrementTtlForRelay(raw);
        if (relayed != null) {
          _scheduleRelay(relayed, isSosPriority: false);
        }
      }
    }
  }

  void _handleIncomingSosAlert(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    final decoded = BleSosAlertPacket.decode(raw, rssi: rssi, peerId: peerId);
    if (decoded == null) return;

    final mySos = _localSosAlert;
    if (mySos != null && mySos.clientSosId == decoded.clientSosId) {
      return;
    }

    final decision = _deduplicator.evaluateSosAlert(
      decoded,
      nowEpochSec: _nowEpochSec(),
    );
    if (!decision.accepted) return;

    if (!_sosAlertCtrl.isClosed) {
      _sosAlertCtrl.add(decoded);
    }
    onSosAlertCallback?.call(decoded);

    if (decision.shouldRelay) {
      final relayed = decrementTtlForRelay(raw);
      if (relayed != null) {
        _scheduleRelay(
          relayed,
          isSosPriority: true,
          cacheTarget: _relayedSosFrames,
          cacheKey: decoded.clientSosId,
        );
      }
    }
  }

  void _handleIncomingSosAck(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    final decoded = BleSosAckPacket.decode(raw, rssi: rssi, peerId: peerId);
    if (decoded == null) return;

    final myAck = _localSosAck;
    if (myAck != null &&
        myAck.clientSosId == decoded.clientSosId &&
        myAck.responderIdHex == decoded.responderIdHex &&
        myAck.ackFlags == decoded.ackFlags) {
      return;
    }

    final decision = _deduplicator.evaluateSosAck(
      decoded,
      nowEpochSec: _nowEpochSec(),
    );
    if (!decision.accepted) return;

    if (!_sosAckCtrl.isClosed) {
      _sosAckCtrl.add(decoded);
    }
    onSosAckCallback?.call(decoded);

    final mySos = _localSosAlert;
    final reachedDestinationVictim =
        mySos != null && mySos.clientSosId == decoded.clientSosId;

    if (decision.shouldRelay && !reachedDestinationVictim) {
      final relayed = decrementTtlForRelay(raw);
      if (relayed != null) {
        _scheduleRelay(
          relayed,
          isSosPriority: true,
          cacheTarget: _relayedAckFrames,
          cacheKey: '${decoded.clientSosId}:${decoded.responderIdHex}',
        );
      }
    }
  }

  void _handleIncomingSosResolved(
    Uint8List raw, {
    int? rssi,
    String? peerId,
  }) {
    final decoded = BleSosResolvedPacket.decode(
      raw,
      rssi: rssi,
      peerId: peerId,
    );
    if (decoded == null) return;

    final myRes = _localSosResolved;
    if (myRes != null && myRes.clientSosId == decoded.clientSosId) {
      return;
    }

    final knownHash = _knownClaimHashLookup?.call(decoded.clientSosId);
    final decision = _deduplicator.evaluateSosResolved(
      decoded,
      expectedClaimHashHex: knownHash,
      nowEpochSec: _nowEpochSec(),
    );
    if (!decision.accepted) return;

    // Evict resolved SOS alert and ACKs from our Store-and-Forward BLE mailbox.
    _relayedSosFrames.remove(decoded.clientSosId);
    _relayedAckFrames.removeWhere(
      (k, _) => k.startsWith('${decoded.clientSosId}:'),
    );

    if (!_sosResolvedCtrl.isClosed) {
      _sosResolvedCtrl.add(decoded);
    }
    onSosResolvedCallback?.call(decoded);

    if (decision.shouldRelay) {
      final relayed = decrementTtlForRelay(raw);
      if (relayed != null) {
        _scheduleRelay(
          relayed,
          isSosPriority: true,
          cacheTarget: _relayedSosFrames,
          cacheKey: decoded.clientSosId,
        );
      }
    }
  }

  void _scheduleRelay(
    Uint8List relayedFrame, {
    required bool isSosPriority,
    LinkedHashMap<String, Uint8List>? cacheTarget,
    String? cacheKey,
  }) {
    if (_disposed || _radioMode.value == BleRadioMode.idleOff) return;

    final minMs = isSosPriority ? minSosRelayJitterMs : minGroupRelayJitterMs;
    final maxMs = isSosPriority ? maxSosRelayJitterMs : maxGroupRelayJitterMs;
    final delayMs = minMs + _random.nextInt(maxMs - minMs + 1);

    late final Timer timer;
    timer = Timer(Duration(milliseconds: delayMs), () {
      _pendingRelayTimers.remove(timer);
      if (_disposed || _radioMode.value == BleRadioMode.idleOff) return;
      if (cacheTarget != null && cacheKey != null) {
        cacheTarget.remove(cacheKey);
        cacheTarget[cacheKey] = relayedFrame;
        while (cacheTarget.length > _maxCachedRelayedFrames) {
          cacheTarget.remove(cacheTarget.keys.first);
        }
      }
      unawaited(_syncOrStartNative(pushFrame: relayedFrame));
    });
    _pendingRelayTimers.add(timer);
  }

  Uint8List? _extractBytes(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  }

  int? _extractInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.isFinite ? raw.round() : null;
    return null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _groupPosCtrl.close();
    await _sosAlertCtrl.close();
    await _sosAckCtrl.close();
    await _sosResolvedCtrl.close();
    _adapterOn.dispose();
    _radioMode.dispose();
    _sosPowerPhase.dispose();
  }
}
