import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/services/power/radio_sync_scheduler.dart';
import 'package:wanderer/services/trail_live_service.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this._handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) _handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('TrailLiveService shared wire protocol', () {
    test('sendHeartbeat sends stationary + stateHash and preserves unchanged delta response', () async {
      final adapter = _RecordingAdapter((options) {
        return ResponseBody.fromString(
          jsonEncode(<String, Object?>{
            'unchanged': true,
            'stateHash': 'h_abc123',
          }),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://wanderer.example/api/v1'))
        ..httpClientAdapter = adapter;
      final service = TrailLiveService(
        dio: dio,
        tokenLoader: () async => 'a' * 64,
      );

      final res = await service.sendHeartbeat(
        trailId: 'trail_bucegi',
        lat: 45.4081,
        lon: 25.4742,
        ele: 2025.0,
        inNavigation: true,
        stationary: true,
        stateHash: 'h_abc123',
      );

      expect(res, isNotNull);
      expect(res!.unchanged, isTrue);
      expect(res.stateHash, 'h_abc123');

      final sentBody = adapter.requests.single.data as Map<String, Object?>;
      expect(sentBody['stationary'], isTrue);
      expect(sentBody['stateHash'], 'h_abc123');
    });

    test('pingGroup sends ?ack=1 + stationary and flags hasMembersSnapshot=false on {ok:true}', () async {
      final adapter = _RecordingAdapter((options) {
        return ResponseBody.fromString(
          jsonEncode(<String, Object?>{'ok': true}),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://wanderer.example/api/v1'))
        ..httpClientAdapter = adapter;
      final service = TrailLiveService(
        dio: dio,
        tokenLoader: () async => 'b' * 64,
      );

      final session = await service.pingGroup(
        code: 'caban1',
        lat: 45.41,
        lon: 25.48,
        accuracy: 8.0,
        ackOnly: true,
        stationary: true,
      );

      expect(adapter.requests.single.queryParameters['ack'], '1');
      final body = adapter.requests.single.data as Map<String, Object?>;
      expect(body['stationary'], isTrue);
      expect(session.hasMembersSnapshot, isFalse);
      expect(session.code, 'CABAN1');
    });

    test('connectStream forwards Last-Event-ID header and parses id: sequence lines', () async {
      final adapter = _RecordingAdapter((options) {
        const ssePayload =
            'id: 42\n'
            'event: group_member_update\n'
            'data: {"member":{"memberId":"m2","displayName":"Ana","lat":45.42,"lon":25.49,"stationary":true}}\n\n';
        return ResponseBody(
          Stream<Uint8List>.fromIterable(<Uint8List>[
            Uint8List.fromList(utf8.encode(ssePayload)),
          ]),
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['text/event-stream'],
          },
        );
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://wanderer.example/api/v1'))
        ..httpClientAdapter = adapter;
      final service = TrailLiveService(
        dio: dio,
        tokenLoader: () async => 'c' * 64,
      );

      final events = await service
          .connectStream(
            lat: 45.41,
            lon: 25.48,
            groupCode: 'caban1',
            lastEventId: '41',
          )
          .toList();

      expect(adapter.requests.single.headers['Last-Event-ID'], '41');
      expect(events, hasLength(1));
      expect(events.single.eventId, '42');
      expect(events.single.groupMember?.isStationary, isTrue);
    });
  });

  group('RadioSyncScheduler RRC coalescing & dead-zone backoff', () {
    test('selects 15s fg group, 30s bg group, 60s fg solo, 180s bg solo, 300s stationary', () {
      expect(
        RadioSyncScheduler.computeBaseInterval(
          sosActive: false,
          isStationary: false,
          hasActiveGroup: true,
          uiForeground: true,
          expeditionMode: false,
        ),
        const Duration(seconds: 15),
      );
      expect(
        RadioSyncScheduler.computeBaseInterval(
          sosActive: false,
          isStationary: false,
          hasActiveGroup: true,
          uiForeground: false,
          expeditionMode: false,
        ),
        const Duration(seconds: 30),
      );
      expect(
        RadioSyncScheduler.computeBaseInterval(
          sosActive: false,
          isStationary: false,
          hasActiveGroup: false,
          uiForeground: true,
          expeditionMode: false,
        ),
        const Duration(seconds: 60),
      );
      expect(
        RadioSyncScheduler.computeBaseInterval(
          sosActive: false,
          isStationary: false,
          hasActiveGroup: false,
          uiForeground: false,
          expeditionMode: false,
        ),
        const Duration(seconds: 180),
      );
      expect(
        RadioSyncScheduler.computeBaseInterval(
          sosActive: false,
          isStationary: true,
          hasActiveGroup: true,
          uiForeground: true,
          expeditionMode: false,
        ),
        const Duration(seconds: 300),
      );
      expect(
        RadioSyncScheduler.computeBaseInterval(
          sosActive: true,
          isStationary: true,
          hasActiveGroup: false,
          uiForeground: false,
          expeditionMode: true,
        ),
        const Duration(seconds: 10),
      );
    });

    test('backs off exponentially in dead zone instead of hammering every 6s and flushes immediately on SOS', () async {
      final firedReasons = <String>[];
      final scheduler = RadioSyncScheduler(
        jitterFactor: 0.0,
        onCoalescedBurst: (ctx) async {
          firedReasons.add(ctx.reason);
          return false; // simulate offline failure
        },
      );
      addTearDown(scheduler.dispose);

      expect(scheduler.offlineProbeDelayForFailure(1), const Duration(seconds: 15));
      expect(scheduler.offlineProbeDelayForFailure(2), const Duration(seconds: 30));
      expect(scheduler.offlineProbeDelayForFailure(3), const Duration(seconds: 60));
      expect(scheduler.offlineProbeDelayForFailure(4), const Duration(seconds: 180));
      expect(scheduler.offlineProbeDelayForFailure(9), const Duration(seconds: 180));

      await scheduler.triggerImmediateBurst(reason: 'sos_emergency');
      expect(firedReasons, contains('sos_emergency'));
    });
  });
}
