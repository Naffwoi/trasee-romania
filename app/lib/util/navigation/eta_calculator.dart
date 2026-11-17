import 'dart:math' as math;

import 'package:gpx/gpx.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/gpx/conversion.dart'
    show hasUsablePosition, parseGpxElevation;
import 'package:wanderer/util/gpx/gpx.dart';

/// Raw track sample along a GPX trail with smoothed elevation and local grade.
class NavTrackPoint {
  const NavTrackPoint({
    required this.lat,
    required this.lon,
    required this.ele,
    required this.distanceM,
    required this.gradePct,
  });

  final double lat;
  final double lon;
  final double ele;
  final double distanceM;
  final double gradePct;

  Geographic get geographic => Geographic(lat: lat, lon: lon);
}

/// Upcoming significant summit along the trail.
class EtaPeak {
  const EtaPeak({
    required this.ele,
    required this.distanceAheadM,
    required this.gainAheadM,
  });

  final double ele;
  final double distanceAheadM;
  final double gainAheadM;
}

/// Live ETA, remaining distance/climb, and next summit snapshot.
class EtaSnapshot {
  const EtaSnapshot({
    required this.remainingDistanceM,
    required this.remainingSeconds,
    required this.arrivalTimeFormatted,
    required this.remainingAscentM,
    required this.remainingDescentM,
    required this.currentEleM,
    required this.currentGradePct,
    required this.progressRatio,
    required this.nextPeak,
    required this.paceFactor,
  });

  final double remainingDistanceM;
  final int remainingSeconds;
  final String arrivalTimeFormatted;
  final double remainingAscentM;
  final double remainingDescentM;
  final double currentEleM;
  final double currentGradePct;
  final double progressRatio;
  final EtaPeak? nextPeak;
  final double paceFactor;

  Duration get remainingDuration => Duration(seconds: remainingSeconds);
}

/// Tobler's hiking function (km/h) or mountain-cycling equivalent for a given
/// fractional slope `dEle / dDist`.
double toblerSpeedKmh(double slopeRatio, {bool isCycling = false}) {
  if (!slopeRatio.isFinite) {
    return isCycling ? 14.0 : 4.5;
  }
  if (isCycling) {
    return (18.0 * math.exp(-2.8 * (slopeRatio + 0.03).abs())).clamp(2.0, 32.0);
  }
  return (6.0 * math.exp(-3.5 * (slopeRatio + 0.05).abs())).clamp(0.7, 7.5);
}

/// Normalized clockwise bearing in `[0, 360)` from `(lat1, lon1)` to `(lat2, lon2)`.
double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  final raw = SphericalGreatCircle(
    Geographic(lat: lat1, lon: lon1),
  ).initialBearingTo(Geographic(lat: lat2, lon: lon2));
  if (!raw.isFinite) return 0.0;
  final mod = raw % 360.0;
  return mod < 0 ? mod + 360.0 : (mod >= 360.0 ? 0.0 : mod);
}

/// Localized 8-wind compass direction abbreviation (`ro` uses `N, NE, E, SE, S, SV, V, NV`).
String cardinalDirection(double bearingDeg, {String localeCode = 'ro'}) {
  final norm = ((bearingDeg % 360.0) + 360.0) % 360.0;
  final idx = ((norm + 22.5) / 45.0).floor() % 8;
  final isRo = localeCode.toLowerCase().startsWith('ro');
  const roDirs = ['N', 'NE', 'E', 'SE', 'S', 'SV', 'V', 'NV'];
  const enDirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return isRo ? roDirs[idx] : enDirs[idx];
}

/// Extracts track points from [gpx] preserving the exact raw cumulative-metre
/// axis used by `buildRawTrackPoints` when elevations exist, and gracefully
/// falling back to `0.0` elevation when the GPX carries no `<ele>` tags.
List<NavTrackPoint> extractNavTrackPoints(Gpx gpx) {
  final allWpts = gpx.allWaypoints.where(hasUsablePosition).toList();
  if (allWpts.isEmpty) return const [];

  final withEle = allWpts
      .where((w) => parseGpxElevation(w.ele) != null)
      .toList();
  final sourceWpts = withEle.length >= 2 ? withEle : allWpts;

  final n = sourceWpts.length;
  final lats = List<double>.filled(n, 0.0);
  final lons = List<double>.filled(n, 0.0);
  final rawEles = List<double>.filled(n, 0.0);
  final dists = List<double>.filled(n, 0.0);

  for (var i = 0; i < n; i++) {
    final w = sourceWpts[i];
    lats[i] = w.lat!;
    lons[i] = w.lon!;
    rawEles[i] = parseGpxElevation(w.ele) ?? 0.0;
    if (i > 0) {
      final hop = SphericalGreatCircle(
        Geographic(lat: lats[i - 1], lon: lons[i - 1]),
      ).distanceTo(Geographic(lat: lats[i], lon: lons[i]));
      dists[i] = dists[i - 1] + (hop.isFinite ? hop : 0.0);
    }
  }

  // 5-point moving average on elevation for clean slope/climb metrics without
  // distorting the raw cumulative distance axis.
  final smoothEles = List<double>.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    final start = math.max(0, i - 2);
    final end = math.min(n - 1, i + 2);
    var sum = 0.0;
    var count = 0;
    for (var j = start; j <= end; j++) {
      sum += rawEles[j];
      count++;
    }
    smoothEles[i] = count > 0 ? sum / count : rawEles[i];
  }

  final result = List<NavTrackPoint>.generate(n, (i) {
    double gradePct = 0.0;
    if (i > 0) {
      final dDist = dists[i] - dists[i - 1];
      if (dDist > 0.5) {
        gradePct = ((smoothEles[i] - smoothEles[i - 1]) / dDist) * 100.0;
      }
    } else if (n > 1) {
      final dDist = dists[1] - dists[0];
      if (dDist > 0.5) {
        gradePct = ((smoothEles[1] - smoothEles[0]) / dDist) * 100.0;
      }
    }
    return NavTrackPoint(
      lat: lats[i],
      lon: lons[i],
      ele: smoothEles[i],
      distanceM: dists[i],
      gradePct: gradePct,
    );
  }, growable: false);

  return result;
}

class _PeakEntry {
  const _PeakEntry({required this.distanceM, required this.ele});

  final double distanceM;
  final double ele;
}

/// Computes live Tobler-adjusted ETA, remaining ascent/descent, and next summit.
class EtaCalculator {
  EtaCalculator._({
    required List<NavTrackPoint> points,
    required this.isCycling,
  }) : _points = points {
    final n = _points.length;
    _cumBaseSeconds = List<double>.filled(n, 0.0);
    _cumAscentM = List<double>.filled(n, 0.0);
    _cumDescentM = List<double>.filled(n, 0.0);

    for (var i = 1; i < n; i++) {
      final prev = _points[i - 1];
      final curr = _points[i];
      final dDist = math.max(0.0, curr.distanceM - prev.distanceM);
      final dEle = curr.ele - prev.ele;
      final slope = dDist > 0.5 ? dEle / dDist : 0.0;
      final speedMs = toblerSpeedKmh(slope, isCycling: isCycling) / 3.6;

      _cumBaseSeconds[i] =
          _cumBaseSeconds[i - 1] + (dDist > 0 ? dDist / speedMs : 0.0);
      _cumAscentM[i] = _cumAscentM[i - 1] + (dEle > 0 ? dEle : 0.0);
      _cumDescentM[i] = _cumDescentM[i - 1] + (dEle < 0 ? -dEle : 0.0);
    }

    _peaks = _detectPeaks(_points);
  }

  factory EtaCalculator.fromGpx(Gpx gpx, {bool isCycling = false}) {
    return EtaCalculator._(
      points: extractNavTrackPoints(gpx),
      isCycling: isCycling,
    );
  }

  factory EtaCalculator.fromPoints(
    List<NavTrackPoint> points, {
    bool isCycling = false,
  }) {
    return EtaCalculator._(points: points, isCycling: isCycling);
  }

  final List<NavTrackPoint> _points;
  final bool isCycling;

  late final List<double> _cumBaseSeconds;
  late final List<double> _cumAscentM;
  late final List<double> _cumDescentM;
  late final List<_PeakEntry> _peaks;

  double _paceFactor = 1.0;
  double? _lastRecordedAtd;
  DateTime? _lastRecordedTime;

  double get paceFactor => _paceFactor;
  double get totalDistanceM => _points.isEmpty ? 0.0 : _points.last.distanceM;
  List<NavTrackPoint> get points => _points;

  /// Base (pace-1.0) seconds from trail start to [alongTrackM].
  double baseSecondsAt(double alongTrackM) =>
      _interpolateSeries(_cumBaseSeconds, alongTrackM);

  /// Updates the EMA pace multiplier (`alpha = 0.2`, clamped `[0.55, 1.85]`)
  /// whenever the hiker moves at least 15 m over a positive interval.
  void recordProgress(double alongTrackM, DateTime timestamp) {
    if (_points.length < 2) return;
    final clamped = alongTrackM.clamp(0.0, totalDistanceM);
    if (_lastRecordedAtd != null && _lastRecordedTime != null) {
      final deltaDist = clamped - _lastRecordedAtd!;
      final deltaSec =
          timestamp.difference(_lastRecordedTime!).inMilliseconds / 1000.0;
      if (deltaDist >= 15.0 && deltaSec > 0.0) {
        final expectedBaseSec =
            baseSecondsAt(clamped) - baseSecondsAt(_lastRecordedAtd!);
        if (expectedBaseSec > 1.0) {
          final instantPace = (deltaSec / expectedBaseSec).clamp(0.55, 1.85);
          _paceFactor = (0.2 * instantPace + 0.8 * _paceFactor).clamp(
            0.55,
            1.85,
          );
        }
        _lastRecordedAtd = clamped;
        _lastRecordedTime = timestamp;
      } else if (deltaDist < 0.0) {
        // Re-anchor if user reversed or rejoined earlier on the trail.
        _lastRecordedAtd = clamped;
        _lastRecordedTime = timestamp;
      }
      return;
    }

    _lastRecordedAtd = clamped;
    _lastRecordedTime = timestamp;
  }

  /// Computes a live [EtaSnapshot] for [alongTrackM], optionally folding in an
  /// active off-trail reroute leg from the user's current position to
  /// [rejoinAlongTrackM].
  EtaSnapshot compute(
    double alongTrackM, {
    DateTime? now,
    double? offTrailDistanceM,
    int? offTrailDurationSec,
    double? offTrailAscentM,
    double? rejoinAlongTrackM,
  }) {
    final effectiveNow = now ?? DateTime.now();
    if (_points.length < 2 || totalDistanceM <= 0.0) {
      return EtaSnapshot(
        remainingDistanceM: offTrailDistanceM ?? 0.0,
        remainingSeconds: offTrailDurationSec ?? 0,
        arrivalTimeFormatted: _formatClock(
          effectiveNow.add(Duration(seconds: offTrailDurationSec ?? 0)),
        ),
        remainingAscentM: offTrailAscentM ?? 0.0,
        remainingDescentM: 0.0,
        currentEleM: _points.isNotEmpty ? _points.first.ele : 0.0,
        currentGradePct: 0.0,
        progressRatio: 0.0,
        nextPeak: null,
        paceFactor: _paceFactor,
      );
    }

    final clampedPos = alongTrackM.clamp(0.0, totalDistanceM);
    final anchorM = (rejoinAlongTrackM ?? clampedPos).clamp(
      0.0,
      totalDistanceM,
    );

    final trailRemainingDist = math.max(0.0, totalDistanceM - anchorM);
    final trailRemainingBaseSec = math.max(
      0.0,
      baseSecondsAt(totalDistanceM) - baseSecondsAt(anchorM),
    );
    final trailRemainingSec = trailRemainingBaseSec * _paceFactor;
    final trailRemainingAscent = math.max(
      0.0,
      _cumAscentM.last - _interpolateSeries(_cumAscentM, anchorM),
    );
    final trailRemainingDescent = math.max(
      0.0,
      _cumDescentM.last - _interpolateSeries(_cumDescentM, anchorM),
    );

    final totalRemDist = trailRemainingDist + (offTrailDistanceM ?? 0.0);
    final totalRemSec = (trailRemainingSec + (offTrailDurationSec ?? 0))
        .round();
    final totalRemAscent = trailRemainingAscent + (offTrailAscentM ?? 0.0);
    final arrival = effectiveNow.add(Duration(seconds: totalRemSec));

    final currentEle = _elevationAt(clampedPos);
    final currentGrade = _gradeAt(clampedPos);
    final currentAscent = _interpolateSeries(_cumAscentM, clampedPos);

    EtaPeak? nextPeak;
    for (final peak in _peaks) {
      if (peak.distanceM > anchorM + 20.0) {
        final peakAscent = _interpolateSeries(_cumAscentM, peak.distanceM);
        final gainAhead = rejoinAlongTrackM != null
            ? math.max(
                    0.0,
                    peakAscent - _interpolateSeries(_cumAscentM, anchorM),
                  ) +
                  (offTrailAscentM ?? 0.0)
            : math.max(0.0, peakAscent - currentAscent);
        final distAhead = rejoinAlongTrackM != null
            ? math.max(0.0, peak.distanceM - anchorM) +
                  (offTrailDistanceM ?? 0.0)
            : math.max(0.0, peak.distanceM - clampedPos);
        nextPeak = EtaPeak(
          ele: peak.ele,
          distanceAheadM: distAhead,
          gainAheadM: gainAhead,
        );
        break;
      }
    }

    return EtaSnapshot(
      remainingDistanceM: totalRemDist,
      remainingSeconds: totalRemSec,
      arrivalTimeFormatted: _formatClock(arrival),
      remainingAscentM: totalRemAscent,
      remainingDescentM: trailRemainingDescent,
      currentEleM: currentEle,
      currentGradePct: currentGrade,
      progressRatio: (clampedPos / totalDistanceM).clamp(0.0, 1.0),
      nextPeak: nextPeak,
      paceFactor: _paceFactor,
    );
  }

  String _formatClock(DateTime dt) {
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  int _segmentIndexFor(double distanceM) {
    var lo = 0;
    var hi = _points.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_points[mid].distanceM <= distanceM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  double _interpolateSeries(List<double> series, double distanceM) {
    if (_points.isEmpty) return 0.0;
    if (distanceM <= _points.first.distanceM) return series.first;
    if (distanceM >= _points.last.distanceM) return series.last;

    final lo = _segmentIndexFor(distanceM);
    final hi = lo + 1;
    final span = _points[hi].distanceM - _points[lo].distanceM;
    if (span <= 0) return series[lo];
    final t = (distanceM - _points[lo].distanceM) / span;
    return series[lo] + (series[hi] - series[lo]) * t;
  }

  double _elevationAt(double distanceM) {
    if (_points.isEmpty) return 0.0;
    if (distanceM <= _points.first.distanceM) return _points.first.ele;
    if (distanceM >= _points.last.distanceM) return _points.last.ele;

    final lo = _segmentIndexFor(distanceM);
    final hi = lo + 1;
    final span = _points[hi].distanceM - _points[lo].distanceM;
    if (span <= 0) return _points[lo].ele;
    final t = (distanceM - _points[lo].distanceM) / span;
    return _points[lo].ele + (_points[hi].ele - _points[lo].ele) * t;
  }

  double _gradeAt(double distanceM) {
    if (_points.length < 2) return 0.0;
    final idx = _segmentIndexFor(distanceM);
    return _points[math.min(idx + 1, _points.length - 1)].gradePct;
  }

  static List<_PeakEntry> _detectPeaks(List<NavTrackPoint> points) {
    if (points.length < 3) return const [];
    final rawPeaks = <_PeakEntry>[];

    for (var i = 1; i < points.length - 1; i++) {
      final ele = points[i].ele;
      if (ele < points[i - 1].ele || ele <= points[i + 1].ele) continue;

      var leftMin = ele;
      for (var j = i - 1; j >= 0; j--) {
        if (points[j].ele > ele) break;
        if (points[j].ele < leftMin) leftMin = points[j].ele;
      }

      var rightMin = ele;
      for (var j = i + 1; j < points.length; j++) {
        if (points[j].ele > ele) break;
        if (points[j].ele < rightMin) rightMin = points[j].ele;
      }

      final prominence = ele - math.max(leftMin, rightMin);
      if (prominence >= 20.0) {
        if (rawPeaks.isNotEmpty &&
            points[i].distanceM - rawPeaks.last.distanceM < 100.0) {
          if (ele > rawPeaks.last.ele) {
            rawPeaks[rawPeaks.length - 1] = _PeakEntry(
              distanceM: points[i].distanceM,
              ele: ele,
            );
          }
        } else {
          rawPeaks.add(_PeakEntry(distanceM: points[i].distanceM, ele: ele));
        }
      }
    }

    // Also capture a true summit finish when the route climbs >= 20 m to the end.
    final last = points.last;
    var minBeforeLast = last.ele;
    for (var j = points.length - 2; j >= 0; j--) {
      if (points[j].ele > last.ele) break;
      if (points[j].ele < minBeforeLast) minBeforeLast = points[j].ele;
    }
    if (last.ele - minBeforeLast >= 20.0 &&
        (rawPeaks.isEmpty || last.distanceM - rawPeaks.last.distanceM >= 50.0)) {
      rawPeaks.add(_PeakEntry(distanceM: last.distanceM, ele: last.ele));
    }

    return rawPeaks;
  }
}
