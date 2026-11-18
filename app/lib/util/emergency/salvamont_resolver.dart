import 'dart:math' as math;

import 'package:wanderer/models/emergency/salvamont_models.dart';

class ResolvedSalvamontPoint {
  const ResolvedSalvamontPoint({
    required this.point,
    required this.service,
    required this.backupCountyService,
    required this.effectivePhone,
    required this.distanceM,
    required this.bearingDeg,
    required this.cardinal,
    required this.deltaEleM,
  });

  final SalvamontPoint point;
  final SalvamontService service;
  final SalvamontService? backupCountyService;
  final String effectivePhone;
  final double distanceM;
  final double bearingDeg;
  final String cardinal;
  final int? deltaEleM;
}

class ResolvedSalvamontService {
  const ResolvedSalvamontService({
    required this.service,
    required this.nearestPoint,
    required this.distanceM,
  });

  final SalvamontService service;
  final SalvamontPoint nearestPoint;
  final double distanceM;
}

class NearestSalvamontResolution {
  const NearestSalvamontResolution({
    required this.emergency112,
    required this.nationalDispatchPhone,
    required this.nationalDispatchLabel,
    required this.isMountainZone,
    required this.isRidgeBorderZone,
    required this.borderCountyCodes,
    required this.nearestBases,
    required this.nearestRefuge,
    required this.activeServices,
    required this.isTrailRef,
  });

  final String emergency112;
  final String nationalDispatchPhone;
  final String nationalDispatchLabel;
  final bool isMountainZone;
  final bool isRidgeBorderZone;
  final List<String> borderCountyCodes;
  final List<ResolvedSalvamontPoint> nearestBases;
  final ResolvedSalvamontPoint? nearestRefuge;
  final List<ResolvedSalvamontService> activeServices;
  final bool isTrailRef;
}

class TrailSalvamontSummary {
  const TrailSalvamontSummary({
    required this.nearestBase,
    required this.nearestRefuge,
    required this.services,
    required this.isRidgeBorderTrail,
    required this.countyCodes,
  });

  final ResolvedSalvamontPoint nearestBase;
  final ResolvedSalvamontPoint? nearestRefuge;
  final List<ResolvedSalvamontService> services;
  final bool isRidgeBorderTrail;
  final List<String> countyCodes;

  bool get isMountainZone => true;
  bool get crossesCountyBorder => countyCodes.length >= 2;
}

const double _kMaxMountainZoneM = 35000.0;
const double _kMaxRefugeRadiusM = 15000.0;
const double _kBorderDeltaM = 3500.0;
const double _kBorderRatio = 1.35;
const double _kBorderMaxDistM = 12000.0;

String formatRoPhoneDisplay(String e164) {
  if (e164.startsWith('+40') && e164.length == 12) {
    final local = '0${e164.substring(3)}';
    return '${local.substring(0, 4)} ${local.substring(4, 7)} ${local.substring(7)}';
  }
  return e164;
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dp = (lat2 - lat1) * math.pi / 180.0;
  final dl = (lon2 - lon1) * math.pi / 180.0;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2.0 * r * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
}

double _bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dl = (lon2 - lon1) * math.pi / 180.0;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}

String _cardinal(double bearing, {required bool isRo}) {
  const ro = ['N', 'NE', 'E', 'SE', 'S', 'SV', 'V', 'NV'];
  const en = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final idx = ((bearing + 22.5) % 360.0) ~/ 45;
  return (isRo ? ro : en)[idx.clamp(0, 7)];
}

NearestSalvamontResolution resolveNearestSalvamont(
  SalvamontDataset dataset,
  double lat,
  double lon, {
  int k = 3,
  double? userEle,
  String localeCode = 'ro',
  bool isTrailRef = false,
}) {
  final isRo = localeCode.toLowerCase().startsWith('ro');
  if (!lat.isFinite || !lon.isFinite) {
    return NearestSalvamontResolution(
      emergency112: dataset.emergency112,
      nationalDispatchPhone: dataset.nationalDispatchPhone,
      nationalDispatchLabel: dataset.nationalDispatchLabel,
      isMountainZone: false,
      isRidgeBorderZone: false,
      borderCountyCodes: const [],
      nearestBases: const [],
      nearestRefuge: null,
      activeServices: const [],
      isTrailRef: isTrailRef,
    );
  }

  final operational = <ResolvedSalvamontPoint>[];
  final refuges = <ResolvedSalvamontPoint>[];

  for (final pt in dataset.points) {
    final svc = dataset.services[pt.serviceId];
    if (svc == null) continue;
    final backup = pt.backupCountyServiceId != null
        ? dataset.services[pt.backupCountyServiceId!]
        : null;
    final distM = _haversineM(lat, lon, pt.lat, pt.lon);
    final brg = _bearingDeg(lat, lon, pt.lat, pt.lon);
    final deltaEle = (userEle != null && userEle.isFinite && pt.ele > 0)
        ? (pt.ele - userEle).round()
        : null;

    final item = ResolvedSalvamontPoint(
      point: pt,
      service: svc,
      backupCountyService: backup,
      effectivePhone: pt.directBasePhone ?? svc.primaryPhone,
      distanceM: distM,
      bearingDeg: brg,
      cardinal: _cardinal(brg, isRo: isRo),
      deltaEleM: deltaEle,
    );

    if (pt.isRefuge) {
      refuges.add(item);
    } else {
      operational.add(item);
    }
  }

  operational.sort((a, b) => a.distanceM.compareTo(b.distanceM));
  refuges.sort((a, b) => a.distanceM.compareTo(b.distanceM));

  final primary = operational.firstOrNull;
  final isMountainZone =
      primary != null && primary.distanceM <= _kMaxMountainZoneM;
  final nearestBases = isMountainZone
      ? operational.take(math.max(1, k)).toList()
      : const <ResolvedSalvamontPoint>[];
  final nearestRefuge =
      (refuges.isNotEmpty && refuges.first.distanceM <= _kMaxRefugeRadiusM)
      ? refuges.first
      : null;

  final activeServices = <ResolvedSalvamontService>[];
  if (isMountainZone && primary != null) {
    final d1 = math.max(1.0, primary.distanceM);
    final seen = <String>{primary.service.id};
    activeServices.add(
      ResolvedSalvamontService(
        service: primary.service,
        nearestPoint: primary.point,
        distanceM: primary.distanceM,
      ),
    );
    for (final cand in operational.skip(1)) {
      if (cand.service.level == 'gendarmerie_info') continue;
      if (seen.contains(cand.service.id)) continue;
      final inBorder =
          (cand.distanceM - primary.distanceM <= _kBorderDeltaM) ||
          (cand.distanceM / d1 <= _kBorderRatio &&
              cand.distanceM <= _kBorderMaxDistM);
      if (inBorder) {
        seen.add(cand.service.id);
        activeServices.add(
          ResolvedSalvamontService(
            service: cand.service,
            nearestPoint: cand.point,
            distanceM: cand.distanceM,
          ),
        );
        if (activeServices.length >= 3) break;
      }
    }
  }

  final borderCounties = activeServices
      .map((s) => s.service.countyCode)
      .toSet()
      .toList();

  return NearestSalvamontResolution(
    emergency112: dataset.emergency112,
    nationalDispatchPhone: dataset.nationalDispatchPhone,
    nationalDispatchLabel: dataset.nationalDispatchLabel,
    isMountainZone: isMountainZone,
    isRidgeBorderZone: activeServices.length >= 2,
    borderCountyCodes: borderCounties,
    nearestBases: nearestBases,
    nearestRefuge: nearestRefuge,
    activeServices: activeServices,
    isTrailRef: isTrailRef,
  );
}

TrailSalvamontSummary? resolveTrailSalvamontSummary(
  SalvamontDataset dataset,
  List<({double lat, double lon, double? ele})> points, {
  String localeCode = 'ro',
}) {
  if (points.isEmpty) return null;
  final start = points.first;
  final mid = points[points.length ~/ 2];
  var highest = points.first;
  for (final p in points) {
    if ((p.ele ?? double.negativeInfinity) >
        (highest.ele ?? double.negativeInfinity)) {
      highest = p;
    }
  }

  final anchors = [start, mid, highest, points.last];
  ResolvedSalvamontPoint? bestBase;
  ResolvedSalvamontPoint? bestRefuge;
  final serviceMap = <String, ResolvedSalvamontService>{};

  for (final a in anchors) {
    final r = resolveNearestSalvamont(
      dataset,
      a.lat,
      a.lon,
      userEle: a.ele,
      localeCode: localeCode,
      isTrailRef: true,
    );
    if (!r.isMountainZone) continue;
    if (r.nearestBases.isNotEmpty &&
        (bestBase == null ||
            r.nearestBases.first.distanceM < bestBase.distanceM)) {
      bestBase = r.nearestBases.first;
    }
    if (r.nearestRefuge != null &&
        (bestRefuge == null ||
            r.nearestRefuge!.distanceM < bestRefuge.distanceM)) {
      bestRefuge = r.nearestRefuge;
    }
    for (final s in r.activeServices) {
      final prev = serviceMap[s.service.id];
      if (prev == null || s.distanceM < prev.distanceM) {
        serviceMap[s.service.id] = s;
      }
    }
  }

  if (bestBase == null) return null;
  final sortedServices = serviceMap.values.toList()
    ..sort((a, b) => a.distanceM.compareTo(b.distanceM));
  final topServices = sortedServices.take(3).toList();
  final countyCodes = topServices
      .map((s) => s.service.countyCode)
      .toSet()
      .toList();

  return TrailSalvamontSummary(
    nearestBase: bestBase,
    nearestRefuge: bestRefuge,
    services: topServices,
    isRidgeBorderTrail: topServices.length >= 2,
    countyCodes: countyCodes,
  );
}
