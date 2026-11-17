import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:wanderer/components/map/center_on_location_button.dart';
import 'package:wanderer/components/map/location_marker_layer.dart'
    show kGoogleMapsBlue;
import 'package:wanderer/i18n/app_localizations.dart';
import 'package:wanderer/provider/compass_heading_stream_provider.dart';
import 'package:wanderer/provider/foreground_position_stream_provider.dart';
import 'package:wanderer/provider/location_tracking_mode_provider.dart';

void main() {
  testWidgets(
    'CenterOnLocationButton cycles freeTracking -> followNorthUp -> followHeadingUp -> followNorthUp',
    (tester) async {
      final posController =
          StreamController<LocationMarkerPosition?>.broadcast(sync: true);
      final compassController =
          StreamController<CompassHeadingReading?>.broadcast(sync: true);
      final modeNotifier = ValueNotifier(LocationTrackingMode.freeTracking);

      addTearDown(() async {
        modeNotifier.dispose();
        await posController.close();
        await compassController.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            liveLocationProvider.overrideWithValue(posController.stream),
            liveCompassProvider.overrideWithValue(compassController.stream),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: CenterOnLocationButton(
                trackingMode: modeNotifier,
                onPressed: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Disabled before any GPS fix arrives
      expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);

      posController.add(
        const LocationMarkerPosition(
          latitude: 45.64,
          longitude: 25.58,
          accuracy: 12,
        ),
      );
      compassController.add(const CompassHeadingReading(heading: 95));
      await tester.pump();

      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );
      expect(modeNotifier.value, LocationTrackingMode.freeTracking);
      expect(
        tester.widget<FaIcon>(find.byType(FaIcon)).icon?.codePoint,
        FontAwesomeIcons.locationCrosshairs.codePoint,
      );

      // Tap 1 -> followNorthUp (active blue crosshairs)
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(modeNotifier.value, LocationTrackingMode.followNorthUp);
      var faIcon = tester.widget<FaIcon>(find.byType(FaIcon));
      expect(
        faIcon.icon?.codePoint,
        FontAwesomeIcons.locationCrosshairs.codePoint,
      );
      expect(faIcon.color, kGoogleMapsBlue);

      // Tap 2 -> followHeadingUp (switches icon to blue locationArrow)
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(modeNotifier.value, LocationTrackingMode.followHeadingUp);
      faIcon = tester.widget<FaIcon>(find.byType(FaIcon));
      expect(faIcon.icon?.codePoint, FontAwesomeIcons.locationArrow.codePoint);
      expect(faIcon.color, kGoogleMapsBlue);

      // Tap 3 -> followNorthUp
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(modeNotifier.value, LocationTrackingMode.followNorthUp);
      faIcon = tester.widget<FaIcon>(find.byType(FaIcon));
      expect(
        faIcon.icon?.codePoint,
        FontAwesomeIcons.locationCrosshairs.codePoint,
      );
      expect(faIcon.color, kGoogleMapsBlue);
    },
  );

  testWidgets(
    'CenterOnLocationButton stays in followNorthUp when no heading is available',
    (tester) async {
      final posController =
          StreamController<LocationMarkerPosition?>.broadcast(sync: true);
      final compassController =
          StreamController<CompassHeadingReading?>.broadcast(sync: true);
      final modeNotifier = ValueNotifier(LocationTrackingMode.freeTracking);

      addTearDown(() async {
        modeNotifier.dispose();
        await posController.close();
        await compassController.close();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            liveLocationProvider.overrideWithValue(posController.stream),
            liveCompassProvider.overrideWithValue(compassController.stream),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: CenterOnLocationButton(
                trackingMode: modeNotifier,
                onPressed: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      posController.add(
        const LocationMarkerPosition(
          latitude: 45.64,
          longitude: 25.58,
          accuracy: 12,
        ),
      );
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
      );

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(modeNotifier.value, LocationTrackingMode.followNorthUp);

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(modeNotifier.value, LocationTrackingMode.followNorthUp);
    },
  );
}
