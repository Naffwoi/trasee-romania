import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:maplibre/maplibre.dart' show Geographic, SphericalGreatCircle;
import 'package:wanderer/util/map/heading_math.dart' show shortestAngleDelta;
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart'
    show bearingDegrees, cardinalDirection;
import 'package:wanderer/util/navigation/ridge_sunset_calculator.dart'
    show kCurvatureRefractionCoeff, kEarthRadiusM;

const double _degToRad = math.pi / 180.0;
const double _radToDeg = 180.0 / math.pi;
const double _eyeHeightM = 1.7;

enum PeakVisibility { visible, unverified }

class PeakEntryModel {
  const PeakEntryModel({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.ele,
    required this.prominenceM,
    required this.kind,
  });

  final int id;
  final String name;
  final double lat;
  final double lon;
  final int ele;
  final int prominenceM;
  final String kind;
}

class VisiblePeakResult {
  const VisiblePeakResult({
    required this.peak,
    required this.distanceM,
    required this.bearingDeg,
    required this.cardinal,
    required this.elevationAngleDeg,
    required this.visibility,
    required this.score,
    required this.tier,
  });

  final PeakEntryModel peak;
  final double distanceM;
  final double bearingDeg;
  final String cardinal;
  final double elevationAngleDeg;
  final PeakVisibility visibility;
  final double score;
  final int tier;
}

class HorizonPanorama {
  const HorizonPanorama({
    required this.observerLat,
    required this.observerLon,
    required this.observerEleM,
    required this.standingOnPeak,
    required this.nearDeg,
    required this.midDeg,
    required this.farDeg,
    required this.visiblePeaks,
  });

  final double observerLat;
  final double observerLon;
  final double observerEleM;
  final PeakEntryModel? standingOnPeak;
  final Float32List nearDeg;
  final Float32List midDeg;
  final Float32List farDeg;
  final List<VisiblePeakResult> visiblePeaks;
}

class OfflinePeakFinder {
  OfflinePeakFinder();

  factory OfflinePeakFinder.fromPeaks(List<PeakEntryModel> peaks) {
    final inst = OfflinePeakFinder()..ingestPeaks(peaks);
    inst._assetLoaded = true;
    return inst;
  }

  final Map<(int, int), List<PeakEntryModel>> _buckets = {};
  final Set<int> _seenIds = {};
  bool _assetLoaded = false;

  void ingestPeaks(Iterable<PeakEntryModel> peaks) {
    for (final p in peaks) {
      if (!_seenIds.add(p.id)) continue;
      final key = ((p.lat * 10.0).floor(), (p.lon * 10.0).floor());
      (_buckets[key] ??= <PeakEntryModel>[]).add(p);
    }
  }

  Future<void> ensureLoaded() async {
    if (_assetLoaded) return;
    try {
      final raw = await rootBundle.loadString(
        'assets/data/romania_peaks_v1.json',
      );
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final count = decoded['count'] as int? ?? 0;
      final ids = decoded['ids'] as List<dynamic>;
      final names = decoded['names'] as List<dynamic>;
      final lats = decoded['lats'] as List<dynamic>;
      final lons = decoded['lons'] as List<dynamic>;
      final eles = decoded['eles'] as List<dynamic>;
      final proms = decoded['prominences'] as List<dynamic>?;
      final kinds = decoded['kinds'] as List<dynamic>?;

      final parsed = <PeakEntryModel>[];
      for (var i = 0; i < count; i++) {
        parsed.add(
          PeakEntryModel(
            id: (ids[i] as num).toInt(),
            name: names[i] as String,
            lat: (lats[i] as num).toDouble(),
            lon: (lons[i] as num).toDouble(),
            ele: (eles[i] as num).toInt(),
            prominenceM: proms != null ? (proms[i] as num).toInt() : 100,
            kind: kinds != null ? (kinds[i] as String) : 'peak',
          ),
        );
      }
      ingestPeaks(parsed);
      _assetLoaded = true;
    } catch (_) {
      // Degrade gracefully in unit tests without asset bundle
    }
  }

  List<PeakEntryModel> queryWithinRadius(
    double lat,
    double lon, {
    double maxRadiusM = 35000.0,
  }) {
    final dLat = maxRadiusM / 111320.0;
    final dLon =
        maxRadiusM / (111320.0 * math.max(0.1, math.cos(lat * _degToRad)));
    final origin = SphericalGreatCircle(Geographic(lat: lat, lon: lon));
    final out = <PeakEntryModel>[];
    for (var li = ((lat - dLat) * 10).floor();
        li <= ((lat + dLat) * 10).floor();
        li++) {
      for (var lj = ((lon - dLon) * 10).floor();
          lj <= ((lon + dLon) * 10).floor();
          lj++) {
        final bucket = _buckets[(li, lj)];
        if (bucket == null) continue;
        for (final p in bucket) {
          final d = origin.distanceTo(Geographic(lat: p.lat, lon: p.lon));
          if (d.isFinite && d <= maxRadiusM) out.add(p);
        }
      }
    }
    return out;
  }

  HorizonPanorama computePanorama(
    DemTileGrid dem,
    double lat,
    double lon,
    double? eleM, {
    String localeCode = 'ro',
    double maxRadiusM = 35000.0,
  }) {
    final demEle = dem.sampleElevation(lat, lon);
    final groundEle = eleM != null && eleM.isFinite
        ? (demEle != null ? math.max(eleM, demEle) : eleM)
        : (demEle ?? 0.0);
    final observerH = groundEle + _eyeHeightM;

    const bins = 720;
    final nearDeg = Float32List(bins);
    final midDeg = Float32List(bins);
    final farDeg = Float32List(bins);

    const metersPerDegLat = _degToRad * kEarthRadiusM;
    final metersPerDegLon =
        metersPerDegLat * math.max(0.05, math.cos(lat * _degToRad));

    for (var b = 0; b < bins; b++) {
      final azRad = b * 0.5 * _degToRad;
      final dirE = math.sin(azRad);
      final dirN = math.cos(azRad);
      var maxNear = -15.0;
      var maxMid = -15.0;
      var maxFar = -15.0;
      var d = 60.0;
      while (d <= maxRadiusM) {
        final z = dem.sampleElevation(
          lat + (dirN * d) / metersPerDegLat,
          lon + (dirE * d) / metersPerDegLon,
        );
        if (z != null) {
          final effZ = z - kCurvatureRefractionCoeff * d * d;
          final ang = math.atan2(effZ - observerH, d) * _radToDeg;
          if (d <= 4000.0 && ang > maxNear) maxNear = ang;
          if (d <= 12000.0 && ang > maxMid) maxMid = ang;
          if (ang > maxFar) maxFar = ang;
        }
        d += d < 2000.0 ? 50.0 : (d < 10000.0 ? 120.0 : 250.0);
      }
      nearDeg[b] = maxNear;
      midDeg[b] = math.max(maxNear, maxMid);
      farDeg[b] = math.max(midDeg[b], maxFar);
    }

    final origin = SphericalGreatCircle(Geographic(lat: lat, lon: lon));
    PeakEntryModel? standingOnPeak;
    final visible = <VisiblePeakResult>[];

    for (final p in queryWithinRadius(lat, lon, maxRadiusM: maxRadiusM)) {
      final distM = origin.distanceTo(Geographic(lat: p.lat, lon: p.lon));
      if (distM < 35.0) {
        if (standingOnPeak == null || p.ele > standingOnPeak.ele) {
          standingOnPeak = p;
        }
        continue;
      }

      final brg = bearingDegrees(lat, lon, p.lat, p.lon);
      final azRad = brg * _degToRad;
      final dirE = math.sin(azRad);
      final dirN = math.cos(azRad);
      final effPeakZ = p.ele - kCurvatureRefractionCoeff * distM * distM;
      final peakAngleDeg = math.atan2(effPeakZ - observerH, distM) * _radToDeg;
      final graceDeg = math.atan2(8.0, distM) * _radToDeg;

      var occluded = false;
      var anyDem = false;
      var s = 40.0;
      final stopDist = math.max(
        0.0,
        distM - math.min(350.0, math.max(120.0, distM * 0.085)),
      );
      while (s < stopDist) {
        final z = dem.sampleElevation(
          lat + (dirN * s) / metersPerDegLat,
          lon + (dirE * s) / metersPerDegLon,
        );
        if (z != null) {
          anyDem = true;
          final effZ = z - kCurvatureRefractionCoeff * s * s;
          final terrainAng = math.atan2(effZ - observerH, s) * _radToDeg;
          if (terrainAng > peakAngleDeg + graceDeg) {
            occluded = true;
            break;
          }
        }
        s += s < 1500.0 ? 35.0 : (s < 8000.0 ? 80.0 : 180.0);
      }
      if (occluded) continue;

      final score =
          p.prominenceM * 2.0 + p.ele * 0.35 - (distM / 1000.0) * 8.0;
      visible.add(
        VisiblePeakResult(
          peak: p,
          distanceM: distM,
          bearingDeg: brg,
          cardinal: cardinalDirection(brg, localeCode: localeCode),
          elevationAngleDeg: peakAngleDeg,
          visibility: anyDem || distM <= 125.0
              ? PeakVisibility.visible
              : PeakVisibility.unverified,
          score: score,
          tier: 0,
        ),
      );
    }

    visible.sort((a, b) => b.score.compareTo(a.score));
    return HorizonPanorama(
      observerLat: lat,
      observerLon: lon,
      observerEleM: groundEle,
      standingOnPeak: standingOnPeak,
      nearDeg: nearDeg,
      midDeg: midDeg,
      farDeg: farDeg,
      visiblePeaks: visible,
    );
  }

  List<VisiblePeakResult> selectViewportPeaks(
    HorizonPanorama panorama,
    double headingDeg, {
    double fovDeg = 90.0,
    int maxLabels = 8,
  }) {
    final halfFov = fovDeg / 2.0;
    final chosen = <VisiblePeakResult>[];
    for (final cand in panorama.visiblePeaks) {
      if (shortestAngleDelta(headingDeg, cand.bearingDeg).abs() > halfFov) {
        continue;
      }
      var tooClose = false;
      var tier1 = false;
      for (final ex in chosen) {
        final sep = shortestAngleDelta(ex.bearingDeg, cand.bearingDeg).abs();
        if (sep < 2.75) {
          tooClose = true;
          break;
        }
        if (sep < 5.5) {
          if (ex.tier == 0 && !tier1) {
            tier1 = true;
          } else {
            tooClose = true;
            break;
          }
        }
      }
      if (!tooClose) {
        chosen.add(
          VisiblePeakResult(
            peak: cand.peak,
            distanceM: cand.distanceM,
            bearingDeg: cand.bearingDeg,
            cardinal: cand.cardinal,
            elevationAngleDeg: cand.elevationAngleDeg,
            visibility: cand.visibility,
            score: cand.score,
            tier: tier1 ? 1 : 0,
          ),
        );
        if (chosen.length >= maxLabels) break;
      }
    }
    chosen.sort(
      (a, b) => shortestAngleDelta(
        headingDeg,
        a.bearingDeg,
      ).compareTo(shortestAngleDelta(headingDeg, b.bearingDeg)),
    );
    return chosen;
  }
}
