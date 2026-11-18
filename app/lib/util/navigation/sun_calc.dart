import 'dart:math' as math;

const double _rad = math.pi / 180.0;
const double _dayMs = 86400000.0;
const double _j1970 = 2440588.0;
const double _j2000 = 2451545.0;
const double _j0 = 0.0009;

enum PolarState { normal, midnightSun, polarNight }

class SunPosition {
  const SunPosition({
    required this.azimuthDeg,
    required this.altitudeDeg,
    required this.trueAltitudeDeg,
  });

  final double azimuthDeg;
  final double altitudeDeg;
  final double trueAltitudeDeg;
}

class SunTimes {
  const SunTimes({
    required this.solarNoon,
    required this.nadir,
    required this.sunrise,
    required this.sunset,
    required this.dawn,
    required this.dusk,
    required this.goldenHour,
    required this.polarState,
  });

  final DateTime solarNoon;
  final DateTime nadir;
  final DateTime? sunrise;
  final DateTime? sunset;
  final DateTime? dawn;
  final DateTime? dusk;
  final DateTime? goldenHour;
  final PolarState polarState;
}

DateTime _fromDaysJ2000(double d) => DateTime.fromMillisecondsSinceEpoch(
  ((d + _j2000 + 0.5 - _j1970) * _dayMs).round(),
  isUtc: true,
);

double _toDays(DateTime dt) =>
    dt.millisecondsSinceEpoch / _dayMs - 0.5 + _j1970 - _j2000;

double _deltaTSeconds(double d) {
  final y = 2000.0 + d / 365.2425;
  if (y < 2050.0) {
    final t = y - 2000.0;
    return 62.92 + t * (0.32217 + t * 0.005589);
  }
  final t = (y - 1820.0) / 100.0;
  return -20.0 + 32.0 * t * t - 0.5628 * (2150.0 - y);
}

double _toDaysTT(double d) => d + _deltaTSeconds(d) / 86400.0;

double _siderealTime(double d, double lw) =>
    _rad * (280.46061837 + 360.98564736629 * d) - lw;

double astroRefractionRad(double hRad) {
  final h = hRad < 0.0 ? 0.0 : hRad;
  return 0.0002967 / math.tan(h + 0.00312536 / (h + 0.08901179));
}

({double ra, double dec}) _sunCoords(double dTT) {
  final t = dTT / 36525.0;
  final l0 = _rad * (280.46646 + t * (36000.76983 + t * 0.0003032));
  final m = _rad * (357.52911 + t * (35999.05029 - t * 0.0001537));
  final sinM = math.sin(m);
  final cosM = math.cos(m);
  final c =
      _rad *
      ((1.914602 - t * (0.004817 + 0.000014 * t)) * sinM +
          (0.019993 - 0.000101 * t) * 2.0 * sinM * cosM +
          0.000289 * sinM * (3.0 - 4.0 * sinM * sinM));
  final omega = _rad * (125.04 - 1934.136 * t);
  final lambda = l0 + c - _rad * (0.00569 + 0.00478 * math.sin(omega));
  final eps =
      _rad * (23.439291 - t * 0.0130042) + _rad * 0.00256 * math.cos(omega);
  return (
    ra: math.atan2(math.cos(eps) * math.sin(lambda), math.cos(lambda)),
    dec: math.asin((math.sin(eps) * math.sin(lambda)).clamp(-1.0, 1.0)),
  );
}

SunPosition getSunPosition(DateTime date, double lat, double lon) {
  final cLat = lat.clamp(-90.0, 90.0);
  final lw = _rad * -lon;
  final phi = _rad * cLat;
  final d = _toDays(date);
  final c = _sunCoords(_toDaysTT(d));
  final hAngle = _siderealTime(d, lw) - c.ra;
  final sinAlt =
      (math.sin(phi) * math.sin(c.dec) +
              math.cos(phi) * math.cos(c.dec) * math.cos(hAngle))
          .clamp(-1.0, 1.0);
  final hRad = math.asin(sinAlt);
  final refr = hRad >= -0.02 ? astroRefractionRad(hRad) : 0.0;
  final az =
      (math.atan2(
                    math.sin(hAngle),
                    math.cos(hAngle) * math.sin(phi) -
                        math.tan(c.dec) * math.cos(phi),
                  ) /
                  _rad +
              540.0) %
          360.0;
  return SunPosition(
    azimuthDeg: az < 0 ? az + 360.0 : az,
    altitudeDeg: (hRad + refr) / _rad,
    trueAltitudeDeg: hRad / _rad,
  );
}

double _wrapPi(double a) =>
    a - 2.0 * math.pi * (a / (2.0 * math.pi)).roundToDouble();

double _solarTransit(double dt, double lw) {
  var cur = dt;
  for (var i = 0; i < 3; i++) {
    final h = _wrapPi(_siderealTime(cur, lw) - _sunCoords(_toDaysTT(cur)).ra);
    cur -= h / (2.0 * math.pi);
  }
  return cur;
}

double _solveCrossing(
  double h0Rad,
  double aIn,
  double bIn,
  double sa,
  double sb,
  double dt,
  double lw,
  double phi,
  double decT,
) {
  final s0 = math.sin(h0Rad);
  final rising = sa < sb;
  if (!((sa - s0) * (sb - s0) <= 0.0)) return double.nan;

  var a = aIn;
  var b = bIn;
  final denom = math.cos(phi) * math.cos(decT);
  final cosH0 = denom.abs() > 1e-12
      ? (s0 - math.sin(phi) * math.sin(decT)) / denom
      : 0.0;
  final h0 = cosH0 <= -1.0
      ? math.pi
      : (cosH0 >= 1.0 ? 0.0 : math.acos(cosH0));
  var d = dt + (rising ? -h0 : h0) / (2.0 * math.pi);
  var dx = b - a;

  for (var iter = 0; iter < 32; iter++) {
    final c = _sunCoords(_toDaysTT(d));
    final h = _siderealTime(d, lw) - c.ra;
    final k = math.cos(phi) * math.cos(c.dec);
    final f = math.sin(phi) * math.sin(c.dec) + k * math.cos(h) - s0;
    if ((f < 0.0) == rising) {
      a = d;
    } else {
      b = d;
    }
    final deriv = 2.0 * math.pi * k * math.sin(h);
    final step = deriv.abs() > 1e-12 ? f / deriv : double.infinity;
    if (d + step > a && d + step < b && step.abs() <= dx.abs() / 2.0) {
      dx = step;
      d += step;
      if (step.abs() < 1e-5) return d;
    } else {
      dx = (b - a) / 2.0;
      d = a + dx;
      if (b - a < 1e-8) return d;
    }
  }
  return d;
}

SunTimes getSunTimes(DateTime date, double lat, double lon) {
  final cLat = lat.clamp(-89.999, 89.999);
  final lw = _rad * -lon;
  final phi = _rad * cLat;
  final anchorD = _toDays(date);
  final lonDays = _j0 + lw / (2.0 * math.pi);
  final dt = _solarTransit(
    (anchorD - lonDays).roundToDouble() + lonDays,
    lw,
  );

  final decNoon = _sunCoords(_toDaysTT(dt)).dec;
  final sNoon = math.cos(phi - decNoon);
  final sNadir1 = -math.cos(phi + _sunCoords(_toDaysTT(dt - 0.5)).dec);
  final sNadir2 = -math.cos(phi + _sunCoords(_toDaysTT(dt + 0.5)).dec);

  (DateTime?, DateTime?) solvePair(double angleDeg) {
    final h0 = angleDeg * _rad;
    final jr = _solveCrossing(
      h0,
      dt - 0.5,
      dt,
      sNadir1,
      sNoon,
      dt,
      lw,
      phi,
      decNoon,
    );
    final js = _solveCrossing(
      h0,
      dt,
      dt + 0.5,
      sNoon,
      sNadir2,
      dt,
      lw,
      phi,
      decNoon,
    );
    return (
      jr.isFinite ? _fromDaysJ2000(jr) : null,
      js.isFinite ? _fromDaysJ2000(js) : null,
    );
  }

  final (sunrise, sunset) = solvePair(-0.833);
  final (dawn, dusk) = solvePair(-6.0);
  final (_, goldenHour) = solvePair(6.0);

  var polar = PolarState.normal;
  if (sunrise == null && sunset == null) {
    polar = sNoon > math.sin(-0.833 * _rad)
        ? PolarState.midnightSun
        : PolarState.polarNight;
  }

  return SunTimes(
    solarNoon: _fromDaysJ2000(dt),
    nadir: _fromDaysJ2000(dt - 0.5),
    sunrise: sunrise,
    sunset: sunset,
    dawn: dawn,
    dusk: dusk,
    goldenHour: goldenHour,
    polarState: polar,
  );
}
