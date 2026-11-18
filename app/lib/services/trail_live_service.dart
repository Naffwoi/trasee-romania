import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:path_provider/path_provider.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/provider/api_provider.dart';
import 'package:wanderer/util/image_cache.dart';

/// Generates a cryptographically random 64-char lowercase hex device token.
String generateLiveDeviceToken() {
  final rng = math.Random.secure();
  final sb = StringBuffer();
  for (var i = 0; i < 32; i++) {
    sb.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

final RegExp _validDeviceTokenPattern = RegExp(r'^[0-9a-fA-F]{32,128}$');

/// Persists and returns the installation's anonymous 64-char hex device token
/// in `<ApplicationSupportDirectory>/wanderer_live_device_token.txt`.
class LiveDeviceTokenStore {
  static String? _cachedToken;
  static Future<String>? _inFlightLoad;
  static const String _fileName = 'wanderer_live_device_token.txt';

  static Future<String> getOrCreateToken() {
    final existing = _cachedToken;
    if (existing != null) return Future<String>.value(existing);
    return _inFlightLoad ??= _loadOrMint().whenComplete(() {
      _inFlightLoad = null;
    });
  }

  static Future<String> _loadOrMint() async {
    try {
      if (!kIsWeb) {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
        if (await file.exists()) {
          final stored = (await file.readAsString()).trim();
          if (_validDeviceTokenPattern.hasMatch(stored)) {
            _cachedToken = stored;
            return stored;
          }
        }
        final minted = generateLiveDeviceToken();
        await file.writeAsString(minted, flush: true);
        _cachedToken = minted;
        return minted;
      }
    } catch (_) {
      // Fallback to in-memory token when path_provider is unavailable (e.g. unit tests).
    }
    final fallback = generateLiveDeviceToken();
    _cachedToken = fallback;
    return fallback;
  }
}

/// High-importance OS notification helper for nearby SOS alerts, reusing the
/// same `FlutterLocalNotificationsPlugin` initialization pattern as
/// `DownloadNotificationService` on a dedicated emergency channel.
class SosLocalNotificationHelper {
  static const String _channelId = 'sos_emergency_alerts';
  static const String _channelName = 'SOS Trail Rescue Alerts';
  static const String _channelDescription =
      'High-priority alerts when a hiker within 5 km requests SOS help';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  Future<void> showNearbySosNotification({
    required SosAlertModel sos,
    double? distanceMeters,
    bool isRo = true,
  }) async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
    try {
      await _ensureInitialized();
      if (!_initialized) return;

      final title = sos.viaBluetooth
          ? (isRo
                ? '🆘 Alertă SOS în apropiere · prin Bluetooth'
                : '🆘 Nearby SOS Alert · via Bluetooth')
          : (isRo
                ? '🆘 Ajutor solicitat în apropiere!'
                : '🆘 Nearby hiker needs help!');
      final reasonText = sos.reason.label(isRo: isRo);
      final distPart = (distanceMeters != null && distanceMeters.isFinite)
          ? (distanceMeters >= 1000
                ? ' · ~${(distanceMeters / 1000.0).toStringAsFixed(1)} km'
                : ' · ~${distanceMeters.round()} m')
          : '';
      final msgPart = sos.message.trim().isNotEmpty
          ? ' — ${sos.message.trim()}'
          : '';
      final body = '$reasonText$distPart$msgPart';

      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.max,
        priority: Priority.high,
        ongoing: false,
        autoCancel: true,
        playSound: true,
        enableVibration: true,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: false,
        presentSound: true,
      );

      final notificationId = 0x5050000 + (sos.id.hashCode.abs() & 0xFFFF);
      await _plugin.show(
        notificationId,
        title,
        body,
        const NotificationDetails(android: androidDetails, iOS: iosDetails),
      );
    } catch (e) {
      debugPrint('SosLocalNotificationHelper: notification failed — $e');
    }
  }
}

/// Client service for `/api/v1/live/*` (Waze trail reports, permanent landmarks,
/// 30-minute privacy-preserving presence, and 5 km community SOS rescue).
class TrailLiveService {
  TrailLiveService({
    required Dio dio,
    Future<String> Function()? tokenLoader,
    SosLocalNotificationHelper? notificationHelper,
    this.onSosNotificationCallback,
  }) : _dio = dio,
       _tokenLoader = tokenLoader ?? LiveDeviceTokenStore.getOrCreateToken,
       _notificationHelper =
           notificationHelper ?? SosLocalNotificationHelper();

  final Dio _dio;
  final Future<String> Function() _tokenLoader;
  final SosLocalNotificationHelper _notificationHelper;

  /// Optional test hook invoked whenever a new nearby `!isMine` SOS triggers a
  /// high-importance notification.
  final Future<void> Function(SosAlertModel sos, double? distanceMeters)?
  onSosNotificationCallback;

  final Set<String> _notifiedSosIds = <String>{};
  TrailLiveSummary? _lastHeartbeatSummary;
  double? _lastHeartbeatLat;
  double? _lastHeartbeatLon;
  final Map<String, GroupSessionModel> _cachedGroupSessions =
      <String, GroupSessionModel>{};

  static double _quantize6(double v) =>
      (v * 1000000.0).roundToDouble() / 1000000.0;
  static double _quantize1(double v) => (v * 10.0).roundToDouble() / 10.0;

  /// Applies +-30% jitter (`[0.7 * baseMs, 1.3 * baseMs]`) to avoid reconnect storms.
  static int computeJitteredBackoffMs(int baseMs, {double? randomUnit}) {
    final u = (randomUnit ?? math.Random().nextDouble()).clamp(0.0, 1.0);
    return math.max(500, (baseMs * (0.7 + 0.6 * u)).round());
  }

  bool get isConfigured {
    final host = Uri.tryParse(_dio.options.baseUrl)?.host ?? '';
    return host.isNotEmpty && !host.contains(kUnconfiguredApiHost);
  }

  /// Returns the installation's persistent anonymous device token.
  Future<String> getDeviceToken() => _tokenLoader();

  Future<Options> _liveOptions({
    Map<String, dynamic>? extraHeaders,
    ResponseType? responseType,
    Duration? receiveTimeout,
  }) async {
    final token = await _tokenLoader();
    return Options(
      headers: <String, dynamic>{
        'X-Device-Token': token,
        if (extraHeaders != null) ...extraHeaders,
      },
      responseType: responseType,
      receiveTimeout: receiveTimeout,
    );
  }

  Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    return const <String, dynamic>{};
  }

  Future<void> notifyBleNearbySos(
    SosAlertModel sos, {
    double? userLat,
    double? userLon,
    bool isRo = true,
  }) {
    return _maybeNotifyNearbySos(
      sos,
      userLat: userLat,
      userLon: userLon,
      isRo: isRo,
    );
  }

  Future<void> _maybeNotifyNearbySos(
    SosAlertModel? sos, {
    double? userLat,
    double? userLon,
    bool isRo = true,
  }) async {
    if (sos == null || sos.id.isEmpty || sos.isMine) return;
    if (!sos.isActiveAt(DateTime.now())) return;
    if (_notifiedSosIds.contains(sos.dedupeKey) ||
        _notifiedSosIds.contains('id:${sos.id}')) {
      return;
    }
    _notifiedSosIds.add(sos.dedupeKey);
    _notifiedSosIds.add('id:${sos.id}');

    double? distM;
    if (userLat != null &&
        userLon != null &&
        userLat.isFinite &&
        userLon.isFinite &&
        sos.lat.isFinite &&
        sos.lon.isFinite) {
      distM = ml.SphericalGreatCircle(
        ml.Geographic(lat: userLat, lon: userLon),
      ).distanceTo(ml.Geographic(lat: sos.lat, lon: sos.lon));
    }

    if (onSosNotificationCallback != null) {
      await onSosNotificationCallback!(sos, distM);
    }
    await _notificationHelper.showNearbySosNotification(
      sos: sos,
      distanceMeters: distM,
      isRo: isRo,
    );
  }

  Future<TrailLiveSummary?> sendHeartbeat({
    String? trailId,
    required double lat,
    required double lon,
    double? ele,
    bool inNavigation = false,
    bool stationary = false,
    String? stateHash,
    bool isRo = true,
  }) async {
    if (!isConfigured) return null;
    final options = await _liveOptions();
    final qLat = _quantize6(lat);
    final qLon = _quantize6(lon);
    final cleanTrailId = trailId?.trim() ?? '';

    String? effectiveStateHash = stateHash?.trim();
    if ((effectiveStateHash == null || effectiveStateHash.isEmpty) &&
        _lastHeartbeatSummary != null &&
        (_lastHeartbeatSummary!.trailId ?? '') == cleanTrailId &&
        _lastHeartbeatSummary!.stateHash != null &&
        _lastHeartbeatLat != null &&
        _lastHeartbeatLon != null) {
      final distM = ml.SphericalGreatCircle(
        ml.Geographic(lat: qLat, lon: qLon),
      ).distanceTo(
        ml.Geographic(lat: _lastHeartbeatLat!, lon: _lastHeartbeatLon!),
      );
      if (distM <= 250.0) {
        effectiveStateHash = _lastHeartbeatSummary!.stateHash;
      }
    }

    final response = await _dio.post<Object?>(
      '/live/heartbeat',
      data: <String, Object?>{
        if (cleanTrailId.isNotEmpty) 'trailId': cleanTrailId,
        'lat': qLat,
        'lon': qLon,
        if (ele != null && ele.isFinite) 'ele': _quantize1(ele),
        'inNavigation': inNavigation,
        if (stationary) 'stationary': true,
        if (effectiveStateHash != null && effectiveStateHash.isNotEmpty)
          'stateHash': effectiveStateHash,
      },
      options: options,
    );
    final bodyMap = _asMap(response.data);
    final TrailLiveSummary summary;
    if (bodyMap['unchanged'] == true) {
      if (_lastHeartbeatSummary != null) {
        final nextHikers = (bodyMap['activeHikers30m'] is num)
            ? math.max(0, (bodyMap['activeHikers30m'] as num).round())
            : _lastHeartbeatSummary!.activeHikers30m;
        final nextHash = (bodyMap['stateHash'] as Object?)?.toString().trim();
        summary = _lastHeartbeatSummary!.copyWith(
          activeHikers30m: nextHikers,
          stateHash: (nextHash != null && nextHash.isNotEmpty)
              ? nextHash
              : _lastHeartbeatSummary!.stateHash,
          unchanged: true,
        );
      } else {
        summary = TrailLiveSummary.fromJson(bodyMap).copyWith(
          trailId: cleanTrailId.isNotEmpty ? cleanTrailId : null,
          unchanged: true,
        );
      }
    } else {
      summary = TrailLiveSummary.fromJson(bodyMap).copyWith(
        trailId: cleanTrailId.isNotEmpty ? cleanTrailId : null,
        unchanged: false,
      );
    }
    _lastHeartbeatSummary = summary;
    _lastHeartbeatLat = qLat;
    _lastHeartbeatLon = qLon;

    for (final sos in summary.nearbyActiveSos()) {
      await _maybeNotifyNearbySos(
        sos,
        userLat: lat,
        userLon: lon,
        isRo: isRo,
      );
    }
    return summary;
  }

  Future<void> clearHeartbeat() async {
    if (!isConfigured) return;
    try {
      final options = await _liveOptions();
      await _dio.delete<Object?>(
        '/live/heartbeat',
        options: options,
      );
    } catch (_) {
      // Best-effort presence cleanup on background/exit.
    }
  }

  Future<TrailLiveSummary?> fetchTrailSummary(
    String trailId, {
    double? lat,
    double? lon,
  }) async {
    final trimmed = trailId.trim();
    if (trimmed.isEmpty || !isConfigured) return null;
    final options = await _liveOptions();
    final queryParams = <String, dynamic>{
      if (lat != null && lat.isFinite && lon != null && lon.isFinite) ...{
        'lat': lat,
        'lon': lon,
      },
    };
    final response = await _dio.get<Object?>(
      '/live/trail/${Uri.encodeComponent(trimmed)}/summary',
      queryParameters: queryParams.isEmpty ? null : queryParams,
      options: options,
    );
    return TrailLiveSummary.fromJson(_asMap(response.data));
  }

  Future<TrailReportModel> createReport({
    String? trailId,
    required TrailReportCategory category,
    String? note,
    required double lat,
    required double lon,
    double? ele,
    double? alongTrackM,
    Uint8List? photoJpegBytes,
    bool photoVerified = false,
  }) async {
    final options = await _liveOptions();
    final trimmedNote = note?.trim() ?? '';
    final safeNote = trimmedNote.length > 160
        ? trimmedNote.substring(0, 160)
        : trimmedNote;
    final safeEle = (ele != null && ele.isFinite) ? ele : 0.0;

    final Object requestData;
    if (photoJpegBytes != null && photoJpegBytes.isNotEmpty) {
      requestData = FormData.fromMap(<String, dynamic>{
        if (trailId != null && trailId.isNotEmpty) 'trailId': trailId,
        'category': category.apiValue,
        if (safeNote.isNotEmpty) 'note': safeNote,
        'lat': lat.toString(),
        'lon': lon.toString(),
        'ele': safeEle.toString(),
        if (alongTrackM != null && alongTrackM.isFinite)
          'alongTrackM': alongTrackM.toString(),
        'photoVerified': photoVerified ? 'true' : 'false',
        'photo': MultipartFile.fromBytes(
          photoJpegBytes,
          filename: 'report.jpg',
          contentType: DioMediaType('image', 'jpeg'),
        ),
      });
    } else {
      requestData = <String, Object?>{
        if (trailId != null && trailId.isNotEmpty) 'trailId': trailId,
        'category': category.apiValue,
        if (safeNote.isNotEmpty) 'note': safeNote,
        'lat': lat,
        'lon': lon,
        'ele': safeEle,
        if (alongTrackM != null && alongTrackM.isFinite)
          'alongTrackM': alongTrackM,
      };
    }

    final response = await _dio.post<Object?>(
      '/live/reports',
      data: requestData,
      options: options,
    );
    final body = _asMap(response.data);
    final rawReport = body['report'];
    if (rawReport is Map) {
      return TrailReportModel.fromJson(Map<String, dynamic>.from(rawReport));
    }
    return TrailReportModel.fromJson(body);
  }

  Future<TrailReportModel> voteReport({
    required String reportId,
    required TrailReportVoteType vote,
  }) async {
    final options = await _liveOptions();
    final response = await _dio.post<Object?>(
      '/live/reports/${Uri.encodeComponent(reportId)}/vote',
      data: <String, Object?>{'vote': vote.apiValue},
      options: options,
    );
    final body = _asMap(response.data);
    final rawReport = body['report'];
    if (rawReport is Map) {
      return TrailReportModel.fromJson(Map<String, dynamic>.from(rawReport));
    }
    return TrailReportModel.fromJson(body);
  }

  Future<SosAlertModel> triggerSos({
    String? trailId,
    required SosReason reason,
    String? message,
    String? requesterName,
    required double lat,
    required double lon,
    double? ele,
    String? clientSosId,
    String? sosClaimSecret,
  }) async {
    final options = await _liveOptions();
    final cleanMsg = (message ?? '').trim();
    final safeMsg = cleanMsg.length > 200
        ? cleanMsg.substring(0, 200)
        : cleanMsg;
    final cleanName = (requesterName ?? '').trim();
    final safeName = cleanName.length > 40
        ? cleanName.substring(0, 40)
        : cleanName;
    final cleanClientId = clientSosId?.trim().toLowerCase();
    final cleanSecret = sosClaimSecret?.trim().toLowerCase();

    final response = await _dio.post<Object?>(
      '/live/sos',
      data: <String, Object?>{
        if (trailId != null && trailId.isNotEmpty) 'trailId': trailId,
        'reason': reason.apiValue,
        if (safeMsg.isNotEmpty) 'message': safeMsg,
        if (safeName.isNotEmpty) 'requesterName': safeName,
        'lat': lat,
        'lon': lon,
        'ele': (ele != null && ele.isFinite) ? ele : 0.0,
        if (cleanClientId != null && cleanClientId.isNotEmpty)
          'clientSosId': cleanClientId,
        if (cleanSecret != null && cleanSecret.isNotEmpty)
          'sosClaimSecret': cleanSecret,
      },
      options: options,
    );
    final body = _asMap(response.data);
    final rawSos = body['sos'];
    final parsed = rawSos is Map
        ? SosAlertModel.fromJson(Map<String, dynamic>.from(rawSos))
        : SosAlertModel.fromJson(body);
    return parsed.copyWith(
      isMine: true,
      clientSosId: parsed.clientSosId ?? cleanClientId,
      localClaimSecret: cleanSecret,
    );
  }

  Future<SosAlertModel> updateSos({
    required String sosId,
    String? status,
    double? lat,
    double? lon,
    double? ele,
    String? sosClaimSecret,
  }) async {
    final options = await _liveOptions();
    final cleanSecret = sosClaimSecret?.trim().toLowerCase();
    final response = await _dio.patch<Object?>(
      '/live/sos/${Uri.encodeComponent(sosId)}',
      data: <String, Object?>{
        if (status != null && status.isNotEmpty) 'status': status,
        if (lat != null && lat.isFinite) 'lat': lat,
        if (lon != null && lon.isFinite) 'lon': lon,
        if (ele != null && ele.isFinite) 'ele': ele,
        if (cleanSecret != null && cleanSecret.isNotEmpty)
          'sosClaimSecret': cleanSecret,
      },
      options: options,
    );
    final body = _asMap(response.data);
    final rawSos = body['sos'];
    return rawSos is Map
        ? SosAlertModel.fromJson(Map<String, dynamic>.from(rawSos))
        : SosAlertModel.fromJson(body);
  }

  Future<SosAlertModel> updateSosStatus({
    required String sosId,
    required String status,
    String? sosClaimSecret,
  }) {
    return updateSos(
      sosId: sosId,
      status: status,
      sosClaimSecret: sosClaimSecret,
    );
  }

  /// Uploads a Store-and-Forward BLE SOS packet (`active` or preimage-verified
  /// `resolved`) to `POST /api/v1/live/sos/relay`.
  Future<SosAlertModel?> relaySos(Map<String, dynamic> relayPayload) async {
    if (!isConfigured) return null;
    final options = await _liveOptions();
    final response = await _dio.post<Object?>(
      '/live/sos/relay',
      data: relayPayload,
      options: options,
    );
    final body = _asMap(response.data);
    final rawSos = body['sos'];
    if (rawSos is Map) {
      return SosAlertModel.fromJson(Map<String, dynamic>.from(rawSos));
    }
    if (body['id'] != null) {
      return SosAlertModel.fromJson(body);
    }
    return null;
  }

  Future<SosAlertModel> respondToSos({
    required String sosId,
    required String status,
    required double lat,
    required double lon,
    double? ele,
    double? distanceM,
    int? etaSec,
  }) async {
    final options = await _liveOptions();
    final response = await _dio.post<Object?>(
      '/live/sos/${Uri.encodeComponent(sosId)}/respond',
      data: <String, Object?>{
        'status': status,
        'lat': lat,
        'lon': lon,
        'ele': (ele != null && ele.isFinite) ? ele : 0.0,
        if (distanceM != null && distanceM.isFinite) 'distanceM': distanceM,
        if (etaSec != null && etaSec >= 0) 'etaSec': etaSec,
      },
      options: options,
    );
    final body = _asMap(response.data);
    final rawSos = body['sos'];
    final parsed = rawSos is Map
        ? SosAlertModel.fromJson(Map<String, dynamic>.from(rawSos))
        : SosAlertModel.fromJson(body);
    return parsed.copyWith(amResponding: status == 'coming');
  }

  String _normalizeGroupCode(String raw) => raw.trim().toUpperCase();

  String _sanitizeDisplayName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'Drumeț';
    return trimmed.length > 24 ? trimmed.substring(0, 24) : trimmed;
  }

  Future<GroupSessionModel> createGroup({
    String? trailId,
    required String displayName,
    String? preferredCode,
  }) async {
    final options = await _liveOptions();
    final cleanPrefCode = preferredCode?.trim();
    final response = await _dio.post<Object?>(
      '/live/groups',
      data: <String, Object?>{
        if (trailId != null && trailId.isNotEmpty) 'trailId': trailId,
        'displayName': _sanitizeDisplayName(displayName),
        if (cleanPrefCode != null && cleanPrefCode.isNotEmpty)
          'preferredCode': _normalizeGroupCode(cleanPrefCode),
      },
      options: options,
    );
    final parsed = GroupSessionModel.fromJson(_asMap(response.data));
    if (parsed.code.isNotEmpty) {
      _cachedGroupSessions[parsed.code] = parsed;
    }
    return parsed;
  }

  Future<GroupSessionModel> getGroup(String code) async {
    final normalized = _normalizeGroupCode(code);
    final options = await _liveOptions();
    final response = await _dio.get<Object?>(
      '/live/groups/${Uri.encodeComponent(normalized)}',
      options: options,
    );
    final parsed = GroupSessionModel.fromJson(_asMap(response.data));
    _cachedGroupSessions[normalized] = parsed;
    return parsed;
  }

  Future<GroupSessionModel> joinGroup({
    required String code,
    required String displayName,
  }) async {
    final normalized = _normalizeGroupCode(code);
    final options = await _liveOptions();
    final response = await _dio.post<Object?>(
      '/live/groups/${Uri.encodeComponent(normalized)}/join',
      data: <String, Object?>{
        'displayName': _sanitizeDisplayName(displayName),
      },
      options: options,
    );
    final parsed = GroupSessionModel.fromJson(_asMap(response.data));
    _cachedGroupSessions[normalized] = parsed;
    return parsed;
  }

  Future<GroupSessionModel> pingGroup({
    required String code,
    required double lat,
    required double lon,
    double? ele,
    required double accuracy,
    double? heading,
    double? speed,
    double? alongTrackM,
    bool inNavigation = true,
    bool stationary = false,
    bool ackOnly = false,
  }) async {
    final normalized = _normalizeGroupCode(code);
    final options = await _liveOptions();
    final response = await _dio.post<Object?>(
      '/live/groups/${Uri.encodeComponent(normalized)}/ping',
      queryParameters: ackOnly ? const <String, Object?>{'ack': '1'} : null,
      data: <String, Object?>{
        'lat': _quantize6(lat),
        'lon': _quantize6(lon),
        'ele': (ele != null && ele.isFinite) ? _quantize1(ele) : 0.0,
        'accuracy': (accuracy.isFinite && accuracy > 0.0)
            ? _quantize1(accuracy)
            : 15.0,
        if (heading != null && heading.isFinite && heading >= 0.0)
          'heading': _quantize1(heading),
        if (speed != null && speed.isFinite && speed >= 0.0)
          'speed': _quantize1(speed),
        if (alongTrackM != null && alongTrackM.isFinite)
          'alongTrackM': _quantize1(alongTrackM),
        'inNavigation': inNavigation,
        if (stationary) 'stationary': true,
      },
      options: options,
    );
    final bodyMap = _asMap(response.data);
    if (bodyMap['ok'] == true && bodyMap['members'] is! List) {
      final existing = _cachedGroupSessions[normalized];
      final respSelfId = (bodyMap['selfMemberId'] ?? bodyMap['self_member_id'])
          ?.toString()
          .trim();
      final rawExpires = (bodyMap['expiresAt'] ?? bodyMap['expires_at'])
          ?.toString()
          .trim();
      final respExpires = (rawExpires != null && rawExpires.isNotEmpty)
          ? DateTime.tryParse(rawExpires)?.toUtc()
          : null;
      if (existing != null) {
        return existing.copyWith(
          selfMemberId: (respSelfId != null && respSelfId.isNotEmpty)
              ? respSelfId
              : existing.selfMemberId,
          expiresAt: respExpires ?? existing.expiresAt,
          hasMembersSnapshot: false,
        );
      }
      return GroupSessionModel(
        code: normalized,
        selfMemberId: respSelfId ?? '',
        expiresAt: respExpires,
        hasMembersSnapshot: false,
      );
    }
    final parsed = GroupSessionModel.fromJson(bodyMap);
    _cachedGroupSessions[normalized] = parsed;
    return parsed;
  }

  Future<void> leaveGroup(String code) async {
    final normalized = _normalizeGroupCode(code);
    final options = await _liveOptions();
    await _dio.post<Object?>(
      '/live/groups/${Uri.encodeComponent(normalized)}/leave',
      data: const <String, Object?>{},
      options: options,
    );
  }

  /// Connects to `/api/v1/live/stream` via Server-Sent Events (`ResponseType.stream`),
  /// emitting real-time report, SOS, and private group member updates and firing
  /// OS emergency notifications whenever a new nearby `!isMine` SOS alert arrives.
  Stream<TrailLiveSseEvent> connectStream({
    required double lat,
    required double lon,
    String? trailId,
    String? groupCode,
    String? lastEventId,
    CancelToken? cancelToken,
    bool isRo = true,
  }) async* {
    if (!isConfigured) return;
    final token = await _tokenLoader();
    final effectiveCancel = cancelToken ?? CancelToken();
    final cleanGroupCode = groupCode?.trim();
    final cleanLastEventId = lastEventId?.trim();
    final response = await _dio.get<ResponseBody>(
      '/live/stream',
      queryParameters: <String, Object?>{
        'lat': _quantize6(lat),
        'lon': _quantize6(lon),
        if (trailId != null && trailId.isNotEmpty) 'trailId': trailId,
        if (cleanGroupCode != null && cleanGroupCode.isNotEmpty)
          'groupCode': _normalizeGroupCode(cleanGroupCode),
        if (cleanLastEventId != null && cleanLastEventId.isNotEmpty)
          'lastEventId': cleanLastEventId,
        'deviceToken': token,
      },
      cancelToken: effectiveCancel,
      options: Options(
        headers: <String, dynamic>{
          'X-Device-Token': token,
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache',
          if (cleanLastEventId != null && cleanLastEventId.isNotEmpty)
            'Last-Event-ID': cleanLastEventId,
        },
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(hours: 2),
      ),
    );

    final body = response.data;
    if (body == null) return;

    String? currentEvent;
    String? currentEventId;
    final dataLines = <String>[];

    await for (final line
        in body.stream
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (effectiveCancel.isCancelled) break;

      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final parsed = TrailLiveSseEvent.tryParse(
            eventName: currentEvent,
            eventId: currentEventId,
            data: dataLines.join('\n'),
          );
          currentEvent = null;
          currentEventId = null;
          dataLines.clear();
          if (parsed != null) {
            if (parsed.type == TrailLiveSseEvent.resyncRequired) {
              _lastHeartbeatSummary = null;
            }
            if (parsed.sos != null) {
              await _maybeNotifyNearbySos(
                parsed.sos,
                userLat: lat,
                userLon: lon,
                isRo: isRo,
              );
            }
            yield parsed;
          }
        } else {
          currentEvent = null;
          currentEventId = null;
        }
        continue;
      }

      if (line.startsWith(':')) {
        // SSE keepalive comment.
        continue;
      }
      if (line.startsWith('id:')) {
        currentEventId = line.substring(3).trim();
      } else if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }

    if (dataLines.isNotEmpty) {
      final parsed = TrailLiveSseEvent.tryParse(
        eventName: currentEvent,
        eventId: currentEventId,
        data: dataLines.join('\n'),
      );
      if (parsed != null) {
        if (parsed.type == TrailLiveSseEvent.resyncRequired) {
          _lastHeartbeatSummary = null;
        }
        if (parsed.sos != null) {
          await _maybeNotifyNearbySos(
            parsed.sos,
            userLat: lat,
            userLon: lon,
            isRo: isRo,
          );
        }
        yield parsed;
      }
    }
  }
}

/// Provides a configured [TrailLiveService] when [apiProvider] is available and
/// pointed at a real Wanderer server, or `null` in unconfigured/test harnesses.
final trailLiveServiceProvider = Provider<TrailLiveService?>((ref) {
  if (WandererImageCacheManager.cookieJar == null && !ref.exists(apiProvider)) {
    return null;
  }
  try {
    final dio = ref.watch(apiProvider);
    final host = Uri.tryParse(dio.options.baseUrl)?.host ?? '';
    if (host.isEmpty || host.contains(kUnconfiguredApiHost)) return null;
    return TrailLiveService(dio: dio);
  } catch (_) {
    return null;
  }
});
