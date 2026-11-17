import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:wanderer/util/map/heading_math.dart';

/// Smoothed device compass reading (degrees clockwise from North) and optional
/// angular accuracy in degrees.
class CompassHeadingReading {
  final double heading;
  final double? accuracy;

  const CompassHeadingReading({
    required this.heading,
    this.accuracy,
  });
}

/// Injectable raw azimuth stream factory (degrees clockwise from North) for testing.
final rawAzimuthDegreesStreamFactoryProvider =
    Provider<Stream<double> Function()>((ref) {
      return () {
        if (kIsWeb ||
            (!Platform.isAndroid && !Platform.isIOS) ||
            !RotationSensor.isPlatformSupported) {
          return const Stream<double>.empty();
        }
        RotationSensor.samplingPeriod = const Duration(milliseconds: 50);
        RotationSensor.coordinateSystem = CoordinateSystem.display();
        return RotationSensor.orientationStream.map(
          (event) => event.eulerAngles.azimuth * 180.0 / math.pi,
        );
      };
    });

final compassHeadingStreamProvider =
    NotifierProvider<CompassHeadingStream, Stream<CompassHeadingReading?>>(
      CompassHeadingStream.new,
    );

/// Scopes live compass sensor usage to widget lifetime; stops hardware subscription
/// when the last map unmounts or when the app enters the background.
final liveCompassProvider =
    Provider.autoDispose<Stream<CompassHeadingReading?>>((ref) {
      final notifier = ref.read(compassHeadingStreamProvider.notifier);
      notifier.acquire();
      ref.onDispose(notifier.release);
      return notifier.replaying;
    });

class CompassHeadingStream extends Notifier<Stream<CompassHeadingReading?>>
    with WidgetsBindingObserver {
  final _filter = CircularHeadingFilter(alpha: 0.22, deadbandDeg: 0.5);
  StreamSubscription<double>? _sensorSub;
  late StreamController<CompassHeadingReading?> _controller;
  late Stream<CompassHeadingReading?> replaying;

  CompassHeadingReading? _latest;
  int _consumers = 0;
  bool _uiSuspended = false;

  void acquire() {
    _consumers++;
    if (_consumers == 1 && !_uiSuspended) {
      _startSensor();
    }
  }

  void release() {
    if (_consumers > 0) _consumers--;
    if (_consumers == 0) {
      _stopSensor();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final suspend = switch (state) {
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => true,
      AppLifecycleState.resumed || AppLifecycleState.inactive => false,
    };
    if (suspend == _uiSuspended) return;
    _uiSuspended = suspend;
    if (suspend) {
      _stopSensor();
    } else if (_consumers > 0) {
      _startSensor();
    }
  }

  void _startSensor() {
    if (_sensorSub != null || _consumers == 0 || _uiSuspended) return;
    final factory = ref.read(rawAzimuthDegreesStreamFactoryProvider);
    try {
      _sensorSub = factory().listen(
        (rawDegrees) {
          if (_controller.isClosed) return;
          final smoothed = _filter.update(rawDegrees);
          if (smoothed != null) {
            _latest = CompassHeadingReading(heading: smoothed);
            _controller.add(_latest);
          }
        },
        onError: (_) {
          // Degrade gracefully when sensor is unavailable on simulator/desktop
        },
      );
    } catch (_) {
      // Degrade gracefully when platform plugin is unavailable (e.g. unit tests)
      _sensorSub = null;
    }
  }

  void _stopSensor() {
    _sensorSub?.cancel();
    _sensorSub = null;
    _filter.reset();
    _latest = null;
  }

  @override
  Stream<CompassHeadingReading?> build() {
    _controller = StreamController<CompassHeadingReading?>.broadcast();
    WidgetsBinding.instance.addObserver(this);

    final ghost = _controller.stream.listen(null, onError: (_) {});
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      ghost.cancel();
      _stopSensor();
      _controller.close();
    });

    replaying = Stream<CompassHeadingReading?>.multi((listener) {
      final latest = _latest;
      if (latest != null) listener.add(latest);
      final sub = _controller.stream.listen(
        listener.add,
        onError: listener.addError,
        onDone: listener.close,
      );
      listener.onCancel = sub.cancel;
    }, isBroadcast: true);

    return _controller.stream;
  }
}
