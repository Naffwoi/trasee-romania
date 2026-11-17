import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/components/map/location_marker_layer.dart';

void main() {
  testWidgets(
    'LocationPuck renders radial flashlight cone when showHeading is true',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: LocationPuck(
                size: 88,
                dotSize: 18,
                heading: 135,
                headingAccuracy: 10,
                showHeading: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('gmaps-heading-cone')), findsOneWidget);
    },
  );

  testWidgets('LocationPuck hides cone when heading is null or negative', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LocationPuck(
              size: 88,
              dotSize: 18,
              heading: null,
              showHeading: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('gmaps-heading-cone')), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: LocationPuck(
              size: 88,
              dotSize: 18,
              heading: -1,
              showHeading: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('gmaps-heading-cone')), findsNothing);
  });

  testWidgets(
    'LocationPuck preserves NavigationScreen call signature compatibility',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: LocationPuck(
                size: 44,
                dotSize: 20,
                heading: 90,
                headingAccuracy: 0,
                showHeading: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('gmaps-heading-cone')), findsOneWidget);
    },
  );

  testWidgets(
    'LocationPuck renders crisp 96x96 directional cone beyond 20px dot',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: LocationPuck(
                size: 96,
                dotSize: 20,
                heading: 45,
                headingAccuracy: 0,
                showHeading: true,
              ),
            ),
          ),
        ),
      );

      final coneFinder = find.byKey(const ValueKey('gmaps-heading-cone'));
      expect(coneFinder, findsOneWidget);
      expect(tester.getSize(find.byType(LocationPuck)), const Size(96, 96));
    },
  );
}
