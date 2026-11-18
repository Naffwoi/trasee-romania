import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

/// Pure decision helper so unit tests verify target gating deterministically.
@visibleForTesting
bool shouldUseNativeQuicAdapter({
  required bool isTestEnv,
  required String os,
}) {
  if (kIsWeb || isTestEnv) return false;
  return os == 'android' || os == 'ios';
}

/// Builds a QUIC / HTTP/3-capable native adapter on physical Android (Cronet)
/// and iOS (NSURLSession) devices for 0-RTT cell-tower connection migration,
/// while keeping `IOHttpClientAdapter` in `flutter test`, desktop builds, and
/// de-Googled AOSP devices without a Cronet provider.
HttpClientAdapter createPlatformHttpClientAdapter({
  bool? isTestEnvOverride,
  String? targetOsOverride,
}) {
  final isTestEnv =
      isTestEnvOverride ?? Platform.environment.containsKey('FLUTTER_TEST');
  final os = targetOsOverride ?? Platform.operatingSystem;

  if (!shouldUseNativeQuicAdapter(isTestEnv: isTestEnv, os: os)) {
    return IOHttpClientAdapter();
  }

  return NativeAdapter(
    createCronetEngine: () => CronetEngine.build(
      cacheMode: CacheMode.memory,
      cacheMaxSize: 4 * 1024 * 1024,
      enableQuic: true,
      enableHttp2: true,
      enableBrotli: true,
    ),
    createCupertinoConfiguration: () =>
        URLSessionConfiguration.ephemeralSessionConfiguration()
          ..allowsCellularAccess = true
          ..allowsExpensiveNetworkAccess = true
          ..allowsConstrainedNetworkAccess = true
          ..waitsForConnectivity = false,
    createFallbackAdapter: (_, _) => IOHttpClientAdapter(),
  );
}
