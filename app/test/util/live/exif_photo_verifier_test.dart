import 'package:exif/exif.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:wanderer/util/live/exif_photo_verifier.dart';

void main() {
  test(
    'verifies fresh nearby EXIF photo and strips 100% of EXIF tags and oversized dimensions',
    () async {
      final source = img.Image(width: 1600, height: 1200);
      img.fill(source, color: img.ColorRgb8(36, 39, 52));
      source.exif.exifIfd['DateTimeOriginal'] = img.IfdValueAscii(
        '2026:11:18 13:15:00',
      );
      source.exif.exifIfd['OffsetTimeOriginal'] = img.IfdValueAscii('+02:00');
      source.exif.gpsIfd.latitude = 45.4458;
      source.exif.gpsIfd.longitude = 25.4563;

      final dirtyJpg = img.encodeJpg(source, quality: 90);
      final preTags = await readExifFromBytes(dirtyJpg);
      expect(preTags.isNotEmpty, isTrue);

      final res = await verifyAndStripReportPhotoBytes(
        rawBytes: dirtyJpg,
        pinLat: 45.4460,
        pinLon: 25.4564,
        now: DateTime.parse('2026-11-18T11:45:00Z'), // 30m after 13:15+02:00
      );

      expect(res.photoVerified, isTrue);
      expect(res.width, 1280);
      expect(res.height, 960);

      final postTags = await readExifFromBytes(res.strippedJpegBytes);
      expect(
        postTags.keys.where((k) => k.startsWith('GPS') || k.contains('DateTime')),
        isEmpty,
      );
    },
  );
}
