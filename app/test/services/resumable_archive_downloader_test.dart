import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/services/resumable_archive_downloader.dart';

void main() {
  group('downloadArchiveWithResume', () {
    late HttpServer server;
    late Directory tempDir;
    late Dio dio;

    String archivePayload = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-pmtiles-archive';
    String archiveEtag = '"34-v1"';
    bool dropMidwayOnce = false;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('wanderer_resume_test_');
      archivePayload = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-pmtiles-archive';
      archiveEtag = '"34-v1"';
      dropMidwayOnce = false;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
        final ifRangeHeader = req.headers.value(HttpHeaders.ifRangeHeader);

        if (dropMidwayOnce) {
          dropMidwayOnce = false;
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(HttpHeaders.etagHeader, archiveEtag);
          req.response.contentLength = archivePayload.length;
          final socket = await req.response.detachSocket(writeHeaders: true);
          socket.add(archivePayload.substring(0, 16).codeUnits);
          await socket.flush();
          socket.destroy();
          return;
        }

        if (rangeHeader != null &&
            rangeHeader.startsWith('bytes=') &&
            (ifRangeHeader == null || ifRangeHeader == archiveEtag)) {
          final offset = int.parse(
            rangeHeader.substring(6).replaceAll('-', ''),
          );
          if (offset >= archivePayload.length) {
            req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await req.response.close();
            return;
          }
          final tail = archivePayload.substring(offset).codeUnits;
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers.set(HttpHeaders.etagHeader, archiveEtag);
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $offset-${archivePayload.length - 1}/${archivePayload.length}',
          );
          req.response.contentLength = tail.length;
          req.response.add(tail);
          await req.response.close();
          return;
        }

        final full = archivePayload.codeUnits;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.set(HttpHeaders.etagHeader, archiveEtag);
        req.response.contentLength = full.length;
        req.response.add(full);
        await req.response.close();
      });

      dio = Dio(
        BaseOptions(
          baseUrl: 'http://127.0.0.1:${server.port}',
          connectTimeout: const Duration(seconds: 3),
        ),
      );
    });

    tearDown(() async {
      dio.close(force: true);
      await server.close(force: true);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('automatically resumes from .part offset via 206 Partial Content after mid-stream socket drop', () async {
      dropMidwayOnce = true;
      final partPath = '${tempDir.path}/romania.pmtiles.part';
      final progressUpdates = <(int, int)>[];

      await downloadArchiveWithResume(
        dio: dio,
        requestPath: '/regions/romania/download',
        partPath: partPath,
        cancelToken: CancelToken(),
        maxAutoRetries: 2,
        retryDelay: const Duration(milliseconds: 20),
        onProgress: (rec, tot) => progressUpdates.add((rec, tot)),
      );

      expect(File(partPath).readAsStringSync(), archivePayload);
      expect(File('$partPath.etag').existsSync(), isFalse);
      expect(progressUpdates.last.$1, archivePayload.length);
      expect(progressUpdates.last.$2, archivePayload.length);
    });

    test('truncates stale .part cleanly when archive ETag changed overnight (If-Range -> 200 OK)', () async {
      final partPath = '${tempDir.path}/romania.pmtiles.part';
      await File(partPath).writeAsString('OLD-BUILD-PREFIX-BYTES');
      await File('$partPath.etag').writeAsString('"old-etag-v0"');

      archivePayload = 'BRAND-NEW-OVERNIGHT-PMTILES-BUILD-V2';
      archiveEtag = '"new-etag-v2"';

      await downloadArchiveWithResume(
        dio: dio,
        requestPath: '/regions/romania/download',
        partPath: partPath,
        cancelToken: CancelToken(),
      );

      expect(File(partPath).readAsStringSync(), archivePayload);
      expect(File('$partPath.etag').existsSync(), isFalse);
    });

    test('deletes both .part and .etag on explicit user CancelToken cancellation', () async {
      final partPath = '${tempDir.path}/cancel.pmtiles.part';
      await File(partPath).writeAsString('partial-bytes');
      await File('$partPath.etag').writeAsString('"v1"');

      final cancel = CancelToken()..cancel('user_cancelled');
      await expectLater(
        () => downloadArchiveWithResume(
          dio: dio,
          requestPath: '/regions/romania/download',
          partPath: partPath,
          cancelToken: cancel,
        ),
        throwsA(isA<DioException>()),
      );

      expect(File(partPath).existsSync(), isFalse);
      expect(File('$partPath.etag').existsSync(), isFalse);
    });
  });
}
