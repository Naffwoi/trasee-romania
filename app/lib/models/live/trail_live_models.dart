import 'dart:convert';
import 'dart:math' as math;

DateTime? _parseOptionalDate(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.toUtc();
}

String? _parseOptionalString(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  return text.isEmpty ? null : text;
}

double _parseDouble(Object? raw, [double fallback = 0.0]) {
  if (raw is num) {
    final val = raw.toDouble();
    return val.isFinite ? val : fallback;
  }
  if (raw is String) {
    final parsed = double.tryParse(raw.trim());
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return fallback;
}

double? _parseOptionalDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final val = raw.toDouble();
    return val.isFinite ? val : null;
  }
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    return (parsed != null && parsed.isFinite) ? parsed : null;
  }
  return null;
}

int _parseInt(Object? raw, [int fallback = 0]) {
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.round() : fallback;
  if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
  return fallback;
}

int? _parseOptionalInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.round() : null;
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }
  return null;
}

bool _parseBool(Object? raw, [bool fallback = false]) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final lower = raw.trim().toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  return fallback;
}

/// The 8 supported trail community report categories (5 temporary Waze alerts +
/// 3 permanent mountain landmarks).
enum TrailReportCategory {
  bear,
  deer,
  shepherdDogs,
  iceMud,
  fallenTreeTerrain,
  spring,
  viewpoint,
  shelter;

  String get apiValue => switch (this) {
    TrailReportCategory.bear => 'bear',
    TrailReportCategory.deer => 'deer',
    TrailReportCategory.shepherdDogs => 'shepherd_dogs',
    TrailReportCategory.iceMud => 'ice_mud',
    TrailReportCategory.fallenTreeTerrain => 'fallen_tree_terrain',
    TrailReportCategory.spring => 'spring',
    TrailReportCategory.viewpoint => 'viewpoint',
    TrailReportCategory.shelter => 'shelter',
  };

  static TrailReportCategory fromApi(String? raw) => switch (raw?.trim()) {
    'bear' => TrailReportCategory.bear,
    'deer' => TrailReportCategory.deer,
    'shepherd_dogs' => TrailReportCategory.shepherdDogs,
    'ice_mud' => TrailReportCategory.iceMud,
    'fallen_tree_terrain' => TrailReportCategory.fallenTreeTerrain,
    'spring' => TrailReportCategory.spring,
    'viewpoint' => TrailReportCategory.viewpoint,
    'shelter' => TrailReportCategory.shelter,
    _ => TrailReportCategory.fallenTreeTerrain,
  };

  bool get isPermanent => switch (this) {
    TrailReportCategory.spring ||
    TrailReportCategory.viewpoint ||
    TrailReportCategory.shelter => true,
    _ => false,
  };

  String get defaultKind => switch (this) {
    TrailReportCategory.deer => 'wildlife_good',
    TrailReportCategory.spring ||
    TrailReportCategory.viewpoint ||
    TrailReportCategory.shelter => 'landmark_permanent',
    _ => 'hazard',
  };

  /// Default time-to-live window for temporary alerts (`null` for permanent landmarks).
  Duration? get defaultTtl => switch (this) {
    TrailReportCategory.bear => const Duration(hours: 3),
    TrailReportCategory.deer => const Duration(hours: 3),
    TrailReportCategory.shepherdDogs => const Duration(hours: 24),
    TrailReportCategory.iceMud => const Duration(hours: 48),
    TrailReportCategory.fallenTreeTerrain => const Duration(days: 14),
    TrailReportCategory.spring ||
    TrailReportCategory.viewpoint ||
    TrailReportCategory.shelter => null,
  };

  String get emoji => switch (this) {
    TrailReportCategory.bear => '🐻',
    TrailReportCategory.deer => '🦌',
    TrailReportCategory.shepherdDogs => '🐕',
    TrailReportCategory.iceMud => '🧊',
    TrailReportCategory.fallenTreeTerrain => '🌲',
    TrailReportCategory.spring => '💧',
    TrailReportCategory.viewpoint => '📸',
    TrailReportCategory.shelter => '🛖',
  };

  String label({required bool isRo}) => switch (this) {
    TrailReportCategory.bear => isRo ? 'Urs pe traseu' : 'Bear spotted',
    TrailReportCategory.deer => isRo ? 'Căprioare' : 'Deer spotted',
    TrailReportCategory.shepherdDogs => isRo ? 'Câini la stână' : 'Shepherd dogs',
    TrailReportCategory.iceMud => isRo ? 'Gheață / Noroi' : 'Ice / Mud',
    TrailReportCategory.fallenTreeTerrain =>
      isRo ? 'Teren cu probleme / Copac căzut' : 'Fallen tree / Bad terrain',
    TrailReportCategory.spring => isRo ? 'Izvor' : 'Water spring',
    TrailReportCategory.viewpoint => isRo ? 'Belvedere' : 'Viewpoint',
    TrailReportCategory.shelter => isRo ? 'Refugiu' : 'Mountain shelter',
  };

  String ttlBadgeLabel({required bool isRo}) => switch (this) {
    TrailReportCategory.bear || TrailReportCategory.deer => '3h',
    TrailReportCategory.shepherdDogs => '24h',
    TrailReportCategory.iceMud => '48h',
    TrailReportCategory.fallenTreeTerrain => isRo ? '14 zile' : '14d',
    TrailReportCategory.spring ||
    TrailReportCategory.viewpoint ||
    TrailReportCategory.shelter => isRo ? 'Permanent' : 'Permanent',
  };

  static const List<TrailReportCategory> temporaryCategories = [
    TrailReportCategory.bear,
    TrailReportCategory.shepherdDogs,
    TrailReportCategory.fallenTreeTerrain,
    TrailReportCategory.iceMud,
    TrailReportCategory.deer,
  ];

  static const List<TrailReportCategory> permanentCategories = [
    TrailReportCategory.spring,
    TrailReportCategory.viewpoint,
    TrailReportCategory.shelter,
  ];
}

enum TrailReportVoteType {
  confirm,
  dismiss,
  seasonalOk,
  seasonalDry,
  spam;

  String get apiValue => switch (this) {
    TrailReportVoteType.confirm => 'confirm',
    TrailReportVoteType.dismiss => 'dismiss',
    TrailReportVoteType.seasonalOk => 'seasonal_ok',
    TrailReportVoteType.seasonalDry => 'seasonal_dry',
    TrailReportVoteType.spam => 'spam',
  };
}

class TrailReportModel {
  const TrailReportModel({
    required this.id,
    this.trailId,
    required this.category,
    required this.kind,
    required this.isPermanent,
    this.conditionStatus = 'active',
    this.note = '',
    required this.lat,
    required this.lon,
    this.ele = 0.0,
    this.alongTrackM,
    this.photoUrl,
    this.photoThumbUrl,
    this.photoVerified = false,
    this.confirmCount = 1,
    this.dismissCount = 0,
    this.createdAt,
    this.lastConfirmedAt,
    this.expiresAt,
  });

  final String id;
  final String? trailId;
  final TrailReportCategory category;
  final String kind;
  final bool isPermanent;
  final String conditionStatus;
  final String note;
  final double lat;
  final double lon;
  final double ele;
  final double? alongTrackM;
  final String? photoUrl;
  final String? photoThumbUrl;
  final bool photoVerified;
  final int confirmCount;
  final int dismissCount;
  final DateTime? createdAt;
  final DateTime? lastConfirmedAt;
  final DateTime? expiresAt;

  bool get isDryOrClosed => conditionStatus == 'dry_or_closed';

  bool isVisibleAt(DateTime now) {
    if (conditionStatus == 'resolved' || conditionStatus == 'spam_hidden') {
      return false;
    }
    if (isPermanent) return true;
    final exp = expiresAt;
    if (exp != null && !exp.isAfter(now.toUtc())) {
      return false;
    }
    return true;
  }

  int? minutesSinceLastConfirmation(DateTime now) {
    final anchor = lastConfirmedAt ?? createdAt;
    if (anchor == null) return null;
    final diff = now.toUtc().difference(anchor.toUtc()).inMinutes;
    return math.max(0, diff);
  }

  String confirmedAgoLabel(DateTime now, {required bool isRo}) {
    final mins = minutesSinceLastConfirmation(now);
    if (mins == null || mins < 1) {
      return isRo ? 'Confirmat chiar acum' : 'Confirmed just now';
    }
    if (mins < 60) {
      return isRo ? 'Confirmat acum $mins min' : 'Confirmed $mins min ago';
    }
    final hours = mins ~/ 60;
    if (hours < 24) {
      return isRo ? 'Confirmat acum $hours h' : 'Confirmed ${hours}h ago';
    }
    final days = hours ~/ 24;
    return isRo ? 'Confirmat acum $days zile' : 'Confirmed ${days}d ago';
  }

  /// Applies optimistic local vote rules matching the Go `/live/reports/{id}/vote`
  /// lifecycle (including extending `expiresAt` on `confirm` for temporary alerts).
  TrailReportModel applyLocalVote(TrailReportVoteType vote, {DateTime? now}) {
    final ts = (now ?? DateTime.now()).toUtc();
    switch (vote) {
      case TrailReportVoteType.confirm:
        DateTime? nextExpires = expiresAt;
        if (!isPermanent) {
          final ttl = category.defaultTtl;
          if (ttl != null) {
            final candidate = ts.add(ttl);
            if (nextExpires == null || candidate.isAfter(nextExpires)) {
              nextExpires = candidate;
            }
          }
        } else {
          nextExpires = null;
        }
        return copyWith(
          confirmCount: confirmCount + 1,
          lastConfirmedAt: ts,
          expiresAt: nextExpires,
          clearExpiresAt: isPermanent,
        );
      case TrailReportVoteType.dismiss:
        if (isPermanent) return this;
        final nextDismiss = dismissCount + 1;
        final shouldResolve =
            nextDismiss >= 3 || (nextDismiss - confirmCount) >= 2;
        return copyWith(
          dismissCount: nextDismiss,
          conditionStatus: shouldResolve ? 'resolved' : conditionStatus,
        );
      case TrailReportVoteType.seasonalOk:
        return copyWith(
          conditionStatus: 'active',
          lastConfirmedAt: ts,
          clearExpiresAt: isPermanent,
        );
      case TrailReportVoteType.seasonalDry:
        return copyWith(
          conditionStatus: 'dry_or_closed',
          lastConfirmedAt: ts,
          clearExpiresAt: isPermanent,
        );
      case TrailReportVoteType.spam:
        return copyWith(conditionStatus: 'spam_hidden');
    }
  }

  TrailReportModel copyWith({
    String? id,
    String? trailId,
    TrailReportCategory? category,
    String? kind,
    bool? isPermanent,
    String? conditionStatus,
    String? note,
    double? lat,
    double? lon,
    double? ele,
    double? alongTrackM,
    String? photoUrl,
    String? photoThumbUrl,
    bool? photoVerified,
    int? confirmCount,
    int? dismissCount,
    DateTime? createdAt,
    DateTime? lastConfirmedAt,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
  }) {
    return TrailReportModel(
      id: id ?? this.id,
      trailId: trailId ?? this.trailId,
      category: category ?? this.category,
      kind: kind ?? this.kind,
      isPermanent: isPermanent ?? this.isPermanent,
      conditionStatus: conditionStatus ?? this.conditionStatus,
      note: note ?? this.note,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      ele: ele ?? this.ele,
      alongTrackM: alongTrackM ?? this.alongTrackM,
      photoUrl: photoUrl ?? this.photoUrl,
      photoThumbUrl: photoThumbUrl ?? this.photoThumbUrl,
      photoVerified: photoVerified ?? this.photoVerified,
      confirmCount: confirmCount ?? this.confirmCount,
      dismissCount: dismissCount ?? this.dismissCount,
      createdAt: createdAt ?? this.createdAt,
      lastConfirmedAt: lastConfirmedAt ?? this.lastConfirmedAt,
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
    );
  }

  factory TrailReportModel.fromJson(Map<String, dynamic> json) {
    final category = TrailReportCategory.fromApi(
      (json['category'] as Object?)?.toString(),
    );
    final isPermanent = json.containsKey('isPermanent')
        ? _parseBool(json['isPermanent'], category.isPermanent)
        : (json.containsKey('is_permanent')
              ? _parseBool(json['is_permanent'], category.isPermanent)
              : category.isPermanent);
    final rawExpires = json['expiresAt'] ?? json['expires_at'];
    return TrailReportModel(
      id: (json['id'] ?? '').toString(),
      trailId: _parseOptionalString(json['trailId'] ?? json['trail_id']),
      category: category,
      kind:
          _parseOptionalString(json['kind']) ??
          category.defaultKind,
      isPermanent: isPermanent,
      conditionStatus:
          _parseOptionalString(
            json['conditionStatus'] ?? json['condition_status'],
          ) ??
          'active',
      note: (json['note'] ?? '').toString(),
      lat: _parseDouble(json['lat']),
      lon: _parseDouble(json['lon']),
      ele: _parseDouble(json['ele']),
      alongTrackM: _parseOptionalDouble(
        json['alongTrackM'] ?? json['along_track_m'],
      ),
      photoUrl: _parseOptionalString(json['photoUrl'] ?? json['photo_url']),
      photoThumbUrl: _parseOptionalString(
        json['photoThumbUrl'] ?? json['photo_thumb_url'],
      ),
      photoVerified: _parseBool(
        json['photoVerified'] ?? json['photo_verified'],
        false,
      ),
      confirmCount: _parseInt(
        json['confirmCount'] ?? json['confirm_count'],
        1,
      ),
      dismissCount: _parseInt(
        json['dismissCount'] ?? json['dismiss_count'],
        0,
      ),
      createdAt: _parseOptionalDate(json['createdAt'] ?? json['created']),
      lastConfirmedAt: _parseOptionalDate(
        json['lastConfirmedAt'] ?? json['last_confirmed_at'],
      ),
      expiresAt: isPermanent ? null : _parseOptionalDate(rawExpires),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'trailId': trailId,
    'category': category.apiValue,
    'kind': kind,
    'isPermanent': isPermanent,
    'conditionStatus': conditionStatus,
    'note': note,
    'lat': lat,
    'lon': lon,
    'ele': ele,
    'alongTrackM': alongTrackM,
    if (photoUrl != null) 'photoUrl': photoUrl,
    if (photoThumbUrl != null) 'photoThumbUrl': photoThumbUrl,
    'photoVerified': photoVerified,
    'confirmCount': confirmCount,
    'dismissCount': dismissCount,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'lastConfirmedAt': lastConfirmedAt?.toUtc().toIso8601String(),
    'expiresAt': isPermanent ? null : expiresAt?.toUtc().toIso8601String(),
  };
}

enum SosReason {
  lost,
  injury,
  exhaustion,
  other;

  String get apiValue => switch (this) {
    SosReason.lost => 'lost',
    SosReason.injury => 'injury',
    SosReason.exhaustion => 'exhaustion',
    SosReason.other => 'other',
  };

  static SosReason fromApi(String? raw) => switch (raw?.trim()) {
    'lost' => SosReason.lost,
    'injury' => SosReason.injury,
    'exhaustion' => SosReason.exhaustion,
    _ => SosReason.other,
  };

  String label({required bool isRo}) => switch (this) {
    SosReason.lost => isRo ? 'Rătăcit pe munte' : 'Lost on trail',
    SosReason.injury => isRo ? 'Accidentare' : 'Injury',
    SosReason.exhaustion =>
      isRo ? 'Epuizare / Fără apă' : 'Exhaustion / Out of water',
    SosReason.other => isRo ? 'Altă urgență' : 'Other emergency',
  };
}

class SosAlertModel {
  const SosAlertModel({
    required this.id,
    this.clientSosId,
    this.trailId,
    this.status = 'active',
    this.reason = SosReason.other,
    this.message = '',
    this.requesterName = '',
    required this.lat,
    required this.lon,
    this.ele = 0.0,
    this.responderCount = 0,
    this.nearestEtaSec,
    this.nearestDistanceM,
    this.isMine = false,
    this.amResponding = false,
    this.createdAt,
    this.expiresAt,
    this.viaBluetooth = false,
    this.bleHopCount = 0,
    this.bleAckCount = 0,
    this.bleServerConfirmed = false,
    this.bleNearestEtaMin,
    this.bleNearestDistanceM,
    this.localClaimSecret,
  });

  final String id;
  final String? clientSosId;
  final String? trailId;
  final String status;
  final SosReason reason;
  final String message;
  final String requesterName;
  final double lat;
  final double lon;
  final double ele;
  final int responderCount;
  final int? nearestEtaSec;
  final double? nearestDistanceM;
  final bool isMine;
  final bool amResponding;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final bool viaBluetooth;
  final int bleHopCount;
  final int bleAckCount;
  final bool bleServerConfirmed;
  final int? bleNearestEtaMin;
  final double? bleNearestDistanceM;
  final String? localClaimSecret;

  String get dedupeKey {
    final cid = clientSosId;
    return (cid != null && cid.isNotEmpty) ? 'csos:$cid' : 'id:$id';
  }

  int get effectiveResponderCount => math.max(responderCount, bleAckCount);

  bool isActiveAt(DateTime now) {
    if (status != 'active') return false;
    final exp = expiresAt;
    if (exp != null && !exp.isAfter(now.toUtc())) return false;
    return true;
  }

  SosAlertModel copyWith({
    String? id,
    String? clientSosId,
    String? trailId,
    String? status,
    SosReason? reason,
    String? message,
    String? requesterName,
    double? lat,
    double? lon,
    double? ele,
    int? responderCount,
    int? nearestEtaSec,
    double? nearestDistanceM,
    bool? isMine,
    bool? amResponding,
    DateTime? createdAt,
    DateTime? expiresAt,
    bool? viaBluetooth,
    int? bleHopCount,
    int? bleAckCount,
    bool? bleServerConfirmed,
    int? bleNearestEtaMin,
    double? bleNearestDistanceM,
    String? localClaimSecret,
  }) {
    return SosAlertModel(
      id: id ?? this.id,
      clientSosId: clientSosId ?? this.clientSosId,
      trailId: trailId ?? this.trailId,
      status: status ?? this.status,
      reason: reason ?? this.reason,
      message: message ?? this.message,
      requesterName: requesterName ?? this.requesterName,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      ele: ele ?? this.ele,
      responderCount: responderCount ?? this.responderCount,
      nearestEtaSec: nearestEtaSec ?? this.nearestEtaSec,
      nearestDistanceM: nearestDistanceM ?? this.nearestDistanceM,
      isMine: isMine ?? this.isMine,
      amResponding: amResponding ?? this.amResponding,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      viaBluetooth: viaBluetooth ?? this.viaBluetooth,
      bleHopCount: bleHopCount ?? this.bleHopCount,
      bleAckCount: bleAckCount ?? this.bleAckCount,
      bleServerConfirmed: bleServerConfirmed ?? this.bleServerConfirmed,
      bleNearestEtaMin: bleNearestEtaMin ?? this.bleNearestEtaMin,
      bleNearestDistanceM: bleNearestDistanceM ?? this.bleNearestDistanceM,
      localClaimSecret: localClaimSecret ?? this.localClaimSecret,
    );
  }

  factory SosAlertModel.fromJson(Map<String, dynamic> json) {
    final rawNearestEta = _parseOptionalInt(
      json['nearestEtaSec'] ?? json['nearest_eta_sec'],
    );
    final rawNearestDist = _parseOptionalDouble(
      json['nearestDistanceM'] ?? json['nearest_distance_m'],
    );
    final rawClientSosId = _parseOptionalString(
      json['clientSosId'] ?? json['client_sos_id'],
    )?.toLowerCase();
    return SosAlertModel(
      id: (json['id'] ?? '').toString(),
      clientSosId: rawClientSosId,
      trailId: _parseOptionalString(json['trailId'] ?? json['trail_id']),
      status: _parseOptionalString(json['status']) ?? 'active',
      reason: SosReason.fromApi((json['reason'] as Object?)?.toString()),
      message: (json['message'] ?? '').toString(),
      requesterName:
          (json['requesterName'] ?? json['requester_name'] ?? '').toString(),
      lat: _parseDouble(json['lat']),
      lon: _parseDouble(json['lon']),
      ele: _parseDouble(json['ele']),
      responderCount: _parseInt(
        json['responderCount'] ?? json['responder_count'],
        0,
      ),
      nearestEtaSec: (rawNearestEta != null && rawNearestEta > 0)
          ? rawNearestEta
          : null,
      nearestDistanceM: (rawNearestDist != null && rawNearestDist > 0)
          ? rawNearestDist
          : null,
      isMine: _parseBool(json['isMine'] ?? json['is_mine']),
      amResponding: _parseBool(json['amResponding'] ?? json['am_responding']),
      createdAt: _parseOptionalDate(json['createdAt'] ?? json['created']),
      expiresAt: _parseOptionalDate(json['expiresAt'] ?? json['expires_at']),
      viaBluetooth: _parseBool(json['viaBluetooth'] ?? json['via_bluetooth']),
      bleHopCount: _parseInt(json['bleHopCount'] ?? json['ble_hop_count'], 0),
      bleAckCount: _parseInt(json['bleAckCount'] ?? json['ble_ack_count'], 0),
      bleServerConfirmed: _parseBool(
        json['bleServerConfirmed'] ?? json['ble_server_confirmed'],
      ),
      bleNearestEtaMin: _parseOptionalInt(
        json['bleNearestEtaMin'] ?? json['ble_nearest_eta_min'],
      ),
      bleNearestDistanceM: _parseOptionalDouble(
        json['bleNearestDistanceM'] ?? json['ble_nearest_distance_m'],
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (clientSosId != null) 'clientSosId': clientSosId,
    'trailId': trailId,
    'status': status,
    'reason': reason.apiValue,
    'message': message,
    'requesterName': requesterName,
    'lat': lat,
    'lon': lon,
    'ele': ele,
    'responderCount': responderCount,
    'nearestEtaSec': nearestEtaSec,
    'nearestDistanceM': nearestDistanceM,
    'isMine': isMine,
    'amResponding': amResponding,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    if (viaBluetooth) 'viaBluetooth': viaBluetooth,
    if (bleHopCount > 0) 'bleHopCount': bleHopCount,
    if (bleAckCount > 0) 'bleAckCount': bleAckCount,
    if (bleServerConfirmed) 'bleServerConfirmed': bleServerConfirmed,
    if (bleNearestEtaMin != null) 'bleNearestEtaMin': bleNearestEtaMin,
    if (bleNearestDistanceM != null)
      'bleNearestDistanceM': bleNearestDistanceM,
  };
}

class TrailLiveSummary {
  const TrailLiveSummary({
    this.trailId,
    required this.activeHikers30m,
    this.reports = const [],
    this.sosAlerts = const [],
    this.stateHash,
    this.unchanged = false,
  });

  final String? trailId;
  final int activeHikers30m;
  final List<TrailReportModel> reports;
  final List<SosAlertModel> sosAlerts;
  final String? stateHash;
  final bool unchanged;

  TrailLiveSummary copyWith({
    String? trailId,
    int? activeHikers30m,
    List<TrailReportModel>? reports,
    List<SosAlertModel>? sosAlerts,
    String? stateHash,
    bool? unchanged,
  }) {
    return TrailLiveSummary(
      trailId: trailId ?? this.trailId,
      activeHikers30m: activeHikers30m ?? this.activeHikers30m,
      reports: reports ?? this.reports,
      sosAlerts: sosAlerts ?? this.sosAlerts,
      stateHash: stateHash ?? this.stateHash,
      unchanged: unchanged ?? this.unchanged,
    );
  }

  List<TrailReportModel> visibleReports({DateTime? now}) {
    final ts = now ?? DateTime.now();
    return reports.where((r) => r.isVisibleAt(ts)).toList(growable: false);
  }

  SosAlertModel? myActiveSos({DateTime? now}) {
    final ts = now ?? DateTime.now();
    for (final s in sosAlerts) {
      if (s.isMine && s.isActiveAt(ts)) return s;
    }
    return null;
  }

  List<SosAlertModel> nearbyActiveSos({DateTime? now}) {
    final ts = now ?? DateTime.now();
    return sosAlerts
        .where((s) => !s.isMine && s.isActiveAt(ts))
        .toList(growable: false);
  }

  factory TrailLiveSummary.fromJson(Map<String, dynamic> json) {
    final rawReports = json['reports'] ?? json['nearbyReports'];
    final parsedReports = <TrailReportModel>[];
    if (rawReports is List) {
      for (final item in rawReports) {
        if (item is Map) {
          parsedReports.add(
            TrailReportModel.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    final rawSos = json['sosAlerts'] ?? json['activeSosAlerts'];
    final parsedSos = <SosAlertModel>[];
    final seenSosIds = <String>{};
    final seenDedupeKeys = <String>{};
    if (rawSos is List) {
      for (final item in rawSos) {
        if (item is Map) {
          final model = SosAlertModel.fromJson(Map<String, dynamic>.from(item));
          if (model.id.isNotEmpty &&
              !seenSosIds.contains(model.id) &&
              !seenDedupeKeys.contains(model.dedupeKey)) {
            seenSosIds.add(model.id);
            seenDedupeKeys.add(model.dedupeKey);
            parsedSos.add(model);
          }
        }
      }
    }

    final rawMySos = json['myActiveSos'];
    if (rawMySos is Map) {
      final mine = SosAlertModel.fromJson(
        Map<String, dynamic>.from(rawMySos),
      ).copyWith(isMine: true);
      if (mine.id.isNotEmpty &&
          !seenSosIds.contains(mine.id) &&
          !seenDedupeKeys.contains(mine.dedupeKey)) {
        seenSosIds.add(mine.id);
        seenDedupeKeys.add(mine.dedupeKey);
        parsedSos.insert(0, mine);
      }
    }

    return TrailLiveSummary(
      trailId: _parseOptionalString(json['trailId'] ?? json['trail_id']),
      activeHikers30m: math.max(
        0,
        _parseInt(json['activeHikers30m'] ?? json['active_hikers_30m'], 0),
      ),
      reports: parsedReports,
      sosAlerts: parsedSos,
      stateHash: _parseOptionalString(json['stateHash'] ?? json['state_hash']),
      unchanged: _parseBool(json['unchanged'], false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'trailId': trailId,
    'activeHikers30m': activeHikers30m,
    'reports': reports.map((r) => r.toJson()).toList(growable: false),
    'sosAlerts': sosAlerts.map((s) => s.toJson()).toList(growable: false),
    if (stateHash != null) 'stateHash': stateHash,
    if (unchanged) 'unchanged': true,
  };
}

class GroupMemberModel {
  const GroupMemberModel({
    required this.memberId,
    required this.displayName,
    this.colorHex = '#242734',
    required this.lat,
    required this.lon,
    this.ele = 0.0,
    this.accuracy = 15.0,
    this.heading,
    this.speed,
    this.alongTrackM,
    this.inNavigation = false,
    this.isStationary = false,
    this.isSelf = false,
    this.updatedAt,
    this.viaBluetooth = false,
    this.bleHopCount = 0,
  });

  final String memberId;
  final String displayName;
  final String colorHex;
  final double lat;
  final double lon;
  final double ele;
  final double accuracy;
  final double? heading;
  final double? speed;
  final double? alongTrackM;
  final bool inNavigation;
  final bool isStationary;
  final bool isSelf;
  final DateTime? updatedAt;
  final bool viaBluetooth;
  final int bleHopCount;

  String get initials {
    final cleaned = displayName.trim();
    if (cleaned.isEmpty) return 'DR';
    final parts = cleaned
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.length >= 2) {
      final a = String.fromCharCode(parts[0].runes.first).toUpperCase();
      final b = String.fromCharCode(parts[1].runes.first).toUpperCase();
      return '$a$b';
    }
    final runes = parts.first.runes.toList(growable: false);
    if (runes.length >= 2) {
      return String.fromCharCodes(runes.sublist(0, 2)).toUpperCase();
    }
    return String.fromCharCodes(runes).toUpperCase();
  }

  GroupMemberModel copyWith({
    String? memberId,
    String? displayName,
    String? colorHex,
    double? lat,
    double? lon,
    double? ele,
    double? accuracy,
    double? heading,
    double? speed,
    double? alongTrackM,
    bool? inNavigation,
    bool? isStationary,
    bool? isSelf,
    DateTime? updatedAt,
    bool? viaBluetooth,
    int? bleHopCount,
  }) {
    return GroupMemberModel(
      memberId: memberId ?? this.memberId,
      displayName: displayName ?? this.displayName,
      colorHex: colorHex ?? this.colorHex,
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      ele: ele ?? this.ele,
      accuracy: accuracy ?? this.accuracy,
      heading: heading ?? this.heading,
      speed: speed ?? this.speed,
      alongTrackM: alongTrackM ?? this.alongTrackM,
      inNavigation: inNavigation ?? this.inNavigation,
      isStationary: isStationary ?? this.isStationary,
      isSelf: isSelf ?? this.isSelf,
      updatedAt: updatedAt ?? this.updatedAt,
      viaBluetooth: viaBluetooth ?? this.viaBluetooth,
      bleHopCount: bleHopCount ?? this.bleHopCount,
    );
  }

  factory GroupMemberModel.fromJson(Map<String, dynamic> json) {
    final rawAcc = _parseDouble(json['accuracy'], 15.0);
    return GroupMemberModel(
      memberId: (json['memberId'] ?? json['member_id'] ?? '').toString().trim(),
      displayName:
          _parseOptionalString(json['displayName'] ?? json['display_name']) ??
          'Drumeț',
      colorHex:
          _parseOptionalString(json['colorHex'] ?? json['color_hex']) ??
          '#242734',
      lat: _parseDouble(json['lat']),
      lon: _parseDouble(json['lon']),
      ele: _parseDouble(json['ele']),
      accuracy: rawAcc > 0.0 ? rawAcc : 15.0,
      heading: _parseOptionalDouble(json['heading']),
      speed: _parseOptionalDouble(json['speed']),
      alongTrackM: _parseOptionalDouble(
        json['alongTrackM'] ?? json['along_track_m'],
      ),
      inNavigation: _parseBool(
        json['inNavigation'] ?? json['in_navigation'],
        false,
      ),
      isStationary: _parseBool(
        json['stationary'] ?? json['isStationary'] ?? json['is_stationary'],
        false,
      ),
      isSelf: _parseBool(json['isSelf'] ?? json['is_self'], false),
      updatedAt: _parseOptionalDate(
        json['updatedAt'] ??
            json['updated_at'] ??
            json['lastSeen'] ??
            json['last_seen'],
      ),
      viaBluetooth: _parseBool(
        json['viaBluetooth'] ?? json['via_bluetooth'],
        false,
      ),
      bleHopCount: _parseInt(
        json['bleHopCount'] ?? json['ble_hop_count'],
        0,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'memberId': memberId,
    'displayName': displayName,
    'colorHex': colorHex,
    'lat': lat,
    'lon': lon,
    'ele': ele,
    'accuracy': accuracy,
    'heading': heading,
    'speed': speed,
    'alongTrackM': alongTrackM,
    'inNavigation': inNavigation,
    if (isStationary) 'stationary': true,
    'isSelf': isSelf,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    if (viaBluetooth) 'viaBluetooth': viaBluetooth,
    if (bleHopCount > 0) 'bleHopCount': bleHopCount,
  };
}

class GroupSessionModel {
  const GroupSessionModel({
    required this.code,
    this.trailId,
    this.expiresAt,
    required this.selfMemberId,
    this.members = const [],
    this.hasMembersSnapshot = true,
    this.isOfflineBleGroup = false,
  });

  final String code;
  final String? trailId;
  final DateTime? expiresAt;
  final String selfMemberId;
  final List<GroupMemberModel> members;
  final bool hasMembersSnapshot;
  final bool isOfflineBleGroup;

  List<GroupMemberModel> get peers => members
      .where((m) => !m.isSelf && m.memberId != selfMemberId)
      .toList(growable: false);

  GroupSessionModel copyWith({
    String? code,
    String? trailId,
    DateTime? expiresAt,
    String? selfMemberId,
    List<GroupMemberModel>? members,
    bool? hasMembersSnapshot,
    bool? isOfflineBleGroup,
  }) {
    return GroupSessionModel(
      code: code ?? this.code,
      trailId: trailId ?? this.trailId,
      expiresAt: expiresAt ?? this.expiresAt,
      selfMemberId: selfMemberId ?? this.selfMemberId,
      members: members ?? this.members,
      hasMembersSnapshot: hasMembersSnapshot ?? this.hasMembersSnapshot,
      isOfflineBleGroup: isOfflineBleGroup ?? this.isOfflineBleGroup,
    );
  }

  factory GroupSessionModel.fromJson(Map<String, dynamic> json) {
    final source = json['group'] is Map
        ? Map<String, dynamic>.from(json['group'] as Map)
        : json;
    final selfId =
        (source['selfMemberId'] ?? source['self_member_id'] ?? '')
            .toString()
            .trim();
    final rawMembers = source['members'];
    final parsedMembers = <GroupMemberModel>[];
    if (rawMembers is List) {
      for (final item in rawMembers) {
        if (item is Map) {
          final member = GroupMemberModel.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (member.memberId.isNotEmpty) {
            parsedMembers.add(
              selfId.isNotEmpty && member.memberId == selfId
                  ? member.copyWith(isSelf: true)
                  : member,
            );
          }
        }
      }
    }
    return GroupSessionModel(
      code: (source['code'] ?? source['groupCode'] ?? '')
          .toString()
          .trim()
          .toUpperCase(),
      trailId: _parseOptionalString(source['trailId'] ?? source['trail_id']),
      expiresAt: _parseOptionalDate(
        source['expiresAt'] ?? source['expires_at'],
      ),
      selfMemberId: selfId,
      members: parsedMembers,
      hasMembersSnapshot: rawMembers is List,
      isOfflineBleGroup: _parseBool(
        source['isOfflineBleGroup'] ?? source['is_offline_ble_group'],
        false,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'code': code,
    'trailId': trailId,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'selfMemberId': selfMemberId,
    'members': members.map((m) => m.toJson()).toList(growable: false),
    if (!hasMembersSnapshot) 'hasMembersSnapshot': false,
    if (isOfflineBleGroup) 'isOfflineBleGroup': isOfflineBleGroup,
  };
}

class TrailLiveSseEvent {
  const TrailLiveSseEvent({
    required this.type,
    this.eventId,
    this.report,
    this.sos,
    this.groupMember,
    this.leftMemberId,
    this.groupCode,
    this.raw = const {},
  });

  static const String groupMemberUpdate = 'group_member_update';
  static const String groupMemberLeft = 'group_member_left';
  static const String resyncRequired = 'resync_required';

  final String type;
  final String? eventId;
  final TrailReportModel? report;
  final SosAlertModel? sos;
  final GroupMemberModel? groupMember;
  final String? leftMemberId;
  final String? groupCode;
  final Map<String, dynamic> raw;

  static TrailLiveSseEvent? tryParse({
    String? eventName,
    String? eventId,
    required String data,
  }) {
    final trimmed = data.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final effectiveType =
          _parseOptionalString(eventName) ??
          _parseOptionalString(map['type']) ??
          'message';

      TrailReportModel? report;
      SosAlertModel? sos;
      GroupMemberModel? groupMember;
      String? leftMemberId;
      final groupCode = _parseOptionalString(
        map['groupCode'] ?? map['group_code'] ?? map['code'],
      )?.toUpperCase();

      if (map['report'] is Map) {
        report = TrailReportModel.fromJson(
          Map<String, dynamic>.from(map['report'] as Map),
        );
      } else if (effectiveType.contains('report') && map.containsKey('id')) {
        report = TrailReportModel.fromJson(map);
      }

      if (map['sos'] is Map) {
        sos = SosAlertModel.fromJson(
          Map<String, dynamic>.from(map['sos'] as Map),
        );
      } else if (effectiveType.contains('sos') && map.containsKey('id')) {
        sos = SosAlertModel.fromJson(map);
      }

      if (effectiveType == groupMemberUpdate) {
        final rawMember = map['member'] is Map
            ? Map<String, dynamic>.from(map['member'] as Map)
            : map;
        final parsedMember = GroupMemberModel.fromJson(rawMember);
        if (parsedMember.memberId.isNotEmpty) {
          groupMember = parsedMember;
        }
      } else if (effectiveType == groupMemberLeft) {
        leftMemberId = _parseOptionalString(
          map['memberId'] ?? map['member_id'],
        );
      }

      return TrailLiveSseEvent(
        type: effectiveType,
        eventId: _parseOptionalString(eventId),
        report: report,
        sos: sos,
        groupMember: groupMember,
        leftMemberId: leftMemberId,
        groupCode: groupCode,
        raw: map,
      );
    } catch (_) {
      return null;
    }
  }
}
