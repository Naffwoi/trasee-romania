import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/components/map/center_on_location_button.dart';
import 'package:wanderer/components/map/location_marker_layer.dart';
import 'package:wanderer/i18n/app_localizations.dart';
import 'package:wanderer/provider/compass_heading_stream_provider.dart';
import 'package:wanderer/provider/foreground_position_stream_provider.dart';
import 'package:wanderer/provider/nav_session_hibernation_provider.dart';

class _SpyForegroundPositionStream extends ForegroundPositionStream {
  int acquireCalls = 0;
  int releaseCalls = 0;
  final _ctrl = StreamController<LocationMarkerPosition?>.broadcast();

  @override
  Stream<LocationMarkerPosition?> build() {
    replaying = _ctrl.stream;
    ref.onDispose(_ctrl.close);
    return _ctrl.stream;
  }

  @override
  void acquire() {
    acquireCalls++;
  }

  @override
  void release() {
    releaseCalls++;
  }
}

class _SpyCompassStream extends CompassHeadingStream {
  int acquireCalls = 0;
  int releaseCalls = 0;
  final _ctrl = StreamController<CompassHeadingReading?>.broadcast();

  @override
  Stream<CompassHeadingReading?> build() {
    replaying = _ctrl.stream;
    ref.onDispose(_ctrl.close);
    return _ctrl.stream;
  }

  @override
  void acquire() {
    acquireCalls++;
  }

  @override
  void release() {
    releaseCalls++;
  }
}

void main() {
  testWidgets(
    'LocationMarkerLayer and CenterOnLocationButton release GPS and compass when covered by pushed route or hibernated',
    (tester) async {
      final gpsSpy = _SpyForegroundPositionStream();
      final compassSpy = _SpyCompassStream();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            foregroundPositionStreamProvider.overrideWith(() => gpsSpy),
            compassHeadingStreamProvider.overrideWith(() => compassSpy),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const LocationMarkerLayer(),
                    CenterOnLocationButton(onPressed: (_) {}),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const Scaffold(
                              body: Text('Top Navigation Route'),
                            ),
                          ),
                        );
                      },
                      child: const Text('Push Route'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(gpsSpy.acquireCalls, 1);
      expect(compassSpy.acquireCalls, 1);
      expect(gpsSpy.releaseCalls, 0);

      // Push an opaque route on top -> TickerMode becomes false on home route.
      await tester.tap(find.text('Push Route'));
      await tester.pumpAndSettle();

      expect(gpsSpy.releaseCalls, 1);
      expect(compassSpy.releaseCalls, 1);

      // Pop back -> sensors re-acquire cleanly.
      Navigator.of(tester.element(find.text('Top Navigation Route'))).pop();
      await tester.pumpAndSettle();

      expect(gpsSpy.acquireCalls, 2);
      expect(compassSpy.acquireCalls, 2);
    },
  );

  test('NavSessionHibernation reference-counts overlapping sessions safely', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(navSessionHibernationProvider.notifier);
    expect(container.read(navSessionHibernationProvider), isFalse);

    notifier.enterNavigationSession();
    expect(container.read(navSessionHibernationProvider), isTrue);

    notifier.enterNavigationSession();
    notifier.exitNavigationSession();
    expect(container.read(navSessionHibernationProvider), isTrue);

    notifier.exitNavigationSession();
    expect(container.read(navSessionHibernationProvider), isFalse);
  });
}
