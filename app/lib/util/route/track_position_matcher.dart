import 'dart:math' as math;
import 'dart:typed_data';

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
       ) {
    _buildSpatialIndex();
  }

  final List<Geographic> _shape;
  final List<double> _cumulative;
  final RouteMapMatcher _matcher;

  static const double _kMetersPerDegree = 111320.0;
  static const double _kGridCellMeters = 200.0;

  double _originLat = 0.0;
  double _originLon = 0.0;
  double _originCosLat = 1.0;
  late Float64List _segCosMidLat;
  late Float64List _segAbX;
  late Float64List _segAbY;
  late Float64List _segLenSq;
  final Map<int, Int32List> _spatialBuckets = <int, Int32List>{};

  static int _packCell(int cx, int cy) =>
      ((cx & 0xFFFFF) << 20) | (cy & 0xFFFFF);

  int _lonToCellX(double lon) =>
      (((lon - _originLon) * _kMetersPerDegree * _originCosLat) /
              _kGridCellMeters)
          .floor();

  int _latToCellY(double lat) =>
      (((lat - _originLat) * _kMetersPerDegree) / _kGridCellMeters).floor();

  void _buildSpatialIndex() {
    final segCount = math.max(0, _shape.length - 1);
    _segCosMidLat = Float64List(segCount);
    _segAbX = Float64List(segCount);
    _segAbY = Float64List(segCount);
    _segLenSq = Float64List(segCount);
    if (segCount == 0) return;

    _originLat = _shape.first.lat;
    _originLon = _shape.first.lon;
    _originCosLat = math.max(
      0.1,
      math.cos(_originLat * math.pi / 180.0),
    );

    final tempBuckets = <int, List<int>>{};
    for (var i = 0; i < segCount; i++) {
      final a = _shape[i];
      final b = _shape[i + 1];
      final cosMid = math.cos(((a.lat + b.lat) * 0.5) * math.pi / 180.0);
      final abX = (b.lon - a.lon) * _kMetersPerDegree * cosMid;
      final abY = (b.lat - a.lat) * _kMetersPerDegree;
      _segCosMidLat[i] = cosMid;
      _segAbX[i] = abX;
      _segAbY[i] = abY;
      _segLenSq[i] = abX * abX + abY * abY;

      final cx0 = _lonToCellX(math.min(a.lon, b.lon));
      final cx1 = _lonToCellX(math.max(a.lon, b.lon));
      final cy0 = _latToCellY(math.min(a.lat, b.lat));
      final cy1 = _latToCellY(math.max(a.lat, b.lat));
      for (var cy = cy0; cy <= cy1; cy++) {
        for (var cx = cx0; cx <= cx1; cx++) {
          (tempBuckets[_packCell(cx, cy)] ??= <int>[]).add(i);
        }
      }
    }
    tempBuckets.forEach((key, list) {
      _spatialBuckets[key] = Int32List.fromList(list);
    });
  }

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
  Geographic? _prevFix;

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

    final prevFix = _prevFix;
    final stepM = prevFix == null
        ? 0.0
        : SphericalGreatCircle(prevFix).distanceTo(pos);
    _prevFix = pos;

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
    final entryThreshold = effAcc > 25.0
        ? math.max(offTrailEntryFloorMeters, math.min(140.0, 2.2 * effAcc))
        : math.max(offTrailEntryFloorMeters, 1.5 * effAcc);

    if (!_isOffTrail) {
      if (nearest.crossTrackMeters > entryThreshold) {
        _consecutiveOffTrailFixes++;
        if (_consecutiveOffTrailFixes >= offTrailConfirmFixes) {
          _isOffTrail = true;
        }
        if (nearest.crossTrackMeters <= 3000.0) {
          _advanceCorridorAlong(pos, prevFix, stepM, nearest);
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
        if (nearest.crossTrackMeters <= 3000.0) {
          _advanceCorridorAlong(pos, prevFix, stepM, nearest);
        }
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

  void _advanceCorridorAlong(
    Geographic pos,
    Geographic? prevFix,
    double stepM,
    ({
      double crossTrackMeters,
      double alongTrackMeters,
      int segmentIndex,
      Geographic point,
    })
    nearest,
  ) {
    if (!_hasValidMatch) {
      _hasValidMatch = true;
      _lastValidAlongTrack = nearest.alongTrackMeters;
      _lastValidSegmentIndex = nearest.segmentIndex;
      _lastValidPoint = nearest.point;
      return;
    }

    final totalLen = _cumulative.last;
    final windowMin = math.max(0.0, _lastValidAlongTrack - 15.0);
    final windowMax = math.min(
      totalLen,
      _lastValidAlongTrack +
          math.max(400.0, 4.0 * (stepM.isFinite ? stepM : 0.0)),
    );
    final forwardCand = _nearestInWindow(pos, windowMin, windowMax);
    if (forwardCand == null ||
        forwardCand.alongTrackMeters <= _lastValidAlongTrack) {
      return;
    }

    if (prevFix != null && stepM.isFinite && stepM >= 5.0) {
      final moveBearing = SphericalGreatCircle(prevFix).initialBearingTo(pos);
      final segIdx = forwardCand.segmentIndex.clamp(0, _shape.length - 2);
      final segBearing = SphericalGreatCircle(
        _shape[segIdx],
      ).initialBearingTo(_shape[segIdx + 1]);
      if (moveBearing.isFinite && segBearing.isFinite) {
        var angleDiff = ((moveBearing - segBearing) % 360.0).abs();
        if (angleDiff > 180.0) angleDiff = 360.0 - angleDiff;
        if (angleDiff > 80.0) {
          return;
        }
      }
    }

    _lastValidAlongTrack = forwardCand.alongTrackMeters;
    _lastValidSegmentIndex = forwardCand.segmentIndex;
    _lastValidPoint = forwardCand.point;
  }

  ({double alongTrackMeters, int segmentIndex, Geographic point})?
  _nearestInWindow(Geographic pos, double minAlong, double maxAlong) {
    if (maxAlong < minAlong || _shape.length < 2) return null;
    var bestApproxSq = double.infinity;
    var bestSeg = -1;
    var bestT = 0.0;

    for (var i = 0; i < _shape.length - 1; i++) {
      final segStart = _cumulative[i];
      final segEnd = _cumulative[i + 1];
      if (segEnd < minAlong || segStart > maxAlong) continue;

      final segLen = segEnd - segStart;
      final a = _shape[i];
      final cosMidLat = _segCosMidLat[i];
      final abX = _segAbX[i];
      final abY = _segAbY[i];
      final segLenSq = _segLenSq[i];
      final apX = (pos.lon - a.lon) * _kMetersPerDegree * cosMidLat;
      final apY = (pos.lat - a.lat) * _kMetersPerDegree;
      final tMin = segLen <= 0.0
          ? 0.0
          : ((minAlong - segStart) / segLen).clamp(0.0, 1.0);
      final tMax = segLen <= 0.0
          ? 0.0
          : ((maxAlong - segStart) / segLen).clamp(0.0, 1.0);
      final rawT = segLenSq <= 0.0 ? 0.0 : ((apX * abX + apY * abY) / segLenSq);
      final t = rawT.clamp(tMin, tMax);

      final footX = apX - t * abX;
      final footY = apY - t * abY;
      final dSq = footX * footX + footY * footY;
      if (dSq < bestApproxSq) {
        bestApproxSq = dSq;
        bestSeg = i;
        bestT = t;
      }
    }

    if (bestSeg < 0) return null;
    final segLen = _cumulative[bestSeg + 1] - _cumulative[bestSeg];
    final along = _cumulative[bestSeg] + bestT * segLen;
    final pt = pointAtAlongTrack(along, bestSeg);
    return (alongTrackMeters: along, segmentIndex: bestSeg, point: pt);
  }

  ({
    double crossTrackMeters,
    double alongTrackMeters,
    int segmentIndex,
    Geographic point,
  })
  _globalNearest(Geographic pos) {
    var bestApproxSq = double.infinity;
    var bestSeg = 0;
    var bestT = 0.0;
    var inspectedAny = false;

    void evaluateSegment(int i) {
      final a = _shape[i];
      final cosMidLat = _segCosMidLat[i];
      final abX = _segAbX[i];
      final abY = _segAbY[i];
      final segLenSq = _segLenSq[i];
      final apX = (pos.lon - a.lon) * _kMetersPerDegree * cosMidLat;
      final apY = (pos.lat - a.lat) * _kMetersPerDegree;
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

    final qx = _lonToCellX(pos.lon);
    final qy = _latToCellY(pos.lat);

    // Fast path 1: 3x3 cells (600m x 600m) covers all on-trail & near-off-trail fixes.
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final bucket = _spatialBuckets[_packCell(qx + dx, qy + dy)];
        if (bucket == null) continue;
        inspectedAny = true;
        for (var k = 0; k < bucket.length; k++) {
          evaluateSegment(bucket[k]);
        }
      }
    }

    // If a closer segment could theoretically sit just outside the 1-cell margin,
    // or if 3x3 had no segments, expand once to 16-cell radius (3.2 km) before
    // falling back to the precomputed linear scan (> 3 km Calm Preview Mode).
    if (!inspectedAny || bestApproxSq > (_kGridCellMeters * _kGridCellMeters)) {
      for (var dy = -16; dy <= 16; dy++) {
        for (var dx = -16; dx <= 16; dx++) {
          if (dx >= -1 && dx <= 1 && dy >= -1 && dy <= 1) continue;
          final bucket = _spatialBuckets[_packCell(qx + dx, qy + dy)];
          if (bucket == null) continue;
          inspectedAny = true;
          for (var k = 0; k < bucket.length; k++) {
            evaluateSegment(bucket[k]);
          }
        }
      }
    }

    if (!inspectedAny) {
      for (var i = 0; i < _shape.length - 1; i++) {
        evaluateSegment(i);
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
