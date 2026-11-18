import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/services/trail_live_service.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this._responder);

  final Future<ResponseBody> Function(RequestOptions options) _responder;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return _responder(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('TrailLiveService Phase 2 compact wire protocol', () {
    test('sendHeartbeat sends stateHash & stationary and reuses cached reports on unchanged: true', () async {
      var callCount = 0;
      final adapter = _RecordingAdapter((options) async {
        callCount++;
        if (callCount == 1) {
          return ResponseBody.fromString(
            jsonEncode({
              'trailId': 'fagaras-1',
              'activeHikers30m': 4,
              'stateHash': 'srv-hash-10',
              'reports': [
                {
                  'id': 'rep-shelter-1',
                  'trailId': 'fagaras-1',
                  'category': 'shelter',
                  'isPermanent': true,
                  'conditionStatus': 'active',
                  'lat': 45.6,
                  'lon': 24.7,
                },
              ],
              'sosAlerts': [],
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        }
        return ResponseBody.fromString(
          jsonEncode({
            'activeHikers30m': 9,
            'unchanged': true,
            'stateHash': 'srv-hash-10',
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final dio = Dio(BaseOptions(baseUrl: 'https://trasee.skillfy.ro/api/v1'))
        ..httpClientAdapter = adapter;
      final svc = TrailLiveService(
        dio: dio,
        tokenLoader: () async => 'a' * 64,
      );

      final s1 = await svc.sendHeartbeat(
        trailId: 'fagaras-1',
        lat: 45.59912345,
        lon: 24.70098765,
        inNavigation: true,
      );
      expect(s1?.activeHikers30m, 4);
      expect(s1?.stateHash, 'srv-hash-10');
      expect(s1?.unchanged, isFalse);
      expect(s1?.reports, hasLength(1));

      final s2 = await svc.sendHeartbeat(
        trailId: 'fagaras-1',
        lat: 45.5992,
        lon: 24.701,
        inNavigation: true,
        stationary: true,
      );
      final secondBody = adapter.requests[1].data as Map<String, Object?>;
      expect(secondBody['stateHash'], 'srv-hash-10');
      expect(secondBody['stationary'], isTrue);
      expect(s2?.activeHikers30m, 9);
      expect(s2?.unchanged, isTrue);
      expect(s2?.reports, hasLength(1));
      expect(s2?.reports.first.id, 'rep-shelter-1');
    });

    test('pingGroup with ackOnly=true sends ?ack=1 and preserves cached group session with hasMembersSnapshot=false', () async {
      var callCount = 0;
      final adapter = _RecordingAdapter((options) async {
        callCount++;
        if (callCount == 1) {
          return ResponseBody.fromString(
            jsonEncode({
              'code': 'FG23RS',
              'trailId': 'fagaras-1',
              'selfMemberId': 'self-1',
              'expiresAt': '2099-01-01T00:00:00Z',
              'members': [
                {
                  'memberId': 'self-1',
                  'displayName': 'Radu',
                  'lat': 45.6,
                  'lon': 24.7,
                  'accuracy': 8.0,
                },
                {
                  'memberId': 'peer-2',
                  'displayName': 'Elena',
                  'lat': 45.601,
                  'lon': 24.702,
                  'accuracy': 10.0,
                  'stationary': true,
                },
              ],
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          );
        }
        return ResponseBody.fromString(
          jsonEncode({
            'ok': true,
            'code': 'FG23RS',
            'selfMemberId': 'self-1-srv',
            'expiresAt': '2099-02-01T00:00:00Z',
            'memberCount': 2,
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final dio = Dio(BaseOptions(baseUrl: 'https://trasee.skillfy.ro/api/v1'))
        ..httpClientAdapter = adapter;
      final svc = TrailLiveService(
        dio: dio,
        tokenLoader: () async => 'b' * 64,
      );

      final initial = await svc.getGroup('FG23RS');
      expect(initial.hasMembersSnapshot, isTrue);
      expect(initial.members, hasLength(2));
      expect(initial.peers.single.isStationary, isTrue);

      final acked = await svc.pingGroup(
        code: 'FG23RS',
        lat: 45.6005,
        lon: 24.7005,
        accuracy: 6.0,
        stationary: true,
        ackOnly: true,
      );
      expect(adapter.requests[1].queryParameters['ack'], '1');
      expect(acked.hasMembersSnapshot, isFalse);
      expect(acked.selfMemberId, 'self-1-srv');
      expect(acked.expiresAt, DateTime.utc(2099, 2, 1));
      expect(acked.peers, hasLength(1));
      expect(acked.peers.first.displayName, 'Elena');
      expect(acked.peers.first.isStationary, isTrue);
    });

    test('connectStream parses SSE id: line into eventId, handles resync_required, and forwards Last-Event-ID header', () async {
      final adapter = _RecordingAdapter((options) async {
        final stream = Stream<Uint8List>.fromIterable([
          Uint8List.fromList(
            utf8.encode(
              ': connected\n\nid: 771\nevent: report_update\ndata: {"id":"rep-bear","category":"bear","lat":45.5,"lon":25.5}\n\nid: 772\nevent: resync_required\ndata: {"reason":"ring_gap"}\n\n',
            ),
          ),
        ]);
        return ResponseBody(
          stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        );
      });

      final dio = Dio(BaseOptions(baseUrl: 'https://trasee.skillfy.ro/api/v1'))
        ..httpClientAdapter = adapter;
      final svc = TrailLiveService(
        dio: dio,
        tokenLoader: () async => 'c' * 64,
      );

      final events = await svc
          .connectStream(
            lat: 45.5,
            lon: 25.5,
            trailId: 'bucegi-1',
            lastEventId: '770',
          )
          .toList();

      expect(adapter.requests.single.headers['Last-Event-ID'], '770');
      expect(adapter.requests.single.queryParameters['lastEventId'], '770');
      expect(events, hasLength(2));
      expect(events.first.eventId, '771');
      expect(events.first.report?.id, 'rep-bear');
      expect(events.last.type, TrailLiveSseEvent.resyncRequired);
      expect(events.last.eventId, '772');
      expect(
        TrailLiveService.computeJitteredBackoffMs(2000, randomUnit: 0.0),
        1400,
      );
      expect(
        TrailLiveService.computeJitteredBackoffMs(2000, randomUnit: 1.0),
        2600,
      );
    });
  });
}
