// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'map_style_json_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The app's single style-JSON provider. Loads the theme-appropriate
/// MapLibre style asset and substitutes the operator's
/// tile, glyph, and sprite endpoints from [mapStyleSourcesProvider], which
/// resolves from the network when reachable and from its persisted copy when
/// not — so this provider never blocks on connectivity.
///
/// Watches [themeModeProvider] and base/overlay settings so the provider
/// re-runs on theme or layer changes.

@ProviderFor(mapStyleJson)
final mapStyleJsonProvider = MapStyleJsonProvider._();

/// The app's single style-JSON provider. Loads the theme-appropriate
/// MapLibre style asset and substitutes the operator's
/// tile, glyph, and sprite endpoints from [mapStyleSourcesProvider], which
/// resolves from the network when reachable and from its persisted copy when
/// not — so this provider never blocks on connectivity.
///
/// Watches [themeModeProvider] and base/overlay settings so the provider
/// re-runs on theme or layer changes.

final class MapStyleJsonProvider
    extends $FunctionalProvider<AsyncValue<String>, String, FutureOr<String>>
    with $FutureModifier<String>, $FutureProvider<String> {
  /// The app's single style-JSON provider. Loads the theme-appropriate
  /// MapLibre style asset and substitutes the operator's
  /// tile, glyph, and sprite endpoints from [mapStyleSourcesProvider], which
  /// resolves from the network when reachable and from its persisted copy when
  /// not — so this provider never blocks on connectivity.
  ///
  /// Watches [themeModeProvider] and base/overlay settings so the provider
  /// re-runs on theme or layer changes.
  MapStyleJsonProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'mapStyleJsonProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$mapStyleJsonHash();

  @$internal
  @override
  $FutureProviderElement<String> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<String> create(Ref ref) {
    return mapStyleJson(ref);
  }
}

String _$mapStyleJsonHash() => r'541f9e4daae9da194cc5c6ab4f2c0a35ced22657';
