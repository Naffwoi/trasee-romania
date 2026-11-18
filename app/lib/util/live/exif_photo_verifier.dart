import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:image/image.dart' as img;

const int _maxImageDimensionPx = 1280;
const int _jpegQuality = 82;
const Duration _maxVerifiedAge = Duration(hours: 2);
const Duration _maxClockSkew = Duration(minutes: 5);
const double _maxVerifiedDistanceM = 250.0;

class SanitizedReportPhoto {
  const SanitizedReportPhoto({
    required this.strippedJpegBytes,
    required this.photoVerified,
    required this.width,
    required this.height,
  });

  final Uint8List strippedJpegBytes;
  final bool photoVerified;
  final int width;
  final int height;
}

double? _dmsRatioToDecimal(IfdTag? dms, IfdTag? ref) {
  if (dms == null || ref == null) return null;
  final parts = dms.values.toList();
  if (parts.length < 3) return null;
  final d = parts[0];
  final m = parts[1];
  final s = parts[2];
  if (d is! Ratio || m is! Ratio || s is! Ratio) return null;
  if (d.denominator == 0 || m.denominator == 0 || s.denominator == 0) {
    return null;
  }

  var dd = d.toDouble() + m.toDouble() / 60.0 + s.toDouble() / 3600.0;
  final dir = ref.printable.trim().toUpperCase();
  if (dir == 'S' || dir == 'W') dd = -dd;
  return dd.isFinite ? dd : null;
}

DateTime? _parseExifDate(String? rawDate, String? rawOffset) {
  if (rawDate == null || rawDate.trim().isEmpty) return null;
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$',
  ).firstMatch(rawDate.trim());
  if (match == null) return null;
  final y = match.group(1)!;
  final mo = match.group(2)!;
  final d = match.group(3)!;
  final hh = match.group(4)!;
  final mm = match.group(5)!;
  final ss = match.group(6)!;
  final off =
      (rawOffset != null &&
          RegExp(r'^[+-]\d{2}:\d{2}$').hasMatch(rawOffset.trim()))
      ? rawOffset.trim()
      : '';
  return DateTime.tryParse('$y-$mo-${d}T$hh:$mm:$ss$off');
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
}

Future<SanitizedReportPhoto> verifyAndStripReportPhotoBytes({
  required Uint8List rawBytes,
  required double pinLat,
  required double pinLon,
  DateTime? now,
}) async {
  var photoVerified = false;
  try {
    final tags = await readExifFromBytes(rawBytes);
    final exifLat = _dmsRatioToDecimal(
      tags['GPS GPSLatitude'],
      tags['GPS GPSLatitudeRef'],
    );
    final exifLon = _dmsRatioToDecimal(
      tags['GPS GPSLongitude'],
      tags['GPS GPSLongitudeRef'],
    );
    final dtStr = (tags['EXIF DateTimeOriginal'] ?? tags['Image DateTime'])
        ?.printable;
    final offStr = tags['EXIF OffsetTimeOriginal']?.printable;
    final capturedAt = _parseExifDate(dtStr, offStr);

    if (exifLat != null &&
        exifLon != null &&
        capturedAt != null &&
        pinLat.isFinite &&
        pinLon.isFinite) {
      final refNow = (now ?? DateTime.now()).toUtc();
      final age = refNow.difference(capturedAt.toUtc());
      final distM = _haversineM(exifLat, exifLon, pinLat, pinLon);
      if (age >= -_maxClockSkew &&
          age <= _maxVerifiedAge &&
          distM <= _maxVerifiedDistanceM) {
        photoVerified = true;
      }
    }
  } catch (_) {
    photoVerified = false;
  }

  final reencoded = await Isolate.run<({Uint8List bytes, int w, int h})>(() {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw const FormatException('unsupported_image_bytes');
    }
    final oriented = img.bakeOrientation(decoded);
    final maxSide = math.max(oriented.width, oriented.height);
    final resized = maxSide > _maxImageDimensionPx
        ? (oriented.width >= oriented.height
              ? img.copyResize(
                  oriented,
                  width: _maxImageDimensionPx,
                  interpolation: img.Interpolation.linear,
                )
              : img.copyResize(
                  oriented,
                  height: _maxImageDimensionPx,
                  interpolation: img.Interpolation.linear,
                ))
        : oriented;

    // Critical privacy step: copyResize clones Image.exif unless explicitly cleared!
    resized.exif.clear();

    final cleanBytes = img.encodeJpg(resized, quality: _jpegQuality);
    return (bytes: cleanBytes, w: resized.width, h: resized.height);
  });

  return SanitizedReportPhoto(
    strippedJpegBytes: reencoded.bytes,
    photoVerified: photoVerified,
    width: reencoded.w,
    height: reencoded.h,
  );
}
