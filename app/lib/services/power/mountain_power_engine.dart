import 'package:maplibre/maplibre.dart' as ml;
import 'package:wanderer/services/power/mountain_motion_channel.dart';

enum MountainPowerState {
  movingActive,
  scrambleGrace,
  stationaryCabanaSleep,
  expeditionMoving,
  sosEmergencyMax,
}

enum MountainGpsTier {
  sosMax2m,
  foreground3m,
  background5m,
  expedition12m,
  stationarySleep,
}

/// 4-State Mountain Power State Machine coordinating GNSS accuracy/distanceFilter,
/// hardware accelerometer/DSP step-wake gating, Expedition Mode, and mandatory
/// SOS max-precision preemption.
class MountainPowerEngine {
  MountainPowerEngine({
    DateTime Function()? clock,
    this.stationarySleepThreshold = const Duration(seconds: 90),
    this.statsFreezeGrace = const Duration(seconds: 15),
    this.stationaryAnchorRadiusMeters = 8.5,
    this.movingSpeedThresholdMps = 0.4,
    this.autoExpeditionBatteryPercent = 15,
    this.onStateChanged,
    this.onGpsTierChanged,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration stationarySleepThreshold;
  final Duration statsFreezeGrace;
  final double stationaryAnchorRadiusMeters;
  final double movingSpeedThresholdMps;
  final int autoExpeditionBatteryPercent;
  final void Function(MountainPowerState state)? onStateChanged;
  final void Function(MountainGpsTier tier)? onGpsTierChanged;

  MountainPowerState _state = MountainPowerState.movingActive;
  MountainGpsTier _gpsTier = MountainGpsTier.foreground3m;

  bool _uiForeground = true;
  bool _userExpeditionMode = false;
  bool _lowBatteryAutoExpedition = false;
  bool _sosActive = false;

  bool _hardwareMoving = true;
  DateTime? _lastMovingAt;
  DateTime? _stillSince;
  ml.Geographic? _stillAnchorPos;
  bool _disposed = false;

  MountainPowerState get state => _state;
  MountainGpsTier get gpsTier => _gpsTier;
  bool get isStationarySleep =>
      _state == MountainPowerState.stationaryCabanaSleep && !_sosActive;
  bool get effectiveExpeditionMode =>
      !_sosActive && (_userExpeditionMode || _lowBatteryAutoExpedition);

  /// True once the hiker has been genuinely motionless for at least
  /// [statsFreezeGrace] (`15s`), freezing moving-time & jitter accumulation
  /// even before the `90s` deep GNSS sleep engages.
  bool get isStatsFrozen {
    if (_sosActive) return false;
    if (_state == MountainPowerState.stationaryCabanaSleep) return true;
    final since = _stillSince;
    if (since == null) return false;
    return _clock().difference(since) >= statsFreezeGrace;
  }

  void setUiForeground(bool foreground) {
    if (_disposed || _uiForeground == foreground) return;
    _uiForeground = foreground;
    _recompute();
  }

  void setExpeditionMode(bool enabled) {
    if (_disposed || _userExpeditionMode == enabled) return;
    _userExpeditionMode = enabled;
    _recompute();
  }

  /// Mandatory safety preemption: active own SOS or responding to a nearby SOS
  /// immediately forces maximum 2m GPS precision and disables stationary sleep.
  void setSosActive(bool active) {
    if (_disposed || _sosActive == active) return;
    _sosActive = active;
    if (active) {
      _stillSince = null;
      _stillAnchorPos = null;
    }
    _recompute();
  }

  void ingestBatterySnapshot(MountainBatterySnapshot snapshot) {
    if (_disposed) return;
    final shouldAuto =
        snapshot.osLowPowerMode ||
        snapshot.batteryPercent <= autoExpeditionBatteryPercent;
    if (_lowBatteryAutoExpedition == shouldAuto) return;
    _lowBatteryAutoExpedition = shouldAuto;
    _recompute();
  }

  void ingestMotionEvent(MountainMotionEvent event) {
    if (_disposed) return;
    final now = _clock();
    if (event.kind == MountainMotionEventKind.stepWake) {
      _hardwareMoving = true;
      _lastMovingAt = now;
      _stillSince = null;
      _stillAnchorPos = null;
      _recompute(now: now);
      return;
    }
    if (event.kind == MountainMotionEventKind.battery &&
        event.batteryPercent != null) {
      ingestBatterySnapshot(
        MountainBatterySnapshot(
          batteryPercent: event.batteryPercent!,
          osLowPowerMode: event.osLowPowerMode ?? false,
        ),
      );
      return;
    }

    _hardwareMoving = event.isMovingHardware;
    if (event.isMovingHardware) {
      _lastMovingAt = now;
      _stillSince = null;
      _stillAnchorPos = null;
    } else {
      _stillSince ??= _lastMovingAt ?? now;
    }
    _recompute(now: now);
  }

  void ingestGpsFix({
    required double lat,
    required double lon,
    required double speedMps,
    required double accuracyM,
  }) {
    if (_disposed || !lat.isFinite || !lon.isFinite) return;
    final now = _clock();
    final pos = ml.Geographic(lat: lat, lon: lon);
    final cleanSpeed = speedMps.isFinite && speedMps >= 0 ? speedMps : 0.0;

    // Guard against indoor cabană multipath spikes: if hardware IMU explicitly
    // reports motionless and fix accuracy is mediocre (> 14m), require real
    // net displacement past the anchor radius before breaking stillness.
    final likelyMultipathSpike = !_hardwareMoving && accuracyM > 14.0;
    final speedSaysMoving =
        cleanSpeed >= movingSpeedThresholdMps && !likelyMultipathSpike;

    final anchor = _stillAnchorPos;
    final effectiveAnchorRadius = accuracyM.isFinite && accuracyM > 8.0
        ? (stationaryAnchorRadiusMeters + 0.35 * accuracyM).clamp(8.5, 22.0)
        : stationaryAnchorRadiusMeters;
    final displacedFromAnchor =
        anchor != null &&
        ml.SphericalGreatCircle(anchor).distanceTo(pos) > effectiveAnchorRadius;

    if (speedSaysMoving || displacedFromAnchor) {
      _lastMovingAt = now;
      _stillSince = null;
      _stillAnchorPos = null;
      _hardwareMoving = true;
    } else {
      _stillSince ??= _lastMovingAt ?? now;
      _stillAnchorPos ??= pos;
    }
    _recompute(now: now);
  }

  void evaluateTick() {
    if (_disposed) return;
    _recompute(now: _clock());
  }

  void _recompute({DateTime? now}) {
    final ts = now ?? _clock();
    final MountainPowerState nextState;
    final MountainGpsTier nextTier;

    if (_sosActive) {
      nextState = MountainPowerState.sosEmergencyMax;
      nextTier = MountainGpsTier.sosMax2m;
    } else {
      final stillElapsed =
          _stillSince == null ? Duration.zero : ts.difference(_stillSince!);
      if (_stillSince != null && stillElapsed >= stationarySleepThreshold) {
        nextState = MountainPowerState.stationaryCabanaSleep;
        nextTier = MountainGpsTier.stationarySleep;
      } else if (_stillSince != null) {
        nextState = MountainPowerState.scrambleGrace;
        nextTier = _movingTier();
      } else if (effectiveExpeditionMode) {
        nextState = MountainPowerState.expeditionMoving;
        nextTier = MountainGpsTier.expedition12m;
      } else {
        nextState = MountainPowerState.movingActive;
        nextTier = _movingTier();
      }
    }

    final stateChanged = nextState != _state;
    final tierChanged = nextTier != _gpsTier;
    _state = nextState;
    _gpsTier = nextTier;

    if (tierChanged) {
      onGpsTierChanged?.call(nextTier);
    }
    if (stateChanged) {
      onStateChanged?.call(nextState);
    }
  }

  MountainGpsTier _movingTier() {
    if (effectiveExpeditionMode) return MountainGpsTier.expedition12m;
    return _uiForeground
        ? MountainGpsTier.foreground3m
        : MountainGpsTier.background5m;
  }

  void dispose() {
    _disposed = true;
  }
}
