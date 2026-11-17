import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/models/waypoint.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';
import 'package:wanderer/util/navigation/trail_maneuver_synthesizer.dart';
import 'package:wanderer/util/route/track_position_matcher.dart';

Gpx _buildRidgeTrailGpx() {
  // Runs north ~1.0 km, then turns sharply east ~1.0 km, climbing over a
  // central 100 m summit and descending.
  final pts = <Wpt>[];
  for (var i = 0; i <= 20; i++) {
    final ele = 1000.0 + (i <= 10 ? i * 12.0 : (20 - i) * 12.0);
    pts.add(
      Wpt(
        lat: 45.5000 + i * 0.00045, // ~50 m per step north
        lon: 25.5000,
        ele: ele,
      ),
    );
  }
  for (var j = 1; j <= 10; j++) {
    pts.add(
      Wpt(
        lat: 45.5000 + 20 * 0.00045,
        lon: 25.5000 + j * 0.00064, // ~50 m per step east
        ele: 1000.0 - j * 8.0, // steep descent (>14%)
      ),
    );
  }
  return Gpx()
    ..trks = [
      Trk(trksegs: [Trkseg(trkpts: pts)]),
    ];
}

void main() {
  group('EtaCalculator', () {
    test('computes Tobler remaining time, arrival HH:mm, climb, and summit', () {
      final gpx = _buildRidgeTrailGpx();
      final calc = EtaCalculator.fromGpx(gpx);
      final fixedNow = DateTime(2026, 6, 15, 10, 0);

      final startSnap = calc.compute(0.0, now: fixedNow);
      expect(startSnap.remainingDistanceM, greaterThan(1400.0));
      expect(startSnap.remainingSeconds, greaterThan(600));
      expect(startSnap.arrivalTimeFormatted, matches(RegExp(r'^\d{2}:\d{2}$')));
      expect(startSnap.remainingAscentM, greaterThan(90.0));
      expect(startSnap.nextPeak, isNotNull);
      expect(startSnap.nextPeak!.ele, closeTo(1110.0, 20.0));

      final midSnap = calc.compute(calc.totalDistanceM * 0.6, now: fixedNow);
      expect(midSnap.remainingDistanceM, lessThan(startSnap.remainingDistanceM));
      expect(midSnap.remainingSeconds, lessThan(startSnap.remainingSeconds));
      expect(midSnap.progressRatio, closeTo(0.6, 0.05));
    });

    test('adapts EMA paceFactor clamped to [0.55, 1.85]', () {
      final gpx = _buildRidgeTrailGpx();
      final calc = EtaCalculator.fromGpx(gpx);

      final t0 = DateTime(2026, 6, 15, 10, 0, 0);
      calc.recordProgress(0.0, t0);
      // Very slow hike (0.5 m/s over 100 m = 200 s)
      calc.recordProgress(100.0, t0.add(const Duration(seconds: 200)));
      expect(calc.paceFactor, greaterThan(1.0));
      expect(calc.paceFactor, lessThanOrEqualTo(1.85));

      // Repeat fast progress to test lower bound clamping.
      var t = t0.add(const Duration(seconds: 200));
      for (var k = 1; k <= 10; k++) {
        t = t.add(const Duration(seconds: 5));
        calc.recordProgress(100.0 + k * 80.0, t);
      }
      expect(calc.paceFactor, greaterThanOrEqualTo(0.55));
    });

    test('folds offTrailExtra into remaining distance, duration, and ascent', () {
      final gpx = _buildRidgeTrailGpx();
      final calc = EtaCalculator.fromGpx(gpx);
      final fixedNow = DateTime(2026, 6, 15, 10, 0);

      final base = calc.compute(500.0, now: fixedNow);
      final withDetour = calc.compute(
        200.0,
        now: fixedNow,
        offTrailDistanceM: 120.0,
        offTrailDurationSec: 180,
        offTrailAscentM: 35.0,
        rejoinAlongTrackM: 500.0,
      );

      expect(withDetour.remainingDistanceM, closeTo(base.remainingDistanceM + 120.0, 1e-6));
      expect(withDetour.remainingSeconds, base.remainingSeconds + 180);
      expect(withDetour.remainingAscentM, closeTo(base.remainingAscentM + 35.0, 1e-6));
    });
  });

  group('TrailManeuverSynthesizer', () {
    test('detects start, right turn, summit, waypoint, and destination', () {
      final gpx = _buildRidgeTrailGpx();
      final now = DateTime.utc(2026, 6, 15);
      final waypoints = [
        Waypoint(
          id: 'wp1',
          name: 'Izvor',
          lat: 45.5000 + 5 * 0.00045,
          lon: 25.5000,
          created: now,
          updated: now,
        ),
      ];

      final roNav = TrailManeuverSynthesizer.fromGpx(
        gpx,
        waypoints: waypoints,
        localeCode: 'ro',
      );
      expect(roNav.shape.length, greaterThanOrEqualTo(30));
      expect(roNav.maneuvers.first.type, TrailManeuverSynthesizer.typeStart);
      expect(roNav.maneuvers.last.type, TrailManeuverSynthesizer.typeDestination);
      expect(roNav.maneuvers.last.length, 0.0);
      expect(
        roNav.maneuvers.any((m) => m.type == TrailManeuverSynthesizer.typeRight),
        isTrue,
      );
      expect(
        roNav.maneuvers.any((m) => m.instruction.contains('Izvor')),
        isTrue,
      );

      final enNav = TrailManeuverSynthesizer.fromGpx(
        gpx,
        waypoints: waypoints,
        localeCode: 'en',
      );
      expect(enNav.maneuvers.first.instruction, contains('Start'));
      expect(enNav.maneuvers.last.instruction, contains('arrived'));
    });
  });

  group('DemTileGrid', () {
    test('decodes Terrarium RGB pixels and bilinearly interpolates', () {
      final grid = DemTileGrid();
      const lat = 45.5000;
      const lon = 25.5000;
      final tc = DemTileGrid.latLonToTile(lat, lon);

      // Encode constant 1250.5 m across a 4x4 synthetic tile:
      // 1250.5 + 32768 = 34018.5 => R = 132, G = 226, B = 128
      const r = 132;
      const g = 226;
      const b = 128;
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = r;
        rgba[i + 1] = g;
        rgba[i + 2] = b;
        rgba[i + 3] = 255;
      }
      grid.putTileRgbaForTest(tc.x, tc.y, width: 4, height: 4, rgba: rgba);

      final sampled = grid.sampleElevation(lat, lon);
      expect(sampled, isNotNull);
      expect(sampled!, closeTo(1250.5, 0.05));
    });
  });

  group('OffTrailRouter', () {
    test('contours around a 45-degree cliff hazard in minClimb mode', () {
      // Straight north-south trail along lon = 25.5000 (x = 0).
      final trail = <NavTrackPoint>[];
      var dist = 0.0;
      for (var i = 0; i <= 20; i++) {
        final lat = 45.5000 + i * 0.00025; // ~27.8 m per step
        if (i > 0) {
          dist += SphericalGreatCircle(
            Geographic(lat: trail[i - 1].lat, lon: 25.5000),
          ).distanceTo(Geographic(lat: lat, lon: 25.5000));
        }
        trail.add(
          NavTrackPoint(
            lat: lat,
            lon: 25.5000,
            ele: 1000.0,
            distanceM: dist,
            gradePct: 0.0,
          ),
        );
      }

      // User is 180 m west of trail midpoint.
      const userPos = Geographic(lat: 45.5025, lon: 25.4977);
      final mPerDegLon = 111320.0 * 0.7009; // cos(45.5 deg)

      // Synthetic 45-degree steep mesa directly between user and trail
      // around lat 45.5020..45.5030, lon 25.4984..25.4995, leaving flat
      // contour corridors north/south of it.
      double cliffSampler(double lat, double lon) {
        final dLatM = (lat - 45.5025) * 111320.0;
        final dLonM = (lon - 25.49895) * mPerDegLon;
        if (dLatM.abs() < 60.0 && dLonM.abs() < 45.0) {
          return 1200.0; // 200 m sheer cliff rise over <45 m => > 77°
        }
        return 1000.0;
      }

      final result = OffTrailRouter.compute(
        userPos: userPos,
        userEleM: 1000.0,
        trailPoints: trail,
        lastAlongTrackM: dist * 0.4,
        sampler: cliffSampler,
        mode: OffTrailMode.minClimb,
        localeCode: 'ro',
      );

      expect(result, isNotNull);
      expect(result!.points.length, greaterThanOrEqualTo(3));
      expect(result.maxSlopeDeg, lessThan(37.0));
      expect(result.avoidedSteepHazard, isTrue);
      expect(result.ascentM, lessThan(20.0));
      expect(result.instruction, contains('până la potecă'));
    });

    test('falls back cleanly to IDW elevation when DEM sampler returns null', () {
      final trail = [
        const NavTrackPoint(
          lat: 45.5000,
          lon: 25.5000,
          ele: 1020.0,
          distanceM: 0.0,
          gradePct: 0.0,
        ),
        const NavTrackPoint(
          lat: 45.5020,
          lon: 25.5000,
          ele: 1040.0,
          distanceM: 222.6,
          gradePct: 9.0,
        ),
      ];
      final res = OffTrailRouter.compute(
        userPos: const Geographic(lat: 45.5010, lon: 25.4985),
        userEleM: 1010.0,
        trailPoints: trail,
        lastAlongTrackM: 50.0,
        sampler: (_, _) => null,
        mode: OffTrailMode.shortestSafe,
        localeCode: 'en',
      );
      expect(res, isNotNull);
      expect(res!.distanceM, greaterThan(80.0));
      expect(res.instruction, contains('to trail'));
    });
  });

  group('TrackPositionMatcher.matchDetailed', () {
    test('applies 3-fix off-trail hysteresis and <= 22 m rejoin exit', () {
      final shape = List.generate(
        20,
        (i) => Geographic(lat: 47.0000 + 0.0002 * i, lon: 9.0000),
      );
      final cum = List<double>.filled(shape.length, 0.0);
      for (var i = 1; i < shape.length; i++) {
        cum[i] =
            cum[i - 1] + SphericalGreatCircle(shape[i - 1]).distanceTo(shape[i]);
      }

      final matcher = TrackPositionMatcher(
        shape: shape,
        cumulativeMeters: cum,
      );

      // Start on track.
      final onTrack = matcher.matchDetailed(shape[3], accuracy: 10.0);
      expect(onTrack, isNotNull);
      expect(onTrack!.isOffTrail, isFalse);

      // ~100 m east off-trail: fixes 1 & 2 stay on-trail (hysteresis).
      final farFix = Geographic(lat: shape[4].lat, lon: shape[4].lon + 0.0014);
      final fix1 = matcher.matchDetailed(farFix, accuracy: 10.0);
      final fix2 = matcher.matchDetailed(farFix, accuracy: 10.0);
      expect(fix1!.isOffTrail, isFalse);
      expect(fix1.consecutiveOffTrailFixes, 1);
      expect(fix2!.isOffTrail, isFalse);
      expect(fix2.consecutiveOffTrailFixes, 2);

      // Fix 3 enters off-trail.
      final fix3 = matcher.matchDetailed(farFix, accuracy: 10.0);
      expect(fix3!.isOffTrail, isTrue);
      expect(fix3.crossTrackMeters, greaterThan(35.0));

      // Move to ~28 m off-trail (> 22 m rejoin threshold): stays off-trail.
      final nearButNotRejoined = Geographic(
        lat: shape[6].lat,
        lon: shape[6].lon + 0.00037,
      );
      final stillOff = matcher.matchDetailed(nearButNotRejoined, accuracy: 10.0);
      expect(stillOff!.isOffTrail, isTrue);

      // Rejoin within 10 m (<= 22 m): clears off-trail and snaps along-track.
      final rejoinFix = Geographic(
        lat: shape[8].lat,
        lon: shape[8].lon + 0.00010,
      );
      final rejoined = matcher.matchDetailed(rejoinFix, accuracy: 10.0);
      expect(rejoined!.isOffTrail, isFalse);
      expect(rejoined.consecutiveOffTrailFixes, 0);
      expect(rejoined.alongTrackMeters, closeTo(cum[8], 10.0));
    });

    test('scales entry threshold by max(35.0, 1.5 * accuracy)', () {
      final shape = List.generate(
        10,
        (i) => Geographic(lat: 47.0000 + 0.0002 * i, lon: 9.0000),
      );
      final cum = List<double>.filled(shape.length, 0.0);
      for (var i = 1; i < shape.length; i++) {
        cum[i] =
            cum[i - 1] + SphericalGreatCircle(shape[i - 1]).distanceTo(shape[i]);
      }

      final matcher = TrackPositionMatcher(
        shape: shape,
        cumulativeMeters: cum,
      );
      matcher.matchDetailed(shape[2], accuracy: 10.0);

      // ~50 m east with 40 m GPS accuracy -> entry threshold is 60 m -> stays on trail.
      final fix50m = Geographic(lat: shape[3].lat, lon: shape[3].lon + 0.00066);
      for (var i = 0; i < 4; i++) {
        final d = matcher.matchDetailed(fix50m, accuracy: 40.0);
        expect(d!.isOffTrail, isFalse);
      }
    });
  });
}
