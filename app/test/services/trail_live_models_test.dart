import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/components/navigation/group_sheet.dart';
import 'package:wanderer/components/navigation/sos_banner_and_dialog.dart';
import 'package:wanderer/components/navigation/waze_nearby_prompt.dart';
import 'package:wanderer/components/navigation/waze_report_sheet.dart';
import 'package:wanderer/components/trail/active_hikers_badge.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/services/trail_live_service.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';

class _FakeLiveAdapter implements HttpClientAdapter {
  _FakeLiveAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;
  final List<RequestOptions> captured = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    captured.add(options);
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('generateLiveDeviceToken', () {
    test('mints unique 64-char lowercase hex device tokens', () {
      final t1 = generateLiveDeviceToken();
      final t2 = generateLiveDeviceToken();
      expect(t1, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(t2, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(t1, isNot(equals(t2)));
    });
  });

  group('TrailReportModel permanent vs temporary lifecycles', () {
    test('parses all 8 categories and keeps permanent landmarks non-expiring', () {
      expect(TrailReportCategory.values, hasLength(8));
      expect(TrailReportCategory.temporaryCategories, hasLength(5));
      expect(TrailReportCategory.permanentCategories, hasLength(3));

      final spring = TrailReportModel.fromJson(<String, dynamic>{
        'id': 'rep_spring_1',
        'trailId': 'trail_bucegi',
        'category': 'spring',
        'kind': 'landmark_permanent',
        'isPermanent': true,
        'conditionStatus': 'active',
        'note': 'Izvor rece sub șa',
        'lat': 45.4123,
        'lon': 25.4567,
        'ele': 1820.0,
        'alongTrackM': 3420.5,
        'confirmCount': 4,
        'dismissCount': 0,
        'createdAt': '2026-11-17T08:00:00Z',
        'lastConfirmedAt': '2026-11-17T10:00:00Z',
        'expiresAt': '',
      });

      expect(spring.isPermanent, isTrue);
      expect(spring.expiresAt, isNull);
      expect(spring.category, TrailReportCategory.spring);
      expect(
        spring.isVisibleAt(DateTime.utc(2028, 6, 1)),
        isTrue,
        reason: 'Permanent landmarks never auto-expire.',
      );

      final dried = spring.applyLocalVote(
        TrailReportVoteType.seasonalDry,
        now: DateTime.utc(2026, 11, 17, 12, 0),
      );
      expect(dried.isDryOrClosed, isTrue);
      expect(dried.expiresAt, isNull);
      expect(dried.isVisibleAt(DateTime.utc(2027, 1, 1)), isTrue);

      final flowingAgain = dried.applyLocalVote(
        TrailReportVoteType.seasonalOk,
        now: DateTime.utc(2026, 11, 17, 14, 0),
      );
      expect(flowingAgain.isDryOrClosed, isFalse);
      expect(flowingAgain.conditionStatus, 'active');

      final spamHidden = flowingAgain.applyLocalVote(TrailReportVoteType.spam);
      expect(spamHidden.isVisibleAt(DateTime.utc(2026, 11, 17, 15, 0)), isFalse);
    });

    test('temporary bear alert expires after 3h unless confirm extends TTL', () {
      final t0 = DateTime.utc(2026, 11, 17, 10, 0);
      final bear = TrailReportModel.fromJson(<String, dynamic>{
        'id': 'rep_bear_1',
        'trailId': 'trail_piatra_craiului',
        'category': 'bear',
        'kind': 'hazard',
        'isPermanent': false,
        'conditionStatus': 'active',
        'note': 'Ursoaică văzută în poiană',
        'lat': 45.5300,
        'lon': 25.2200,
        'ele': 1420.0,
        'confirmCount': 1,
        'dismissCount': 0,
        'createdAt': t0.toIso8601String(),
        'lastConfirmedAt': t0.toIso8601String(),
        'expiresAt': t0.add(const Duration(hours: 3)).toIso8601String(),
      });

      expect(bear.isPermanent, isFalse);
      expect(bear.isVisibleAt(t0.add(const Duration(hours: 2))), isTrue);
      expect(bear.isVisibleAt(t0.add(const Duration(hours: 3, minutes: 1))), isFalse);
      expect(
        bear.confirmedAgoLabel(t0.add(const Duration(minutes: 15)), isRo: true),
        'Confirmat acum 15 min',
      );

      // Confirming at +2h extends expiresAt to (t0 + 2h) + 3h = t0 + 5h!
      final confirmAt = t0.add(const Duration(hours: 2));
      final extended = bear.applyLocalVote(
        TrailReportVoteType.confirm,
        now: confirmAt,
      );
      expect(extended.confirmCount, 2);
      expect(extended.lastConfirmedAt, confirmAt);
      expect(extended.expiresAt, confirmAt.add(const Duration(hours: 3)));
      expect(extended.isVisibleAt(t0.add(const Duration(hours: 4))), isTrue);

      // Dismissing 3 times resolves a temporary alert.
      var cur = bear;
      cur = cur.applyLocalVote(TrailReportVoteType.dismiss, now: confirmAt);
      expect(cur.conditionStatus, 'active');
      cur = cur.applyLocalVote(TrailReportVoteType.dismiss, now: confirmAt);
      expect(cur.conditionStatus, 'active');
      cur = cur.applyLocalVote(TrailReportVoteType.dismiss, now: confirmAt);
      expect(cur.conditionStatus, 'resolved');
      expect(cur.isVisibleAt(confirmAt), isFalse);
    });
  });

  group('TrailLiveSummary, SosAlertModel & TrailLiveService', () {
    test('attaches X-Device-Token and fires SOS notification once for !isMine', () async {
      const fixedToken =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      final futureExpiry = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 5))
          .toIso8601String();

      final adapter = _FakeLiveAdapter((options) async {
        if (options.path == '/live/heartbeat') {
          return ResponseBody.fromString(
            jsonEncode(<String, Object?>{
              'activeHikers30m': 7,
              'reports': <Object?>[
                <String, Object?>{
                  'id': 'r1',
                  'category': 'deer',
                  'isPermanent': false,
                  'lat': 45.501,
                  'lon': 25.501,
                  'expiresAt': futureExpiry,
                },
              ],
              'sosAlerts': <Object?>[
                <String, Object?>{
                  'id': 'sos_mine',
                  'status': 'active',
                  'reason': 'lost',
                  'lat': 45.500,
                  'lon': 25.500,
                  'responderCount': 2,
                  'isMine': true,
                  'expiresAt': futureExpiry,
                },
                <String, Object?>{
                  'id': 'sos_other_1',
                  'status': 'active',
                  'reason': 'injury',
                  'message': 'Gleznă luxată',
                  'requesterName': 'Andrei',
                  'lat': 45.505,
                  'lon': 25.505,
                  'ele': 1340,
                  'responderCount': 1,
                  'isMine': false,
                  'expiresAt': futureExpiry,
                },
              ],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        }
        if (options.path == '/live/stream') {
          final ssePayload =
              ': keepalive\n\n'
              'event: sos_update\n'
              'data: ${jsonEncode(<String, Object?>{
                'sos': <String, Object?>{
                  'id': 'sos_other_2',
                  'status': 'active',
                  'reason': 'exhaustion',
                  'lat': 45.508,
                  'lon': 25.502,
                  'isMine': false,
                  'expiresAt': futureExpiry,
                },
              })}\n\n';
          return ResponseBody(
            Stream<Uint8List>.fromIterable(<Uint8List>[
              Uint8List.fromList(utf8.encode(ssePayload)),
            ]),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/event-stream'],
            },
          );
        }
        return ResponseBody.fromString('{}', 200);
      });

      final dio = Dio(BaseOptions(baseUrl: 'https://trasee.skillfy.ro/api/v1'))
        ..httpClientAdapter = adapter;

      final notifiedIds = <String>[];
      final service = TrailLiveService(
        dio: dio,
        tokenLoader: () async => fixedToken,
        onSosNotificationCallback: (sos, distanceM) async {
          notifiedIds.add(sos.id);
          expect(distanceM, isNotNull);
          expect(distanceM!, greaterThan(100.0));
        },
      );

      final summary1 = await service.sendHeartbeat(
        trailId: '2dpactqgvlbl47q',
        lat: 45.500,
        lon: 25.500,
        ele: 1200.0,
        inNavigation: true,
      );
      expect(summary1, isNotNull);
      expect(summary1!.activeHikers30m, 7);
      expect(summary1.myActiveSos()?.id, 'sos_mine');
      expect(summary1.nearbyActiveSos().map((s) => s.id), <String>['sos_other_1']);
      expect(notifiedIds, <String>['sos_other_1']);
      expect(adapter.captured.first.headers['X-Device-Token'], fixedToken);

      // Second heartbeat with the same SOS id must NOT re-notify.
      await service.sendHeartbeat(lat: 45.500, lon: 25.500);
      expect(notifiedIds, <String>['sos_other_1']);

      // SSE stream delivers sos_other_2 and triggers notification once.
      final events = await service
          .connectStream(lat: 45.500, lon: 25.500, trailId: '2dpactqgvlbl47q')
          .toList();
      expect(events, hasLength(1));
      expect(events.first.type, 'sos_update');
      expect(events.first.sos?.id, 'sos_other_2');
      expect(notifiedIds, <String>['sos_other_1', 'sos_other_2']);
    });
  });

  group('OffTrailRouter.computeDirectRescueRoute', () {
    test('routes directly to SOS victim and steers around >36.8 deg cliff wall', () {
      const responderPos = Geographic(lat: 45.5000, lon: 25.5000);
      // Victim is ~445 m North.
      const victimPos = Geographic(lat: 45.5040, lon: 25.5000);

      // Synthetic cliff barrier blocking direct North chord near lat 45.5020
      // for lon <= 25.5012, while East around lon 25.5018 is a gentle ramp!
      double cliffSampler(double lat, double lon) {
        if (lon < 25.5012) {
          if (lat < 45.5018) return 1000.0;
          if (lat > 45.5022) return 1060.0; // 60 m vertical jump in ~44 m => >53 deg cliff!
          final t = ((lat - 45.5018) / 0.0004).clamp(0.0, 1.0);
          return 1000.0 + 60.0 * t;
        }
        // Gentle bypass ramp to the East: 60 m over 445 m (~13.5% grade).
        final rampT = ((lat - 45.5000) / 0.0040).clamp(0.0, 1.0);
        return 1000.0 + 60.0 * rampT;
      }

      final rescue = computeDirectRescueRoute(
        userPos: responderPos,
        userEleM: 1000.0,
        targetPos: victimPos,
        targetEleM: 1060.0,
        sampler: cliffSampler,
        localeCode: 'ro',
      );

      expect(rescue, isNotNull);
      expect(rescue!.points.length, greaterThanOrEqualTo(2));
      expect(rescue.points.first.lat, closeTo(responderPos.lat, 1e-6));
      expect(rescue.points.last.lat, closeTo(victimPos.lat, 1e-6));
      expect(rescue.distanceM, greaterThan(440.0));
      expect(rescue.estimatedSeconds, greaterThan(60));
      expect(rescue.avoidedSteepHazard, isTrue);
      expect(rescue.maxSlopeDeg, lessThan(38.5));
      expect(rescue.instruction, contains('Rută salvare'));

      // Also works with IDW fallback when no DEM tiles are cached (`sampler` -> null).
      final offlineRescue = computeDirectRescueRoute(
        userPos: responderPos,
        userEleM: 1100.0,
        targetPos: victimPos,
        targetEleM: 1180.0,
        sampler: (_, _) => null,
        localeCode: 'en',
      );
      expect(offlineRescue, isNotNull);
      expect(offlineRescue!.ascentM, closeTo(80.0, 5.0));
      expect(offlineRescue.instruction, contains('Rescue route'));

      // > 3 km off-trail (e.g. 270+ km away) enters Calm Preview Mode (returns null with zero DEM samples).
      var farSamples = 0;
      final farReroute = OffTrailRouter.compute(
        userPos: const Geographic(lat: 47.1584, lon: 27.6014),
        userEleM: 120.0,
        trailPoints: const [
          NavTrackPoint(lat: 46.16, lon: 24.35, ele: 320, distanceM: 0, gradePct: 0),
          NavTrackPoint(lat: 46.17, lon: 24.36, ele: 340, distanceM: 1350, gradePct: 1.5),
        ],
        lastAlongTrackM: 0,
        sampler: (_, _) {
          farSamples++;
          return 200.0;
        },
      );
      expect(farReroute, isNull);
      expect(farSamples, 0);
    });
  });

  group('Live community widgets', () {
    testWidgets('ActiveHikersBadge hides when 0 and renders live nearby copy without 30 min', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: [Locale('ro'), Locale('en')],
            locale: Locale('ro'),
            home: Scaffold(
              body: ActiveHikersBadge(countOverride: 0),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('active-hikers-badge')), findsNothing);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: [Locale('ro'), Locale('en')],
            locale: Locale('ro'),
            home: Scaffold(
              body: ActiveHikersBadge(countOverride: 4),
            ),
          ),
        ),
      );

      expect(find.text('4 persoane în zonă'), findsOneWidget);
      expect(find.textContaining('30 min'), findsNothing);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: [Locale('ro'), Locale('en')],
            locale: Locale('en'),
            home: Scaffold(
              body: ActiveHikersBadge(countOverride: 1),
            ),
          ),
        ),
      );

      expect(find.text('1 person nearby'), findsOneWidget);

      // Bare ProviderScope without cookieJarProvider override must settle
      // cleanly with zero uncaught Riverpod errors when trailId is supplied.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ActiveHikersBadge(trailId: 'server-1'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('active-hikers-badge')), findsNothing);
    });

    testWidgets(
      'SosFloatingButton is icon-only and WazeReportSheet submits in 1 tap without TTL clutter',
      (tester) async {
        WazeReportSubmission? submitted;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Column(
                  children: [
                    SosFloatingButton(onPressed: () {}),
                    ElevatedButton(
                      key: const ValueKey('open-waze'),
                      onPressed: () async {
                        submitted = await showWazeReportSheet(ctx, isRo: true);
                      },
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        // Icon-only SOS button: no aggressive "Ajutor" text
        expect(find.byKey(const ValueKey('nav-sos-btn')), findsOneWidget);
        expect(find.text('Ajutor'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('open-waze')));
        await tester.pumpAndSettle();

        expect(find.textContaining('3h'), findsNothing);
        expect(find.textContaining('expiră automat'), findsNothing);

        // 1-tap on bear category immediately pops sheet with submission!
        await tester.tap(find.byKey(const ValueKey('waze-cat-bear')));
        await tester.pumpAndSettle();

        expect(submitted, isNotNull);
        expect(submitted!.category, TrailReportCategory.bear);
      },
    );

    testWidgets(
      'WazeNearbyPrompt dispatches confirm for temporary alert and seasonal votes for spring',
      (tester) async {
        final now = DateTime.now().toUtc();
        final bearReport = TrailReportModel(
          id: 'rep_1',
          category: TrailReportCategory.bear,
          kind: 'hazard',
          isPermanent: false,
          lat: 45.5,
          lon: 25.5,
          lastConfirmedAt: now.subtract(const Duration(minutes: 8)),
          expiresAt: now.add(const Duration(hours: 2)),
        );

        TrailReportVoteType? recordedVote;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WazeNearbyPrompt(
                report: bearReport,
                distanceMeters: 92,
                onVote: (v) => recordedVote = v,
                onClose: () {},
              ),
            ),
          ),
        );

        expect(find.text('👍 OK, mai este'), findsOneWidget);
        expect(find.text('👎 Nu mai e'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('waze-vote-confirm')));
        expect(recordedVote, TrailReportVoteType.confirm);

        final springReport = TrailReportModel(
          id: 'rep_2',
          category: TrailReportCategory.spring,
          kind: 'landmark_permanent',
          isPermanent: true,
          lat: 45.5,
          lon: 25.5,
          lastConfirmedAt: now.subtract(const Duration(minutes: 20)),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WazeNearbyPrompt(
                report: springReport,
                distanceMeters: 45,
                onVote: (v) => recordedVote = v,
                onClose: () {},
              ),
            ),
          ),
        );

        expect(find.text('💧 Curge apă'), findsOneWidget);
        expect(find.text('⚠️ Secat momentan'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('waze-vote-seasonal-dry')));
        expect(recordedVote, TrailReportVoteType.seasonalDry);
      },
    );

    testWidgets(
      'SosFloatingButton uses calm onSurface when inactive and red only when active, and LiveGroupSheet creates/leaves group',
      (tester) async {
        final sessionNotifier = ValueNotifier<GroupSessionModel?>(null);
        var leftCalled = false;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Column(
                  children: [
                    SosFloatingButton(isActive: false, onPressed: () {}),
                    SosFloatingButton(
                      key: const ValueKey('active-sos'),
                      isActive: true,
                      onPressed: () {},
                    ),
                    ElevatedButton(
                      key: const ValueKey('open-group'),
                      onPressed: () {
                        showLiveGroupSheet(
                          ctx,
                          sessionListenable: sessionNotifier,
                          initialDisplayName: 'Grigore',
                          userAlongTrackM: 250.0,
                          onCreateGroup: (name) async {
                            final created = GroupSessionModel(
                              code: 'K7M4P9',
                              selfMemberId: 'mem_self_123',
                              members: <GroupMemberModel>[
                                GroupMemberModel(
                                  memberId: 'mem_self_123',
                                  displayName: name,
                                  colorHex: '#242734',
                                  lat: 45.44,
                                  lon: 25.55,
                                  accuracy: 8.0,
                                  alongTrackM: 250.0,
                                  isSelf: true,
                                ),
                                const GroupMemberModel(
                                  memberId: 'mem_peer_456',
                                  displayName: 'Diana Pop',
                                  colorHex: '#0f766e',
                                  lat: 45.441,
                                  lon: 25.55,
                                  accuracy: 6.0,
                                  alongTrackM: 345.0,
                                  isSelf: false,
                                ),
                              ],
                            );
                            sessionNotifier.value = created;
                            return created;
                          },
                          onJoinGroup: (_, _) async => null,
                          onLeaveGroup: () async {
                            leftCalled = true;
                            sessionNotifier.value = null;
                          },
                        );
                      },
                      child: const Text('Group'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final icons = tester
            .widgetList<Icon>(find.byIcon(Icons.sos_rounded))
            .toList();
        expect(icons, hasLength(2));
        expect(icons[0].color, isNot(equals(const Color(0xFFDC2626))));
        expect(icons[1].color, Colors.white);

        await tester.tap(find.byKey(const ValueKey('open-group')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('group-create-btn')));
        await tester.pumpAndSettle();

        expect(find.text('K7M4P9'), findsOneWidget);
        expect(find.text('DP'), findsOneWidget);
        expect(find.textContaining('+95 m în față'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('group-leave-btn')));
        await tester.pumpAndSettle();
        expect(leftCalled, isTrue);
        sessionNotifier.dispose();
      },
    );
  });

  group('Live Group Models, Service & SSE Events', () {
    test('creates, joins, pings, leaves group and parses group SSE events', () async {
      const fixedToken =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      final nowIso = DateTime.utc(2026, 11, 18, 12, 0).toIso8601String();
      final expIso = DateTime.utc(2026, 11, 19, 0, 0).toIso8601String();

      final sampleSessionJson = <String, Object?>{
        'code': 'K7M4P9',
        'trailId': 'trail_bucegi',
        'expiresAt': expIso,
        'selfMemberId': 'a1b2c3d4e5f6',
        'members': <Object?>[
          <String, Object?>{
            'memberId': 'a1b2c3d4e5f6',
            'displayName': 'Grigore',
            'colorHex': '#242734',
            'lat': 45.4400,
            'lon': 25.5500,
            'ele': 1320.0,
            'accuracy': 12.0,
            'alongTrackM': 180.0,
            'inNavigation': true,
            'isSelf': true,
            'updatedAt': nowIso,
          },
          <String, Object?>{
            'memberId': 'f6e5d4c3b2a1',
            'displayName': 'Diana',
            'colorHex': '#0f766e',
            'lat': 45.4403,
            'lon': 25.5501,
            'ele': 1325.0,
            'accuracy': 6.0,
            'heading': 14.5,
            'speed': 1.3,
            'alongTrackM': 215.0,
            'inNavigation': true,
            'isSelf': false,
            'updatedAt': nowIso,
          },
        ],
      };

      final adapter = _FakeLiveAdapter((options) async {
        if (options.path == '/live/groups' && options.method == 'POST') {
          return ResponseBody.fromString(
            jsonEncode(sampleSessionJson),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        }
        if (options.path == '/live/groups/K7M4P9' && options.method == 'GET') {
          return ResponseBody.fromString(
            jsonEncode(sampleSessionJson),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        }
        if (options.path == '/live/groups/K7M4P9/join' &&
            options.method == 'POST') {
          return ResponseBody.fromString(
            jsonEncode(sampleSessionJson),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        }
        if (options.path == '/live/groups/K7M4P9/ping' &&
            options.method == 'POST') {
          return ResponseBody.fromString(
            jsonEncode(<String, Object?>{
              'code': 'K7M4P9',
              'selfMemberId': 'a1b2c3d4e5f6',
              'members': sampleSessionJson['members'],
            }),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        }
        if (options.path == '/live/groups/K7M4P9/leave' &&
            options.method == 'POST') {
          return ResponseBody.fromString(
            jsonEncode(<String, Object?>{'ok': true}),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>[Headers.jsonContentType],
            },
          );
        }
        if (options.path == '/live/stream') {
          expect(options.queryParameters['groupCode'], 'K7M4P9');
          final ssePayload =
              'event: group_member_update\n'
              'data: ${jsonEncode(<String, Object?>{
                'memberId': 'f6e5d4c3b2a1',
                'displayName': 'Diana',
                'colorHex': '#0f766e',
                'lat': 45.4410,
                'lon': 25.5502,
                'ele': 1330.0,
                'accuracy': 5.5,
                'alongTrackM': 260.0,
                'inNavigation': true,
                'isSelf': false,
                'updatedAt': nowIso,
              })}\n\n'
              'event: group_member_left\n'
              'data: ${jsonEncode(<String, Object?>{
                'groupCode': 'K7M4P9',
                'memberId': 'f6e5d4c3b2a1',
              })}\n\n';
          return ResponseBody(
            Stream<Uint8List>.fromIterable(<Uint8List>[
              Uint8List.fromList(utf8.encode(ssePayload)),
            ]),
            200,
            headers: <String, List<String>>{
              Headers.contentTypeHeader: <String>['text/event-stream'],
            },
          );
        }
        return ResponseBody.fromString('{}', 200);
      });

      final dio = Dio(BaseOptions(baseUrl: 'https://maps.skillfy.ro/api/v1'))
        ..httpClientAdapter = adapter;
      final service = TrailLiveService(
        dio: dio,
        tokenLoader: () async => fixedToken,
      );

      final created = await service.createGroup(
        trailId: 'trail_bucegi',
        displayName: 'Grigore',
      );
      expect(created.code, 'K7M4P9');
      expect(created.selfMemberId, 'a1b2c3d4e5f6');
      expect(created.members, hasLength(2));
      expect(created.peers, hasLength(1));
      expect(created.peers.first.displayName, 'Diana');
      expect(created.peers.first.initials, 'DI');

      final fetched = await service.getGroup('k7m4p9');
      expect(fetched.code, 'K7M4P9');

      final joined = await service.joinGroup(
        code: 'k7m4p9',
        displayName: 'Grigore',
      );
      expect(joined.members, hasLength(2));

      final pinged = await service.pingGroup(
        code: 'K7M4P9',
        lat: 45.4405,
        lon: 25.5500,
        ele: 1322.0,
        accuracy: 7.5,
        alongTrackM: 195.0,
      );
      expect(pinged.peers, hasLength(1));

      final events = await service
          .connectStream(
            lat: 45.4405,
            lon: 25.5500,
            trailId: 'trail_bucegi',
            groupCode: 'k7m4p9',
          )
          .toList();
      expect(events, hasLength(2));
      expect(events[0].type, TrailLiveSseEvent.groupMemberUpdate);
      expect(events[0].groupMember?.memberId, 'f6e5d4c3b2a1');
      expect(events[0].groupMember?.accuracy, closeTo(5.5, 1e-6));
      expect(events[1].type, TrailLiveSseEvent.groupMemberLeft);
      expect(events[1].leftMemberId, 'f6e5d4c3b2a1');
      expect(events[1].groupCode, 'K7M4P9');

      await service.leaveGroup('K7M4P9');
    });
  });
}
