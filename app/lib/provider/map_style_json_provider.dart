import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/map_style_sources_provider.dart';
import 'package:wanderer/util/map/raster_layer_composer.dart';

part 'map_style_json_provider.g.dart';

String? _cachedRainViewerTemplate;
DateTime? _cachedRainViewerAt;

Future<String?> _resolveRainViewerTemplate() async {
  final now = DateTime.now();
  if (_cachedRainViewerTemplate != null &&
      _cachedRainViewerAt != null &&
      now.difference(_cachedRainViewerAt!) < const Duration(minutes: 5)) {
    return _cachedRainViewerTemplate;
  }
  try {
    final res = await Dio(
      BaseOptions(connectTimeout: const Duration(seconds: 5)),
    ).get<Map<String, dynamic>>(
      'https://api.rainviewer.com/public/weather-maps.json',
    );
    final data = res.data;
    final host = data?['host'] as String?;
    final past = (data?['radar'] as Map?)?['past'] as List?;
    if (host != null && past != null && past.isNotEmpty) {
      final latestPath = (past.last as Map)['path'] as String?;
      if (latestPath != null && latestPath.isNotEmpty) {
        _cachedRainViewerTemplate = '$host$latestPath/256/{z}/{x}/{y}/2/1_1.png';
        _cachedRainViewerAt = now;
        return _cachedRainViewerTemplate;
      }
    }
  } catch (_) {}
  return _cachedRainViewerTemplate;
}

/// The app's single style-JSON provider. Loads the theme-appropriate
/// MapLibre style asset and substitutes the operator's
/// tile, glyph, and sprite endpoints from [mapStyleSourcesProvider], which
/// resolves from the network when reachable and from its persisted copy when
/// not — so this provider never blocks on connectivity.
///
/// Watches [themeModeProvider] and base/overlay settings so the provider
/// re-runs on theme or layer changes.
@Riverpod(keepAlive: true)
Future<String> mapStyleJson(Ref ref) async {
  final mode = ref.watch(themeModeProvider);
  final baseMode = ref.watch(localSettingsProvider.select((s) => s.mapBaseStyle));
  final overlaysRaw = ref.watch(
    localSettingsProvider.select((s) => s.mapOverlaysJson),
  );
  final sources = await ref.watch(mapStyleSourcesProvider.future);
  final brightness = effectiveBrightness(mode);
  final assetPath = brightness == Brightness.dark
      ? 'assets/map/wanderer_dark.json'
      : 'assets/map/wanderer_light.json';

  // spriteUrl is a theme-agnostic base (".../sprites/v4"); MapLibre resolves
  // "<sprite>@2x.png"/"<sprite>.json" etc. directly against it, so the
  // per-theme variant ("/light" or "/dark") must be appended here.
  final spriteVariant = brightness == Brightness.dark ? 'dark' : 'light';

  final raw = await rootBundle.loadString(assetPath);
  final substituted = raw
      .replaceAll('__TILE_URL__', sources.tileUrl)
      .replaceAll('__GLYPH_URL__', sources.glyphUrl)
      .replaceAll('__SPRITE_URL__', '${sources.spriteUrl}/$spriteVariant');

  final ovMap = decodeMapOverlaysJson(overlaysRaw);
  final activeOverlays = <String>{
    for (final key in const [
      'snowCover',
      'dailySatellite',
      'weatherRadar',
      'forestDisturbance',
      'waymarkedHiking',
    ])
      if (ovMap[key] == true) key,
  };
  final satelliteDate = (ovMap['satelliteDate'] as String?) ?? 'default';

  if (baseMode == 'default' && activeOverlays.isEmpty) {
    return substituted;
  }

  final rainViewerTpl = activeOverlays.contains('weatherRadar')
      ? await _resolveRainViewerTemplate()
      : null;

  final composed = composeSatelliteAndRasterOverlays(
    jsonDecode(substituted) as Map<String, dynamic>,
    baseMode: baseMode,
    activeOverlays: activeOverlays,
    rainViewerTileTemplate: rainViewerTpl,
    satelliteDate: satelliteDate,
  );
  return jsonEncode(composed);
}

/// Resolves the effective [Brightness] for a given [ThemeMode], falling back
/// to the platform's current brightness when the mode is [ThemeMode.system].
Brightness effectiveBrightness(ThemeMode mode) {
  if (mode == ThemeMode.dark) return Brightness.dark;
  if (mode == ThemeMode.light) return Brightness.light;
  return WidgetsBinding.instance.platformDispatcher.platformBrightness;
}
