// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_settings_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(LocalSettingsNotifier)
final localSettingsProvider = LocalSettingsNotifierProvider._();

final class LocalSettingsNotifierProvider
    extends $NotifierProvider<LocalSettingsNotifier, LocalSettingsEntity> {
  LocalSettingsNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localSettingsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localSettingsNotifierHash();

  @$internal
  @override
  LocalSettingsNotifier create() => LocalSettingsNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LocalSettingsEntity value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LocalSettingsEntity>(value),
    );
  }
}

String _$localSettingsNotifierHash() =>
    r'b12bf21a1e9da9e8b309ff051348480f9c45b320';

abstract class _$LocalSettingsNotifier extends $Notifier<LocalSettingsEntity> {
  LocalSettingsEntity build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<LocalSettingsEntity, LocalSettingsEntity>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<LocalSettingsEntity, LocalSettingsEntity>,
              LocalSettingsEntity,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(themeMode)
final themeModeProvider = ThemeModeProvider._();

final class ThemeModeProvider
    extends $FunctionalProvider<ThemeMode, ThemeMode, ThemeMode>
    with $Provider<ThemeMode> {
  ThemeModeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'themeModeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$themeModeHash();

  @$internal
  @override
  $ProviderElement<ThemeMode> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  ThemeMode create(Ref ref) {
    return themeMode(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ThemeMode value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ThemeMode>(value),
    );
  }
}

String _$themeModeHash() => r'688b55e2c54c3ee17b0d204c96143c1ca617264f';

@ProviderFor(locale)
final localeProvider = LocaleProvider._();

final class LocaleProvider
    extends $FunctionalProvider<Locale?, Locale?, Locale?>
    with $Provider<Locale?> {
  LocaleProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'localeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$localeHash();

  @$internal
  @override
  $ProviderElement<Locale?> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  Locale? create(Ref ref) {
    return locale(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(Locale? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<Locale?>(value),
    );
  }
}

String _$localeHash() => r'91fb75995faecbb71c068dbc8c7cd89d4f22a974';

@ProviderFor(unit)
final unitProvider = UnitProvider._();

final class UnitProvider extends $FunctionalProvider<String, String, String>
    with $Provider<String> {
  UnitProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'unitProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$unitHash();

  @$internal
  @override
  $ProviderElement<String> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String create(Ref ref) {
    return unit(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }
}

String _$unitHash() => r'61cb2b8e04879730d2520f184f8c89b7c5d086a9';

@ProviderFor(showSalvamontLayer)
final showSalvamontLayerProvider = ShowSalvamontLayerProvider._();

final class ShowSalvamontLayerProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  ShowSalvamontLayerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'showSalvamontLayerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$showSalvamontLayerHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return showSalvamontLayer(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$showSalvamontLayerHash() =>
    r'd4693575446b68a647ed6fffbe0fc252a986b7a9';

@ProviderFor(showAvalancheSlope)
final showAvalancheSlopeProvider = ShowAvalancheSlopeProvider._();

final class ShowAvalancheSlopeProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  ShowAvalancheSlopeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'showAvalancheSlopeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$showAvalancheSlopeHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return showAvalancheSlope(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$showAvalancheSlopeHash() =>
    r'57e56f759fc350824d89476875f0417741d92176';

@ProviderFor(showSolarShadows)
final showSolarShadowsProvider = ShowSolarShadowsProvider._();

final class ShowSolarShadowsProvider
    extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  ShowSolarShadowsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'showSolarShadowsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$showSolarShadowsHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return showSolarShadows(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$showSolarShadowsHash() => r'cf96b0fd0113db8041a4f64bf4e06470f878686c';
