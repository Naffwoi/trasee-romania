import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/map/raster_layer_composer.dart';
import 'package:wanderer/util/region/proxy_style_rewriter.dart';

void main() {
  test(
    'rewriteStyleForProxy rewrites vector & raster-dem while preserving raster tile URLs and maxzoom',
    () {
      final baseStyle = <String, dynamic>{
        'version': 8,
        'glyphs': 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
        'sprite': 'https://protomaps.github.io/basemaps-assets/sprites/v4/light',
        'sources': <String, dynamic>{
          'protomaps': <String, dynamic>{
            'type': 'vector',
            'tiles': ['https://api.protomaps.com/tiles/v4/{z}/{x}/{y}.mvt'],
          },
          'hillshadeSource': <String, dynamic>{
            'type': 'raster-dem',
            'url': 'https://tiles.mapterhorn.com/tilejson.json',
          },
        },
        'layers': <Map<String, dynamic>>[
          {'id': 'background', 'type': 'background'},
          {
            'id': 'roads',
            'type': 'line',
            'source': 'protomaps',
            'source-layer': 'roads',
          },
          {
            'id': 'place-labels',
            'type': 'symbol',
            'source': 'protomaps',
            'source-layer': 'places',
          },
        ],
      };

      final composed = composeSatelliteAndRasterOverlays(
        baseStyle,
        baseMode: 'esri_satellite',
        activeOverlays: {'snowCover', 'dailySatellite', 'weatherRadar'},
        rainViewerTileTemplate:
            'https://tilecache.rainviewer.com/v2/radar/abc/256/{z}/{x}/{y}/2/1_1.png',
      );

      final rewritten = rewriteStyleForProxy(
        composed,
        proxyBaseUrl: 'http://127.0.0.1:54321/secret123',
        dark: false,
      );

      final sources = rewritten['sources'] as Map<String, dynamic>;
      expect(
        (sources['protomaps'] as Map)['tiles'],
        ['http://127.0.0.1:54321/secret123/vector/{z}/{x}/{y}.pbf'],
      );
      expect(
        (sources['hillshadeSource'] as Map)['tiles'],
        ['http://127.0.0.1:54321/secret123/dem/{z}/{x}/{y}.png'],
      );

      final esri = sources['esriWorldImagery'] as Map<String, dynamic>;
      expect(esri['type'], 'raster');
      expect(esri['maxzoom'], 18);
      expect(
        (esri['tiles'] as List).first,
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      );

      final snow = sources['gibsSnowCover'] as Map<String, dynamic>;
      expect(snow['maxzoom'], 8);

      final dailySat = sources['gibsTrueColor'] as Map<String, dynamic>;
      expect(dailySat['maxzoom'], 9);

      final radar = sources['rainViewerRadar'] as Map<String, dynamic>;
      expect(radar['maxzoom'], 7);
    },
  );
}
