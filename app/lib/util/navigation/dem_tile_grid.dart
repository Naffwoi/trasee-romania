import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;
import 'package:maplibre/maplibre.dart' show Geographic;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pmtiles/pmtiles.dart';

/// Compact 16-bit quantized elevation tile (`512 KB` for `512×512`, half the
/// memory of `Float32List` or `RGBA8888`).
///
/// Encoding: `u16 = ((eleMeters + 1000.0) * 6.0).round().clamp(0, 65534)`
/// (`~0.167 m` (`<= 0.20 m`) vertical resolution across `-1,000.0 m .. +9,922.3 m`,
/// covering Dead Sea to Mount Everest with exact `.0`/`.5` m representation;
/// `0xFFFF` = transparent/void sentinel).
class _DecodedDemTile {
  const _DecodedDemTile({
    required this.width,
    required this.height,
    required this.quantizedU16,
  });

  static const int voidSentinel = 0xFFFF;
  static const int slabMagic = 0x36314D44; // 'DM16' little-endian
  static const double _scale = 6.0;

  final int width;
  final int height;
  final Uint16List quantizedU16;

  static int encodeElevation(double meters) =>
      ((meters + 1000.0) * _scale).round().clamp(0, 65534);

  static double decodeElevation(int u16) => u16 / _scale - 1000.0;

  factory _DecodedDemTile.fromRgbaBytes({
    required int width,
    required int height,
    required Uint8List rgba,
  }) {
    final count = width * height;
    final slab = Uint16List(count);
    for (var i = 0; i < count; i++) {
      final offset = i * 4;
      if (offset + 3 >= rgba.length || rgba[offset + 3] == 0) {
        slab[i] = voidSentinel;
        continue;
      }
      final r = rgba[offset];
      final g = rgba[offset + 1];
      final b = rgba[offset + 2];
      final meters = (r * 256.0 + g + b / 256.0) - 32768.0;
      slab[i] = encodeElevation(meters);
    }
    return _DecodedDemTile(width: width, height: height, quantizedU16: slab);
  }

  Uint8List toBinarySlabBytes() {
    final payloadBytes = quantizedU16.length * 2;
    final out = Uint8List(8 + payloadBytes);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, slabMagic, Endian.little);
    bd.setUint16(4, width, Endian.little);
    bd.setUint16(6, height, Endian.little);
    for (var i = 0; i < quantizedU16.length; i++) {
      bd.setUint16(8 + i * 2, quantizedU16[i], Endian.little);
    }
    return out;
  }

  static _DecodedDemTile? fromBinarySlabBytes(Uint8List bytes) {
    if (bytes.length < 8) return null;
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != slabMagic) return null;
    final w = bd.getUint16(4, Endian.little);
    final h = bd.getUint16(6, Endian.little);
    final count = w * h;
    if (w <= 0 || h <= 0 || bytes.length != 8 + count * 2) return null;

    final slab = Uint16List(count);
    for (var i = 0; i < count; i++) {
      slab[i] = bd.getUint16(8 + i * 2, Endian.little);
    }
    return _DecodedDemTile(width: w, height: h, quantizedU16: slab);
  }

  double? pixelElevation(int px, int py) {
    if (width <= 0 || height <= 0) return null;
    final cx = px.clamp(0, width - 1);
    final cy = py.clamp(0, height - 1);
    final idx = cy * width + cx;
    if (idx < 0 || idx >= quantizedU16.length) return null;
    final raw = quantizedU16[idx];
    if (raw == voidSentinel) return null;
    return decodeElevation(raw);
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

/// Pure-Dart, isolate-safe zoom-12 Terrarium DEM tile grid backed by:
/// 1. Local offline `.pmtiles` DEM archives ([demArchivePaths]),
/// 2. Pre-decoded `.dem16` `Uint16List` binary slabs on disk (`< 0.4 ms` load),
/// 3. Remote `{z}/{x}/{y}` WebP/PNG tiles decoded via `package:image` (zero
///    `dart:ui` GPU texture upload/readback).
class DemTileGrid {
  DemTileGrid({
    Dio? dio,
    double? Function(double lat, double lon)? customSampler,
    this.tileUrlTemplate = 'https://tiles.mapterhorn.com/{z}/{x}/{y}.webp',
    Future<Directory> Function()? cacheRootProvider,
    List<String> demArchivePaths = const <String>[],
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 10),
             ),
           ),
       _customSampler = customSampler,
       _cacheRootProvider =
           cacheRootProvider ?? getApplicationSupportDirectory,
       _demArchivePaths = List<String>.from(demArchivePaths);

  static const int zoom = 12;
  static const int maxPrefetchTiles = 9;
  static const int maxCachedTiles = 48;
  static const int _gridSize = 1 << zoom;

  final Dio _dio;
  final String tileUrlTemplate;
  final Future<Directory> Function() _cacheRootProvider;
  double? Function(double lat, double lon)? _customSampler;
  List<String> _demArchivePaths;

  final Map<(int, int), _DecodedDemTile> _tiles = {};
  final Set<(int, int)> _failedTiles = {};
  final Map<(int, int), Future<void>> _inFlight = {};
  final Map<String, PmTilesArchive> _openArchives = {};

  static double webMercatorRowCellSizeMeters(
    int z,
    int tileY,
    int row,
    int tileSize,
  ) {
    final numTiles = 1 << z;
    final yNorm = (tileY + (row + 0.5) / tileSize) / numTiles;
    final arg = math.pi * (1.0 - 2.0 * yNorm);
    final sinhVal = 0.5 * (math.exp(arg) - math.exp(-arg));
    final latRad = math.atan(sinhVal);
    return (2.0 * math.pi * 6378137.0 * math.cos(latRad)) /
        (tileSize * numTiles);
  }

  void setCustomSampler(double? Function(double lat, double lon)? sampler) {
    _customSampler = sampler;
  }

  void setDemArchivePaths(List<String> paths) {
    _demArchivePaths = List<String>.from(paths);
    _failedTiles.clear();
  }

  void putTileRgbaForTest(
    int x,
    int y, {
    required int width,
    required int height,
    required Uint8List rgba,
  }) {
    _storeTile(
      (x, y),
      _DecodedDemTile.fromRgbaBytes(width: width, height: height, rgba: rgba),
    );
  }

  void _storeTile((int, int) key, _DecodedDemTile tile) {
    _tiles.remove(key);
    _tiles[key] = tile;
    while (_tiles.length > maxCachedTiles) {
      _tiles.remove(_tiles.keys.first);
    }
  }

  ({int width, int height, double? Function(int px, int py) pixel})?
  getDecodedTile(int x, int y) {
    if (y < 0 || y >= _gridSize) return null;
    final wx = ((x % _gridSize) + _gridSize) % _gridSize;
    final key = (wx, y);
    final hit = _tiles.remove(key);
    if (hit == null) return null;
    _tiles[key] = hit;
    return (width: hit.width, height: hit.height, pixel: hit.pixelElevation);
  }

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

  Future<void> ensureTileLoaded(int x, int y) {
    if (y < 0 || y >= _gridSize) return Future.value();
    final wx = ((x % _gridSize) + _gridSize) % _gridSize;
    return _ensureTileLoaded(wx, y);
  }

  double? samplePixelStitched(int baseX, int baseY, int localX, int localY) {
    final primary = _tiles[(baseX, baseY)];
    if (primary == null) return null;
    final w = primary.width;
    final h = primary.height;
    var tx = baseX;
    var ty = baseY;
    var lx = localX;
    var ly = localY;
    if (lx < 0) {
      tx = ((tx - 1) % _gridSize + _gridSize) % _gridSize;
      lx += w;
    } else if (lx >= w) {
      tx = (tx + 1) % _gridSize;
      lx -= w;
    }
    if (ly < 0) {
      ty -= 1;
      ly += h;
    } else if (ly >= h) {
      ty += 1;
      ly -= h;
    }
    final neighbor = (tx == baseX && ty == baseY) ? primary : _tiles[(tx, ty)];
    if (neighbor != null &&
        lx >= 0 &&
        lx < neighbor.width &&
        ly >= 0 &&
        ly < neighbor.height) {
      return neighbor.pixelElevation(lx, ly);
    }
    return primary.pixelElevation(localX, localY);
  }

  Future<void> prefetchRadius(
    double lat,
    double lon, {
    double radiusMeters = 20000.0,
    int maxTiles = 36,
  }) async {
    if (_customSampler != null || !lat.isFinite || !lon.isFinite) return;
    final safeR = radiusMeters.clamp(500.0, 40000.0);
    final dLat = safeR / 111320.0;
    final dLon =
        safeR / (111320.0 * math.max(0.1, math.cos(lat * math.pi / 180.0)));
    final center = latLonToTile(lat, lon);
    final nw = latLonToTile(lat + dLat, lon - dLon);
    final se = latLonToTile(lat - dLat, lon + dLon);

    final candidates = <(int, int)>[];
    for (var y = nw.y; y <= se.y; y++) {
      for (var x = nw.x; x <= se.x; x++) {
        if (x >= 0 && x < _gridSize && y >= 0 && y < _gridSize) {
          candidates.add((x, y));
        }
      }
    }
    candidates.sort((a, b) {
      final da =
          (a.$1 - center.x) * (a.$1 - center.x) +
          (a.$2 - center.y) * (a.$2 - center.y);
      final db =
          (b.$1 - center.x) * (b.$1 - center.x) +
          (b.$2 - center.y) * (b.$2 - center.y);
      return da.compareTo(db);
    });
    final capped = candidates.take(maxTiles).toList(growable: false);
    await Future.wait(capped.map((t) => _ensureTileLoaded(t.$1, t.$2)));
  }

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

  double? sampleElevation(double lat, double lon) {
    final custom = _customSampler;
    if (custom != null) return custom(lat, lon);
    if (!lat.isFinite || !lon.isFinite) return null;

    final tileCoords = latLonToTile(lat, lon);
    final key = (tileCoords.x, tileCoords.y);
    final tile = _tiles.remove(key);
    if (tile == null) return null;
    _tiles[key] = tile;
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
      final slabFile = cacheDir == null
          ? null
          : File(p.join(cacheDir.path, '${zoom}_${x}_$y.dem16'));

      // 1. Zero-decode binary .dem16 slab hit (< 0.4 ms).
      if (slabFile != null && await slabFile.exists()) {
        try {
          final slabBytes = await slabFile.readAsBytes();
          final decoded = _DecodedDemTile.fromBinarySlabBytes(slabBytes);
          if (decoded != null) {
            _storeTile(key, decoded);
            return;
          }
        } catch (_) {}
      }

      // 2. Local downloaded DEM .pmtiles archive hit (100% offline!).
      final archiveBytes = await _readFromOfflinePmTiles(x, y);
      if (archiveBytes != null && archiveBytes.isNotEmpty) {
        final decoded = _decodeImagePureDart(archiveBytes);
        if (decoded != null) {
          _storeTile(key, decoded);
          await _persistSlabBestEffort(slabFile, decoded);
          return;
        }
      }

      // 3. Remote HTTP {z}/{x}/{y} fetch + pure-Dart decode + .dem16 slab write.
      final url = tileUrlTemplate
          .replaceAll('{z}', zoom.toString())
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
      final decoded = _decodeImagePureDart(bytes);
      if (decoded == null) {
        _failedTiles.add(key);
        return;
      }
      _storeTile(key, decoded);
      await _persistSlabBestEffort(slabFile, decoded);
    } catch (_) {
      _failedTiles.add(key);
    }
  }

  Future<Uint8List?> _readFromOfflinePmTiles(int x, int y) async {
    if (_demArchivePaths.isEmpty) return null;
    final tileId = ZXY(zoom, x, y).toTileId();
    for (final path in _demArchivePaths) {
      try {
        var archive = _openArchives[path];
        if (archive == null) {
          final f = File(path);
          if (!f.existsSync()) continue;
          archive = await PmTilesArchive.fromFile(f);
          _openArchives[path] = archive;
        }
        final tile = await archive.tile(tileId);
        final raw = tile.bytes();
        if (raw.isNotEmpty) {
          return raw is Uint8List ? raw : Uint8List.fromList(raw);
        }
      } on TileNotFoundException {
        continue;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> _persistSlabBestEffort(
    File? slabFile,
    _DecodedDemTile tile,
  ) async {
    if (slabFile == null) return;
    try {
      await slabFile.writeAsBytes(tile.toBinarySlabBytes(), flush: false);
    } catch (_) {}
  }

  Future<Directory?> _cacheDir() async {
    try {
      final root = await _cacheRootProvider();
      final dir = Directory(p.join(root.path, 'wanderer_dem_v2'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  static _DecodedDemTile? _decodeImagePureDart(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        return null;
      }
      final w = decoded.width;
      final h = decoded.height;
      final hasAlpha = decoded.numChannels >= 4;
      final slab = Uint16List(w * h);

      var idx = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final pxl = decoded.getPixel(x, y);
          if (hasAlpha && pxl.a == 0) {
            slab[idx++] = _DecodedDemTile.voidSentinel;
            continue;
          }
          final meters =
              (pxl.r * 256.0 + pxl.g + pxl.b / 256.0) - 32768.0;
          slab[idx++] = _DecodedDemTile.encodeElevation(meters);
        }
      }
      return _DecodedDemTile(width: w, height: h, quantizedU16: slab);
    } catch (_) {
      return null;
    }
  }

  Future<void> closeArchives() async {
    for (final a in _openArchives.values) {
      try {
        await a.close();
      } catch (_) {}
    }
    _openArchives.clear();
  }
}
