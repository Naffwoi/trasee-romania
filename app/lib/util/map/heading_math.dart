import 'dart:math' as math;

const double _degToRad = math.pi / 180.0;
const double _radToDeg = 180.0 / math.pi;

/// Normalizes [deg] into the half-open interval `[0.0, 360.0)`.
double normalizeHeading(double deg) {
  if (!deg.isFinite) return 0.0;
  final mod = deg % 360.0;
  if (mod < 0) {
    final wrapped = mod + 360.0;
    return wrapped >= 360.0 ? 0.0 : wrapped;
  }
  return (mod == 0 || mod >= 360.0) ? 0.0 : mod;
}

/// Shortest signed angular delta in `(-180.0, 180.0]` from [fromDeg] to [toDeg].
double shortestAngleDelta(double fromDeg, double toDeg) {
  final diff = ((toDeg - fromDeg + 540.0) % 360.0) - 180.0;
  return diff == -180.0 ? 180.0 : diff;
}

/// Interpolates along the shortest arc between [fromDeg] and [toDeg].
double lerpBearing(double fromDeg, double toDeg, double t) {
  return normalizeHeading(fromDeg + shortestAngleDelta(fromDeg, toDeg) * t);
}

/// Maps compass/heading accuracy in degrees to the flashlight cone's half-angle.
double coneHalfAngleFromAccuracy(double? accuracyDeg) {
  if (accuracyDeg == null || accuracyDeg.isNaN) return 25.0;
  if (accuracyDeg < 0 || accuracyDeg > 35.0) return 45.0;
  if (accuracyDeg > 15.0) return 35.0;
  return 25.0;
}

/// Circular low-pass filter on the unit circle with deadband suppression to
/// avoid 359 <-> 0 wraparound jumps and jitter while stationary.
class CircularHeadingFilter {
  CircularHeadingFilter({
    this.alpha = 0.22,
    this.deadbandDeg = 0.5,
  });

  final double alpha;
  final double deadbandDeg;

  double? _sinSum;
  double? _cosSum;
  double? _lastEmitted;

  double? get current => _lastEmitted;

  void reset() {
    _sinSum = null;
    _cosSum = null;
    _lastEmitted = null;
  }

  double? update(double rawDeg) {
    if (!rawDeg.isFinite) return null;
    final normalized = normalizeHeading(rawDeg);
    final rad = normalized * _degToRad;
    final s = math.sin(rad);
    final c = math.cos(rad);

    if (_sinSum == null || _cosSum == null || _lastEmitted == null) {
      _sinSum = s;
      _cosSum = c;
      _lastEmitted = normalized;
      return _lastEmitted;
    }

    _sinSum = alpha * s + (1.0 - alpha) * _sinSum!;
    _cosSum = alpha * c + (1.0 - alpha) * _cosSum!;

    final smoothed = normalizeHeading(
      math.atan2(_sinSum!, _cosSum!) * _radToDeg,
    );
    if (shortestAngleDelta(_lastEmitted!, smoothed).abs() < deadbandDeg) {
      return null;
    }
    _lastEmitted = smoothed;
    return smoothed;
  }
}
