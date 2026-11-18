import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// Deletes both `<partPath>` and its companion `<partPath>.etag` sidecar.
void deleteArchivePartAndEtag(String partPath) {
  for (final candidate in <String>[partPath, '$partPath.etag']) {
    final f = File(candidate);
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}

bool _isTransientNetworkFailure(DioException e) {
  if (CancelToken.isCancel(e)) return false;
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
      return true;
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode ?? 0;
      return status == 408 || status == 429 || status >= 500;
    case DioExceptionType.badCertificate:
    case DioExceptionType.cancel:
      return false;
  }
}

bool _isTransientMidStreamIoFailure(Object e) =>
    e is SocketException || e is HttpException || e is TimeoutException;

int? _parseTotalFromContentRange(String? contentRange) {
  if (contentRange == null) return null;
  final slashIdx = contentRange.lastIndexOf('/');
  if (slashIdx < 0 || slashIdx + 1 >= contentRange.length) return null;
  final rawTotal = contentRange.substring(slashIdx + 1).trim();
  if (rawTotal == '*') return null;
  return int.tryParse(rawTotal);
}

/// Streams [requestPath] into [partPath] with HTTP `Range` + `If-Range` resume.
///
/// - On transient 2G/4G drops (including mid-stream socket resets), keeps
///   `<partPath>` + `<partPath>.etag` intact and retries up to [maxAutoRetries]
///   times from `partFile.lengthSync()`.
/// - If the server rebuilt the `.pmtiles` archive overnight (`If-Range` mismatch ->
///   `200 OK`), truncates `<partPath>` cleanly before writing byte 0 of the new build.
/// - On explicit user cancellation (`CancelToken.isCancel`), deletes both `<partPath>`
///   and `<partPath>.etag` immediately.
Future<void> downloadArchiveWithResume({
  required Dio dio,
  required String requestPath,
  required String partPath,
  required CancelToken cancelToken,
  void Function(int received, int total)? onProgress,
  int maxAutoRetries = 2,
  Duration retryDelay = const Duration(milliseconds: 1200),
}) async {
  final partFile = File(partPath);
  final etagFile = File('$partPath.etag');
  await partFile.parent.create(recursive: true);

  var attempt = 0;
  while (true) {
    if (cancelToken.isCancelled) {
      deleteArchivePartAndEtag(partPath);
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: requestPath),
        reason: cancelToken.cancelError,
      );
    }

    var resumeOffset = partFile.existsSync() ? partFile.lengthSync() : 0;
    final storedEtag = etagFile.existsSync()
        ? etagFile.readAsStringSync().trim()
        : '';

    final reqHeaders = <String, dynamic>{};
    if (resumeOffset > 0) {
      reqHeaders[HttpHeaders.rangeHeader] = 'bytes=$resumeOffset-';
      if (storedEtag.isNotEmpty) {
        reqHeaders[HttpHeaders.ifRangeHeader] = storedEtag;
      }
    }

    IOSink? sink;
    RequestOptions? activeRequestOptions;
    try {
      final response = await dio.get<ResponseBody>(
        requestPath,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: reqHeaders.isEmpty ? null : reqHeaders,
          validateStatus: (status) =>
              status == HttpStatus.ok ||
              status == HttpStatus.partialContent ||
              status == HttpStatus.requestedRangeNotSatisfiable,
        ),
      );
      activeRequestOptions = response.requestOptions;

      final statusCode = response.statusCode ?? 0;
      if (statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        deleteArchivePartAndEtag(partPath);
        if (attempt <= maxAutoRetries) {
          attempt++;
          continue;
        }
        throw DioException.badResponse(
          statusCode: statusCode,
          requestOptions: response.requestOptions,
          response: response,
        );
      }

      final respEtag =
          response.headers.value(HttpHeaders.etagHeader)?.trim() ?? '';
      if (respEtag.isNotEmpty) {
        await etagFile.writeAsString(respEtag, flush: true);
      }

      final isPartial =
          statusCode == HttpStatus.partialContent && resumeOffset > 0;
      if (!isPartial) {
        resumeOffset = 0;
      }

      final contentLengthHeader = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      final totalBytes = isPartial
          ? (_parseTotalFromContentRange(
                  response.headers.value(HttpHeaders.contentRangeHeader),
                ) ??
                (contentLengthHeader != null
                    ? resumeOffset + contentLengthHeader
                    : -1))
          : (contentLengthHeader ?? -1);

      sink = partFile.openWrite(
        mode: isPartial ? FileMode.append : FileMode.writeOnly,
      );

      var receivedBytes = resumeOffset;
      final bodyStream = response.data?.stream;
      if (bodyStream != null) {
        await for (final chunk in bodyStream) {
          if (cancelToken.isCancelled) {
            throw DioException.requestCancelled(
              requestOptions: response.requestOptions,
              reason: cancelToken.cancelError,
            );
          }
          sink.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(receivedBytes, totalBytes);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (etagFile.existsSync()) {
        try {
          etagFile.deleteSync();
        } catch (_) {}
      }
      return;
    } on DioException catch (e) {
      if (sink != null) {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
        sink = null;
      }

      if (CancelToken.isCancel(e) || cancelToken.isCancelled) {
        deleteArchivePartAndEtag(partPath);
        rethrow;
      }

      if (_isTransientNetworkFailure(e) && attempt < maxAutoRetries) {
        attempt++;
        await Future<void>.delayed(retryDelay * attempt);
        continue;
      }
      rethrow;
    } catch (e) {
      if (sink != null) {
        try {
          await sink.flush();
          await sink.close();
        } catch (_) {}
        sink = null;
      }

      if (cancelToken.isCancelled) {
        deleteArchivePartAndEtag(partPath);
        throw DioException.requestCancelled(
          requestOptions:
              activeRequestOptions ?? RequestOptions(path: requestPath),
          reason: cancelToken.cancelError,
        );
      }

      if (_isTransientMidStreamIoFailure(e)) {
        if (attempt < maxAutoRetries) {
          attempt++;
          await Future<void>.delayed(retryDelay * attempt);
          continue;
        }
        throw DioException(
          requestOptions:
              activeRequestOptions ?? RequestOptions(path: requestPath),
          type: DioExceptionType.connectionError,
          error: e,
          message: e.toString(),
        );
      }
      rethrow;
    }
  }
}
