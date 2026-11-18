import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/services/navigation/nav_terrain_worker_isolate.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';

void main() {
  late Directory tempCacheDir;

  setUp(() async {
    tempCacheDir = await Directory.systemTemp.createTemp('nav_worker_iso_test_');
  });

  tearDown(() async {
    if (await tempCacheDir.exists()) {
      await tempCacheDir.delete(recursive: true);
    }
  });

  test('persistent worker isolate matches on-trail fixes, computes off-trail A* + GeoJSON, and drops stale generations', () async {
    final trail = <NavTrackPoint>[
      for (var i = 0; i <= 40; i++)
        NavTrackPoint(
          lat: 45.4000 + i * 0.0005,
          lon: 25.4600,
          ele: 1500.0 + i * 4.0,
          distanceM: i * 55.66,
          gradePct: 7.2,
        ),
    ];

    final worker = await NavTerrainWorkerIsolate.spawn(
      trailPoints: trail,
      isCycling: false,
      localeCode: 'ro',
      demTileUrlTemplate: 'https://unconfigured.invalid/{z}/{x}/{y}.webp',
      cacheRootPath: tempCacheDir.path,
      demArchivePaths: const <String>[],
    );
    addTearDown(worker.dispose);

    // 1. On-trail fix ~278 m along track.
    final onTrail = await worker.matchFix(
      lat: 45.4025,
      lon: 25.46005,
      heading: 0.0,
      headingAccuracy: 10.0,
      speed: 1.2,
      accuracy: 6.0,
      recordProgress: true,
      nowMs: DateTime.utc(2026, 11, 18, 10, 0, 0).millisecondsSinceEpoch,
    );
    expect(onTrail, isNotNull);
    expect(onTrail!.detail.isOffTrail, isFalse);
    expect(onTrail.detail.alongTrackMeters, closeTo(278.3, 18.0));
    expect(onTrail.eta, isNotNull);

    // 2. Rapidly fire two reroute generations; latest generation produces valid
    //    reroute + UTF-8 GeoJSON LineString bytes transferred via TransferableTypedData.
    final staleFuture = worker.computeReroute(
      generation: 1,
      userPos: const Geographic(lat: 45.4030, lon: 25.4622),
      userEleM: 1520.0,
      alongTrackM: 280.0,
      mode: OffTrailMode.minClimb,
      localeCode: 'ro',
      tryValhalla: false,
    );
    final freshFuture = worker.computeReroute(
      generation: 2,
      userPos: const Geographic(lat: 45.4035, lon: 25.4625),
      userEleM: 1525.0,
      alongTrackM: 320.0,
      mode: OffTrailMode.shortestSafe,
      localeCode: 'ro',
      tryValhalla: false,
    );

    final results = await Future.wait([staleFuture, freshFuture]);
    final fresh = results[1];
    expect(fresh, isNotNull);
    expect(fresh!.generation, 2);
    expect(fresh.result.points.length, greaterThanOrEqualTo(2));
    expect(fresh.geoJsonString, isNotEmpty);

    final decodedGeoJson = jsonDecode(fresh.geoJsonString) as Map<String, dynamic>;
    expect(decodedGeoJson['type'], 'FeatureCollection');
    expect((decodedGeoJson['features'] as List), isNotEmpty);
  });
}
