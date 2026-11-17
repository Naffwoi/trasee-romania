import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/provider/location_tracking_mode_provider.dart';
import 'package:wanderer/util/map/heading_math.dart';

void main() {
  group('heading_math', () {
    test('normalizes degrees into [0, 360)', () {
      expect(normalizeHeading(0), 0);
      expect(normalizeHeading(-0.0), 0);
      expect(normalizeHeading(360), 0);
      expect(normalizeHeading(-15), 345);
      expect(normalizeHeading(725), 5);
    });

    test('shortestAngleDelta wraps across North', () {
      expect(shortestAngleDelta(358, 2), closeTo(4, 1e-6));
      expect(shortestAngleDelta(2, 358), closeTo(-4, 1e-6));
      expect(shortestAngleDelta(0, 180), closeTo(180, 1e-6));
      expect(lerpBearing(350, 10, 0.5), closeTo(0, 1e-6));
    });

    test('CircularHeadingFilter wraps across 359 -> 1 without crossing 180', () {
      final filter = CircularHeadingFilter(alpha: 0.22, deadbandDeg: 0.5);
      expect(filter.update(358), closeTo(358, 0.01));
      final next = filter.update(2);
      expect(next, isNotNull);
      expect(next! > 358 || next < 3, isTrue);
    });

    test('suppresses sub-deadband jitter', () {
      final filter = CircularHeadingFilter(alpha: 0.22, deadbandDeg: 0.5);
      expect(filter.update(45), closeTo(45, 0.01));
      expect(filter.update(45.1), isNull);
    });

    test('maps accuracy to Google Maps cone half-angle', () {
      expect(coneHalfAngleFromAccuracy(null), 25);
      expect(coneHalfAngleFromAccuracy(12), 25);
      expect(coneHalfAngleFromAccuracy(28), 35);
      expect(coneHalfAngleFromAccuracy(48), 45);
      expect(coneHalfAngleFromAccuracy(-1), 45);
    });
  });

  group('LocationTrackingMode transitions', () {
    test('cycles freeTracking -> followNorthUp -> followHeadingUp -> followNorthUp', () {
      expect(
        nextLocationTrackingMode(
          LocationTrackingMode.inactive,
          hasHeading: true,
        ),
        LocationTrackingMode.followNorthUp,
      );
      expect(
        nextLocationTrackingMode(
          LocationTrackingMode.freeTracking,
          hasHeading: true,
        ),
        LocationTrackingMode.followNorthUp,
      );
      expect(
        nextLocationTrackingMode(
          LocationTrackingMode.followNorthUp,
          hasHeading: true,
        ),
        LocationTrackingMode.followHeadingUp,
      );
      expect(
        nextLocationTrackingMode(
          LocationTrackingMode.followHeadingUp,
          hasHeading: true,
        ),
        LocationTrackingMode.followNorthUp,
      );
    });

    test('stays in followNorthUp when no heading is available', () {
      expect(
        nextLocationTrackingMode(
          LocationTrackingMode.followNorthUp,
          hasHeading: false,
        ),
        LocationTrackingMode.followNorthUp,
      );
    });
  });
}
