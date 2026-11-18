import 'dart:convert';

Map<String, dynamic> composeSatelliteAndRasterOverlays(
  Map<String, dynamic> baseStyle, {
  required String baseMode,
  required Set<String> activeOverlays,
  String? rainViewerTileTemplate,
  String? ancpiOrthoTileUrl,
  String satelliteDate = 'default',
}) {
  final out = jsonDecode(jsonEncode(baseStyle)) as Map<String, dynamic>;
  final sources =
      (out['sources'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  out['sources'] = sources;
  final rawLayers = (out['layers'] as List?) ?? <dynamic>[];
  final layers = <Map<String, dynamic>>[
    for (final l in rawLayers)
      if (l is Map) Map<String, dynamic>.from(l),
  ];

  String? baseRasterId;
  if (baseMode == 'esri_satellite') {
    baseRasterId = 'esriWorldImagery';
    sources[baseRasterId] = <String, dynamic>{
      'type': 'raster',
      'tiles': [
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      ],
      'tileSize': 256,
      'maxzoom': 18,
      'attribution': 'Source: Esri, Maxar, Earthstar Geographics',
    };
  } else if (baseMode == 'sentinel2_cloudless') {
    baseRasterId = 'eoxSentinel2';
    sources[baseRasterId] = <String, dynamic>{
      'type': 'raster',
      'tiles': [
        'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg',
      ],
      'tileSize': 256,
      'maxzoom': 15,
      'attribution':
          'Sentinel-2 cloudless - s2maps.eu by EOX (Copernicus data 2025)',
    };
  } else if (baseMode == 'opentopomap') {
    baseRasterId = 'openTopoMap';
    sources[baseRasterId] = <String, dynamic>{
      'type': 'raster',
      'tiles': ['https://tile.opentopomap.org/{z}/{x}/{y}.png'],
      'tileSize': 256,
      'maxzoom': 17,
      'attribution': '© OpenTopoMap © OpenStreetMap contributors',
    };
  } else if (baseMode == 'ancpi_ortho' &&
      ancpiOrthoTileUrl != null &&
      ancpiOrthoTileUrl.isNotEmpty) {
    baseRasterId = 'ancpiOrthoRo';
    sources[baseRasterId] = <String, dynamic>{
      'type': 'raster',
      'tiles': [ancpiOrthoTileUrl],
      'tileSize': 256,
      'maxzoom': 19,
      'attribution': '© ANCPI România',
    };
  }

  if (baseRasterId != null) {
    // Keep background + symbol/road/waterway hybrid context over satellite; hide opaque landcover fills.
    layers.removeWhere((l) => l['type'] == 'fill');
    final insertIdx = layers.indexWhere((l) => l['type'] != 'background');
    final targetIdx = insertIdx < 0 ? layers.length : insertIdx;
    layers.insert(targetIdx, <String, dynamic>{
      'id': baseRasterId,
      'type': 'raster',
      'source': baseRasterId,
    });
  }

  final overlayLayers = <Map<String, dynamic>>[];
  final safeDate = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(satelliteDate)
      ? satelliteDate
      : 'default';

  if (activeOverlays.contains('dailySatellite')) {
    sources['gibsTrueColor'] = <String, dynamic>{
      'type': 'raster',
      'tiles': [
        'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_NOAA20_CorrectedReflectance_TrueColor/default/$safeDate/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpg',
      ],
      'tileSize': 256,
      'maxzoom': 9,
      'attribution': 'NASA EOSDIS GIBS (VIIRS NOAA-20 True Color)',
    };
    overlayLayers.add(<String, dynamic>{
      'id': 'gibsTrueColor',
      'type': 'raster',
      'source': 'gibsTrueColor',
      'paint': <String, dynamic>{'raster-opacity': 0.86},
    });
  }

  if (activeOverlays.contains('snowCover')) {
    sources['gibsSnowCover'] = <String, dynamic>{
      'type': 'raster',
      'tiles': [
        'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_NOAA20_NDSI_Snow_Cover/default/$safeDate/GoogleMapsCompatible_Level8/{z}/{y}/{x}.png',
      ],
      'tileSize': 256,
      'maxzoom': 8,
      'attribution': 'NASA EOSDIS GIBS (VIIRS NOAA-20 Snow)',
    };
    overlayLayers.add(<String, dynamic>{
      'id': 'gibsSnowCover',
      'type': 'raster',
      'source': 'gibsSnowCover',
      'paint': <String, dynamic>{'raster-opacity': 0.68},
    });
  }

  if (activeOverlays.contains('forestDisturbance')) {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 180))
        .toIso8601String()
        .substring(0, 10);
    sources['gfwDisturbance'] = <String, dynamic>{
      'type': 'raster',
      'tiles': [
        'https://tiles.globalforestwatch.org/umd_glad_dist_alerts/latest/dynamic/{z}/{x}/{y}.png?render_type=true_color&alert_confidence=high&tree_cover_density_threshold=30&tree_cover_height_threshold=5&start_date=$cutoff',
      ],
      'tileSize': 256,
      'maxzoom': 14,
      'attribution': 'UMD GLAD DIST-ALERT via GFW',
    };
    overlayLayers.add(<String, dynamic>{
      'id': 'gfwDisturbance',
      'type': 'raster',
      'source': 'gfwDisturbance',
      'paint': <String, dynamic>{'raster-opacity': 0.78},
    });
  }

  if (activeOverlays.contains('weatherRadar') &&
      rainViewerTileTemplate != null &&
      rainViewerTileTemplate.isNotEmpty) {
    sources['rainViewerRadar'] = <String, dynamic>{
      'type': 'raster',
      'tiles': [rainViewerTileTemplate],
      'tileSize': 256,
      'maxzoom': 7,
      'attribution': 'Radar © RainViewer',
    };
    overlayLayers.add(<String, dynamic>{
      'id': 'rainViewerRadar',
      'type': 'raster',
      'source': 'rainViewerRadar',
      'paint': <String, dynamic>{'raster-opacity': 0.65},
    });
  }

  if (activeOverlays.contains('waymarkedHiking')) {
    sources['waymarkedHiking'] = <String, dynamic>{
      'type': 'raster',
      'tiles': ['https://tile.waymarkedtrails.org/hiking/{z}/{x}/{y}.png'],
      'tileSize': 256,
      'maxzoom': 18,
      'attribution': '© Waymarked Trails',
    };
    overlayLayers.add(<String, dynamic>{
      'id': 'waymarkedHiking',
      'type': 'raster',
      'source': 'waymarkedHiking',
    });
  }

  // Insert raster overlays right below the first symbol label layer so peaks/names stay readable.
  final firstSymbolIdx = layers.indexWhere((l) => l['type'] == 'symbol');
  final overlayInsertIdx = firstSymbolIdx < 0 ? layers.length : firstSymbolIdx;
  layers.insertAll(overlayInsertIdx, overlayLayers);

  out['layers'] = layers;
  return out;
}
