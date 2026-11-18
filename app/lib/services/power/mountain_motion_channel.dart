import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

enum MountainMotionEventKind { motionSample, stepWake, battery }

class MountainMotionEvent {
  const MountainMotionEvent({
    required this.kind,
    this.stepBandVariance = 0.0,
    this.isMovingHardware = true,
    this.batteryPercent,
    this.osLowPowerMode,
  });

  final MountainMotionEventKind kind;
  final double stepBandVariance;
  final bool isMovingHardware;
  final int? batteryPercent;
  final bool? osLowPowerMode;
}

class MountainBatterySnapshot {
  const MountainBatterySnapshot({
    required this.batteryPercent,
    required this.osLowPowerMode,
  });

  final int batteryPercent;
  final bool osLowPowerMode;

  static const MountainBatterySnapshot full = MountainBatterySnapshot(
    batteryPercent: 100,
    osLowPowerMode: false,
  );
}

class MountainMotionChannel {
  MountainMotionChannel({
    MethodChannel methodChannel = const MethodChannel(
      'com.openwanderer.wanderer/mountain_motion',
    ),
    EventChannel eventChannel = const EventChannel(
      'com.openwanderer.wanderer/mountain_motion/events',
    ),
    Stream<Object?>? eventStreamOverride,
    bool? isSupportedPlatformOverride,
  }) : _methodChannel = methodChannel,
       _eventChannel = eventChannel,
       _eventStreamOverride = eventStreamOverride,
       _isSupported =
           isSupportedPlatformOverride ??
           (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final Stream<Object?>? _eventStreamOverride;
  final bool _isSupported;

  final StreamController<MountainMotionEvent> _controller =
      StreamController<MountainMotionEvent>.broadcast();
  StreamSubscription<Object?>? _sub;
  bool _disposed = false;

  bool get isSupported => _isSupported;
  Stream<MountainMotionEvent> get events => _controller.stream;

  void _ensureListening() {
    if (_sub != null || !_isSupported || _disposed) return;
    final rawStream =
        _eventStreamOverride ?? _eventChannel.receiveBroadcastStream();
    _sub = rawStream.listen(_onRawEvent, onError: (_) {});
  }

  void _onRawEvent(Object? raw) {
    if (_disposed || _controller.isClosed || raw is! Map) return;
    final kindStr = raw['kind']?.toString() ?? 'motion_sample';
    final kind = switch (kindStr) {
      'step_wake' => MountainMotionEventKind.stepWake,
      'battery' => MountainMotionEventKind.battery,
      _ => MountainMotionEventKind.motionSample,
    };
    final variance = (raw['stepBandVariance'] as num?)?.toDouble() ?? 0.0;
    final moving = raw['isMovingHardware'] == true;
    final bat = (raw['batteryPercent'] as num?)?.toInt();
    final lowPower = raw['osLowPowerMode'] as bool?;

    _controller.add(
      MountainMotionEvent(
        kind: kind,
        stepBandVariance: variance.isFinite ? variance : 0.0,
        isMovingHardware: moving,
        batteryPercent: bat,
        osLowPowerMode: lowPower,
      ),
    );
  }

  Future<bool> startStepMonitoring() async {
    if (!_isSupported || _disposed) return false;
    _ensureListening();
    try {
      final ok = await _methodChannel
          .invokeMethod<bool>('startStepMonitoring')
          .timeout(const Duration(seconds: 3));
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> armStationaryWakeTrigger() async {
    if (!_isSupported || _disposed) return false;
    _ensureListening();
    try {
      final ok = await _methodChannel
          .invokeMethod<bool>('armStationaryWakeTrigger')
          .timeout(const Duration(seconds: 3));
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<MountainBatterySnapshot> getBatterySnapshot() async {
    if (!_isSupported || _disposed) return MountainBatterySnapshot.full;
    try {
      final map = await _methodChannel
          .invokeMethod<Map<Object?, Object?>>('getBatterySnapshot')
          .timeout(const Duration(seconds: 2));
      if (map == null) return MountainBatterySnapshot.full;
      final pct = (map['batteryPercent'] as num?)?.toInt() ?? 100;
      final lowPower = map['osLowPowerMode'] == true;
      return MountainBatterySnapshot(
        batteryPercent: pct.clamp(0, 100),
        osLowPowerMode: lowPower,
      );
    } on MissingPluginException {
      return MountainBatterySnapshot.full;
    } catch (_) {
      return MountainBatterySnapshot.full;
    }
  }

  Future<void> stop() async {
    if (!_isSupported) return;
    try {
      await _methodChannel
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    await stop();
    await _controller.close();
  }
}
