import 'dart:math' as math;

import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/route/map_matcher.dart';

/// Rich match state returned by [TrackPositionMatcher.matchDetailed], including
/// global cross-track distance and 3-fix hysteresis off-trail tracking.
class TrackMatchDetail {
  const TrackMatchDetail({
    required this.isOffTrail,
    required this.alongTrackMeters,
    required this.crossTrackMeters,
    required this.matchedPoint,
    required this.segmentIndex,
    required this.consecutiveOffTrailFixes,
  });

  final bool isOffTrail;
  final double alongTrackMeters;
  final double crossTrackMeters;
  final Geographic matchedPoint;
  final int segmentIndex;
  final int consecutiveOffTrailFixes;
}

/// Resolves live GPS fixes to a distance along a GPX track in that track's
/// OWN cumulative-metre coordinate — the elevation chart's x-axis (see
/// `buildElevationTrackPoints`'s raw-axis comment).
///
/// Deliberately reuses [RouteMapMatcher] (an HMM with hairpin/out-and-back
/// robustness) rather than a nearest-point projection, which flips legs on a
/// self-overlapping trail. This is NOT the `Navigation` provider's own
/// matcher: that one runs on the Valhalla map-snapped `NavigateResponse.shape`
/// — a different, map-matched, ≤500-point axis — while this one runs on the
/// GPX's own raw polyline so its result lands directly on the chart's axis.
class TrackPositionMatcher {
  TrackPositionMatcher({
    required List<Geographic> shape,
    required List<double> cumulativeMeters,
    this.onTrackThresholdMeters = 50.0,
    this.offTrailEntryFloorMeters = 35.0,
    this.offTrailRejoinMeters = 22.0,
    this.offTrailConfirmFixes = 3,
  }) : assert(
         shape.length == cumulativeMeters.length,
         'shape and cumulativeMeters must be the same length',
       ),
       _shape = shape,
       _cumulative = cumulativeMeters,
       _matcher = RouteMapMatcher(
         shape: shape,
         shapeCumulativeMeters: cumulativeMeters,
       );

  final List<Geographic> _shape;
  final List<double> _cumulative;
  final RouteMapMatcher _matcher;

  /// Distance (metres) from a fix to the point the matcher committed to,
  /// beyond which [update] returns null (hides the marker) rather than a
  /// possibly-misleading position. Generous — 15–30 m GPS accuracy is
  /// routine outdoors, more under canopy or in a gorge — while still hiding
  /// the marker once the user has clearly left the track. Aligned with
  /// [RouteMapMatcher.offRouteCrossTrackThresholdMeters] (40 m) plus slack;
  /// a discretionary choice, not a derived constant.
  final double onTrackThresholdMeters;

  /// Minimum cross-track threshold (metres) before off-trail hysteresis counts
  /// a fix as off-trail (`max(offTrailEntryFloorMeters, 1.5 * accuracy)`).
  final double offTrailEntryFloorMeters;

  /// Cross-track threshold (metres) at or below which an off-trail user is
  /// considered back on the trail (`<= 22.0 m`).
  final double offTrailRejoinMeters;

  /// Consecutive fixes exceeding the entry threshold required to flip into
  /// off-trail mode (`3`).
  final int offTrailConfirmFixes;

  bool _isOffTrail = false;
  int _consecutiveOffTrailFixes = 0;
  bool _hasValidMatch = false;
  double _lastValidAlongTrack = 0.0;
  int _lastValidSegmentIndex = 0;
  Geographic? _lastValidPoint;

  /// Feeds one GPS fix into the underlying matcher and returns the along-
  /// track distance (chart x-axis units) when [pos] is within
  /// [onTrackThresholdMeters] of the point the matcher committed to, or null
  /// when off-track (or uncertain — see below).
  ///
  /// The gate measures distance from [pos] to the matcher's COMMITTED point
  /// (not a perpendicular cross-track distance) — so it also reads null
  /// while [RouteMapMatcher] is coasting on an unconfirmed leg jump (see its
  /// `commitConfirmFixes` docs), which is the desired "uncertain → hide"
  /// behaviour rather than reporting a possibly-wrong leg.
  double? update(
    Geographic pos, {
    double? heading,
    double? headingAccuracy,
    double? speed,
    double? accuracy,
  }) {
    if (_shape.length < 2) return null;

    final result = _matcher.update(
      pos: pos,
      heading: heading,
      headingAccuracy: headingAccuracy,
      speed: speed,
      accuracy: accuracy,
    );
    final matched = pointAtAlongTrack(
      result.alongTrackMeters,
      result.shapeIndex,
    );
    final distance = SphericalGreatCircle(matched).distanceTo(pos);
    return distance <= onTrackThresholdMeters ? result.alongTrackMeters : null;
  }

  /// Feeds one GPS fix into both the HMM matcher and a global nearest-segment
  /// cross-track check, applying 3-fix off-trail hysteresis (`max(35.0,
  /// 1.5 * accuracy)` entry, `<= 22.0 m` exit).
  TrackMatchDetail? matchDetailed(
    Geographic pos, {
    double? heading,
    double? headingAccuracy,
    double? speed,
    double? accuracy,
  }) {
    if (_shape.length < 2 || _cumulative.length < 2) return null;

    final hmm = _matcher.update(
      pos: pos,
      heading: heading,
      headingAccuracy: headingAccuracy,
      speed: speed,
      accuracy: accuracy,
    );
    final hmmPoint = pointAtAlongTrack(hmm.alongTrackMeters, hmm.shapeIndex);
    final hmmCrossTrack = SphericalGreatCircle(hmmPoint).distanceTo(pos);

    final nearest = _globalNearest(pos);
    final effAcc =
        (accuracy != null && accuracy.isFinite && accuracy > 0) ? accuracy : 0.0;
    final entryThreshold = math.max(offTrailEntryFloorMeters, 1.5 * effAcc);

    if (!_isOffTrail) {
      if (nearest.crossTrackMeters > entryThreshold) {
        _consecutiveOffTrailFixes++;
        if (_consecutiveOffTrailFixes >= offTrailConfirmFixes) {
          _isOffTrail = true;
        }
      } else {
        _consecutiveOffTrailFixes = 0;
        if (hmmCrossTrack <= onTrackThresholdMeters) {
          _hasValidMatch = true;
          _lastValidAlongTrack = hmm.alongTrackMeters;
          _lastValidSegmentIndex = hmm.shapeIndex;
          _lastValidPoint = hmmPoint;
        } else {
          _hasValidMatch = true;
          _lastValidAlongTrack = nearest.alongTrackMeters;
          _lastValidSegmentIndex = nearest.segmentIndex;
          _lastValidPoint = nearest.point;
        }
      }
    } else {
      if (nearest.crossTrackMeters <= offTrailRejoinMeters) {
        _isOffTrail = false;
        _consecutiveOffTrailFixes = 0;
        _hasValidMatch = true;
        _lastValidAlongTrack = nearest.alongTrackMeters;
        _lastValidSegmentIndex = nearest.segmentIndex;
        _lastValidPoint = nearest.point;
      } else {
        _consecutiveOffTrailFixes++;
      }
    }

    final reportedAlong = _hasValidMatch
        ? _lastValidAlongTrack
        : nearest.alongTrackMeters;
    final reportedSeg = _hasValidMatch
        ? _lastValidSegmentIndex
        : nearest.segmentIndex;
    final reportedPoint = _hasValidMatch
        ? (_lastValidPoint ?? nearest.point)
        : nearest.point;

    return TrackMatchDetail(
      isOffTrail: _isOffTrail,
      alongTrackMeters: reportedAlong,
      crossTrackMeters: nearest.crossTrackMeters,
      matchedPoint: reportedPoint,
      segmentIndex: reportedSeg,
      consecutiveOffTrailFixes: _consecutiveOffTrailFixes,
    );
  }

  ({
    double crossTrackMeters,
    double alongTrackMeters,
    int segmentIndex,
    Geographic point,
  })
  _globalNearest(Geographic pos) {
    const metersPerDegree = 111320.0;
    var bestApproxSq = double.infinity;
    var bestSeg = 0;
    var bestT = 0.0;

    for (var i = 0; i < _shape.length - 1; i++) {
      final a = _shape[i];
      final b = _shape[i + 1];
      final midLatRad = ((a.lat + b.lat) / 2.0) * math.pi / 180.0;
      final cosMidLat = math.cos(midLatRad);

      final abX = (b.lon - a.lon) * metersPerDegree * cosMidLat;
      final abY = (b.lat - a.lat) * metersPerDegree;
      final apX = (pos.lon - a.lon) * metersPerDegree * cosMidLat;
      final apY = (pos.lat - a.lat) * metersPerDegree;

      final segLenSq = abX * abX + abY * abY;
      final t = segLenSq <= 0.0
          ? 0.0
          : ((apX * abX + apY * abY) / segLenSq).clamp(0.0, 1.0);

      final footX = apX - t * abX;
      final footY = apY - t * abY;
      final dSq = footX * footX + footY * footY;
      if (dSq < bestApproxSq) {
        bestApproxSq = dSq;
        bestSeg = i;
        bestT = t;
      }
    }

    final segLen = _cumulative[bestSeg + 1] - _cumulative[bestSeg];
    final along = _cumulative[bestSeg] + bestT * segLen;
    final pt = pointAtAlongTrack(along, bestSeg);
    final dist = SphericalGreatCircle(pt).distanceTo(pos);
    return (
      crossTrackMeters: dist,
      alongTrackMeters: along,
      segmentIndex: bestSeg,
      point: pt,
    );
  }

  /// The point on the shape's polyline at [alongTrackMeters], interpolated
  /// within the segment starting at [shapeIndex] (clamped into range).
  Geographic pointAtAlongTrack(double alongTrackMeters, int shapeIndex) {
    final i = shapeIndex.clamp(0, _shape.length - 2);
    final segLen = _cumulative[i + 1] - _cumulative[i];
    if (segLen <= 0) return _shape[i];
    final t = ((alongTrackMeters - _cumulative[i]) / segLen).clamp(0.0, 1.0);
    return SphericalGreatCircle(
      _shape[i],
    ).intermediatePointTo(_shape[i + 1], fraction: t);
  }
}
