import 'dart:math' as math;

import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/sun_calc.dart';

const double _degToRad = math.pi / 180.0;
const double _radToDeg = 180.0 / math.pi;
const double kEarthRadiusM = 6371000.0;
const double kCurvatureRefractionCoeff = (1.0 - 0.13) / (2.0 * kEarthRadiusM);
const double _eyeHeightM = 1.7;
const double _solarUpperLimbDeg = 0.266;

enum LightSafetyStatus {
  daylightSafe,
  ridgeShade,
  twilightWarning,
  nightDanger,
}

class RidgeSunsetResult {
  const RidgeSunsetResult({
    required this.ridgeSunset,
    required this.astroSunset,
    required this.civilDusk,
    required this.ridgeHorizonDeg,
    required this.minutesBeforeAstroSunset,
    required this.partialDemCoverage,
  });

  final DateTime? ridgeSunset;
  final DateTime? astroSunset;
  final DateTime? civilDusk;
  final double ridgeHorizonDeg;
  final int minutesBeforeAstroSunset;
  final bool partialDemCoverage;
}

class TrailSolarForecast {
  const TrailSolarForecast({
    required this.status,
    required this.finishRidgeSunset,
    required this.ridgeShadeAlongM,
    required this.ridgeShadeTime,
    required this.astroSunsetAlongM,
    required this.civilDuskAlongM,
    required this.nightRemainingDistanceM,
  });

  final LightSafetyStatus status;
  final RidgeSunsetResult finishRidgeSunset;
  final double? ridgeShadeAlongM;
  final DateTime? ridgeShadeTime;
  final double? astroSunsetAlongM;
  final double? civilDuskAlongM;
  final double nightRemainingDistanceM;
}

({double angleDeg, bool partialDem}) computeHorizonAngleDeg(
  DemTileGrid dem,
  double lat,
  double lon,
  double eleM,
  double azimuthDeg, {
  double maxDistM = 25000.0,
}) {
  final observerH = eleM + _eyeHeightM;
  final azRad = azimuthDeg * _degToRad;
  final dirEast = math.sin(azRad);
  final dirNorth = math.cos(azRad);
  const metersPerDegLat = _degToRad * kEarthRadiusM;
  final metersPerDegLon =
      metersPerDegLat * math.max(0.05, math.cos(lat * _degToRad));

  var maxAngleDeg = 0.0;
  var partialDem = false;
  var d = 40.0;

  while (d <= maxDistM) {
    final z = dem.sampleElevation(
      lat + (dirNorth * d) / metersPerDegLat,
      lon + (dirEast * d) / metersPerDegLon,
    );
    if (z == null) {
      partialDem = true;
    } else {
      final effZ = z - kCurvatureRefractionCoeff * d * d;
      final angle = math.atan2(effZ - observerH, d) * _radToDeg;
      if (angle > maxAngleDeg) maxAngleDeg = angle;
    }
    d += d < 1500.0 ? 25.0 : (d < 6000.0 ? 60.0 : 150.0);
  }
  return (angleDeg: maxAngleDeg, partialDem: partialDem);
}

({double marginDeg, double horizonDeg, bool partialDem, double trueAltDeg})
_sunlightMargin(
  DemTileGrid dem,
  double lat,
  double lon,
  double eleM,
  DateTime ts,
) {
  final sun = getSunPosition(ts, lat, lon);
  if (sun.trueAltitudeDeg <= -0.833) {
    return (
      marginDeg: sun.trueAltitudeDeg + 0.833,
      horizonDeg: 0.0,
      partialDem: false,
      trueAltDeg: sun.trueAltitudeDeg,
    );
  }
  final h = computeHorizonAngleDeg(dem, lat, lon, eleM, sun.azimuthDeg);
  return (
    marginDeg: sun.altitudeDeg + _solarUpperLimbDeg - h.angleDeg,
    horizonDeg: h.angleDeg,
    partialDem: h.partialDem,
    trueAltDeg: sun.trueAltitudeDeg,
  );
}

RidgeSunsetResult computeLocalRidgeSunset(
  DemTileGrid dem,
  double lat,
  double lon,
  double eleM,
  DateTime refDate,
) {
  final times = getSunTimes(refDate, lat, lon);
  final astro = times.sunset;
  if (astro == null) {
    return RidgeSunsetResult(
      ridgeSunset: null,
      astroSunset: null,
      civilDusk: times.dusk,
      ridgeHorizonDeg: 0.0,
      minutesBeforeAstroSunset: 0,
      partialDemCoverage: false,
    );
  }

  final noonMs = times.solarNoon.millisecondsSinceEpoch;
  const stepMs = 10 * 60 * 1000;
  final tHighMs = astro.millisecondsSinceEpoch + 5 * 60 * 1000;
  var evalHigh = _sunlightMargin(
    dem,
    lat,
    lon,
    eleM,
    DateTime.fromMillisecondsSinceEpoch(tHighMs, isUtc: true),
  );
  var partial = evalHigh.partialDem;

  int? bracketLo;
  var bracketHi = tHighMs;
  for (var t = tHighMs - stepMs; t >= noonMs; t -= stepMs) {
    final ev = _sunlightMargin(
      dem,
      lat,
      lon,
      eleM,
      DateTime.fromMillisecondsSinceEpoch(t, isUtc: true),
    );
    if (ev.partialDem) partial = true;
    if (ev.marginDeg > 0.0 && evalHigh.marginDeg <= 0.0) {
      bracketLo = t;
      bracketHi = t + stepMs;
      break;
    }
    evalHigh = ev;
  }

  if (bracketLo == null) {
    final noonEv = _sunlightMargin(dem, lat, lon, eleM, times.solarNoon);
    final finalDt = noonEv.marginDeg <= 0.0 ? times.solarNoon : astro;
    return RidgeSunsetResult(
      ridgeSunset: finalDt,
      astroSunset: astro,
      civilDusk: times.dusk,
      ridgeHorizonDeg: noonEv.horizonDeg,
      minutesBeforeAstroSunset: math.max(
        0,
        astro.difference(finalDt).inMinutes,
      ),
      partialDemCoverage: partial || noonEv.partialDem,
    );
  }

  var lo = bracketLo.toDouble();
  var hi = bracketHi.toDouble();
  var horizonAtSet = evalHigh.horizonDeg;
  for (var i = 0; i < 6; i++) {
    final mid = 0.5 * (lo + hi);
    final ev = _sunlightMargin(
      dem,
      lat,
      lon,
      eleM,
      DateTime.fromMillisecondsSinceEpoch(mid.round(), isUtc: true),
    );
    if (ev.partialDem) partial = true;
    if (ev.marginDeg > 0.0) {
      lo = mid;
    } else {
      hi = mid;
      horizonAtSet = ev.horizonDeg;
    }
  }

  final ridgeDt = DateTime.fromMillisecondsSinceEpoch(
    (0.5 * (lo + hi)).round(),
    isUtc: true,
  );
  return RidgeSunsetResult(
    ridgeSunset: ridgeDt,
    astroSunset: astro,
    civilDusk: times.dusk,
    ridgeHorizonDeg: horizonAtSet,
    minutesBeforeAstroSunset: math.max(0, astro.difference(ridgeDt).inMinutes),
    partialDemCoverage: partial,
  );
}

NavTrackPoint _interpolateAt(List<NavTrackPoint> pts, double distM) {
  if (distM <= pts.first.distanceM) return pts.first;
  if (distM >= pts.last.distanceM) return pts.last;
  var lo = 0;
  var hi = pts.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (pts[mid].distanceM <= distM) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = pts[lo];
  final b = pts[hi];
  final span = b.distanceM - a.distanceM;
  final t = span > 1e-6 ? ((distM - a.distanceM) / span).clamp(0.0, 1.0) : 0.0;
  return NavTrackPoint(
    lat: a.lat + (b.lat - a.lat) * t,
    lon: a.lon + (b.lon - a.lon) * t,
    ele: a.ele + (b.ele - a.ele) * t,
    distanceM: distM,
    gradePct: a.gradePct + (b.gradePct - a.gradePct) * t,
  );
}

TrailSolarForecast computeTrailSolarForecast({
  required List<NavTrackPoint> points,
  required EtaCalculator etaCalc,
  required DemTileGrid dem,
  required double alongTrackM,
  required DateTime now,
  int? offTrailDurationSec,
  double? rejoinAlongTrackM,
}) {
  if (points.isEmpty) {
    return const TrailSolarForecast(
      status: LightSafetyStatus.daylightSafe,
      finishRidgeSunset: RidgeSunsetResult(
        ridgeSunset: null,
        astroSunset: null,
        civilDusk: null,
        ridgeHorizonDeg: 0.0,
        minutesBeforeAstroSunset: 0,
        partialDemCoverage: false,
      ),
      ridgeShadeAlongM: null,
      ridgeShadeTime: null,
      astroSunsetAlongM: null,
      civilDuskAlongM: null,
      nightRemainingDistanceM: 0.0,
    );
  }

  final totalDist = points.last.distanceM;
  final finishRes = computeLocalRidgeSunset(
    dem,
    points.last.lat,
    points.last.lon,
    points.last.ele,
    now,
  );
  final anchorM = (rejoinAlongTrackM ?? alongTrackM).clamp(0.0, totalDist);
  final baseAnchor = etaCalc.baseSecondsAt(anchorM);
  final pace = etaCalc.paceFactor;
  final leadSec = math.max(0, offTrailDurationSec ?? 0);

  final remSpan = math.max(0.0, totalDist - anchorM);
  final count = ((remSpan / 500.0).ceil() + 1).clamp(2, 30);
  final stepM = count > 1 ? remSpan / (count - 1) : 0.0;

  final samples =
      <
        ({
          double d,
          DateTime ts,
          bool shade,
          bool astro,
          bool dusk,
        })
      >[];

  for (var i = 0; i < count; i++) {
    final d = i == count - 1 ? totalDist : anchorM + i * stepM;
    final pt = _interpolateAt(points, d);
    final dtSec =
        leadSec + math.max(0.0, etaCalc.baseSecondsAt(d) - baseAnchor) * pace;
    final ts = now.add(Duration(milliseconds: (dtSec * 1000.0).round()));
    final effEle = dem.sampleElevation(pt.lat, pt.lon) ?? pt.ele;
    final ev = _sunlightMargin(dem, pt.lat, pt.lon, effEle, ts);
    samples.add((
      d: d,
      ts: ts,
      shade: ev.marginDeg <= 0.0,
      astro: ev.trueAltDeg <= -0.833,
      dusk: ev.trueAltDeg <= -6.0,
    ));
  }

  var ridgeIdx = -1;
  if (samples.last.shade) {
    ridgeIdx = samples.length - 1;
    while (ridgeIdx > 0 && samples[ridgeIdx - 1].shade) {
      ridgeIdx--;
    }
  }
  final astroHit = samples.where((s) => s.astro).firstOrNull;
  final duskHit = samples.where((s) => s.dusk).firstOrNull;

  var status = LightSafetyStatus.daylightSafe;
  if (duskHit != null) {
    status = LightSafetyStatus.nightDanger;
  } else if (astroHit != null) {
    status = LightSafetyStatus.twilightWarning;
  } else if (ridgeIdx >= 0) {
    status = LightSafetyStatus.ridgeShade;
  }

  return TrailSolarForecast(
    status: status,
    finishRidgeSunset: finishRes,
    ridgeShadeAlongM: ridgeIdx >= 0 ? samples[ridgeIdx].d : null,
    ridgeShadeTime: ridgeIdx >= 0 ? samples[ridgeIdx].ts : null,
    astroSunsetAlongM: astroHit?.d,
    civilDuskAlongM: duskHit?.d,
    nightRemainingDistanceM: duskHit != null
        ? math.max(0.0, totalDist - duskHit.d)
        : 0.0,
  );
}
