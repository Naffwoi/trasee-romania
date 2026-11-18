import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/emergency/rescue_coordinates.dart';

void main() {
  group('RescueCoordinates (Karney UTM + Plus Codes + SMS 113)', () {
    test(
      'matches Vf. Omu (35T), Vf. Retezat (34T), Horodistea (35U) and Zurich OLC vectors',
      () {
        final omu = wgs84ToUtm(45.445833, 25.456389);
        expect(omu.formatted, '35T 379287 E 5033638 N');
        expect(
          encodePlusCode(45.445833, 25.456389, codeLength: 11),
          '8GQ7CFW4+8HJ',
        );

        final retezat = wgs84ToUtm(45.366111, 22.876944);
        expect(retezat.formatted, '34T 646986 E 5025336 N');
        expect(
          encodePlusCode(45.366111, 22.876944, codeLength: 11),
          '8GQ49V8G+CQW',
        );

        final horodistea = wgs84ToUtm(48.258000, 26.701000);
        expect(horodistea.formatted, '35U 477807 E 5345020 N');

        expect(
          encodePlusCode(47.365590, 8.524997, codeLength: 10),
          '8FVC9G8F+6X',
        );
        expect(
          encodePlusCode(47.365590, 8.524997, codeLength: 11),
          '8FVC9G8F+6XQ',
        );
      },
    );

    test(
      'never emits 60.0s in DMS and encodes SMS spaces as %20 (never +) on iOS & Android',
      () {
        expect(formatDmsCoordinate(45.999999, 25.499999), isNot(contains('60.0"')));

        final bundle = formatRescueCoordinates(
          lat: 45.445833,
          lon: 25.456389,
          elevationM: 2505,
          accuracyM: 7,
          reasonRo: 'Accidentare',
          now: DateTime.utc(2026, 11, 18, 12, 32),
        );
        expect(bundle.sms113AsciiBody.length, lessThanOrEqualTo(160));

        final iosUri = buildEmergencySmsUri(
          recipient: '113',
          asciiBody: 'SOS MUNTE',
          isIOS: true,
        );
        expect(iosUri.toString(), 'sms:113&body=SOS%20MUNTE');

        final androidUri = buildEmergencySmsUri(
          recipient: '113',
          asciiBody: 'SOS MUNTE',
          isIOS: false,
        );
        expect(androidUri.toString(), 'sms:113?body=SOS%20MUNTE');
      },
    );
  });
}
