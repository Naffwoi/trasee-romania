import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';
import 'package:wanderer/util/route/track_position_matcher.dart';

class _UrlCaptureAdapter implements HttpClientAdapter {
  _UrlCaptureAdapter(this.pngBytes);

  final Uint8List pngBytes;
  final List<String> requestedUrls = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUrls.add(options.uri.toString());
    return ResponseBody.fromBytes(
      pngBytes,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _encodeTerrariumPng(int size, double elevationMeters) {
  // Terrarium: ele = (R * 256 + G + B / 256) - 32768
  final shifted = elevationMeters + 32768.0;
  final r = (shifted ~/ 256).clamp(0, 255);
  final rem = shifted - r * 256.0;
  final g = rem.floor().clamp(0, 255);
  final b = ((rem - g) * 256.0).round().clamp(0, 255);

  final image = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('DemTileGrid pure-Dart Uint16 .dem16 slab cache', () {
    late Directory cacheDir;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('dem16_cache_test_');
    });

    tearDown(() async {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    });

    test('substitutes {z}/{x}/{y}, decodes pure-Dart PNG/WebP without dart:ui, and reloads .dem16 slab offline', () async {
      // Moldoveanu Peak: 2544.0 m (also verify > 3277 m Mont Blanc 4808.4 m range!)
      final pngBytes = _encodeTerrariumPng(16, 4808.4);
      final adapter = _UrlCaptureAdapter(pngBytes);
      final dio = Dio()..httpClientAdapter = adapter;

      final grid = DemTileGrid(
        dio: dio,
        tileUrlTemplate: 'https://tiles.example.org/dem/{z}/{x}/{y}.png',
        cacheRootProvider: () async => cacheDir,
      );

      final t = DemTileGrid.latLonToTile(45.5995, 24.7362);
      await grid.ensureTileLoaded(t.x, t.y);

      expect(
        adapter.requestedUrls.single,
        'https://tiles.example.org/dem/12/${t.x}/${t.y}.png',
      );
      expect(grid.sampleElevation(45.5995, 24.7362), closeTo(4808.4, 0.25));

      // Second instance with failing network reads straight from .dem16 binary slab!
      final offlineDio = Dio()
        ..httpClientAdapter = _UrlCaptureAdapter(Uint8List(0));
      final secondGrid = DemTileGrid(
        dio: offlineDio,
        tileUrlTemplate: 'https://tiles.example.org/dem/{z}/{x}/{y}.png',
        cacheRootProvider: () async => cacheDir,
      );
      await secondGrid.ensureTileLoaded(t.x, t.y);
      expect(offlineDio.httpClientAdapter, isNotNull);
      expect(
        (offlineDio.httpClientAdapter as _UrlCaptureAdapter).requestedUrls,
        isEmpty,
      );
      expect(secondGrid.sampleElevation(45.5995, 24.7362), closeTo(4808.4, 0.25));
    });
  });

  group('TrackPositionMatcher 200m spatial index parity', () {
    test('matches exact nearest segment on a 4,000-point winding Carpathian ridge track', () {
      final shape = <Geographic>[];
      final cum = <double>[];
      var dist = 0.0;
      for (var i = 0; i < 4000; i++) {
        final lat = 45.35 + i * 0.00012 + 0.0008 * math.sin(i * 0.07);
        final lon = 25.45 + i * 0.00015 + 0.0008 * math.cos(i * 0.05);
        final pt = Geographic(lat: lat, lon: lon);
        if (shape.isNotEmpty) {
          dist += SphericalGreatCircle(shape.last).distanceTo(pt);
        }
        shape.add(pt);
        cum.add(dist);
      }

      final matcher = TrackPositionMatcher(
        shape: shape,
        cumulativeMeters: cum,
      );

      // Query 45m off segment ~2150.
      final target = shape[2150];
      final query = Geographic(lat: target.lat + 0.0004, lon: target.lon - 0.0002);
      final detail = matcher.matchDetailed(query, accuracy: 8.0);
      expect(detail, isNotNull);
      expect((detail!.segmentIndex - 2150).abs(), lessThanOrEqualTo(5));
      expect(detail.crossTrackMeters, inInclusiveRange(30.0, 65.0));
    });
  });

  group('OffTrailRouter single-A* precomputedLocalResult & cooperative cancel', () {
    test('reuses precomputedLocalResult without re-invoking sampler and honors isCancelled', () async {
      var sampleCount = 0;
      double? countingSampler(double lat, double lon) {
        sampleCount++;
        return 1400.0;
      }

      final trail = <NavTrackPoint>[
        const NavTrackPoint(lat: 45.4000, lon: 25.4500, ele: 1400, distanceM: 0, gradePct: 0),
        const NavTrackPoint(lat: 45.4100, lon: 25.4500, ele: 1420, distanceM: 1113, gradePct: 1.8),
      ];
      final eta = EtaCalculator.fromPoints(trail);
      const userPos = Geographic(lat: 45.4020, lon: 25.4520);

      // Cancelled run aborts early and returns null.
      final cancelled = OffTrailRouter.compute(
        userPos: userPos,
        trailPoints: trail,
        lastAlongTrackM: 100.0,
        sampler: countingSampler,
        precomputedEta: eta,
        isCancelled: () => true,
      );
      expect(cancelled, isNull);

      sampleCount = 0;
      final local = OffTrailRouter.compute(
        userPos: userPos,
        trailPoints: trail,
        lastAlongTrackM: 100.0,
        sampler: countingSampler,
        precomputedEta: eta,
      );
      expect(local, isNotNull);
      final samplesAfterLocal = sampleCount;
      expect(samplesAfterLocal, greaterThan(0));

      // Hybrid fallback with unconfigured Dio + precomputedLocalResult does ZERO extra DEM samples!
      final unconfiguredDio = Dio(BaseOptions(baseUrl: 'https://unconfigured.invalid'));
      final hybrid = await OffTrailRouter.computeHybridWithValhalla(
        dio: unconfiguredDio,
        userPos: userPos,
        trailPoints: trail,
        lastAlongTrackM: 100.0,
        sampler: countingSampler,
        precomputedLocalResult: local,
      );
      expect(identical(hybrid, local), isTrue);
      expect(sampleCount, samplesAfterLocal);
    });
  });
}
