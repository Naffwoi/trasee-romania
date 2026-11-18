import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';
import 'package:wanderer/components/navigation/group_sheet.dart';
import 'package:wanderer/components/trail/elevation_profile.dart';
import 'package:wanderer/components/trail/trail_salvamont_card.dart';
import 'package:wanderer/i18n/app_localizations.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/models/global_search_models.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/models/trail.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/salvamont_provider.dart';
import 'package:wanderer/util/trail/curated_carpathian_photos.dart';

void main() {
  test('zero dates from Go/PocketBase normalize to null', () {
    final searchZero = TrailSearchResult.mock().copyWith(date: 0);
    expect(searchZero.summaryDate, isNull);

    final searchPreEpoch = TrailSearchResult.mock().copyWith(date: -62135596800);
    expect(searchPreEpoch.summaryDate, isNull);

    final searchValid = TrailSearchResult.mock().copyWith(date: 1731931200);
    expect(searchValid.summaryDate, isNotNull);

    final trailZero = Trail.fromJson({
      'id': 'tr_zero_1',
      'name': 'Timișu de Sus - Cascada Tamina',
      'date': '0001-01-01 00:00:00.000Z',
      'created': '2026-11-17 10:00:00.000Z',
      'updated': '2026-11-17 10:00:00.000Z',
    });
    expect(trailZero.date, isNull);
    expect(trailZero.summaryDate, isNull);
  });

  test('resolveCuratedCarpathianPhoto matches Tamina and Predeal trails', () {
    final tamina = resolveCuratedCarpathianPhoto(
      name: 'Timișu de Sus - Cascada Tamina - Stâna sub Piatra Mare',
      location: 'DN1 (Timișu de Sus)',
    );
    expect(tamina?.assetPath, 'assets/images/carpathians/cascada_tamina.jpg');

    final predeal = resolveCuratedCarpathianPhoto(
      name: 'Predeal - Fetifoiu - La Șipote',
      location: 'Predeal',
    );
    expect(predeal?.assetPath, 'assets/images/carpathians/predeal_clabucet.jpg');
    expect(isPlaceholderPhotoName('wanderer_route_placeholder_123.svg'), isTrue);
  });

  testWidgets(
    'ElevationProfile uses trailDisplayDuration instead of 0min when GPX lacks timestamps',
    (tester) async {
      final gpx = Gpx()
        ..trks = [
          Trk(
            trksegs: [
              Trkseg(
                trkpts: [
                  Wpt(lat: 45.54, lon: 25.63, ele: 900),
                  Wpt(lat: 45.55, lon: 25.64, ele: 1200),
                  Wpt(lat: 45.56, lon: 25.65, ele: 1500),
                ],
              ),
            ],
          ),
        ];

      final trail = Trail.mock().copyWith(
        duration: 10200, // 2h 50m
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            unitProvider.overrideWithValue('metric'),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('ro'),
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 300,
                child: ElevationProfile(
                  trail: trail,
                  gpx: gpx,
                  enableLineTouch: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('0min'), findsNothing);
      expect(find.textContaining('2h'), findsOneWidget);
      expect(find.textContaining('50m'), findsOneWidget);
    },
  );

  testWidgets(
    'TrailSalvamontCard shows white phone vector on 112 and collapses local dispatches',
    (tester) async {
      final raw = File('assets/data/salvamont_ro.json').readAsStringSync();
      final ds = SalvamontDataset.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );

      final omuTrail = Trail.mock().copyWith(
        lat: 45.4458,
        lon: 25.4563,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            salvamontDatasetProvider.overrideWith((ref) async => ds),
            localeProvider.overrideWithValue(const Locale('ro')),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TrailSalvamontCard(trail: omuTrail),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('salvamont-call-112')), findsOneWidget);
      final phoneIcon = tester.widget<Icon>(
        find.byIcon(Icons.phone_in_talk_rounded),
      );
      expect(phoneIcon.color, Colors.white);

      final toggleFinder = find.byKey(const ValueKey('salvamont-local-toggle'));
      expect(toggleFinder, findsOneWidget);
      expect(find.byIcon(Icons.call_outlined), findsNothing);

      await tester.tap(toggleFinder);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.call_outlined), findsWidgets);
    },
  );

  testWidgets(
    'LiveGroupSheet supports QR invite when active and Planifică Tură tab',
    (tester) async {
      final sessionNotifier = ValueNotifier<GroupSessionModel?>(
        const GroupSessionModel(
          code: 'K7M4P9',
          selfMemberId: 'mem-1',
          members: [
            GroupMemberModel(
              memberId: 'mem-1',
              displayName: 'Grigore',
              lat: 45.5,
              lon: 25.57,
              isSelf: true,
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LiveGroupSheet(
                sessionListenable: sessionNotifier,
                initialDisplayName: 'Grigore',
                initialTrailName: 'Timișu de Sus - Cascada Tamina',
                onCreateGroup: (_) async => sessionNotifier.value,
                onJoinGroup: (_, _) async => sessionNotifier.value,
                onLeaveGroup: () async => sessionNotifier.value = null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('group-qr-invite')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('group-tab-plan')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('group-plan-share-btn')), findsOneWidget);
      expect(find.text('Timișu de Sus - Cascada Tamina'), findsOneWidget);
    },
  );
}
