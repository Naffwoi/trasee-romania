import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:maplibre/maplibre.dart' show Geographic;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class _DecodedDemTile {
  const _DecodedDemTile({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;

  double? pixelElevation(int px, int py) {
    final cx = px.clamp(0, width - 1);
    final cy = py.clamp(0, height - 1);
    final offset = (cy * width + cx) * 4;
    if (offset + 3 >= rgba.length) return null;
    if (rgba[offset + 3] == 0) return null;
    final r = rgba[offset];
    final g = rgba[offset + 1];
    final b = rgba[offset + 2];
    return (r * 256.0 + g + b / 256.0) - 32768.0;
  }

  double? sampleBilinear(double u, double v) {
    if (width <= 0 || height <= 0) return null;
    final fx = (u.clamp(0.0, 1.0)) * (width - 1);
    final fy = (v.clamp(0.0, 1.0)) * (height - 1);
    final x0 = fx.floor().clamp(0, width - 1);
    final y0 = fy.floor().clamp(0, height - 1);
    final x1 = math.min(x0 + 1, width - 1);
    final y1 = math.min(y0 + 1, height - 1);
    final dx = fx - x0;
    final dy = fy - y0;

    final e00 = pixelElevation(x0, y0);
    final e10 = pixelElevation(x1, y0);
    final e01 = pixelElevation(x0, y1);
    final e11 = pixelElevation(x1, y1);

    if (e00 != null && e10 != null && e01 != null && e11 != null) {
      final top = e00 * (1.0 - dx) + e10 * dx;
      final bottom = e01 * (1.0 - dx) + e11 * dx;
      return top * (1.0 - dy) + bottom * dy;
    }
    return e00 ?? e10 ?? e01 ?? e11;
  }
}

/// Downloads, caches, and bilinearly samples Mapterhorn zoom-12 Terrarium
/// elevation WebP tiles (`https://tiles.mapterhorn.com/12/{x}/{y}.webp`).
class DemTileGrid {
  DemTileGrid({
    Dio? dio,
    double? Function(double lat, double lon)? customSampler,
    this.tileUrlTemplate = 'https://tiles.mapterhorn.com/12/{x}/{y}.webp',
    Future<Directory> Function()? cacheRootProvider,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 10),
             ),
           ),
       _customSampler = customSampler,
       _cacheRootProvider = cacheRootProvider ?? getTemporaryDirectory;

  static const int zoom = 12;
  static const int maxPrefetchTiles = 9;
  static const int _gridSize = 1 << zoom;

  final Dio _dio;
  final String tileUrlTemplate;
  final Future<Directory> Function() _cacheRootProvider;
  double? Function(double lat, double lon)? _customSampler;

  final Map<(int, int), _DecodedDemTile> _tiles = {};
  final Set<(int, int)> _failedTiles = {};
  final Map<(int, int), Future<void>> _inFlight = {};

  /// Overrides or clears the custom elevation sampler (useful in tests).
  void setCustomSampler(double? Function(double lat, double lon)? sampler) {
    _customSampler = sampler;
  }

  /// Inserts a raw RGBA Terrarium buffer for zoom-12 tile ([x], [y]) in tests.
  void putTileRgbaForTest(
    int x,
    int y, {
    required int width,
    required int height,
    required Uint8List rgba,
  }) {
    _tiles[(x, y)] = _DecodedDemTile(width: width, height: height, rgba: rgba);
  }

  /// Converts [lat]/[lon] into zoom-12 tile coordinates `(tx, ty)` and local
  /// normalized tile offsets `(u, v)` in `[0, 1)`.
  static ({int x, int y, double u, double v}) latLonToTile(
    double lat,
    double lon,
  ) {
    final clampedLat = lat.clamp(-85.05112878, 85.05112878);
    final latRad = clampedLat * math.pi / 180.0;
    final normLon = ((lon + 180.0) / 360.0).clamp(0.0, 0.9999999);
    final fx = normLon * _gridSize;
    final mercY =
        (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
        2.0;
    final fy = mercY.clamp(0.0, 0.9999999) * _gridSize;
    final tx = fx.floor().clamp(0, _gridSize - 1);
    final ty = fy.floor().clamp(0, _gridSize - 1);
    return (
      x: tx,
      y: ty,
      u: (fx - tx).clamp(0.0, 1.0),
      v: (fy - ty).clamp(0.0, 1.0),
    );
  }

  /// Prefetches zoom-12 DEM tiles covering [points] expanded by [bufferMeters],
  /// capped at [maxPrefetchTiles] (9 tiles). Never throws on offline errors.
  Future<void> prefetchCorridor(
    List<Geographic> points, {
    double bufferMeters = 1000.0,
  }) async {
    if (_customSampler != null || points.isEmpty) return;

    final targets = <(int, int)>[];
    final seen = <(int, int)>{};

    void addTile(int x, int y) {
      if (targets.length >= maxPrefetchTiles) return;
      if (x < 0 || x >= _gridSize || y < 0 || y >= _gridSize) return;
      final key = (x, y);
      if (seen.add(key)) targets.add(key);
    }

    // 1. Sample along the trail path itself so core corridor tiles are first.
    final step = math.max(1, (points.length / 24).floor());
    for (var i = 0; i < points.length; i += step) {
      final t = latLonToTile(points[i].lat, points[i].lon);
      addTile(t.x, t.y);
      if (targets.length >= maxPrefetchTiles) break;
    }
    if (targets.length < maxPrefetchTiles) {
      final last = latLonToTile(points.last.lat, points.last.lon);
      addTile(last.x, last.y);
    }

    // 2. Expand into buffered bounding box around the corridor up to the 9-tile cap.
    if (targets.length < maxPrefetchTiles) {
      var minLat = double.infinity;
      var maxLat = double.negativeInfinity;
      var minLon = double.infinity;
      var maxLon = double.negativeInfinity;
      for (final pt in points) {
        if (pt.lat < minLat) minLat = pt.lat;
        if (pt.lat > maxLat) maxLat = pt.lat;
        if (pt.lon < minLon) minLon = pt.lon;
        if (pt.lon > maxLon) maxLon = pt.lon;
      }
      final midLatRad = ((minLat + maxLat) / 2.0) * math.pi / 180.0;
      final dLat = bufferMeters / 111320.0;
      final dLon =
          bufferMeters / (111320.0 * math.max(0.1, math.cos(midLatRad)));
      final nw = latLonToTile(maxLat + dLat, minLon - dLon);
      final se = latLonToTile(minLat - dLat, maxLon + dLon);

      for (var y = nw.y; y <= se.y; y++) {
        for (var x = nw.x; x <= se.x; x++) {
          addTile(x, y);
          if (targets.length >= maxPrefetchTiles) break;
        }
        if (targets.length >= maxPrefetchTiles) break;
      }
    }

    await Future.wait(targets.map((t) => _ensureTileLoaded(t.$1, t.$2)));
  }

  /// Bilinearly samples elevation (metres) at ([lat], [lon]) from cached
  /// Terrarium DEM tiles, or returns `null` if the tile is unavailable.
  double? sampleElevation(double lat, double lon) {
    final custom = _customSampler;
    if (custom != null) return custom(lat, lon);
    if (!lat.isFinite || !lon.isFinite) return null;

    final tileCoords = latLonToTile(lat, lon);
    final tile = _tiles[(tileCoords.x, tileCoords.y)];
    if (tile == null) return null;
    return tile.sampleBilinear(tileCoords.u, tileCoords.v);
  }

  Future<void> _ensureTileLoaded(int x, int y) {
    final key = (x, y);
    if (_tiles.containsKey(key) || _failedTiles.contains(key)) {
      return Future.value();
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _loadTile(x, y).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<void> _loadTile(int x, int y) async {
    final key = (x, y);
    try {
      final cacheDir = await _cacheDir();
      final cacheFile = cacheDir == null
          ? null
          : File(p.join(cacheDir.path, '${zoom}_${x}_$y.webp'));

      if (cacheFile != null && await cacheFile.exists()) {
        try {
          final diskBytes = await cacheFile.readAsBytes();
          final decoded = await _decodeWebpTile(diskBytes);
          if (decoded != null) {
            _tiles[key] = decoded;
            return;
          }
        } catch (_) {
          // Corrupt disk tile — fall through to network fetch.
        }
      }

      final url = tileUrlTemplate
          .replaceAll('{x}', x.toString())
          .replaceAll('{y}', y.toString());
      final response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final raw = response.data;
      if (raw == null || raw.isEmpty) {
        _failedTiles.add(key);
        return;
      }
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      final decoded = await _decodeWebpTile(bytes);
      if (decoded == null) {
        _failedTiles.add(key);
        return;
      }
      _tiles[key] = decoded;

      if (cacheFile != null) {
        try {
          await cacheFile.writeAsBytes(bytes, flush: true);
        } catch (_) {
          // Disk cache write is best-effort.
        }
      }
    } catch (_) {
      _failedTiles.add(key);
    }
  }

  Future<Directory?> _cacheDir() async {
    try {
      final root = await _cacheRootProvider();
      final dir = Directory(p.join(root.path, 'wanderer_dem_v1'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  Future<_DecodedDemTile?> _decodeWebpTile(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return _DecodedDemTile(
        width: image.width,
        height: image.height,
        rgba: rgba,
      );
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
