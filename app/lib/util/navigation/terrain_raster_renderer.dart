import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:wanderer/util/navigation/dem_tile_grid.dart';

const double _radToDeg = 180.0 / math.pi;
const double _degToRad = math.pi / 180.0;

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(List<int> typeBytes, List<int> dataBytes) {
  var c = 0xFFFFFFFF;
  for (final b in typeBytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  for (final b in dataBytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

void _writeChunk(BytesBuilder out, List<int> type, List<int> data) {
  final header = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32(type, data));
  out.add(header.buffer.asUint8List());
  out.add(type);
  out.add(data);
  out.add(crc.buffer.asUint8List());
}

/// Pure-Dart zero-dependency RGBA8888 -> PNG encoder (isolate-safe).
Uint8List encodeRgbaToPng(Uint8List rgba, int width, int height) {
  final rawScanlines = Uint8List((width * 4 + 1) * height);
  final rowBytes = width * 4;
  for (var y = 0; y < height; y++) {
    final dstOffset = y * (rowBytes + 1);
    rawScanlines[dstOffset] = 0; // Filter type 0 (None)
    rawScanlines.setRange(
      dstOffset + 1,
      dstOffset + 1 + rowBytes,
      rgba,
      y * rowBytes,
    );
  }
  final compressed = zlib.encode(rawScanlines);

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth 8
    ..setUint8(9, 6) // color type 6 = RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);

  final out = BytesBuilder(copy: false);
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _writeChunk(out, const [0x49, 0x48, 0x44, 0x52], ihdr.buffer.asUint8List());
  _writeChunk(out, const [0x49, 0x44, 0x41, 0x54], compressed);
  _writeChunk(out, const [0x49, 0x45, 0x4E, 0x44], const []);
  return out.takeBytes();
}

(int, int, int, int) avalancheSlopeColorRgba(double slopeDeg) {
  if (!slopeDeg.isFinite || slopeDeg < 26.75) return (0, 0, 0, 0);
  if (slopeDeg < 27.25) {
    final t = (slopeDeg - 26.75) / 0.5;
    return (234, 179, 8, (115 * t).round());
  }
  if (slopeDeg < 30.0) return (234, 179, 8, 115);
  if (slopeDeg < 35.0) return (249, 115, 22, 140);
  if (slopeDeg < 45.0) return (220, 38, 38, 158);
  if (slopeDeg < 50.0) return (147, 51, 234, 165);
  return (29, 78, 216, 175);
}

({int z12X, int z12Y, double u0, double v0, double span})? _mapToZ12(
  int z,
  int x,
  int y,
) {
  if (z < 12) return null;
  final scale = 1 << (z - 12);
  final z12X = x ~/ scale;
  final z12Y = y ~/ scale;
  final span = 1.0 / scale;
  return (
    z12X: z12X,
    z12Y: z12Y,
    u0: (x - z12X * scale) * span,
    v0: (y - z12Y * scale) * span,
    span: span,
  );
}

Uint8List? renderAvalancheSlopeRgba(
  int z,
  int x,
  int y,
  DemTileGrid dem, {
  int outSize = 256,
}) {
  final win = _mapToZ12(z, x, y);
  if (win == null) return null;
  final baseTile = dem.getDecodedTile(win.z12X, win.z12Y);
  if (baseTile == null) return null;

  final srcW = baseTile.width;
  final srcH = baseTile.height;
  final out = Uint8List(outSize * outSize * 4);

  for (var rOut = 0; rOut < outSize; rOut++) {
    final v = win.v0 + ((rOut + 0.5) / outSize) * win.span;
    final srcRow = (v * srcH - 0.5).round().clamp(0, srcH - 1);
    final inv8Cell =
        1.0 /
        (8.0 *
            DemTileGrid.webMercatorRowCellSizeMeters(
              12,
              win.z12Y,
              srcRow,
              srcW,
            ));

    for (var cOut = 0; cOut < outSize; cOut++) {
      final u = win.u0 + ((cOut + 0.5) / outSize) * win.span;
      final srcCol = (u * srcW - 0.5).round().clamp(0, srcW - 1);

      final nw =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol - 1, srcRow - 1) ??
          0.0;
      final n =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol, srcRow - 1) ??
          0.0;
      final ne =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol + 1, srcRow - 1) ??
          0.0;
      final wPx =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol - 1, srcRow) ??
          0.0;
      final ePx =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol + 1, srcRow) ??
          0.0;
      final sw =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol - 1, srcRow + 1) ??
          0.0;
      final s =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol, srcRow + 1) ??
          0.0;
      final se =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol + 1, srcRow + 1) ??
          0.0;

      final dzdx = ((ne + 2.0 * ePx + se) - (nw + 2.0 * wPx + sw)) * inv8Cell;
      final dzdy = ((sw + 2.0 * s + se) - (nw + 2.0 * n + ne)) * inv8Cell;
      final slopeDeg =
          math.atan(math.sqrt(dzdx * dzdx + dzdy * dzdy)) * _radToDeg;

      final (cr, cg, cb, ca) = avalancheSlopeColorRgba(slopeDeg);
      final idx = (rOut * outSize + cOut) * 4;
      out[idx] = cr;
      out[idx + 1] = cg;
      out[idx + 2] = cb;
      out[idx + 3] = ca;
    }
  }
  return out;
}

Uint8List? renderCastShadowRgba(
  int z,
  int x,
  int y,
  DemTileGrid dem, {
  required double sunAzimuthDeg,
  required double sunAltitudeDeg,
  int outSize = 256,
}) {
  final win = _mapToZ12(z, x, y);
  if (win == null) return null;
  final baseTile = dem.getDecodedTile(win.z12X, win.z12Y);
  if (baseTile == null) return null;

  final out = Uint8List(outSize * outSize * 4);
  if (sunAltitudeDeg <= -0.833) {
    for (var i = 0; i < out.length; i += 4) {
      out[i] = 15;
      out[i + 1] = 23;
      out[i + 2] = 42;
      out[i + 3] = 130;
    }
    return out;
  }

  final srcW = baseTile.width;
  final decimate = math.max(1, (srcW / outSize).round());
  final pad = outSize;
  final gridN = outSize * 2;
  final azRad = sunAzimuthDeg * _degToRad;
  final sunDirX = math.sin(azRad);
  final sunDirY = -math.cos(azRad);

  final padOffsetCol = sunDirX >= 0 ? 0 : -pad;
  final padOffsetRow = sunDirY >= 0 ? 0 : -pad;

  final elevGrid = Float32List(gridN * gridN);
  for (var gr = 0; gr < gridN; gr++) {
    final srcRow = (gr + padOffsetRow) * decimate;
    for (var gc = 0; gc < gridN; gc++) {
      final srcCol = (gc + padOffsetCol) * decimate;
      elevGrid[gr * gridN + gc] =
          dem.samplePixelStitched(win.z12X, win.z12Y, srcCol, srcRow) ?? 0.0;
    }
  }

  final cellM = DemTileGrid.webMercatorRowCellSizeMeters(
    12,
    win.z12Y,
    srcW ~/ 2,
    outSize,
  );
  final tanAlt = math.tan(math.max(0.5, sunAltitudeDeg) * _degToRad);
  final ceiling = Float32List.fromList(elevGrid);

  final downX = -sunDirX;
  final downY = -sunDirY;
  final rStart = downY >= 0 ? 0 : gridN - 1;
  final rEnd = downY >= 0 ? gridN : -1;
  final rStep = downY >= 0 ? 1 : -1;
  final cStart = downX >= 0 ? 0 : gridN - 1;
  final cEnd = downX >= 0 ? gridN : -1;
  final cStep = downX >= 0 ? 1 : -1;

  final majorIsX = downX.abs() >= downY.abs();
  final minorFrac = majorIsX
      ? downY.abs() / math.max(1e-6, downX.abs())
      : downX.abs() / math.max(1e-6, downY.abs());
  final dropPerStepM = cellM * math.sqrt(1.0 + minorFrac * minorFrac) * tanAlt;

  for (var gr = rStart; gr != rEnd; gr += rStep) {
    for (var gc = cStart; gc != cEnd; gc += cStep) {
      final upC = gc - cStep;
      final upR = gr - rStep;
      var upwindCeiling = elevGrid[gr * gridN + gc];
      if (majorIsX && upC >= 0 && upC < gridN) {
        final c0 = ceiling[gr * gridN + upC];
        final cDiag = (upR >= 0 && upR < gridN)
            ? ceiling[upR * gridN + upC]
            : c0;
        upwindCeiling =
            c0 * (1.0 - minorFrac) + cDiag * minorFrac - dropPerStepM;
      } else if (!majorIsX && upR >= 0 && upR < gridN) {
        final c0 = ceiling[upR * gridN + gc];
        final cDiag = (upC >= 0 && upC < gridN)
            ? ceiling[upR * gridN + upC]
            : c0;
        upwindCeiling =
            c0 * (1.0 - minorFrac) + cDiag * minorFrac - dropPerStepM;
      }
      final idx = gr * gridN + gc;
      if (upwindCeiling > ceiling[idx]) ceiling[idx] = upwindCeiling;
    }
  }

  for (var rOut = 0; rOut < outSize; rOut++) {
    final v = win.v0 + ((rOut + 0.5) / outSize) * win.span;
    final gr = ((v * outSize - 0.5).round() - padOffsetRow).clamp(0, gridN - 1);
    for (var cOut = 0; cOut < outSize; cOut++) {
      final u = win.u0 + ((cOut + 0.5) / outSize) * win.span;
      final gc = ((u * outSize - 0.5).round() - padOffsetCol).clamp(
        0,
        gridN - 1,
      );
      final diffM = ceiling[gr * gridN + gc] - elevGrid[gr * gridN + gc];
      if (diffM > 0.25) {
        final outIdx = (rOut * outSize + cOut) * 4;
        out[outIdx] = 18;
        out[outIdx + 1] = 28;
        out[outIdx + 2] = 52;
        out[outIdx + 3] = ((diffM / 4.0).clamp(0.0, 1.0) * 115.0).round();
      }
    }
  }
  return out;
}
