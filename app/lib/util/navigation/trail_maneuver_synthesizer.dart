import 'dart:math' as math;

import 'package:gpx/gpx.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/models/navigate_response.dart';
import 'package:wanderer/models/waypoint.dart';
import 'package:wanderer/util/gpx/conversion.dart'
    show hasUsablePosition, parseGpxElevation;
import 'package:wanderer/util/gpx/gpx.dart';
import 'package:wanderer/util/map/heading_math.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';

class _RawEvent {
  const _RawEvent({
    required this.rawIndex,
    required this.priority,
    required this.type,
    required this.bearing,
    required this.instruction,
  });

  final int rawIndex;
  final int priority; // higher wins when two events are too close
  final int type;
  final double bearing;
  final String instruction;
}

/// Synthesizes Valhalla-compatible turn-by-turn maneuvers directly from GPX
/// track geometry, elevation grades, summits, and trail waypoints so navigation
/// works identically offline and on servers without Valhalla.
class TrailManeuverSynthesizer {
  const TrailManeuverSynthesizer._();

  static const int typeStart = 1;
  static const int typeDestination = 4;
  static const int typeContinue = 8;
  static const int typeSlightRight = 9;
  static const int typeRight = 10;
  static const int typeSharpRight = 11;
  static const int typeSharpLeft = 14;
  static const int typeLeft = 15;
  static const int typeSlightLeft = 16;

  /// Generates a [NavigateResponse] from [gpx] and optional [waypoints].
  static NavigateResponse fromGpx(
    Gpx gpx, {
    List<Waypoint>? waypoints,
    String localeCode = 'ro',
  }) {
    final allWpts = gpx.allWaypoints.where(hasUsablePosition).toList();
    if (allWpts.length < 2) {
      return const NavigateResponse(maneuvers: [], shape: []);
    }

    final hasElevation =
        allWpts.where((w) => parseGpxElevation(w.ele) != null).length >= 2;
    final navPoints = extractNavTrackPoints(gpx);
    if (navPoints.length < 2) {
      return const NavigateResponse(maneuvers: [], shape: []);
    }

    final wpRecords = <({double lat, double lon, String? name})>[
      if (waypoints != null)
        for (final wp in waypoints)
          if (wp.lat.isFinite && wp.lon.isFinite)
            (lat: wp.lat, lon: wp.lon, name: wp.name),
    ];

    return fromNavPoints(
      navPoints,
      waypoints: wpRecords,
      localeCode: localeCode,
      hasElevation: hasElevation,
    );
  }

  /// Generates a [NavigateResponse] from already-extracted [points].
  static NavigateResponse fromNavPoints(
    List<NavTrackPoint> points, {
    List<({double lat, double lon, String? name})> waypoints = const [],
    String localeCode = 'ro',
    bool hasElevation = true,
  }) {
    if (points.length < 2) {
      return const NavigateResponse(maneuvers: [], shape: []);
    }

    final isRo = localeCode.toLowerCase().startsWith('ro');
    final n = points.length;
    final totalDistM = points.last.distanceM;

    // Build downsampled shape (<= 500 points) matching buildNavShape().
    final sampledRawIndices = <int>[];
    if (n > 500) {
      final step = (n / 499).ceil();
      for (var i = 0; i < n; i++) {
        if (i % step == 0) sampledRawIndices.add(i);
      }
      if (sampledRawIndices.isEmpty || sampledRawIndices.last != n - 1) {
        sampledRawIndices.add(n - 1);
      }
    } else {
      for (var i = 0; i < n; i++) {
        sampledRawIndices.add(i);
      }
    }

    final shape = <List<double>>[
      for (final idx in sampledRawIndices)
        <double>[points[idx].lat, points[idx].lon],
    ];
    final shapeCumM = List<double>.filled(shape.length, 0.0);
    for (var i = 1; i < shape.length; i++) {
      final a = Geographic(lat: shape[i - 1][0], lon: shape[i - 1][1]);
      final b = Geographic(lat: shape[i][0], lon: shape[i][1]);
      final d = SphericalGreatCircle(a).distanceTo(b);
      shapeCumM[i] = shapeCumM[i - 1] + (d.isFinite ? d : 0.0);
    }

    final events = <_RawEvent>[];

    // 1. Start maneuver.
    final startTargetIdx = _indexAheadBy(points, 0, 25.0);
    final startBearing = bearingDegrees(
      points.first.lat,
      points.first.lon,
      points[startTargetIdx].lat,
      points[startTargetIdx].lon,
    );
    final startCardinal = cardinalDirection(
      startBearing,
      localeCode: localeCode,
    );
    events.add(
      _RawEvent(
        rawIndex: 0,
        priority: 100,
        type: typeStart,
        bearing: startBearing,
        instruction: isRo
            ? 'Pornește pe traseu spre $startCardinal'
            : 'Start on the trail heading $startCardinal',
      ),
    );

    // 2. Geometry turns using ~25m incoming vs ~25m outgoing chord bearings.
    var lastTurnDistM = -999.0;
    for (var i = 1; i < n - 1; i++) {
      final currDist = points[i].distanceM;
      if (currDist < 30.0 || totalDistM - currDist < 30.0) continue;

      final backIdx = _indexBehindBy(points, i, 25.0);
      final fwdIdx = _indexAheadBy(points, i, 25.0);
      if (backIdx == i || fwdIdx == i) continue;

      final inBearing = bearingDegrees(
        points[backIdx].lat,
        points[backIdx].lon,
        points[i].lat,
        points[i].lon,
      );
      final outBearing = bearingDegrees(
        points[i].lat,
        points[i].lon,
        points[fwdIdx].lat,
        points[fwdIdx].lon,
      );
      final delta = shortestAngleDelta(inBearing, outBearing);
      final absDelta = delta.abs();
      if (absDelta < 32.0) continue;

      final int turnType;
      final String instruction;
      if (absDelta >= 105.0) {
        turnType = delta > 0 ? typeSharpRight : typeSharpLeft;
        instruction = delta > 0
            ? (isRo ? 'Virează strâns dreapta' : 'Sharp right turn')
            : (isRo ? 'Virează strâns stânga' : 'Sharp left turn');
      } else if (absDelta >= 60.0) {
        turnType = delta > 0 ? typeRight : typeLeft;
        instruction = delta > 0
            ? (isRo ? 'Virează dreapta' : 'Turn right')
            : (isRo ? 'Virează stânga' : 'Turn left');
      } else {
        turnType = delta > 0 ? typeSlightRight : typeSlightLeft;
        instruction = delta > 0
            ? (isRo ? 'Virează ușor dreapta' : 'Keep slight right')
            : (isRo ? 'Virează ușor stânga' : 'Keep slight left');
      }

      if (currDist - lastTurnDistM < 60.0) {
        // Keep the sharper turn within the 60m spacing window.
        if (events.isNotEmpty &&
            events.last.priority == 3 &&
            _isSharperTurn(turnType, events.last.type)) {
          events[events.length - 1] = _RawEvent(
            rawIndex: i,
            priority: 3,
            type: turnType,
            bearing: outBearing,
            instruction: instruction,
          );
          lastTurnDistM = currDist;
        }
        continue;
      }

      events.add(
        _RawEvent(
          rawIndex: i,
          priority: 3,
          type: turnType,
          bearing: outBearing,
          instruction: instruction,
        ),
      );
      lastTurnDistM = currDist;
    }

    // 3. Sustained steep climbs (>= +14%) and steep descents (<= -14%) over >= 150m.
    if (hasElevation) {
      _detectSteepGradeEvents(
        points: points,
        isClimb: true,
        isRo: isRo,
        events: events,
      );
      _detectSteepGradeEvents(
        points: points,
        isClimb: false,
        isRo: isRo,
        events: events,
      );

      // 4. Highest summit along the trail (when overall relief >= 30 m).
      var minEle = points.first.ele;
      var maxEle = points.first.ele;
      var maxIdx = 0;
      for (var i = 0; i < n; i++) {
        if (points[i].ele < minEle) minEle = points[i].ele;
        if (points[i].ele > maxEle) {
          maxEle = points[i].ele;
          maxIdx = i;
        }
      }
      if (maxEle - minEle >= 30.0 &&
          points[maxIdx].distanceM > 50.0 &&
          totalDistM - points[maxIdx].distanceM > 50.0) {
        final fwd = _indexAheadBy(points, maxIdx, 25.0);
        final bearing = bearingDegrees(
          points[maxIdx].lat,
          points[maxIdx].lon,
          points[fwd].lat,
          points[fwd].lon,
        );
        events.add(
          _RawEvent(
            rawIndex: maxIdx,
            priority: 2,
            type: typeContinue,
            bearing: bearing,
            instruction: isRo
                ? 'Vârf · punct maxim (${maxEle.round()} m)'
                : 'Summit · high point (${maxEle.round()} m)',
          ),
        );
      }
    }

    // 5. Nearby trail waypoints within 40m of track.
    for (final wp in waypoints) {
      final name = wp.name?.trim() ?? '';
      if (name.isEmpty) continue;
      final wpGeo = Geographic(lat: wp.lat, lon: wp.lon);
      var bestIdx = -1;
      var bestDist = double.infinity;
      for (var i = 0; i < n; i++) {
        final d = SphericalGreatCircle(
          Geographic(lat: points[i].lat, lon: points[i].lon),
        ).distanceTo(wpGeo);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      if (bestIdx > 0 && bestIdx < n - 1 && bestDist <= 40.0) {
        final fwd = _indexAheadBy(points, bestIdx, 25.0);
        final bearing = bearingDegrees(
          points[bestIdx].lat,
          points[bestIdx].lon,
          points[fwd].lat,
          points[fwd].lon,
        );
        events.add(
          _RawEvent(
            rawIndex: bestIdx,
            priority: 4,
            type: typeContinue,
            bearing: bearing,
            instruction: isRo ? 'Punct de reper: $name' : 'Waypoint: $name',
          ),
        );
      }
    }

    // 6. Destination maneuver.
    final endBackIdx = _indexBehindBy(points, n - 1, 25.0);
    final endBearing = bearingDegrees(
      points[endBackIdx].lat,
      points[endBackIdx].lon,
      points.last.lat,
      points.last.lon,
    );
    events.add(
      _RawEvent(
        rawIndex: n - 1,
        priority: 100,
        type: typeDestination,
        bearing: endBearing,
        instruction: isRo
            ? 'Ai ajuns la destinație'
            : 'You have arrived at the destination',
      ),
    );

    // Sort and filter collisions within 45m (preserving start & destination).
    events.sort((a, b) {
      final cmp = a.rawIndex.compareTo(b.rawIndex);
      return cmp != 0 ? cmp : b.priority.compareTo(a.priority);
    });

    final filtered = <_RawEvent>[];
    for (final ev in events) {
      if (filtered.isEmpty) {
        filtered.add(ev);
        continue;
      }
      final prev = filtered.last;
      if (ev.type == typeDestination) {
        // Keep destination always at the end; drop colliding non-start event
        // right next to the finish line.
        if (prev.type != typeStart &&
            totalDistM - points[prev.rawIndex].distanceM < 35.0) {
          filtered.removeLast();
        }
        filtered.add(ev);
        continue;
      }
      final gap = points[ev.rawIndex].distanceM - points[prev.rawIndex].distanceM;
      if (gap < 45.0) {
        if (prev.priority < ev.priority && prev.type != typeStart) {
          filtered[filtered.length - 1] = ev;
        }
        continue;
      }
      filtered.add(ev);
    }

    // Map raw event indices onto downsampled shape indices.
    final mappedIndices = <int>[];
    final keptEvents = <_RawEvent>[];
    for (final ev in filtered) {
      int shapeIdx;
      if (ev.type == typeStart) {
        shapeIdx = 0;
      } else if (ev.type == typeDestination) {
        shapeIdx = shape.length - 1;
      } else {
        shapeIdx = _nearestShapeIndex(sampledRawIndices, ev.rawIndex);
        if (shape.length > 2) {
          shapeIdx = shapeIdx.clamp(1, shape.length - 2);
        }
      }

      if (keptEvents.isNotEmpty &&
          ev.type != typeDestination &&
          shapeIdx <= mappedIndices.last) {
        continue;
      }
      if (ev.type == typeDestination &&
          keptEvents.isNotEmpty &&
          shapeIdx <= mappedIndices.last &&
          shape.length > 2 &&
          keptEvents.last.type != typeStart) {
        keptEvents.removeLast();
        mappedIndices.removeLast();
      }
      keptEvents.add(ev);
      mappedIndices.add(shapeIdx);
    }

    // Assemble final NavigateManeuver list with `length` in km to next maneuver.
    final maneuvers = <NavigateManeuver>[];
    for (var i = 0; i < keptEvents.length; i++) {
      final ev = keptEvents[i];
      final beginIdx = mappedIndices[i];
      final nextIdx = i + 1 < keptEvents.length ? mappedIndices[i + 1] : beginIdx;
      final distKm = i + 1 < keptEvents.length
          ? math.max(0.0, shapeCumM[nextIdx] - shapeCumM[beginIdx]) / 1000.0
          : 0.0;
      maneuvers.add(
        NavigateManeuver(
          instruction: ev.instruction,
          length: distKm,
          beginShapeIndex: beginIdx,
          bearing: ev.bearing,
          type: ev.type,
        ),
      );
    }

    return NavigateResponse(maneuvers: maneuvers, shape: shape);
  }

  static void _detectSteepGradeEvents({
    required List<NavTrackPoint> points,
    required bool isClimb,
    required bool isRo,
    required List<_RawEvent> events,
  }) {
    final n = points.length;
    var runStart = -1;
    var lastWarnDist = -999.0;

    void flushRun(int endIdx) {
      if (runStart == -1) return;
      final span = points[endIdx].distanceM - points[runStart].distanceM;
      if (span >= 150.0 && points[runStart].distanceM - lastWarnDist >= 350.0) {
        final eleDelta = (points[endIdx].ele - points[runStart].ele).abs();
        final avgGrade = span > 0 ? (eleDelta / span) * 100.0 : 14.0;
        if (avgGrade >= 14.0 && eleDelta >= 20.0) {
          final fwd = _indexAheadBy(points, runStart, 25.0);
          final bearing = bearingDegrees(
            points[runStart].lat,
            points[runStart].lon,
            points[fwd].lat,
            points[fwd].lon,
          );
          events.add(
            _RawEvent(
              rawIndex: runStart,
              priority: 1,
              type: typeContinue,
              bearing: bearing,
              instruction: isClimb
                  ? (isRo
                        ? 'Urcare abruptă (${avgGrade.round()}%, +${eleDelta.round()} m)'
                        : 'Steep climb (${avgGrade.round()}%, +${eleDelta.round()} m)')
                  : (isRo
                        ? 'Coborâre abruptă (-${avgGrade.round()}%, -${eleDelta.round()} m)'
                        : 'Steep descent (-${avgGrade.round()}%, -${eleDelta.round()} m)'),
            ),
          );
          lastWarnDist = points[runStart].distanceM;
        }
      }
      runStart = -1;
    }

    for (var i = 1; i < n; i++) {
      final g = points[i].gradePct;
      final matches = isClimb ? g >= 14.0 : g <= -14.0;
      if (matches) {
        runStart = runStart == -1 ? i - 1 : runStart;
      } else {
        flushRun(i - 1);
      }
    }
    flushRun(n - 1);
  }

  static bool _isSharperTurn(int candidateType, int existingType) {
    int rank(int t) => switch (t) {
      typeSharpRight || typeSharpLeft => 3,
      typeRight || typeLeft => 2,
      typeSlightRight || typeSlightLeft => 1,
      _ => 0,
    };
    return rank(candidateType) > rank(existingType);
  }

  static int _indexBehindBy(
    List<NavTrackPoint> points,
    int index,
    double meters,
  ) {
    final targetDist = points[index].distanceM - meters;
    var j = index;
    while (j > 0 && points[j].distanceM > targetDist) {
      j--;
    }
    return j;
  }

  static int _indexAheadBy(
    List<NavTrackPoint> points,
    int index,
    double meters,
  ) {
    final targetDist = points[index].distanceM + meters;
    var j = index;
    while (j < points.length - 1 && points[j].distanceM < targetDist) {
      j++;
    }
    return j;
  }

  static int _nearestShapeIndex(List<int> sampledRawIndices, int rawIdx) {
    var lo = 0;
    var hi = sampledRawIndices.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sampledRawIndices[mid] < rawIdx) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 &&
        (sampledRawIndices[lo] - rawIdx).abs() >
            (rawIdx - sampledRawIndices[lo - 1]).abs()) {
      return lo - 1;
    }
    return lo;
  }
}
