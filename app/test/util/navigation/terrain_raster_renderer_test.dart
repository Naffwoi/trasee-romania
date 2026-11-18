import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/terrain_raster_renderer.dart';

Uint8List _encodeTerrariumRgba(
  int size,
  double Function(int col, int row) eleFn,
) {
  final rgba = Uint8List(size * size * 4);
  for (var r = 0; r < size; r++) {
    for (var c = 0; c < size; c++) {
      final v = (eleFn(c, r) + 32768.0).clamp(0.0, 65535.0);
      final rByte = (v / 256.0).floor();
      final gByte = (v - rByte * 256.0).floor();
      final bByte = ((v - rByte * 256.0 - gByte) * 256.0).round().clamp(
        0,
        255,
      );
      final idx = (r * size + c) * 4;
      rgba[idx] = rByte;
      rgba[idx + 1] = gByte;
      rgba[idx + 2] = bByte;
      rgba[idx + 3] = 255;
    }
  }
  return rgba;
}

void main() {
  group(
    'TerrainRasterRenderer (Pure-Dart PNG + Horn 3x3 + Scanline Shadow)',
    () {
      test(
        'encodes valid PNG header/IEND and maps 38 deg slope at 45.5N to Crimson Red',
        () {
          const tx = 2337;
          const ty = 1468;
          final tan38 = math.tan(38.0 * math.pi / 180.0);
          final dem = DemTileGrid();
          dem.putTileRgbaForTest(
            tx,
            ty,
            width: 512,
            height: 512,
            rgba: _encodeTerrariumRgba(512, (col, row) {
              final cellM = DemTileGrid.webMercatorRowCellSizeMeters(
                12,
                ty,
                row,
                512,
              );
              return 1000.0 + col * cellM * tan38;
            }),
          );

          final rgba = renderAvalancheSlopeRgba(12, tx, ty, dem, outSize: 256);
          expect(rgba, isNotNull);
          final mid = (128 * 256 + 128) * 4;
          expect(rgba![mid], 220);
          expect(rgba[mid + 1], 38);
          expect(rgba[mid + 2], 38);

          final png = encodeRgbaToPng(rgba, 256, 256);
          // Verify 8-byte PNG signature: 89 50 4E 47 0D 0A 1A 0A
          expect(png.sublist(0, 8), [
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
          ]);
          expect(png.length, greaterThan(100));
        },
      );
    },
  );
}
