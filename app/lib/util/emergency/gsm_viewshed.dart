import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre/maplibre.dart' show Geographic;
import 'package:wanderer/util/navigation/dem_tile_grid.dart';

const double _rEarthM = 6371000.0;
const double _rEff43M = (4.0 / 3.0) * _rEarthM;
const double _gsmWavelengthM = 0.353;
const double _userHandAntennaM = 1.7;
const double _maxTowerSearchM = 30000.0;
const double _maxSafeSlopeRatio = 0.70;

enum GsmLosClass { clearLos, grazingLos, diffracted, blocked }

enum GsmSignalStatus { alreadyLos, climbRecommended, noLosWithin400m }

class CellTowerEntry {
  const CellTowerEntry({
    required this.lat,
    required this.lon,
    required this.groundEleM,
    required this.mastHeightM,
    required this.carrierMask,
    required this.isOsm,
  });

  final double lat;
  final double lon;
  final int groundEleM;
  final int mastHeightM;
  final int carrierMask;
  final bool isOsm;
}

class LandmarkEntry {
  const LandmarkEntry({
    required this.lat,
    required this.lon,
    required this.eleM,
    required this.kind,
    required this.name,
  });

  final double lat;
  final double lon;
  final int eleM;
  final int kind;
  final String name;
}

class GsmSignalRecommendation {
  const GsmSignalRecommendation({
    required this.status,
    required this.targetLat,
    required this.targetLon,
    required this.walkDistanceM,
    required this.ascentM,
    required this.estimatedWalkMinutes,
    required this.bearingDeg,
    required this.cardinalRo,
    required this.onTrail,
    required this.reachableTowerCount,
    required this.nearestTowerDistanceKm,
    required this.losQuality,
    required this.instructionRo,
  });

  final GsmSignalStatus status;
  final double targetLat;
  final double targetLon;
  final int walkDistanceM;
  final int ascentM;
  final int estimatedWalkMinutes;
  final double bearingDeg;
  final String cardinalRo;
  final bool onTrail;
  final int reachableTowerCount;
  final double nearestTowerDistanceKm;
  final GsmLosClass losQuality;
  final String instructionRo;
}

double _toRad(double d) => d * math.pi / 180.0;

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(_toRad(lat1)) *
          math.cos(_toRad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 *
      _rEarthM *
      math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
}

double _bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _toRad(lat1);
  final p2 = _toRad(lat2);
  final dl = _toRad(lon2 - lon1);
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return ((math.atan2(y, x) * 180.0 / math.pi) + 360.0) % 360.0;
}

String _cardinal8Ro(double deg) {
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SV', 'V', 'NV'];
  return dirs[((((deg % 360.0) + 360.0) % 360.0) / 45.0).round() % 8];
}

({double lat, double lon}) _destinationPoint(
  double lat,
  double lon,
  double distM,
  double azDeg,
) {
  final ang = distM / _rEarthM;
  final br = _toRad(azDeg);
  final p1 = _toRad(lat);
  final l1 = _toRad(lon);
  final p2 = math.asin(
    math.sin(p1) * math.cos(ang) +
        math.cos(p1) * math.sin(ang) * math.cos(br),
  );
  final l2 =
      l1 +
      math.atan2(
        math.sin(br) * math.sin(ang) * math.cos(p1),
        math.cos(ang) - math.sin(p1) * math.sin(p2),
      );
  return (lat: p2 * 180.0 / math.pi, lon: l2 * 180.0 / math.pi);
}

double _toblerSeconds(double distM, double deltaEleM) {
  if (distM <= 1.0) return 0.0;
  final slope = deltaEleM / distM;
  final speedKmh = math.max(0.8, 6.0 * math.exp(-3.5 * (slope + 0.05).abs()));
  return distM / (speedKmh / 3.6);
}

class EmergencySpatialIndex {
  EmergencySpatialIndex._(this.towers, this.landmarks) {
    for (final t in towers) {
      (_towerBuckets[_cellKey(t.lat, t.lon)] ??= <CellTowerEntry>[]).add(t);
    }
    for (final lm in landmarks) {
      (_landmarkBuckets[_cellKey(lm.lat, lm.lon)] ??= <LandmarkEntry>[]).add(
        lm,
      );
    }
  }

  final List<CellTowerEntry> towers;
  final List<LandmarkEntry> landmarks;
  final Map<int, List<CellTowerEntry>> _towerBuckets =
      <int, List<CellTowerEntry>>{};
  final Map<int, List<LandmarkEntry>> _landmarkBuckets =
      <int, List<LandmarkEntry>>{};

  static Future<EmergencySpatialIndex>? _cachedAssetFuture;

  static int _cellKey(double lat, double lon) =>
      (lat * 10.0).floor() * 100000 + (lon * 10.0).floor();

  factory EmergencySpatialIndex.fromJson(Map<String, dynamic> json) {
    final rawTowers = json['towers'];
    final towers = <CellTowerEntry>[];
    if (rawTowers is List) {
      for (final row in rawTowers) {
        if (row is List && row.length >= 6) {
          towers.add(
            CellTowerEntry(
              lat: (row[0] as num).toDouble() / 1e5,
              lon: (row[1] as num).toDouble() / 1e5,
              groundEleM: (row[2] as num).toInt(),
              mastHeightM: (row[3] as num).toInt(),
              carrierMask: (row[4] as num).toInt(),
              isOsm: (row[5] as num).toInt() == 1,
            ),
          );
        }
      }
    }

    final rawPeaks = json['peaks'];
    final landmarks = <LandmarkEntry>[];
    if (rawPeaks is List) {
      for (final row in rawPeaks) {
        if (row is List && row.length >= 5) {
          landmarks.add(
            LandmarkEntry(
              lat: (row[0] as num).toDouble() / 1e5,
              lon: (row[1] as num).toDouble() / 1e5,
              eleM: (row[2] as num).toInt(),
              kind: (row[3] as num).toInt(),
              name: row[4].toString(),
            ),
          );
        }
      }
    }

    return EmergencySpatialIndex._(towers, landmarks);
  }

  static Future<EmergencySpatialIndex> loadFromAsset() {
    return _cachedAssetFuture ??= () async {
      try {
        final raw = await rootBundle.loadString(
          'assets/data/romania_emergency_112.json',
        );
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return EmergencySpatialIndex.fromJson(decoded);
        }
      } catch (_) {}
      return EmergencySpatialIndex.fromJson(const <String, dynamic>{});
    }();
  }

  List<CellTowerEntry> findTowersWithin(
    double lat,
    double lon, {
    double radiusM = _maxTowerSearchM,
  }) {
    final dLat = ((radiusM / 111320.0) * 10.0).ceil();
    final dLon =
        ((radiusM / (111320.0 * math.max(0.2, math.cos(_toRad(lat))))) * 10.0)
            .ceil();
    final bLat = (lat * 10.0).floor();
    final bLon = (lon * 10.0).floor();

    final matches = <({CellTowerEntry tower, double distM})>[];
    for (var gy = bLat - dLat; gy <= bLat + dLat; gy++) {
      for (var gx = bLon - dLon; gx <= bLon + dLon; gx++) {
        final bucket = _towerBuckets[gy * 100000 + gx];
        if (bucket == null) continue;
        for (final t in bucket) {
          final d = _haversineM(lat, lon, t.lat, t.lon);
          if (d <= radiusM) matches.add((tower: t, distM: d));
        }
      }
    }
    matches.sort((a, b) => a.distM.compareTo(b.distM));
    return matches.take(16).map((m) => m.tower).toList(growable: false);
  }

  LandmarkEntry? findNearestLandmark(
    double lat,
    double lon, {
    double maxRadiusM = 15000.0,
  }) {
    final dLat = ((maxRadiusM / 111320.0) * 10.0).ceil();
    final dLon =
        ((maxRadiusM / (111320.0 * math.max(0.2, math.cos(_toRad(lat))))) *
                10.0)
            .ceil();
    final bLat = (lat * 10.0).floor();
    final bLon = (lon * 10.0).floor();

    LandmarkEntry? best;
    var bestDist = maxRadiusM;
    for (var gy = bLat - dLat; gy <= bLat + dLat; gy++) {
      for (var gx = bLon - dLon; gx <= bLon + dLon; gx++) {
        final bucket = _landmarkBuckets[gy * 100000 + gx];
        if (bucket == null) continue;
        for (final lm in bucket) {
          final d = _haversineM(lat, lon, lm.lat, lm.lon);
          if (d < bestDist) {
            bestDist = d;
            best = lm;
          }
        }
      }
    }
    return best;
  }
}

({GsmLosClass losClass, double distanceM, double bearingDeg}) evaluateTowerLos({
  required double userLat,
  required double userLon,
  required double userGroundEleM,
  required CellTowerEntry tower,
  required DemTileGrid dem,
}) {
  final distM = _haversineM(userLat, userLon, tower.lat, tower.lon);
  final az = _bearingDeg(userLat, userLon, tower.lat, tower.lon);
  if (distM < 60.0) {
    return (losClass: GsmLosClass.clearLos, distanceM: distM, bearingDeg: az);
  }

  final h0 = userGroundEleM + _userHandAntennaM;
  final towerGround =
      dem.sampleElevation(tower.lat, tower.lon) ?? tower.groundEleM.toDouble();
  final hT = towerGround + tower.mastHeightM;

  var minClearanceM = double.infinity;
  var minFresnelMarginM = double.infinity;
  var maxNu = double.negativeInfinity;

  var d = 40.0;
  while (d < distM - 30.0) {
    final t = d / distM;
    final sLat = userLat + (tower.lat - userLat) * t;
    final sLon = userLon + (tower.lon - userLon) * t;
    final zTer = dem.sampleElevation(sLat, sLon);
    if (zTer != null && zTer.isFinite) {
      final bulge = (d * (distM - d)) / (2.0 * _rEff43M);
      final hRay = h0 + t * (hT - h0) - bulge;
      final clearance = hRay - zTer;
      final rF1 = math.sqrt((_gsmWavelengthM * d * (distM - d)) / distM);
      final nu = -math.sqrt2 * (clearance / math.max(0.5, rF1));

      if (clearance < minClearanceM) minClearanceM = clearance;
      if (clearance - 0.6 * rF1 < minFresnelMarginM) {
        minFresnelMarginM = clearance - 0.6 * rF1;
      }
      if (nu > maxNu) maxNu = nu;

      if (clearance < -25.0 && nu > 2.2) {
        return (
          losClass: GsmLosClass.blocked,
          distanceM: distM,
          bearingDeg: az,
        );
      }
    }
    d += d < 4000.0 ? 40.0 : 120.0;
  }

  if (minFresnelMarginM >= 0.0) {
    return (losClass: GsmLosClass.clearLos, distanceM: distM, bearingDeg: az);
  }
  if (minClearanceM >= 0.0) {
    return (
      losClass: GsmLosClass.grazingLos,
      distanceM: distM,
      bearingDeg: az,
    );
  }
  if (minClearanceM >= -12.0 && maxNu <= 1.2) {
    return (
      losClass: GsmLosClass.diffracted,
      distanceM: distM,
      bearingDeg: az,
    );
  }
  return (losClass: GsmLosClass.blocked, distanceM: distM, bearingDeg: az);
}

GsmSignalRecommendation findBestGsm112SignalSpot({
  required double lat,
  required double lon,
  required DemTileGrid dem,
  required EmergencySpatialIndex index,
  List<Geographic> trailPoints = const <Geographic>[],
}) {
  final towers = index
      .findTowersWithin(lat, lon)
      .take(12)
      .toList(growable: false);
  final userEle = dem.sampleElevation(lat, lon) ?? 1200.0;

  if (towers.isEmpty) {
    return GsmSignalRecommendation(
      status: GsmSignalStatus.noLosWithin400m,
      targetLat: lat,
      targetLon: lon,
      walkDistanceM: 0,
      ascentM: 0,
      estimatedWalkMinutes: 0,
      bearingDeg: 0,
      cardinalRo: 'N',
      onTrail: false,
      reachableTowerCount: 0,
      nearestTowerDistanceKm: 0,
      losQuality: GsmLosClass.blocked,
      instructionRo:
          'Niciun releu GSM pe o rază de 30 km. Urcă spre creastă deschisă și formează 112.',
    );
  }

  ({
    int losCount,
    GsmLosClass bestClass,
    double nearestDistM,
    double nearestAz,
  })
  evalSpot(double sLat, double sLon, double sEle) {
    var losCount = 0;
    var bestClass = GsmLosClass.blocked;
    var nearestDistM = double.infinity;
    var nearestAz = 0.0;
    for (final t in towers) {
      final res = evaluateTowerLos(
        userLat: sLat,
        userLon: sLon,
        userGroundEleM: sEle,
        tower: t,
        dem: dem,
      );
      if (res.losClass == GsmLosClass.clearLos ||
          res.losClass == GsmLosClass.grazingLos) {
        losCount++;
        if (res.losClass == GsmLosClass.clearLos ||
            bestClass != GsmLosClass.clearLos) {
          bestClass = res.losClass;
        }
        if (res.distanceM < nearestDistM) {
          nearestDistM = res.distanceM;
          nearestAz = res.bearingDeg;
        }
      }
    }
    return (
      losCount: losCount,
      bestClass: bestClass,
      nearestDistM: nearestDistM,
      nearestAz: nearestAz,
    );
  }

  final here = evalSpot(lat, lon, userEle);
  if (here.losCount > 0) {
    final km = double.parse((here.nearestDistM / 1000.0).toStringAsFixed(1));
    final dir = _cardinal8Ro(here.nearestAz);
    return GsmSignalRecommendation(
      status: GsmSignalStatus.alreadyLos,
      targetLat: lat,
      targetLon: lon,
      walkDistanceM: 0,
      ascentM: 0,
      estimatedWalkMinutes: 0,
      bearingDeg: here.nearestAz,
      cardinalRo: dir,
      onTrail: true,
      reachableTowerCount: here.losCount,
      nearestTowerDistanceKm: km,
      losQuality: here.bestClass,
      instructionRo:
          'Ai deja linie vizuală spre ${here.losCount == 1 ? 'un releu GSM' : '${here.losCount} relee GSM'} ($km km $dir). Ridică telefonul și sună la 112.',
    );
  }

  final candidates = <({double lat, double lon, bool onTrail})>[];
  for (final pt in trailPoints) {
    final d = _haversineM(lat, lon, pt.lat, pt.lon);
    if (d >= 40.0 && d <= 400.0) {
      candidates.add((lat: pt.lat, lon: pt.lon, onTrail: true));
    }
  }
  for (final r in const [
    50.0,
    100.0,
    150.0,
    200.0,
    250.0,
    300.0,
    350.0,
    400.0,
  ]) {
    for (var az = 0.0; az < 360.0; az += 22.5) {
      final dest = _destinationPoint(lat, lon, r, az);
      candidates.add((lat: dest.lat, lon: dest.lon, onTrail: false));
    }
  }

  double? bestCost;
  GsmSignalRecommendation? bestRec;

  for (final cand in candidates) {
    final totalDist = _haversineM(lat, lon, cand.lat, cand.lon);
    final targetEle = dem.sampleElevation(cand.lat, cand.lon);
    if (targetEle == null ||
        !targetEle.isFinite ||
        targetEle < userEle - 15.0) {
      continue;
    }

    final steps = math.max(1, (totalDist / 35.0).ceil());
    var prevEle = userEle;
    var safe = true;
    final stepDist = totalDist / steps;
    for (var i = 1; i <= steps; i++) {
      final f = i / steps;
      final e = dem.sampleElevation(
        lat + (cand.lat - lat) * f,
        lon + (cand.lon - lon) * f,
      );
      if (e == null ||
          (e - prevEle).abs() / math.max(10.0, stepDist) > _maxSafeSlopeRatio) {
        safe = false;
        break;
      }
      prevEle = e;
    }
    if (!safe) continue;

    final spot = evalSpot(cand.lat, cand.lon, targetEle);
    if (spot.losCount == 0) continue;

    final ascentM = math.max(0.0, targetEle - userEle);
    final walkSec = _toblerSeconds(totalDist, targetEle - userEle);
    final cost =
        walkSec * (cand.onTrail ? 0.75 : 1.0) -
        (spot.bestClass == GsmLosClass.clearLos ? 15.0 : 0.0);

    if (bestCost == null || cost < bestCost) {
      bestCost = cost;
      final moveAz = _bearingDeg(lat, lon, cand.lat, cand.lon);
      final moveDir = _cardinal8Ro(moveAz);
      final towerKm = double.parse(
        (spot.nearestDistM / 1000.0).toStringAsFixed(1),
      );
      final towerDir = _cardinal8Ro(spot.nearestAz);
      final walkM = totalDist.round();
      final climbRound = ascentM.round();
      final walkMin = math.max(1, (walkSec / 60.0).round());
      final whereLabel = cand.onTrail ? 'pe potecă' : 'în amonte';

      bestRec = GsmSignalRecommendation(
        status: GsmSignalStatus.climbRecommended,
        targetLat: cand.lat,
        targetLon: cand.lon,
        walkDistanceM: walkM,
        ascentM: climbRound,
        estimatedWalkMinutes: walkMin,
        bearingDeg: moveAz,
        cardinalRo: moveDir,
        onTrail: cand.onTrail,
        reachableTowerCount: spot.losCount,
        nearestTowerDistanceKm: towerKm,
        losQuality: spot.bestClass,
        instructionRo:
            'Urcă $walkM m $whereLabel spre $moveDir (+$climbRound m, ~$walkMin min) pentru linie vizuală către ${spot.losCount == 1 ? '1 releu GSM' : '${spot.losCount} relee GSM'} ($towerKm km $towerDir).',
      );
    }
  }

  return bestRec ??
      GsmSignalRecommendation(
        status: GsmSignalStatus.noLosWithin400m,
        targetLat: lat,
        targetLon: lon,
        walkDistanceM: 0,
        ascentM: 0,
        estimatedWalkMinutes: 0,
        bearingDeg: _bearingDeg(lat, lon, towers.first.lat, towers.first.lon),
        cardinalRo: _cardinal8Ro(
          _bearingDeg(lat, lon, towers.first.lat, towers.first.lon),
        ),
        onTrail: false,
        reachableTowerCount: 0,
        nearestTowerDistanceKm: double.parse(
          (_haversineM(lat, lon, towers.first.lat, towers.first.lon) / 1000.0)
              .toStringAsFixed(1),
        ),
        losQuality: GsmLosClass.blocked,
        instructionRo:
            'Vale adâncă fără linie vizuală în primii 400 m. Urcă pe poteca marcată spre creastă/șa deschisă.',
      );
}
