import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:objectbox/objectbox.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wanderer/entities/local_settings_entity.dart';
import 'package:wanderer/provider/objectbox_store_provider.dart';
import 'package:wanderer/provider/settings_provider.dart';

part 'local_settings_provider.g.dart';

Map<String, dynamic> decodeMapOverlaysJson(String raw) {
  if (raw.isEmpty) return <String, dynamic>{};
  try {
    final parsed = jsonDecode(raw);
    return parsed is Map<String, dynamic>
        ? Map<String, dynamic>.from(parsed)
        : <String, dynamic>{};
  } catch (_) {
    return <String, dynamic>{};
  }
}

@Riverpod(keepAlive: true)
class LocalSettingsNotifier extends _$LocalSettingsNotifier {
  Box<LocalSettingsEntity> get _box =>
      ref.read(objectBoxProvider).box<LocalSettingsEntity>();

  @override
  LocalSettingsEntity build() {
    final box = ref.watch(objectBoxProvider).box<LocalSettingsEntity>();
    return box.getAll().firstOrNull ?? LocalSettingsEntity();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    entity.themeMode = _modeToString(mode);
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> markBackgroundLocationAsked() async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    if (entity.backgroundLocationAsked) return;
    entity.backgroundLocationAsked = true;
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> setExpeditionBatteryMode(bool enabled) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    if (entity.expeditionBatteryMode == enabled) return;
    entity.expeditionBatteryMode = enabled;
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> setShowSalvamontLayer(bool visible) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    if (entity.showSalvamontLayer == visible) return;
    entity.showSalvamontLayer = visible;
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> setShowAvalancheSlope(bool enabled) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    if (entity.showAvalancheSlope == enabled) return;
    entity.showAvalancheSlope = enabled;
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> setShowSolarShadows(bool enabled) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    if (entity.showSolarShadows == enabled) return;
    entity.showSolarShadows = enabled;
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> setMapBaseStyle(String styleKey) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    if (entity.mapBaseStyle == styleKey) return;
    entity.mapBaseStyle = styleKey;
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> toggleMapOverlay(String overlayKey, bool enabled) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    final map = decodeMapOverlaysJson(entity.mapOverlaysJson);
    map[overlayKey] = enabled;
    entity.mapOverlaysJson = jsonEncode(map);
    _box.put(entity);
    ref.invalidateSelf();
  }

  Future<void> setSatellitePassDate(String dateOrDefault) async {
    final entity = _box.getAll().firstOrNull ?? LocalSettingsEntity();
    final map = decodeMapOverlaysJson(entity.mapOverlaysJson);
    map['satelliteDate'] = dateOrDefault;
    entity.mapOverlaysJson = jsonEncode(map);
    _box.put(entity);
    ref.invalidateSelf();
  }

  String _modeToString(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}

@Riverpod(keepAlive: true)
ThemeMode themeMode(Ref ref) {
  final settings = ref.watch(localSettingsProvider);
  return switch (settings.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

@Riverpod(keepAlive: true)
Locale? locale(Ref ref) {
  final lang = ref.watch(settingsProvider)?.language;
  if (lang == null) return null;
  return Locale(lang.name);
}

@Riverpod(keepAlive: true)
String unit(Ref ref) {
  final settings = ref.watch(settingsProvider);
  return settings?.unit ?? 'metric';
}

final expeditionBatteryModeProvider = Provider<bool>((ref) {
  final settings = ref.watch(localSettingsProvider);
  return settings.expeditionBatteryMode;
});

@Riverpod(keepAlive: true)
bool showSalvamontLayer(Ref ref) =>
    ref.watch(localSettingsProvider).showSalvamontLayer;

@Riverpod(keepAlive: true)
bool showAvalancheSlope(Ref ref) =>
    ref.watch(localSettingsProvider).showAvalancheSlope;

@Riverpod(keepAlive: true)
bool showSolarShadows(Ref ref) =>
    ref.watch(localSettingsProvider).showSolarShadows;
