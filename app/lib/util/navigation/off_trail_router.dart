import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';

enum OffTrailMode { minClimb, shortestSafe }

class OffTrailPoint {
  const OffTrailPoint({
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

class OffTrailRerouteResult {
  const OffTrailRerouteResult({
    required this.mode,
    required this.points,
    required this.rejoinPoint,
    required this.rejoinAlongTrackM,
    required this.rejoinEleM,
    required this.distanceM,
    required this.estimatedSeconds,
    required this.ascentM,
    required this.descentM,
    required this.maxSlopeDeg,
    required this.avoidedSteepHazard,
    required this.initialBearingDeg,
    required this.instruction,
    required this.slopeAdvice,
  });

  final OffTrailMode mode;
  final List<OffTrailPoint> points;
  final Geographic rejoinPoint;
  final double rejoinAlongTrackM;
  final double rejoinEleM;
  final double distanceM;
  final int estimatedSeconds;
  final double ascentM;
  final double descentM;
  final double maxSlopeDeg;
  final bool avoidedSteepHazard;
  final double initialBearingDeg;
  final String instruction;
  final String slopeAdvice;
}

typedef ElevationSampler = double? Function(double lat, double lon);

class _RejoinCandidate {
  const _RejoinCandidate({
    required this.lat,
    required this.lon,
    required this.ele,
    required this.alongTrackM,
    required this.x,
    required this.y,
    required this.goalPenalty,
  });

  final double lat;
  final double lon;
  final double ele;
  final double alongTrackM;
  final double x;
  final double y;
  final double goalPenalty;
}

class _IntMinHeap {
  final List<int> _heap = [];
  final Float64List _priority;

  _IntMinHeap(this._priority);

  bool get isEmpty => _heap.isEmpty;

  void push(int node) {
    _heap.add(node);
    _siftUp(_heap.length - 1);
  }

  int pop() {
    final top = _heap[0];
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _siftDown(0);
    }
    return top;
  }

  void _siftUp(int idx) {
    final node = _heap[idx];
    final p = _priority[node];
    var i = idx;
    while (i > 0) {
      final parentIdx = (i - 1) >> 1;
      final parentNode = _heap[parentIdx];
      if (_priority[parentNode] <= p) break;
      _heap[i] = parentNode;
      i = parentIdx;
    }
    _heap[i] = node;
  }

  void _siftDown(int idx) {
    final len = _heap.length;
    final node = _heap[idx];
    final p = _priority[node];
    var i = idx;
    while (true) {
      final left = (i << 1) + 1;
      if (left >= len) break;
      final right = left + 1;
      var smallest = left;
      if (right < len && _priority[_heap[right]] < _priority[_heap[left]]) {
        smallest = right;
      }
      if (_priority[_heap[smallest]] >= p) break;
      _heap[i] = _heap[smallest];
      i = smallest;
    }
    _heap[i] = node;
  }
}

/// Computes a terrain-aware 16-neighbor Multi-Target A* off-trail recovery
/// path back to the trail using DEM elevation tiles (with IDW fallback).
class OffTrailRouter {
  const OffTrailRouter._();

  /// Slope ratio corresponding to `atan(0.75) ~= 36.87°` cliff hazard barrier.
  static const double cliffSlopeRatioThreshold = 0.75;
  static const double _steepSlopeRatioThreshold = 0.50;
  static const int _maxGridDim = 180;

  static const List<(int dc, int dr)> _neighbors16 = [
    (1, 0),
    (-1, 0),
    (0, 1),
    (0, -1),
    (1, 1),
    (1, -1),
    (-1, 1),
    (-1, -1),
    (1, 2),
    (1, -2),
    (-1, 2),
    (-1, -2),
    (2, 1),
    (2, -1),
    (-2, 1),
    (-2, -1),
  ];

  static OffTrailRerouteResult? compute({
    required Geographic userPos,
    double? userEleM,
    required List<NavTrackPoint> trailPoints,
    required double lastAlongTrackM,
    required ElevationSampler sampler,
    OffTrailMode mode = OffTrailMode.minClimb,
    String localeCode = 'ro',
    bool isCycling = false,
  }) {
    if (trailPoints.length < 2) return null;

    final mPerDegLat = 111320.0;
    final mPerDegLon =
        111320.0 * math.max(0.1, math.cos(userPos.lat * math.pi / 180.0));

    double toX(double lon) => (lon - userPos.lon) * mPerDegLon;
    double toY(double lat) => (lat - userPos.lat) * mPerDegLat;
    double toLat(double y) => userPos.lat + y / mPerDegLat;
    double toLon(double x) => userPos.lon + x / mPerDegLon;

    final etaCalc = EtaCalculator.fromPoints(trailPoints, isCycling: isCycling);
    final totalDistM = etaCalc.totalDistanceM;
    final totalBaseSec = etaCalc.baseSecondsAt(totalDistM);

    // 1. Collect rejoin candidates in [lastAlongTrackM - 150, lastAlongTrackM + 1500]
    //    plus the global nearest point on the trail.
    final windowMin = math.max(0.0, lastAlongTrackM - 150.0);
    final windowMax = math.min(totalDistM, lastAlongTrackM + 1500.0);

    var nearestLat = trailPoints.first.lat;
    var nearestLon = trailPoints.first.lon;
    var nearestEle = trailPoints.first.ele;
    var nearestAlongM = trailPoints.first.distanceM;
    var nearestDistSq = double.infinity;

    final denseSamples =
        <({double lat, double lon, double ele, double alongTrackM})>[];

    for (var i = 0; i < trailPoints.length - 1; i++) {
      final a = trailPoints[i];
      final b = trailPoints[i + 1];
      final segLen = math.max(0.0, b.distanceM - a.distanceM);

      final ax = toX(a.lon);
      final ay = toY(a.lat);
      final bx = toX(b.lon);
      final by = toY(b.lat);
      final abx = bx - ax;
      final aby = by - ay;
      final lenSq = abx * abx + aby * aby;
      final tProj = lenSq > 0.0
          ? ((-ax * abx - ay * aby) / lenSq).clamp(0.0, 1.0)
          : 0.0;
      final px = ax + tProj * abx;
      final py = ay + tProj * aby;
      final dSq = px * px + py * py;
      if (dSq < nearestDistSq) {
        nearestDistSq = dSq;
        nearestLat = a.lat + tProj * (b.lat - a.lat);
        nearestLon = a.lon + tProj * (b.lon - a.lon);
        nearestEle = a.ele + tProj * (b.ele - a.ele);
        nearestAlongM = a.distanceM + tProj * segLen;
      }

      if (b.distanceM < windowMin || a.distanceM > windowMax) continue;
      final steps = math.max(1, (segLen / 40.0).ceil());
      for (var s = 0; s < steps; s++) {
        final t = s / steps;
        final dAlong = a.distanceM + t * segLen;
        if (dAlong >= windowMin && dAlong <= windowMax) {
          denseSamples.add((
            lat: a.lat + t * (b.lat - a.lat),
            lon: a.lon + t * (b.lon - a.lon),
            ele: a.ele + t * (b.ele - a.ele),
            alongTrackM: dAlong,
          ));
        }
      }
    }
    if (trailPoints.last.distanceM >= windowMin &&
        trailPoints.last.distanceM <= windowMax) {
      denseSamples.add((
        lat: trailPoints.last.lat,
        lon: trailPoints.last.lon,
        ele: trailPoints.last.ele,
        alongTrackM: trailPoints.last.distanceM,
      ));
    }

    // Subsample candidates to <= 35 while always preserving the global nearest
    // point and window ends.
    final candidates = <_RejoinCandidate>[];
    void addCandidate(double lat, double lon, double ele, double alongM) {
      final remSec = math.max(0.0, totalBaseSec - etaCalc.baseSecondsAt(alongM));
      final goalPenalty = mode == OffTrailMode.minClimb
          ? 0.30 * remSec
          : 0.05 * math.max(0.0, totalDistM - alongM);
      candidates.add(
        _RejoinCandidate(
          lat: lat,
          lon: lon,
          ele: ele,
          alongTrackM: alongM,
          x: toX(lon),
          y: toY(lat),
          goalPenalty: goalPenalty,
        ),
      );
    }

    addCandidate(nearestLat, nearestLon, nearestEle, nearestAlongM);
    if (denseSamples.isNotEmpty) {
      const maxWindowCandidates = 34;
      final stride = math.max(1, (denseSamples.length / maxWindowCandidates).ceil());
      for (var i = 0; i < denseSamples.length; i += stride) {
        final pt = denseSamples[i];
        addCandidate(pt.lat, pt.lon, pt.ele, pt.alongTrackM);
      }
      final last = denseSamples.last;
      addCandidate(last.lat, last.lon, last.ele, last.alongTrackM);
    }

    // Downsample trail points for IDW fallback.
    final idwRefs = <({double x, double y, double ele})>[];
    if (userEleM != null && userEleM.isFinite) {
      idwRefs.add((x: 0.0, y: 0.0, ele: userEleM));
    }
    final idwStep = math.max(1, (trailPoints.length / 24).ceil());
    for (var i = 0; i < trailPoints.length; i += idwStep) {
      final p = trailPoints[i];
      idwRefs.add((x: toX(p.lon), y: toY(p.lat), ele: p.ele));
    }

    double sampleWithFallback(double lat, double lon) {
      final dem = sampler(lat, lon);
      if (dem != null && dem.isFinite) return dem;
      if (idwRefs.isEmpty) return 0.0;
      final px = toX(lon);
      final py = toY(lat);
      var numSum = 0.0;
      var denSum = 0.0;
      for (final ref in idwRefs) {
        final dx = px - ref.x;
        final dy = py - ref.y;
        final dSq = dx * dx + dy * dy;
        if (dSq < 1.0) return ref.ele;
        final w = 1.0 / dSq;
        numSum += w * ref.ele;
        denSum += w;
      }
      return denSum > 0.0 ? numSum / denSum : 0.0;
    }

    // 2. Bounding box & adaptive grid sizing (cellSize 15m..35m, max 180x180).
    var minX = 0.0;
    var maxX = 0.0;
    var minY = 0.0;
    var maxY = 0.0;
    for (final c in candidates) {
      if (c.x < minX) minX = c.x;
      if (c.x > maxX) maxX = c.x;
      if (c.y < minY) minY = c.y;
      if (c.y > maxY) maxY = c.y;
    }

    final nearestDistM = math.sqrt(nearestDistSq);
    final padM = math.max(250.0, 0.45 * nearestDistM);
    minX -= padM;
    maxX += padM;
    minY -= padM;
    maxY += padM;

    final spanX = maxX - minX;
    final spanY = maxY - minY;
    final maxSpan = math.max(spanX, spanY);
    var cellSize = (maxSpan / (_maxGridDim - 2)).clamp(15.0, 35.0);
    if (maxSpan / cellSize > _maxGridDim - 2) {
      cellSize = maxSpan / (_maxGridDim - 2);
    }

    final cols = (spanX / cellSize).ceil().clamp(3, _maxGridDim);
    final rows = (spanY / cellSize).ceil().clamp(3, _maxGridDim);
    final totalCells = cols * rows;

    int xToCol(double x) => ((x - minX) / cellSize).floor().clamp(0, cols - 1);
    int yToRow(double y) => ((y - minY) / cellSize).floor().clamp(0, rows - 1);
    double colToX(int c) => minX + (c + 0.5) * cellSize;
    double rowToY(int r) => minY + (r + 0.5) * cellSize;

    final startCol = xToCol(0.0);
    final startRow = yToRow(0.0);
    final startIdx = startRow * cols + startCol;

    // Cache cell elevations lazily.
    final eleGrid = Float64List(totalCells);
    for (var i = 0; i < totalCells; i++) {
      eleGrid[i] = double.nan;
    }
    double cellEle(int col, int row) {
      final idx = row * cols + col;
      final cached = eleGrid[idx];
      if (!cached.isNaN) return cached;
      final val = sampleWithFallback(toLat(rowToY(row)), toLon(colToX(col)));
      eleGrid[idx] = val;
      return val;
    }

    // Register target cells and precompute cell-center coordinates for a
    // strictly admissible Multi-Target A* heuristic.
    final goalByCell = <int, _RejoinCandidate>{};
    final goalTargets = <({double x, double y, double penalty})>[];
    for (final c in candidates) {
      final gc = xToCol(c.x);
      final gr = yToRow(c.y);
      final gIdx = gr * cols + gc;
      final prev = goalByCell[gIdx];
      if (prev == null || c.goalPenalty < prev.goalPenalty) {
        goalByCell[gIdx] = c;
      }
    }
    for (final entry in goalByCell.entries) {
      final gIdx = entry.key;
      goalTargets.add((
        x: colToX(gIdx % cols),
        y: rowToY(gIdx ~/ cols),
        penalty: entry.value.goalPenalty,
      ));
    }

    final maxOffTrailSpeedMs =
        0.6 * (isCycling ? 32.0 : 7.5) / 3.6; // fastest possible Tobler off-trail
    final minCostPerMeter =
        mode == OffTrailMode.minClimb ? (1.0 / maxOffTrailSpeedMs) : 1.0;

    double heuristic(int col, int row) {
      final cx = colToX(col);
      final cy = rowToY(row);
      var bestH = double.infinity;
      for (final t in goalTargets) {
        final dx = cx - t.x;
        final dy = cy - t.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        final h = minCostPerMeter * dist + t.penalty;
        if (h < bestH) bestH = h;
      }
      return bestH.isFinite ? bestH : 0.0;
    }

    // Edge cost helper between two adjacent/knight cells.
    double edgeCost(int c0, int r0, int c1, int r1, double distM) {
      final e0 = cellEle(c0, r0);
      final e1 = cellEle(c1, r1);
      final dEle = e1 - e0;
      final s = distM > 0.0 ? dEle / distM : 0.0;
      final absS = s.abs();

      var hazardMult = absS > cliffSlopeRatioThreshold
          ? 40.0
          : (absS > _steepSlopeRatioThreshold && mode == OffTrailMode.minClimb
                ? 4.0
                : 1.0);

      // For knight moves, ensure the move does not tunnel across a 1-cell cliff.
      final dc = c1 - c0;
      final dr = r1 - r0;
      if (dc.abs() + dr.abs() == 3) {
        final midC1 = c0 + (dc.abs() == 2 ? dc.sign : 0);
        final midR1 = r0 + (dr.abs() == 2 ? dr.sign : 0);
        final midC2 = c0 + dc.sign;
        final midR2 = r0 + dr.sign;
        final halfDist = distM * 0.5;
        final sMid1 = ((cellEle(midC1, midR1) - e0) / halfDist).abs();
        final sMid2 = ((cellEle(midC2, midR2) - e0) / halfDist).abs();
        if (sMid1 > cliffSlopeRatioThreshold ||
            sMid2 > cliffSlopeRatioThreshold) {
          hazardMult = math.max(hazardMult, 40.0);
        }
      }

      if (mode == OffTrailMode.minClimb) {
        final vMs = 0.6 * toblerSpeedKmh(s, isCycling: isCycling) / 3.6;
        final baseSec = distM / math.max(0.15, vMs);
        final climbPenalty = 6.5 * math.max(0.0, dEle);
        final steepDescPenalty = s < -0.20 ? 2.0 * dEle.abs() : 0.0;
        return (baseSec + climbPenalty + steepDescPenalty) * hazardMult;
      } else {
        return (distM + 1.0 * math.max(0.0, dEle)) * hazardMult;
      }
    }

    // 3. Run Multi-Target A*.
    final gScore = Float64List(totalCells);
    final fScore = Float64List(totalCells);
    final cameFrom = Int32List(totalCells);
    final closed = Uint8List(totalCells);

    for (var i = 0; i < totalCells; i++) {
      gScore[i] = double.infinity;
      fScore[i] = double.infinity;
      cameFrom[i] = -1;
    }

    gScore[startIdx] = 0.0;
    fScore[startIdx] = heuristic(startCol, startRow);

    final openHeap = _IntMinHeap(fScore)..push(startIdx);
    var bestGoalIdx = -1;
    var bestTotalCost = double.infinity;

    while (!openHeap.isEmpty) {
      final curr = openHeap.pop();
      if (fScore[curr] >= bestTotalCost) break;
      if (closed[curr] != 0) continue;
      closed[curr] = 1;

      final goalCand = goalByCell[curr];
      if (goalCand != null) {
        final total = gScore[curr] + goalCand.goalPenalty;
        if (total < bestTotalCost) {
          bestTotalCost = total;
          bestGoalIdx = curr;
        }
      }

      final cc = curr % cols;
      final cr = curr ~/ cols;
      for (final (dc, dr) in _neighbors16) {
        final nc = cc + dc;
        final nr = cr + dr;
        if (nc < 0 || nc >= cols || nr < 0 || nr >= rows) continue;
        final nIdx = nr * cols + nc;
        if (closed[nIdx] != 0) continue;

        final stepDist = math.sqrt(dc * dc + dr * dr) * cellSize;
        final tentativeG = gScore[curr] + edgeCost(cc, cr, nc, nr, stepDist);
        if (tentativeG < gScore[nIdx]) {
          cameFrom[nIdx] = curr;
          gScore[nIdx] = tentativeG;
          fScore[nIdx] = tentativeG + heuristic(nc, nr);
          openHeap.push(nIdx);
        }
      }
    }

    // Fallback to nearest candidate if start already equals target or A* failed.
    final chosenTarget = goalByCell[bestGoalIdx] ?? candidates.first;
    final rawCoords = <({double x, double y})>[];
    if (bestGoalIdx != -1) {
      final reversedIdx = <int>[];
      var cur = bestGoalIdx;
      while (cur != -1) {
        reversedIdx.add(cur);
        if (cur == startIdx) break;
        cur = cameFrom[cur];
      }
      for (var i = reversedIdx.length - 1; i >= 0; i--) {
        final idx = reversedIdx[i];
        rawCoords.add((x: colToX(idx % cols), y: rowToY(idx ~/ cols)));
      }
    }

    if (rawCoords.isEmpty) {
      rawCoords.add((x: 0.0, y: 0.0));
      rawCoords.add((x: chosenTarget.x, y: chosenTarget.y));
    } else {
      rawCoords[0] = (x: 0.0, y: 0.0);
      if (rawCoords.length == 1) {
        rawCoords.add((x: chosenTarget.x, y: chosenTarget.y));
      } else {
        rawCoords[rawCoords.length - 1] = (x: chosenTarget.x, y: chosenTarget.y);
      }
    }

    // 4. Safe string-pulling smoothing (never cuts across >36.8° cliffs or adds climb).
    final smoothedCoords = _smoothPathSafely(
      rawCoords,
      cellSize: cellSize,
      mode: mode,
      eleAtXY: (x, y) => sampleWithFallback(toLat(y), toLon(x)),
    );

    // Check whether the direct straight-line chord to the nearest trail point
    // hits a steep cliff hazard (> 36.8°) that the A* path steered around.
    final directHitCliff = _lineHitsSteepHazard(
      x0: 0.0,
      y0: 0.0,
      x1: nearestLat == chosenTarget.lat && nearestLon == chosenTarget.lon
          ? chosenTarget.x
          : toX(nearestLon),
      y1: nearestLat == chosenTarget.lat && nearestLon == chosenTarget.lon
          ? chosenTarget.y
          : toY(nearestLat),
      stepM: math.max(10.0, cellSize * 0.5),
      eleAtXY: (x, y) => sampleWithFallback(toLat(y), toLon(x)),
    );

    // 5. Build final OffTrailPoint list & route summary metrics.
    final outPoints = <OffTrailPoint>[];
    var cumDist = 0.0;
    var ascent = 0.0;
    var descent = 0.0;
    var estSec = 0.0;
    var maxAbsSlopeRatio = 0.0;

    final eles = <double>[
      for (var i = 0; i < smoothedCoords.length; i++)
        i == 0 && userEleM != null && userEleM.isFinite && sampler(userPos.lat, userPos.lon) == null
            ? userEleM
            : sampleWithFallback(
                toLat(smoothedCoords[i].y),
                toLon(smoothedCoords[i].x),
              ),
    ];

    for (var i = 0; i < smoothedCoords.length; i++) {
      final lat = i == 0
          ? userPos.lat
          : (i == smoothedCoords.length - 1
                ? chosenTarget.lat
                : toLat(smoothedCoords[i].y));
      final lon = i == 0
          ? userPos.lon
          : (i == smoothedCoords.length - 1
                ? chosenTarget.lon
                : toLon(smoothedCoords[i].x));
      final ele = eles[i];
      var gradePct = 0.0;

      if (i > 0) {
        final prev = outPoints[i - 1];
        final d = SphericalGreatCircle(
          Geographic(lat: prev.lat, lon: prev.lon),
        ).distanceTo(Geographic(lat: lat, lon: lon));
        final segDist = d.isFinite ? d : 0.0;
        cumDist += segDist;
        final dEle = ele - prev.ele;
        if (dEle > 0) ascent += dEle;
        if (dEle < 0) descent += -dEle;

        final slopeRatio = segDist > 0.5 ? dEle / segDist : 0.0;
        if (slopeRatio.abs() > maxAbsSlopeRatio) {
          maxAbsSlopeRatio = slopeRatio.abs();
        }
        gradePct = slopeRatio * 100.0;
        final speedMs =
            0.6 * toblerSpeedKmh(slopeRatio, isCycling: isCycling) / 3.6;
        if (segDist > 0.0) {
          estSec += segDist / math.max(0.15, speedMs);
        }
      }

      outPoints.add(
        OffTrailPoint(
          lat: lat,
          lon: lon,
          ele: ele,
          distanceM: cumDist,
          gradePct: gradePct,
        ),
      );
    }

    final maxSlopeDeg = math.atan(maxAbsSlopeRatio) * 180.0 / math.pi;
    final avoidedSteepHazard =
        directHitCliff && maxAbsSlopeRatio <= cliffSlopeRatioThreshold + 0.05;

    // Initial bearing ~35m ahead along the computed reroute path.
    var guideIdx = outPoints.length - 1;
    for (var i = 1; i < outPoints.length; i++) {
      if (outPoints[i].distanceM >= 35.0) {
        guideIdx = i;
        break;
      }
    }
    final initialBearingDeg = bearingDegrees(
      outPoints.first.lat,
      outPoints.first.lon,
      outPoints[guideIdx].lat,
      outPoints[guideIdx].lon,
    );

    final isRo = localeCode.toLowerCase().startsWith('ro');
    final cardinal = cardinalDirection(
      initialBearingDeg,
      localeCode: localeCode,
    );
    final distText = cumDist >= 1000.0
        ? '${(cumDist / 1000.0).toStringAsFixed(2)} km'
        : '${cumDist.round()} m';
    final instruction = isRo
        ? 'Îndreaptă-te spre $cardinal ($distText până la potecă)'
        : 'Head $cardinal ($distText to trail)';

    final String slopeAdvice;
    if (avoidedSteepHazard) {
      slopeAdvice = isRo
          ? 'Ocolește panta abruptă · +${ascent.round()} m / -${descent.round()} m (max ${maxSlopeDeg.round()}°)'
          : 'Avoids steep cliff · +${ascent.round()} m / -${descent.round()} m (max ${maxSlopeDeg.round()}°)';
    } else if (ascent > descent + 10.0) {
      slopeAdvice = isRo
          ? 'Urcare lină +${ascent.round()} m · pantă max ${maxSlopeDeg.round()}°'
          : 'Steady climb +${ascent.round()} m · max ${maxSlopeDeg.round()}°';
    } else if (descent > ascent + 10.0) {
      slopeAdvice = isRo
          ? 'Coborâre -${descent.round()} m · pantă max ${maxSlopeDeg.round()}°'
          : 'Descent -${descent.round()} m · max ${maxSlopeDeg.round()}°';
    } else {
      slopeAdvice = isRo
          ? 'Teren moderat · +${ascent.round()} m / -${descent.round()} m'
          : 'Moderate terrain · +${ascent.round()} m / -${descent.round()} m';
    }

    return OffTrailRerouteResult(
      mode: mode,
      points: outPoints,
      rejoinPoint: Geographic(lat: chosenTarget.lat, lon: chosenTarget.lon),
      rejoinAlongTrackM: chosenTarget.alongTrackM,
      rejoinEleM: outPoints.last.ele,
      distanceM: cumDist,
      estimatedSeconds: estSec.round(),
      ascentM: ascent,
      descentM: descent,
      maxSlopeDeg: maxSlopeDeg,
      avoidedSteepHazard: avoidedSteepHazard,
      initialBearingDeg: initialBearingDeg,
      instruction: instruction,
      slopeAdvice: slopeAdvice,
    );
  }

  static bool _lineHitsSteepHazard({
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required double stepM,
    required double Function(double x, double y) eleAtXY,
  }) {
    final dx = x1 - x0;
    final dy = y1 - y0;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 5.0) return false;
    final steps = math.max(2, (len / stepM).ceil());
    final segLen = len / steps;
    var prevEle = eleAtXY(x0, y0);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final currEle = eleAtXY(x0 + dx * t, y0 + dy * t);
      if (segLen > 0.5 &&
          ((currEle - prevEle) / segLen).abs() > cliffSlopeRatioThreshold) {
        return true;
      }
      prevEle = currEle;
    }
    return false;
  }

  static List<({double x, double y})> _smoothPathSafely(
    List<({double x, double y})> path, {
    required double cellSize,
    required OffTrailMode mode,
    required double Function(double x, double y) eleAtXY,
  }) {
    if (path.length <= 2) return path;

    final result = <({double x, double y})>[path.first];
    var anchorIdx = 0;

    while (anchorIdx < path.length - 1) {
      var farthest = anchorIdx + 1;
      for (var cand = path.length - 1; cand > anchorIdx + 1; cand--) {
        if (_canShortcut(
          path: path,
          fromIdx: anchorIdx,
          toIdx: cand,
          stepM: math.max(8.0, cellSize * 0.5),
          mode: mode,
          eleAtXY: eleAtXY,
        )) {
          farthest = cand;
          break;
        }
      }
      result.add(path[farthest]);
      anchorIdx = farthest;
    }
    return result;
  }

  static bool _canShortcut({
    required List<({double x, double y})> path,
    required int fromIdx,
    required int toIdx,
    required double stepM,
    required OffTrailMode mode,
    required double Function(double x, double y) eleAtXY,
  }) {
    final a = path[fromIdx];
    final b = path[toIdx];
    if (_lineHitsSteepHazard(
      x0: a.x,
      y0: a.y,
      x1: b.x,
      y1: b.y,
      stepM: stepM,
      eleAtXY: eleAtXY,
    )) {
      return false;
    }

    if (mode != OffTrailMode.minClimb) return true;

    // In minClimb mode, reject shortcuts that climb more than the A* detour.
    var rawAscent = 0.0;
    var prevRawEle = eleAtXY(a.x, a.y);
    for (var i = fromIdx + 1; i <= toIdx; i++) {
      final currEle = eleAtXY(path[i].x, path[i].y);
      if (currEle > prevRawEle) rawAscent += currEle - prevRawEle;
      prevRawEle = currEle;
    }

    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final len = math.sqrt(dx * dx + dy * dy);
    final steps = math.max(2, (len / stepM).ceil());
    var chordAscent = 0.0;
    var prevChordEle = eleAtXY(a.x, a.y);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final currEle = eleAtXY(a.x + dx * t, a.y + dy * t);
      if (currEle > prevChordEle) chordAscent += currEle - prevChordEle;
      prevChordEle = currEle;
    }

    return chordAscent <= rawAscent + 2.0;
  }

  /// Computes a terrain-aware 16-neighbor DEM A* rescue route directly from
  /// [userPos] to an SOS requester's [targetPos] (`(sos.lat, sos.lon, sos.ele)`),
  /// avoiding `> 36.8°` cliffs and steep hazards.
  static OffTrailRerouteResult? computeDirectRescueRoute({
    required Geographic userPos,
    double? userEleM,
    required Geographic targetPos,
    double? targetEleM,
    List<NavTrackPoint> referencePoints = const [],
    required ElevationSampler sampler,
    OffTrailMode mode = OffTrailMode.minClimb,
    String localeCode = 'ro',
    bool isCycling = false,
  }) {
    if (!userPos.lat.isFinite ||
        !userPos.lon.isFinite ||
        !targetPos.lat.isFinite ||
        !targetPos.lon.isFinite) {
      return null;
    }

    const mPerDegLat = 111320.0;
    final mPerDegLon =
        111320.0 * math.max(0.1, math.cos(userPos.lat * math.pi / 180.0));

    double toX(double lon) => (lon - userPos.lon) * mPerDegLon;
    double toY(double lat) => (lat - userPos.lat) * mPerDegLat;
    double toLat(double y) => userPos.lat + y / mPerDegLat;
    double toLon(double x) => userPos.lon + x / mPerDegLon;

    final targetX = toX(targetPos.lon);
    final targetY = toY(targetPos.lat);
    final directDistM = math.sqrt(targetX * targetX + targetY * targetY);

    // Build IDW fallback references from user, SOS target, and any trail points.
    final idwRefs = <({double x, double y, double ele})>[];
    if (userEleM != null && userEleM.isFinite) {
      idwRefs.add((x: 0.0, y: 0.0, ele: userEleM));
    }
    if (targetEleM != null && targetEleM.isFinite) {
      idwRefs.add((x: targetX, y: targetY, ele: targetEleM));
    }
    if (referencePoints.isNotEmpty) {
      final idwStep = math.max(1, (referencePoints.length / 24).ceil());
      for (var i = 0; i < referencePoints.length; i += idwStep) {
        final p = referencePoints[i];
        idwRefs.add((x: toX(p.lon), y: toY(p.lat), ele: p.ele));
      }
    }

    double sampleWithFallback(double lat, double lon) {
      final dem = sampler(lat, lon);
      if (dem != null && dem.isFinite) return dem;
      if (idwRefs.isEmpty) return 0.0;
      final px = toX(lon);
      final py = toY(lat);
      var numSum = 0.0;
      var denSum = 0.0;
      for (final ref in idwRefs) {
        final dx = px - ref.x;
        final dy = py - ref.y;
        final dSq = dx * dx + dy * dy;
        if (dSq < 1.0) return ref.ele;
        final w = 1.0 / dSq;
        numSum += w * ref.ele;
        denSum += w;
      }
      return denSum > 0.0 ? numSum / denSum : 0.0;
    }

    final padM = math.max(180.0, math.min(900.0, 0.35 * directDistM));
    final minX = math.min(0.0, targetX) - padM;
    final maxX = math.max(0.0, targetX) + padM;
    final minY = math.min(0.0, targetY) - padM;
    final maxY = math.max(0.0, targetY) + padM;

    final spanX = maxX - minX;
    final spanY = maxY - minY;
    final maxSpan = math.max(spanX, spanY);
    var cellSize = (maxSpan / (_maxGridDim - 2)).clamp(15.0, 35.0);
    if (maxSpan / cellSize > _maxGridDim - 2) {
      cellSize = maxSpan / (_maxGridDim - 2);
    }

    final cols = (spanX / cellSize).ceil().clamp(3, _maxGridDim);
    final rows = (spanY / cellSize).ceil().clamp(3, _maxGridDim);
    final totalCells = cols * rows;

    int xToCol(double x) => ((x - minX) / cellSize).floor().clamp(0, cols - 1);
    int yToRow(double y) => ((y - minY) / cellSize).floor().clamp(0, rows - 1);
    double colToX(int c) => minX + (c + 0.5) * cellSize;
    double rowToY(int r) => minY + (r + 0.5) * cellSize;

    final startCol = xToCol(0.0);
    final startRow = yToRow(0.0);
    final startIdx = startRow * cols + startCol;

    final goalCol = xToCol(targetX);
    final goalRow = yToRow(targetY);
    final goalIdx = goalRow * cols + goalCol;
    final goalCellX = colToX(goalCol);
    final goalCellY = rowToY(goalRow);

    final eleGrid = Float64List(totalCells);
    for (var i = 0; i < totalCells; i++) {
      eleGrid[i] = double.nan;
    }
    double cellEle(int col, int row) {
      final idx = row * cols + col;
      final cached = eleGrid[idx];
      if (!cached.isNaN) return cached;
      final val = sampleWithFallback(toLat(rowToY(row)), toLon(colToX(col)));
      eleGrid[idx] = val;
      return val;
    }

    final maxOffTrailSpeedMs = 0.6 * (isCycling ? 32.0 : 7.5) / 3.6;
    final minCostPerMeter = mode == OffTrailMode.minClimb
        ? (1.0 / maxOffTrailSpeedMs)
        : 1.0;

    double heuristic(int col, int row) {
      final dx = colToX(col) - goalCellX;
      final dy = rowToY(row) - goalCellY;
      return minCostPerMeter * math.sqrt(dx * dx + dy * dy);
    }

    double edgeCost(int c0, int r0, int c1, int r1, double distM) {
      final e0 = cellEle(c0, r0);
      final e1 = cellEle(c1, r1);
      final dEle = e1 - e0;
      final s = distM > 0.0 ? dEle / distM : 0.0;
      final absS = s.abs();

      var hazardMult = absS > cliffSlopeRatioThreshold
          ? 40.0
          : (absS > _steepSlopeRatioThreshold && mode == OffTrailMode.minClimb
                ? 4.0
                : 1.0);

      final dc = c1 - c0;
      final dr = r1 - r0;
      if (dc.abs() + dr.abs() == 3) {
        final midC1 = c0 + (dc.abs() == 2 ? dc.sign : 0);
        final midR1 = r0 + (dr.abs() == 2 ? dr.sign : 0);
        final midC2 = c0 + dc.sign;
        final midR2 = r0 + dr.sign;
        final halfDist = distM * 0.5;
        final sMid1 = ((cellEle(midC1, midR1) - e0) / halfDist).abs();
        final sMid2 = ((cellEle(midC2, midR2) - e0) / halfDist).abs();
        if (sMid1 > cliffSlopeRatioThreshold ||
            sMid2 > cliffSlopeRatioThreshold) {
          hazardMult = math.max(hazardMult, 40.0);
        }
      }

      if (mode == OffTrailMode.minClimb) {
        final vMs = 0.6 * toblerSpeedKmh(s, isCycling: isCycling) / 3.6;
        final baseSec = distM / math.max(0.15, vMs);
        final climbPenalty = 6.5 * math.max(0.0, dEle);
        final steepDescPenalty = s < -0.20 ? 2.0 * dEle.abs() : 0.0;
        return (baseSec + climbPenalty + steepDescPenalty) * hazardMult;
      } else {
        return (distM + 1.0 * math.max(0.0, dEle)) * hazardMult;
      }
    }

    final rawCoords = <({double x, double y})>[];
    if (directDistM >= 8.0 && startIdx != goalIdx) {
      final gScore = Float64List(totalCells);
      final fScore = Float64List(totalCells);
      final cameFrom = Int32List(totalCells);
      final closed = Uint8List(totalCells);

      for (var i = 0; i < totalCells; i++) {
        gScore[i] = double.infinity;
        fScore[i] = double.infinity;
        cameFrom[i] = -1;
      }

      gScore[startIdx] = 0.0;
      fScore[startIdx] = heuristic(startCol, startRow);

      final openHeap = _IntMinHeap(fScore)..push(startIdx);
      var reachedGoal = false;

      while (!openHeap.isEmpty) {
        final curr = openHeap.pop();
        if (curr == goalIdx) {
          reachedGoal = true;
          break;
        }
        if (closed[curr] != 0) continue;
        closed[curr] = 1;

        final cc = curr % cols;
        final cr = curr ~/ cols;
        for (final (dc, dr) in _neighbors16) {
          final nc = cc + dc;
          final nr = cr + dr;
          if (nc < 0 || nc >= cols || nr < 0 || nr >= rows) continue;
          final nIdx = nr * cols + nc;
          if (closed[nIdx] != 0) continue;

          final stepDist = math.sqrt(dc * dc + dr * dr) * cellSize;
          final tentativeG = gScore[curr] + edgeCost(cc, cr, nc, nr, stepDist);
          if (tentativeG < gScore[nIdx]) {
            cameFrom[nIdx] = curr;
            gScore[nIdx] = tentativeG;
            fScore[nIdx] = tentativeG + heuristic(nc, nr);
            openHeap.push(nIdx);
          }
        }
      }

      if (reachedGoal) {
        final reversedIdx = <int>[];
        var cur = goalIdx;
        while (cur != -1) {
          reversedIdx.add(cur);
          if (cur == startIdx) break;
          cur = cameFrom[cur];
        }
        for (var i = reversedIdx.length - 1; i >= 0; i--) {
          final idx = reversedIdx[i];
          rawCoords.add((x: colToX(idx % cols), y: rowToY(idx ~/ cols)));
        }
      }
    }

    if (rawCoords.isEmpty) {
      rawCoords.add((x: 0.0, y: 0.0));
      rawCoords.add((x: targetX, y: targetY));
    } else {
      rawCoords[0] = (x: 0.0, y: 0.0);
      if (rawCoords.length == 1) {
        rawCoords.add((x: targetX, y: targetY));
      } else {
        rawCoords[rawCoords.length - 1] = (x: targetX, y: targetY);
      }
    }

    final smoothedCoords = _smoothPathSafely(
      rawCoords,
      cellSize: cellSize,
      mode: mode,
      eleAtXY: (x, y) => sampleWithFallback(toLat(y), toLon(x)),
    );

    final directHitCliff = _lineHitsSteepHazard(
      x0: 0.0,
      y0: 0.0,
      x1: targetX,
      y1: targetY,
      stepM: math.max(10.0, cellSize * 0.5),
      eleAtXY: (x, y) => sampleWithFallback(toLat(y), toLon(x)),
    );

    final outPoints = <OffTrailPoint>[];
    var cumDist = 0.0;
    var ascent = 0.0;
    var descent = 0.0;
    var estSec = 0.0;
    var maxAbsSlopeRatio = 0.0;

    final eles = <double>[
      for (var i = 0; i < smoothedCoords.length; i++)
        if (i == 0 &&
            userEleM != null &&
            userEleM.isFinite &&
            sampler(userPos.lat, userPos.lon) == null)
          userEleM
        else if (i == smoothedCoords.length - 1 &&
            targetEleM != null &&
            targetEleM.isFinite &&
            sampler(targetPos.lat, targetPos.lon) == null)
          targetEleM
        else
          sampleWithFallback(
            toLat(smoothedCoords[i].y),
            toLon(smoothedCoords[i].x),
          ),
    ];

    for (var i = 0; i < smoothedCoords.length; i++) {
      final lat = i == 0
          ? userPos.lat
          : (i == smoothedCoords.length - 1
                ? targetPos.lat
                : toLat(smoothedCoords[i].y));
      final lon = i == 0
          ? userPos.lon
          : (i == smoothedCoords.length - 1
                ? targetPos.lon
                : toLon(smoothedCoords[i].x));
      final ele = eles[i];
      var gradePct = 0.0;

      if (i > 0) {
        final prev = outPoints[i - 1];
        final d = SphericalGreatCircle(
          Geographic(lat: prev.lat, lon: prev.lon),
        ).distanceTo(Geographic(lat: lat, lon: lon));
        final segDist = d.isFinite ? d : 0.0;
        cumDist += segDist;
        final dEle = ele - prev.ele;
        if (dEle > 0) ascent += dEle;
        if (dEle < 0) descent += -dEle;

        final slopeRatio = segDist > 0.5 ? dEle / segDist : 0.0;
        if (slopeRatio.abs() > maxAbsSlopeRatio) {
          maxAbsSlopeRatio = slopeRatio.abs();
        }
        gradePct = slopeRatio * 100.0;
        final speedMs =
            0.6 * toblerSpeedKmh(slopeRatio, isCycling: isCycling) / 3.6;
        if (segDist > 0.0) {
          estSec += segDist / math.max(0.15, speedMs);
        }
      }

      outPoints.add(
        OffTrailPoint(
          lat: lat,
          lon: lon,
          ele: ele,
          distanceM: cumDist,
          gradePct: gradePct,
        ),
      );
    }

    final maxSlopeDeg = math.atan(maxAbsSlopeRatio) * 180.0 / math.pi;
    final avoidedSteepHazard =
        directHitCliff && maxAbsSlopeRatio <= cliffSlopeRatioThreshold + 0.05;

    var guideIdx = outPoints.length - 1;
    for (var i = 1; i < outPoints.length; i++) {
      if (outPoints[i].distanceM >= 35.0) {
        guideIdx = i;
        break;
      }
    }
    final initialBearingDeg = bearingDegrees(
      outPoints.first.lat,
      outPoints.first.lon,
      outPoints[guideIdx].lat,
      outPoints[guideIdx].lon,
    );

    final isRo = localeCode.toLowerCase().startsWith('ro');
    final cardinal = cardinalDirection(
      initialBearingDeg,
      localeCode: localeCode,
    );
    final distText = cumDist >= 1000.0
        ? '${(cumDist / 1000.0).toStringAsFixed(2)} km'
        : '${cumDist.round()} m';
    final instruction = cumDist < 12.0
        ? (isRo ? 'Ai ajuns la persoana în dificultate' : 'Reached SOS location')
        : (isRo
              ? 'Rută salvare spre $cardinal ($distText până la persoană)'
              : 'Rescue route $cardinal ($distText to person)');

    final String slopeAdvice;
    if (avoidedSteepHazard) {
      slopeAdvice = isRo
          ? 'Ocolește panta abruptă · +${ascent.round()} m / -${descent.round()} m (max ${maxSlopeDeg.round()}°)'
          : 'Avoids steep cliff · +${ascent.round()} m / -${descent.round()} m (max ${maxSlopeDeg.round()}°)';
    } else if (ascent > descent + 10.0) {
      slopeAdvice = isRo
          ? 'Urcare +${ascent.round()} m · pantă max ${maxSlopeDeg.round()}°'
          : 'Climb +${ascent.round()} m · max ${maxSlopeDeg.round()}°';
    } else if (descent > ascent + 10.0) {
      slopeAdvice = isRo
          ? 'Coborâre -${descent.round()} m · pantă max ${maxSlopeDeg.round()}°'
          : 'Descent -${descent.round()} m · max ${maxSlopeDeg.round()}°';
    } else {
      slopeAdvice = isRo
          ? 'Teren moderat · +${ascent.round()} m / -${descent.round()} m'
          : 'Moderate terrain · +${ascent.round()} m / -${descent.round()} m';
    }

    return OffTrailRerouteResult(
      mode: mode,
      points: outPoints,
      rejoinPoint: targetPos,
      rejoinAlongTrackM: 0.0,
      rejoinEleM: outPoints.last.ele,
      distanceM: cumDist,
      estimatedSeconds: estSec.round(),
      ascentM: ascent,
      descentM: descent,
      maxSlopeDeg: maxSlopeDeg,
      avoidedSteepHazard: avoidedSteepHazard,
      initialBearingDeg: initialBearingDeg,
      instruction: instruction,
      slopeAdvice: slopeAdvice,
    );
  }
}

/// Top-level convenience wrapper for [OffTrailRouter.computeDirectRescueRoute].
OffTrailRerouteResult? computeDirectRescueRoute({
  required Geographic userPos,
  double? userEleM,
  required Geographic targetPos,
  double? targetEleM,
  List<NavTrackPoint> referencePoints = const [],
  required ElevationSampler sampler,
  OffTrailMode mode = OffTrailMode.minClimb,
  String localeCode = 'ro',
  bool isCycling = false,
}) => OffTrailRouter.computeDirectRescueRoute(
  userPos: userPos,
  userEleM: userEleM,
  targetPos: targetPos,
  targetEleM: targetEleM,
  referencePoints: referencePoints,
  sampler: sampler,
  mode: mode,
  localeCode: localeCode,
  isCycling: isCycling,
);
