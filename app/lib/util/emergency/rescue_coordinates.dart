import 'dart:math' as math;

const double _wgs84A = 6378137.0;
const double _wgs84F = 1.0 / 298.257223563;
const double _utmK0 = 0.9996;
const double _utmFalseEasting = 500000.0;
const double _utmFalseNorthing = 10000000.0;
const String _mgrsLatBands = 'CDEFGHJKLMNPQRSTUVWXX';

const String _olcAlphabet = '23456789CFGHJMPQRVWX';
const int _olcBase = 20;
const int _olcGridCols = 4;
const int _olcGridRows = 5;
const int _olcFinalLatPrec = 25000000;
const int _olcFinalLngPrec = 8192000;

class UtmCoordinate {
  const UtmCoordinate({
    required this.zone,
    required this.band,
    required this.hemisphere,
    required this.easting,
    required this.northing,
    required this.formatted,
  });

  final int zone;
  final String band;
  final String hemisphere;
  final double easting;
  final double northing;
  final String formatted;
}

class NearbyLandmarkRef {
  const NearbyLandmarkRef({
    required this.name,
    this.eleM,
    required this.distanceM,
    required this.summaryRo,
    required this.summaryAscii,
  });

  final String name;
  final int? eleM;
  final int distanceM;
  final String summaryRo;
  final String summaryAscii;
}

class RescueCoordinateBundle {
  const RescueCoordinateBundle({
    required this.wgs84Decimal,
    required this.wgs84RawPair,
    required this.wgs84Dms,
    required this.utm,
    required this.plusCode,
    this.elevationM,
    this.accuracyM,
    this.nearestLandmark,
    required this.sms113AsciiBody,
    required this.clipboardFullCardRo,
  });

  final String wgs84Decimal;
  final String wgs84RawPair;
  final String wgs84Dms;
  final UtmCoordinate utm;
  final String plusCode;
  final int? elevationM;
  final int? accuracyM;
  final NearbyLandmarkRef? nearestLandmark;
  final String sms113AsciiBody;
  final String clipboardFullCardRo;
}

String stripRomanianDiacritics(String input) {
  return input
      .replaceAll('ă', 'a')
      .replaceAll('â', 'a')
      .replaceAll('î', 'i')
      .replaceAll('ș', 's')
      .replaceAll('ş', 's')
      .replaceAll('ț', 't')
      .replaceAll('ţ', 't')
      .replaceAll('Ă', 'A')
      .replaceAll('Â', 'A')
      .replaceAll('Î', 'I')
      .replaceAll('Ș', 'S')
      .replaceAll('Ş', 'S')
      .replaceAll('Ț', 'T')
      .replaceAll('Ţ', 'T')
      .replaceAll('—', '-')
      .replaceAll('–', '-')
      .replaceAll(RegExp(r'[^\x20-\x7E\n]'), '');
}

double _asinh(double x) => math.log(x + math.sqrt(x * x + 1.0));
double _atanh(double x) => 0.5 * math.log((1.0 + x) / (1.0 - x));
double _sinh(double x) => 0.5 * (math.exp(x) - math.exp(-x));
double _cosh(double x) => 0.5 * (math.exp(x) + math.exp(-x));
double _toRad(double deg) => deg * math.pi / 180.0;

String _formatSingleDms(double degVal, String posHemi, String negHemi) {
  final hemi = degVal >= 0 ? posHemi : negHemi;
  final totalTenths = (degVal.abs() * 36000.0).round();
  final d = totalTenths ~/ 36000;
  final rem = totalTenths % 36000;
  final m = rem ~/ 600;
  final tenthsSec = rem % 600;
  final secWhole = tenthsSec ~/ 10;
  final secFrac = tenthsSec % 10;
  return "${d.toString().padLeft(2, '0')}° ${m.toString().padLeft(2, '0')}' ${secWhole.toString().padLeft(2, '0')}.$secFrac\" $hemi";
}

String formatDmsCoordinate(double lat, double lon) =>
    '${_formatSingleDms(lat, 'N', 'S')}, ${_formatSingleDms(lon, 'E', 'W')}';

UtmCoordinate wgs84ToUtm(double lat, double lon) {
  final clampedLat = lat.clamp(-80.0, 84.0);
  final normLon = ((((lon + 180.0) % 360.0) + 360.0) % 360.0) - 180.0;

  var zone = ((normLon + 180.0) / 6.0).floor() + 1;
  final bandIdx = (clampedLat / 8.0 + 10.0)
      .floor()
      .clamp(0, _mgrsLatBands.length - 1);
  final band = _mgrsLatBands[bandIdx];

  if (zone == 31 && band == 'V' && normLon >= 3.0) {
    zone = 32;
  } else if (band == 'X') {
    if (zone == 32 && normLon < 9.0) {
      zone = 31;
    } else if (zone == 32 && normLon >= 9.0) {
      zone = 33;
    } else if (zone == 34 && normLon < 21.0) {
      zone = 33;
    } else if (zone == 34 && normLon >= 21.0) {
      zone = 35;
    } else if (zone == 36 && normLon < 33.0) {
      zone = 35;
    } else if (zone == 36 && normLon >= 33.0) {
      zone = 37;
    }
  }

  final lam0 = _toRad((zone - 1) * 6 - 180 + 3);
  final phi = _toRad(clampedLat);
  final lam = _toRad(normLon) - lam0;

  final e = math.sqrt(_wgs84F * (2.0 - _wgs84F));
  final n = _wgs84F / (2.0 - _wgs84F);
  final n2 = n * n;
  final n3 = n2 * n;
  final n4 = n3 * n;
  final n5 = n4 * n;
  final n6 = n5 * n;

  final bigA =
      (_wgs84A / (1.0 + n)) * (1.0 + n2 / 4.0 + n4 / 64.0 + n6 / 256.0);
  final alpha = <double>[
    0.0,
    0.5 * n -
        (2.0 / 3.0) * n2 +
        (5.0 / 16.0) * n3 +
        (41.0 / 180.0) * n4 -
        (127.0 / 288.0) * n5 +
        (7891.0 / 37800.0) * n6,
    (13.0 / 48.0) * n2 -
        (3.0 / 5.0) * n3 +
        (557.0 / 1440.0) * n4 +
        (281.0 / 630.0) * n5 -
        (1983433.0 / 1935360.0) * n6,
    (61.0 / 240.0) * n3 -
        (103.0 / 140.0) * n4 +
        (15061.0 / 26880.0) * n5 +
        (167603.0 / 181440.0) * n6,
    (49561.0 / 161280.0) * n4 -
        (179.0 / 168.0) * n5 +
        (6601661.0 / 7257600.0) * n6,
    (34729.0 / 80640.0) * n5 - (3418889.0 / 1995840.0) * n6,
    (212378941.0 / 319334400.0) * n6,
  ];

  final tau = math.tan(phi);
  final sigma = _sinh(e * _atanh((e * tau) / math.sqrt(1.0 + tau * tau)));
  final tauPrime =
      tau * math.sqrt(1.0 + sigma * sigma) - sigma * math.sqrt(1.0 + tau * tau);

  final cosLam = math.cos(lam);
  final sinLam = math.sin(lam);
  final xiPrime = math.atan2(tauPrime, cosLam);
  final etaPrime = _asinh(
    sinLam / math.sqrt(tauPrime * tauPrime + cosLam * cosLam),
  );

  var xi = xiPrime;
  var eta = etaPrime;
  for (var j = 1; j <= 6; j++) {
    xi += alpha[j] * math.sin(2 * j * xiPrime) * _cosh(2 * j * etaPrime);
    eta += alpha[j] * math.cos(2 * j * xiPrime) * _sinh(2 * j * etaPrime);
  }

  final easting = _utmK0 * bigA * eta + _utmFalseEasting;
  final rawNorthing = _utmK0 * bigA * xi;
  final northing = clampedLat < 0
      ? rawNorthing + _utmFalseNorthing
      : rawNorthing;
  final hemi = clampedLat >= 0 ? 'N' : 'S';

  return UtmCoordinate(
    zone: zone,
    band: band,
    hemisphere: hemi,
    easting: easting,
    northing: northing,
    formatted: '$zone$band ${easting.round()} E ${northing.round()} N',
  );
}

String encodePlusCode(double lat, double lon, {int codeLength = 11}) {
  var latVal = (lat * _olcFinalLatPrec).floor() + 90 * _olcFinalLatPrec;
  const maxLatVal = 180 * _olcFinalLatPrec;
  if (latVal < 0) latVal = 0;
  if (latVal >= maxLatVal) latVal = maxLatVal - 1;

  var lngVal = (lon * _olcFinalLngPrec).floor() + 180 * _olcFinalLngPrec;
  const maxLngVal = 360 * _olcFinalLngPrec;
  lngVal = ((lngVal % maxLngVal) + maxLngVal) % maxLngVal;

  final chars = List<String>.filled(16, '');
  chars[8] = '+';

  if (codeLength == 11) {
    latVal = latVal ~/ 625;
    lngVal = lngVal ~/ 256;
    final latDigit = latVal % _olcGridRows;
    final lngDigit = lngVal % _olcGridCols;
    chars[11] = _olcAlphabet[latDigit * _olcGridCols + lngDigit];
    latVal = latVal ~/ _olcGridRows;
    lngVal = lngVal ~/ _olcGridCols;
  } else {
    latVal = latVal ~/ 3125;
    lngVal = lngVal ~/ 1024;
  }

  chars[9] = _olcAlphabet[latVal % _olcBase];
  chars[10] = _olcAlphabet[lngVal % _olcBase];
  latVal = latVal ~/ _olcBase;
  lngVal = lngVal ~/ _olcBase;

  for (var i = 6; i >= 0; i -= 2) {
    chars[i] = _olcAlphabet[latVal % _olcBase];
    chars[i + 1] = _olcAlphabet[lngVal % _olcBase];
    latVal = latVal ~/ _olcBase;
    lngVal = lngVal ~/ _olcBase;
  }

  return chars.sublist(0, codeLength + 1).join();
}

Uri buildEmergencySmsUri({
  required String recipient,
  required String asciiBody,
  required bool isIOS,
}) {
  final sep = isIOS ? '&' : '?';
  final encoded = Uri.encodeComponent(asciiBody);
  return Uri.parse('sms:${recipient.trim()}${sep}body=$encoded');
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _toRad(lat2 - lat1);
  final dLon = _toRad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(_toRad(lat1)) *
          math.cos(_toRad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
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

RescueCoordinateBundle formatRescueCoordinates({
  required double lat,
  required double lon,
  double? elevationM,
  double? accuracyM,
  String reasonRo = 'Urgență',
  ({String name, double lat, double lon, int? eleM})? landmark,
  DateTime? now,
}) {
  final ns = lat >= 0 ? 'N' : 'S';
  final ew = lon >= 0 ? 'E' : 'W';
  final wgs84Decimal =
      '${lat.abs().toStringAsFixed(5)}° $ns, ${lon.abs().toStringAsFixed(5)}° $ew';
  final wgs84RawPair = '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
  final wgs84Dms = formatDmsCoordinate(lat, lon);
  final utm = wgs84ToUtm(lat, lon);
  final plusCode = encodePlusCode(lat, lon, codeLength: 11);

  final eleInt =
      (elevationM != null && elevationM.isFinite) ? elevationM.round() : null;
  final accInt = (accuracyM != null && accuracyM.isFinite && accuracyM > 0)
      ? math.max(1, accuracyM.round())
      : null;

  NearbyLandmarkRef? lmRef;
  if (landmark != null) {
    final distM = _haversineM(landmark.lat, landmark.lon, lat, lon).round();
    final dirRo = _cardinal8Ro(
      _bearingDeg(landmark.lat, landmark.lon, lat, lon),
    );
    final distText =
        distM >= 1000 ? '${(distM / 1000.0).toStringAsFixed(1)}km' : '${distM}m';
    final eleSuffix = landmark.eleM != null ? ' (${landmark.eleM}m)' : '';
    final asciiName = stripRomanianDiacritics(landmark.name);
    final shortAscii = asciiName.length > 20
        ? asciiName.substring(0, 20).trim()
        : asciiName;
    lmRef = NearbyLandmarkRef(
      name: landmark.name,
      eleM: landmark.eleM,
      distanceM: distM,
      summaryRo: '$distText $dirRo de ${landmark.name}$eleSuffix',
      summaryAscii: '$distText $dirRo $shortAscii',
    );
  }

  final ts = now ?? DateTime.now();
  final hh = ts.hour.toString().padLeft(2, '0');
  final mm = ts.minute.toString().padLeft(2, '0');
  final cleanReason = stripRomanianDiacritics(reasonRo);
  final shortReason =
      cleanReason.length > 14 ? cleanReason.substring(0, 14) : cleanReason;
  final altLine = eleInt != null
      ? 'Alt:${eleInt}m${accInt != null ? '(+/-${accInt}m)' : ''}'
      : (accInt != null ? 'GPS:+/-${accInt}m' : 'GPS:activ');

  final smsLines = <String>[
    'SOS MUNTE [$shortReason]',
    'WGS84:$wgs84RawPair',
    altLine,
    'UTM:${utm.zone}${utm.band} ${utm.easting.round()} ${utm.northing.round()}',
    'Plus:$plusCode',
    if (lmRef != null) 'Reper:${lmRef.summaryAscii}',
    'Ora:$hh:$mm',
  ];
  final rawSms = stripRomanianDiacritics(smsLines.join('\n'));
  final sms113 = rawSms.length > 160 ? rawSms.substring(0, 160) : rawSms;

  final cardLines = <String>[
    'FIȘĂ COORDONATE 112 / SALVAMONT',
    'WGS84: $wgs84Decimal ($wgs84RawPair)',
    'DMS: $wgs84Dms',
    'UTM: ${utm.formatted}',
    'Plus Code: $plusCode',
    if (eleInt != null)
      'Altitudine: $eleInt m${accInt != null ? ' (±$accInt m)' : ''}',
    if (lmRef != null) 'Reper: ${lmRef.summaryRo}',
    'Ora: $hh:$mm',
  ];

  return RescueCoordinateBundle(
    wgs84Decimal: wgs84Decimal,
    wgs84RawPair: wgs84RawPair,
    wgs84Dms: wgs84Dms,
    utm: utm,
    plusCode: plusCode,
    elevationM: eleInt,
    accuracyM: accInt,
    nearestLandmark: lmRef,
    sms113AsciiBody: sms113,
    clipboardFullCardRo: cardLines.join('\n'),
  );
}
