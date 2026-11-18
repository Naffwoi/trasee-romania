import 'dart:math' as math;

class CuratedCarpathianPhoto {
  final String assetPath;
  final String caption;
  final String license;

  const CuratedCarpathianPhoto({
    required this.assetPath,
    required this.caption,
    required this.license,
  });
}

const CuratedCarpathianPhoto _taminaPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/cascada_tamina.jpg',
  caption: 'Canionul Tamina · CC0',
  license: 'CC0',
);

const CuratedCarpathianPhoto _sapteScariPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/canionul_7_scari.jpg',
  caption: 'Canionul 7 Scări · CC BY 3.0',
  license: 'CC BY 3.0',
);

const CuratedCarpathianPhoto _piatraMarePhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/varful_piatra_mare.jpg',
  caption: 'Masivul Piatra Mare · CC BY-SA 3.0',
  license: 'CC BY-SA 3.0',
);

const CuratedCarpathianPhoto _predealPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/predeal_clabucet.jpg',
  caption: 'Predeal – Clăbucet · CC BY 2.0',
  license: 'CC BY 2.0',
);

const CuratedCarpathianPhoto _postavarulPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/postavarul.jpg',
  caption: 'Masivul Postăvarul · CC BY 3.0',
  license: 'CC BY 3.0',
);

const CuratedCarpathianPhoto _ciucasPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/varful_ciucas.jpg',
  caption: 'Munții Ciucaș · CC BY-SA 3.0',
  license: 'CC BY-SA 3.0',
);

const CuratedCarpathianPhoto _piatraCraiuluiPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/piatra_craiului.jpg',
  caption: 'Piatra Craiului · CC BY 2.0',
  license: 'CC BY 2.0',
);

const CuratedCarpathianPhoto _bucegiPhoto = CuratedCarpathianPhoto(
  assetPath: 'assets/images/carpathians/cabana_carpati.jpg',
  caption: 'Munții Bucegi – Vf. Omu · CC BY-SA 3.0',
  license: 'CC BY-SA 3.0',
);

const List<(double lat, double lon, CuratedCarpathianPhoto photo)> _centroids = [
  (45.548, 25.643, _taminaPhoto),
  (45.565, 25.644, _sapteScariPhoto),
  (45.554, 25.647, _piatraMarePhoto),
  (45.505, 25.578, _predealPhoto),
  (45.569, 25.569, _postavarulPhoto),
  (45.522, 25.926, _ciucasPhoto),
  (45.528, 25.217, _piatraCraiuluiPhoto),
  (45.446, 25.456, _bucegiPhoto),
];

bool isPlaceholderPhotoName(String? name) {
  if (name == null) return true;
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  return trimmed.contains('wanderer_route_placeholder');
}

String _foldDiacritics(String input) {
  return input
      .toLowerCase()
      .replaceAll('ă', 'a')
      .replaceAll('â', 'a')
      .replaceAll('î', 'i')
      .replaceAll('ș', 's')
      .replaceAll('ş', 's')
      .replaceAll('ț', 't')
      .replaceAll('ţ', 't');
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return earthRadiusKm * 2.0 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

CuratedCarpathianPhoto? resolveCuratedCarpathianPhoto({
  required String name,
  String? location,
  double? lat,
  double? lon,
}) {
  final haystack = _foldDiacritics('$name ${location ?? ''}');

  if (haystack.contains('tamina')) return _taminaPhoto;
  if (haystack.contains('7 scari') || haystack.contains('sapte scari')) {
    return _sapteScariPhoto;
  }
  if (haystack.contains('piatra mare') ||
      haystack.contains('dambu morii') ||
      haystack.contains('timisu') ||
      haystack.contains('familiar')) {
    return _piatraMarePhoto;
  }
  if (haystack.contains('predeal') ||
      haystack.contains('clabucet') ||
      haystack.contains('fetifoiu') ||
      haystack.contains('sipote') ||
      haystack.contains('susai') ||
      haystack.contains('garbova')) {
    return _predealPhoto;
  }
  if (haystack.contains('postavaru') ||
      haystack.contains('poiana brasov') ||
      haystack.contains('tampa') ||
      haystack.contains('rasnov') ||
      haystack.contains('cristian')) {
    return _postavarulPhoto;
  }
  if (haystack.contains('ciucas') ||
      haystack.contains('bratocea') ||
      haystack.contains('muntele rosu') ||
      haystack.contains('cheia') ||
      haystack.contains('tigailor')) {
    return _ciucasPhoto;
  }
  if (haystack.contains('piatra craiului') ||
      haystack.contains('zarnesti') ||
      haystack.contains('prapastiile') ||
      haystack.contains('curmatura') ||
      haystack.contains('ascutit') ||
      haystack.contains('magura')) {
    return _piatraCraiuluiPhoto;
  }
  if (haystack.contains('bucegi') ||
      haystack.contains('omu') ||
      haystack.contains('caraiman') ||
      haystack.contains('babele') ||
      haystack.contains('busteni') ||
      haystack.contains('sinaia') ||
      haystack.contains('diham') ||
      haystack.contains('malaiesti')) {
    return _bucegiPhoto;
  }

  if (lat != null && lon != null && lat.isFinite && lon.isFinite) {
    CuratedCarpathianPhoto? best;
    var bestKm = 25.0;
    for (final (cLat, cLon, photo) in _centroids) {
      final dist = _haversineKm(lat, lon, cLat, cLon);
      if (dist <= bestKm) {
        bestKm = dist;
        best = photo;
      }
    }
    return best;
  }

  return null;
}
