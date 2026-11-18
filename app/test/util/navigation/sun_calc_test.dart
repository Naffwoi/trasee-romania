import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/navigation/sun_calc.dart';

void main() {
  group('sun_calc (Dart Meeus Ch.25 + rtsafe)', () {
    test(
      'computes North-clockwise azimuth and summer solstice altitude at Vf. Omu',
      () {
        final noon = getSunPosition(
          DateTime.parse('2026-06-21T10:20:00Z'),
          45.4457,
          25.4563,
        );
        expect(noon.azimuthDeg, inInclusiveRange(177.0, 183.0));
        expect(noon.altitudeDeg, inInclusiveRange(67.5, 68.3));
      },
    );

    test(
      'handles Arctic midnight sun and polar night safely with null times',
      () {
        final summer = getSunTimes(
          DateTime.parse('2026-06-21T12:00:00Z'),
          69.6492,
          18.9553,
        );
        expect(summer.polarState, PolarState.midnightSun);
        expect(summer.sunrise, isNull);
        expect(summer.sunset, isNull);

        final winter = getSunTimes(
          DateTime.parse('2026-12-21T12:00:00Z'),
          69.6492,
          18.9553,
        );
        expect(winter.polarState, PolarState.polarNight);
        expect(winter.sunrise, isNull);
        expect(winter.sunset, isNull);
      },
    );
  });
}
