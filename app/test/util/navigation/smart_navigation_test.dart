import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/geo/polyline.dart';
import 'package:wanderer/util/navigation/cooperative_gps_fusion.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/gps_pace_coaster.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';
import 'package:wanderer/util/route/track_position_matcher.dart';

class _FakeValhallaAdapter implements HttpClientAdapter {
  _FakeValhallaAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => _handler(options);

  @override
  void close({bool force = false}) {}
}

List<NavTrackPoint> _buildNorthTrail({int count = 25}) {
  final pts = <NavTrackPoint>[];
  var cumDist = 0.0;
  for (var i = 0; i < count; i++) {
    final lat = 45.4400 + i * 0.00045; // ~50 m per step north
    const lon = 25.5500;
    final ele = 1000.0 + i * 2.0;
    if (i > 0) {
      cumDist += SphericalGreatCircle(
        Geographic(lat: pts[i - 1].lat, lon: pts[i - 1].lon),
      ).distanceTo(Geographic(lat: lat, lon: lon));
    }
    pts.add(
      NavTrackPoint(
        lat: lat,
        lon: lon,
        ele: ele,
        distanceM: cumDist,
        gradePct: 4.0,
      ),
    );
  }
  return pts;
}

bool _pointInsideRect(
  double lat,
  double lon, {
  required double minLat,
  required double maxLat,
  required double minLon,
  required double maxLon,
}) {
  return lat > minLat && lat < maxLat && lon > minLon && lon < maxLon;
}

void main() {
  group('CooperativeGpsFusion (IVW + Proximity Gate + Group Tether)', () {
    test('sharpens noisy canopy GPS (60m) using nearby peer (6m) within gate', () {
      const now = 1700000000000;
      final res = CooperativeGpsFusion.fuse(
        selfFix: const SelfGpsObservation(
          lat: 45.4400,
          lon: 25.5504,
          accuracy: 60.0,
          timestampMs: now,
        ),
        peers: const <PeerGpsObservation>[
          PeerGpsObservation(
            memberId: 'peer-1',
            lat: 45.4400,
            lon: 25.5500,
            accuracy: 6.0,
            updatedAtMs: now - 2000,
          ),
        ],
        nowMs: now,
      );

      expect(res, isNotNull);
      expect(res!.source, FusedGpsSource.cooperative);
      expect(res.fusedPeerCount, 1);
      expect(res.accuracy, lessThan(12.0));
      expect((res.lon - 25.5500).abs(), lessThan(0.0001));
    });

    test('ignores lagging peer standing >300m behind so position never pulls back', () {
      const now = 1700000000000;
      final res = CooperativeGpsFusion.fuse(
        selfFix: const SelfGpsObservation(
          lat: 45.4450,
          lon: 25.5500,
          accuracy: 45.0,
          timestampMs: now,
        ),
        peers: const <PeerGpsObservation>[
          PeerGpsObservation(
            memberId: 'peer-lagging',
            lat: 45.4420,
            lon: 25.5500,
            accuracy: 5.0,
            updatedAtMs: now - 1000,
          ),
        ],
        nowMs: now,
      );

      expect(res, isNotNull);
      expect(res!.source, FusedGpsSource.self);
      expect(res.fusedPeerCount, 0);
      expect(res.lat, closeTo(45.4450, 1e-6));
    });

    test('activates groupTether when own GPS drops out >6s and co-located peer is fresh', () {
      const now = 1700000010000;
      final res = CooperativeGpsFusion.fuse(
        selfFix: null,
        peers: const <PeerGpsObservation>[
          PeerGpsObservation(
            memberId: 'peer-1',
            lat: 45.4410,
            lon: 25.5500,
            accuracy: 7.0,
            updatedAtMs: now - 3000,
          ),
        ],
        lastCoLocatedPeerIds: const <String>{'peer-1'},
        nowMs: now,
      );

      expect(res, isNotNull);
      expect(res!.source, FusedGpsSource.groupTether);
      expect(res.lat, closeTo(45.4410, 1e-6));
      expect(res.accuracy, closeTo(16.55, 0.2)); // hypot(7, 15)
    });
  });

  group('GpsPaceCoaster', () {
    test('suppresses off-trail under degraded canopy GPS and coasts up to 180s cap', () {
      final sampleTrack = _buildNorthTrail();
      final coaster = GpsPaceCoaster(sampleTrack, isCycling: false);
      const t0 = 1700000000000;

      final s1 = coaster.ingestFix(
        lat: sampleTrack[2].lat,
        lon: sampleTrack[2].lon,
        accuracy: 8.0,
        matchedAlongM: sampleTrack[2].distanceM,
        crossTrackM: 4.0,
        isPaused: false,
        paceFactor: 1.0,
        nowMs: t0,
      );
      expect(s1.signalState, GpsSignalState.good);
      expect(s1.suppressOffTrail, isFalse);

      // Degraded 65 m accuracy 55 m off trail -> canopy suppression keeps user on-trail!
      final s2 = coaster.ingestFix(
        lat: sampleTrack[3].lat,
        lon: 25.5507,
        accuracy: 65.0,
        matchedAlongM: sampleTrack[3].distanceM,
        crossTrackM: 55.0,
        isPaused: false,
        paceFactor: 1.0,
        nowMs: t0 + 35000,
      );
      expect(s2.signalState, GpsSignalState.degraded);
      expect(s2.suppressOffTrail, isTrue);
      expect(s2.effectiveAlongM, greaterThanOrEqualTo(sampleTrack[3].distanceM - 10.0));

      // 15s without fixes (>6s trigger) -> 1Hz coasting advances smoothly along trail.
      final coast15 = coaster.tickCoasting(t0 + 50000, 1.0, false);
      expect(coast15, isNotNull);
      expect(coast15!.signalState, GpsSignalState.coasting);
      expect(coast15.effectiveAlongM, greaterThan(s2.effectiveAlongM + 10.0));

      // Cap at 180s after last fix (t0 + 35s + 180s = t0 + 215s).
      final coastAtCap = coaster.tickCoasting(t0 + 215000, 1.0, false);
      final coastPastCap = coaster.tickCoasting(t0 + 280000, 1.0, false);
      expect(coastAtCap, isNotNull);
      expect(coastPastCap, isNotNull);
      expect(coastPastCap!.effectiveAlongM, closeTo(coastAtCap!.effectiveAlongM, 1e-6));
    });
  });

  group('Forward Corridor Matching & Curved Hybrid Rejoin', () {
    test('parallel walk in woods advances alongTrackMeters and rejoins strictly ahead', () {
      final trail = _buildNorthTrail(count: 25);
      final matcher = TrackPositionMatcher(
        shape: trail.map((p) => p.geographic).toList(growable: false),
        cumulativeMeters: trail.map((p) => p.distanceM).toList(growable: false),
      );

      // Start on trail at ~100 m (index 2).
      final startDetail = matcher.matchDetailed(
        trail[2].geographic,
        accuracy: 8.0,
      );
      expect(startDetail!.isOffTrail, isFalse);
      expect(startDetail.alongTrackMeters, closeTo(trail[2].distanceM, 5.0));

      // Walk north parallel in woods ~65 m east of trail from ~100 m up to ~500 m (index 10).
      TrackMatchDetail? latest;
      for (var step = 2; step <= 10; step++) {
        latest = matcher.matchDetailed(
          Geographic(lat: trail[step].lat, lon: 25.55084), // ~66 m east
          accuracy: 8.0,
        );
      }

      expect(latest, isNotNull);
      expect(latest!.isOffTrail, isTrue);
      expect(latest.alongTrackMeters, greaterThanOrEqualTo(trail[9].distanceM));

      final reroute = OffTrailRouter.compute(
        userPos: Geographic(lat: trail[10].lat, lon: 25.55084),
        userEleM: trail[10].ele,
        trailPoints: trail,
        lastAlongTrackM: latest.alongTrackMeters,
        sampler: (_, _) => 1020.0,
        mode: OffTrailMode.minClimb,
      );

      expect(reroute, isNotNull);
      // Never proposes going back to 100 m; rejoins ahead of current ~500 m progress!
      expect(
        reroute!.rejoinAlongTrackM,
        greaterThanOrEqualTo(latest.alongTrackMeters - 10.0),
      );
      expect(reroute.points.length, greaterThanOrEqualTo(6));
    });

    test('returns null in >3000m Preview Mode and steers around building obstacles with Chaikin curves', () {
      final trail = _buildNorthTrail(count: 20);

      // User in Bucharest (~140+ km from trail) -> Preview Mode returns null!
      final farPreview = OffTrailRouter.compute(
        userPos: const Geographic(lat: 44.4268, lon: 26.1025),
        trailPoints: trail,
        lastAlongTrackM: 0.0,
        sampler: (_, _) => 100.0,
      );
      expect(farPreview, isNull);

      // Building obstacle directly between user (lon 25.5476) and trail (lon 25.5500).
      const minLat = 45.4420;
      const maxLat = 45.4432;
      const minLon = 25.5484;
      const maxLon = 25.5494;
      const building = <Geographic>[
        Geographic(lat: minLat, lon: minLon),
        Geographic(lat: minLat, lon: maxLon),
        Geographic(lat: maxLat, lon: maxLon),
        Geographic(lat: maxLat, lon: minLon),
      ];

      final aroundBuilding = OffTrailRouter.compute(
        userPos: const Geographic(lat: 45.4425, lon: 25.5476),
        userEleM: 1010.0,
        trailPoints: trail,
        lastAlongTrackM: trail[5].distanceM,
        sampler: (_, _) => 1010.0,
        obstacles: const <List<Geographic>>[building],
      );

      expect(aroundBuilding, isNotNull);
      expect(aroundBuilding!.points.length, greaterThanOrEqualTo(6));
      for (final p in aroundBuilding.points) {
        expect(
          _pointInsideRect(
            p.lat,
            p.lon,
            minLat: minLat,
            maxLat: maxLat,
            minLon: minLon,
            maxLon: maxLon,
          ),
          isFalse,
          reason: 'Reroute must never cut through building obstacle interior',
        );
      }
    });

    test('computeHybridWithValhalla stitches connectors >25m and falls back offline', () async {
      final trail = _buildNorthTrail(count: 20);
      const userPos = Geographic(lat: 45.4420, lon: 25.5475);

      // Curved Valhalla OSM path starting ~40m east of userPos (triggers >25m connector).
      final osmCurve = <Geographic>[
        const Geographic(lat: 45.4421, lon: 25.5481),
        const Geographic(lat: 45.4425, lon: 25.5489),
        const Geographic(lat: 45.4431, lon: 25.5496),
        Geographic(lat: trail[8].lat, lon: trail[8].lon),
      ];
      final encodedShape = PolylineUtil.encode(osmCurve, precision: 6);

      final okDio = Dio(BaseOptions(baseUrl: 'https://maps.skillfy.ro/api/v1'))
        ..httpClientAdapter = _FakeValhallaAdapter((options) async {
          expect(options.path, '/valhalla/route');
          return ResponseBody.fromString(
            jsonEncode(<String, Object?>{
              'trip': <String, Object?>{
                'legs': <Object?>[
                  <String, Object?>{'shape': encodedShape},
                ],
                'summary': <String, Object?>{'time': 195},
              },
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        });

      final hybrid = await OffTrailRouter.computeHybridWithValhalla(
        dio: okDio,
        userPos: userPos,
        userEleM: 1005.0,
        trailPoints: trail,
        lastAlongTrackM: trail[4].distanceM,
        sampler: (_, _) => 1012.0,
      );

      expect(hybrid, isNotNull);
      expect(hybrid!.points.first.lat, closeTo(userPos.lat, 1e-5));
      expect(hybrid.points.length, greaterThanOrEqualTo(osmCurve.length + 1));

      // Network failure (HTTP 502) falls back cleanly to local curved A*.
      final failDio = Dio(BaseOptions(baseUrl: 'https://maps.skillfy.ro/api/v1'))
        ..httpClientAdapter = _FakeValhallaAdapter((options) async {
          throw DioException(
            requestOptions: options,
            response: Response<Object?>(requestOptions: options, statusCode: 502),
            type: DioExceptionType.badResponse,
          );
        });

      final fallback = await OffTrailRouter.computeHybridWithValhalla(
        dio: failDio,
        userPos: userPos,
        userEleM: 1005.0,
        trailPoints: trail,
        lastAlongTrackM: trail[4].distanceM,
        sampler: (_, _) => 1012.0,
      );
      expect(fallback, isNotNull);
      expect(fallback!.points.length, greaterThanOrEqualTo(2));
    });
  });
}
