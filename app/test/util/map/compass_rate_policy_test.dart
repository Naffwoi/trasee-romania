import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/components/map/location_marker_layer.dart';
import 'package:wanderer/util/map/compass_rate_policy.dart';

void main() {
  group('resolveCompassRatePolicy', () {
    test('disables rotation sensor completely when UI hidden or stationary', () {
      final hidden = resolveCompassRatePolicy(
        uiVisible: false,
        headingUp: true,
        isStationary: false,
        expeditionMode: false,
      );
      expect(hidden.sensorEnabled, isFalse);

      final stationary = resolveCompassRatePolicy(
        uiVisible: true,
        headingUp: true,
        isStationary: true,
        expeditionMode: false,
      );
      expect(stationary.sensorEnabled, isFalse);
    });

    test('uses 66ms / 0.3 deg in headingUp and steps down to 200ms / 1.5 deg in northUp', () {
      final headingUp = resolveCompassRatePolicy(
        uiVisible: true,
        headingUp: true,
        isStationary: false,
        expeditionMode: false,
      );
      expect(headingUp.sensorEnabled, isTrue);
      expect(headingUp.samplingPeriod, const Duration(milliseconds: 66));
      expect(headingUp.deadbandDeg, 0.3);

      final northUp = resolveCompassRatePolicy(
        uiVisible: true,
        headingUp: false,
        isStationary: false,
        expeditionMode: false,
      );
      expect(northUp.sensorEnabled, isTrue);
      expect(northUp.samplingPeriod, const Duration(milliseconds: 200));
      expect(northUp.deadbandDeg, 1.5);
    });

    test('uses 250ms / 2.5 deg in expedition mode when headingUp', () {
      final exp = resolveCompassRatePolicy(
        uiVisible: true,
        headingUp: true,
        isStationary: false,
        expeditionMode: true,
      );
      expect(exp.sensorEnabled, isTrue);
      expect(exp.samplingPeriod, const Duration(milliseconds: 250));
      expect(exp.deadbandDeg, 2.5);
    });
  });

  group('CameraPushThrottle', () {
    test('caps 120Hz animation frames (8.3ms) down to ~30Hz (33ms) while always allowing final frame', () {
      final throttle = CameraPushThrottle();
      expect(throttle.shouldPush(const Duration(milliseconds: 0)), isTrue);
      expect(throttle.shouldPush(const Duration(milliseconds: 8)), isFalse);
      expect(throttle.shouldPush(const Duration(milliseconds: 16)), isFalse);
      expect(throttle.shouldPush(const Duration(milliseconds: 25)), isFalse);
      expect(throttle.shouldPush(const Duration(milliseconds: 34)), isTrue);
      expect(
        throttle.shouldPush(const Duration(milliseconds: 40), isFinalFrame: true),
        isTrue,
      );
    });
  });

  testWidgets('LocationPuck rotates cone via headingListenable without rebuilding parent tree', (tester) async {
    var parentBuilds = 0;
    final headingNotifier = ValueNotifier<double?>(15.0);
    addTearDown(headingNotifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, _) {
            parentBuilds++;
            return LocationPuck(
              size: 96,
              dotSize: 20,
              headingListenable: headingNotifier,
              headingAccuracy: 10.0,
            );
          },
        ),
      ),
    );

    expect(parentBuilds, 1);
    expect(find.byKey(const ValueKey('gmaps-heading-cone')), findsOneWidget);

    headingNotifier.value = 95.0;
    await tester.pump();

    expect(parentBuilds, 1);
  });
}
