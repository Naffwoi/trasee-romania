import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/services/platform_http_adapter.dart';

void main() {
  group('createPlatformHttpClientAdapter', () {
    test('returns IOHttpClientAdapter inside flutter test VM environment', () {
      final adapter = createPlatformHttpClientAdapter();
      expect(adapter, isA<IOHttpClientAdapter>());
      adapter.close(force: true);
    });

    test('returns IOHttpClientAdapter on non-mobile desktop targets even when isTestEnv=false', () {
      final adapter = createPlatformHttpClientAdapter(
        isTestEnvOverride: false,
        targetOsOverride: 'linux',
      );
      expect(adapter, isA<IOHttpClientAdapter>());
      adapter.close(force: true);
    });

    test('exposes shouldUseNativeQuicAdapter pure predicate accurately', () {
      expect(
        shouldUseNativeQuicAdapter(isTestEnv: true, os: 'android'),
        isFalse,
      );
      expect(
        shouldUseNativeQuicAdapter(isTestEnv: false, os: 'android'),
        isTrue,
      );
      expect(
        shouldUseNativeQuicAdapter(isTestEnv: false, os: 'ios'),
        isTrue,
      );
      expect(
        shouldUseNativeQuicAdapter(isTestEnv: false, os: 'macos'),
        isFalse,
      );
    });
  });
}
