class CompassRateConfig {
  const CompassRateConfig({
    required this.sensorEnabled,
    required this.samplingPeriod,
    required this.deadbandDeg,
  });

  final bool sensorEnabled;
  final Duration samplingPeriod;
  final double deadbandDeg;

  static const CompassRateConfig disabled = CompassRateConfig(
    sensorEnabled: false,
    samplingPeriod: Duration(milliseconds: 250),
    deadbandDeg: 5.0,
  );

  @override
  bool operator ==(Object other) =>
      other is CompassRateConfig &&
      other.sensorEnabled == sensorEnabled &&
      other.samplingPeriod == samplingPeriod &&
      other.deadbandDeg == deadbandDeg;

  @override
  int get hashCode => Object.hash(sensorEnabled, samplingPeriod, deadbandDeg);
}

/// Resolves the optimal IMU magnetometer/gyroscope cadence for the current
/// navigation visibility, camera mode, motion state, and battery saver setting.
CompassRateConfig resolveCompassRatePolicy({
  required bool uiVisible,
  required bool headingUp,
  required bool isStationary,
  required bool expeditionMode,
}) {
  if (!uiVisible || isStationary) {
    return CompassRateConfig.disabled;
  }
  if (expeditionMode) {
    if (!headingUp) {
      return CompassRateConfig.disabled;
    }
    return const CompassRateConfig(
      sensorEnabled: true,
      samplingPeriod: Duration(milliseconds: 250),
      deadbandDeg: 2.5,
    );
  }
  if (headingUp) {
    return const CompassRateConfig(
      sensorEnabled: true,
      samplingPeriod: Duration(milliseconds: 66),
      deadbandDeg: 0.3,
    );
  }
  return const CompassRateConfig(
    sensorEnabled: true,
    samplingPeriod: Duration(milliseconds: 200),
    deadbandDeg: 1.5,
  );
}

/// Caps platform-channel `moveCamera` updates during position tweens to ~30 Hz
/// on 120 Hz ProMotion / LTPO displays while guaranteeing the final frame lands.
class CameraPushThrottle {
  CameraPushThrottle({
    this.minInterval = const Duration(milliseconds: 33),
  });

  final Duration minInterval;
  Duration? _lastPushed;

  void reset() => _lastPushed = null;

  bool shouldPush(Duration elapsed, {bool isFinalFrame = false}) {
    if (isFinalFrame) {
      _lastPushed = elapsed;
      return true;
    }
    final prev = _lastPushed;
    if (prev == null || (elapsed - prev) >= minInterval || elapsed < prev) {
      _lastPushed = elapsed;
      return true;
    }
    return false;
  }
}
