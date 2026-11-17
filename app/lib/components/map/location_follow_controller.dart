import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:wanderer/provider/compass_heading_stream_provider.dart';
import 'package:wanderer/provider/foreground_position_stream_provider.dart';
import 'package:wanderer/provider/location_tracking_mode_provider.dart';
import 'package:wanderer/util/map/heading_math.dart';

/// Invisible map-child coordinator that drives the camera in `followNorthUp`
/// and `followHeadingUp` modes, and drops back to `freeTracking` when the user
/// manually pans or rotates the map.
class LocationFollowController extends ConsumerStatefulWidget {
  final ValueNotifier<LocationTrackingMode> trackingMode;

  const LocationFollowController({
    super.key,
    required this.trackingMode,
  });

  @override
  ConsumerState<LocationFollowController> createState() =>
      _LocationFollowControllerState();
}

class _LocationFollowControllerState
    extends ConsumerState<LocationFollowController>
    with SingleTickerProviderStateMixin {
  static const double _kBearingTauSeconds = 0.14;
  static const Duration _kModeTransitionDuration = Duration(milliseconds: 300);

  Stream<LocationMarkerPosition?>? _boundPosStream;
  Stream<CompassHeadingReading?>? _boundCompassStream;
  StreamSubscription<LocationMarkerPosition?>? _posSub;
  StreamSubscription<CompassHeadingReading?>? _compassSub;
  late final Ticker _bearingTicker = createTicker(_onBearingTick);

  LocationMarkerPosition? _latestPos;
  double? _compassHeading;
  double _currentBearing = 0.0;
  Duration? _lastTickElapsed;
  Timer? _transitionTimer;
  bool _inModeTransition = false;
  bool _pendingSmartZoom = false;
  final Map<int, Offset> _pointers = {};

  double? get _effectiveTargetHeading {
    if (_compassHeading != null) return _compassHeading;
    final gpsHeading = _latestPos?.heading;
    if (gpsHeading != null && gpsHeading.isFinite && gpsHeading >= 0) {
      return gpsHeading;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.trackingMode.addListener(_onModeChanged);
  }

  @override
  void didUpdateWidget(covariant LocationFollowController oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackingMode != widget.trackingMode) {
      oldWidget.trackingMode.removeListener(_onModeChanged);
      widget.trackingMode.addListener(_onModeChanged);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    widget.trackingMode.removeListener(_onModeChanged);
    _transitionTimer?.cancel();
    _posSub?.cancel();
    _compassSub?.cancel();
    _bearingTicker.stop();
    _bearingTicker.dispose();
    super.dispose();
  }

  void _beginModeTransition() {
    _transitionTimer?.cancel();
    _inModeTransition = true;
    _transitionTimer = Timer(const Duration(milliseconds: 320), () {
      _inModeTransition = false;
    });
  }

  void _onModeChanged() {
    if (!mounted) return;
    final mode = widget.trackingMode.value;
    final controller = ml.MapController.maybeOf(context);
    final camera = ml.MapCamera.maybeOf(context);
    if (camera != null) {
      _currentBearing = camera.bearing;
    }

    if (mode == LocationTrackingMode.followNorthUp) {
      _pendingSmartZoom = true;
    } else if (mode != LocationTrackingMode.followHeadingUp) {
      _pendingSmartZoom = false;
      _transitionTimer?.cancel();
      _inModeTransition = false;
    }

    _syncTicker();

    if (controller == null || _latestPos == null) return;
    final center = ml.Geographic(
      lat: _latestPos!.latitude,
      lon: _latestPos!.longitude,
    );
    final currentZoom = camera?.zoom ?? 14.0;
    final targetZoom = currentZoom < 14.0 ? 15.5 : currentZoom;

    if (mode == LocationTrackingMode.followNorthUp) {
      _pendingSmartZoom = false;
      _currentBearing = 0.0;
      _beginModeTransition();
      controller.animateCamera(
        center: center,
        zoom: targetZoom,
        bearing: 0.0,
        nativeDuration: _kModeTransitionDuration,
      );
    } else if (mode == LocationTrackingMode.followHeadingUp) {
      _pendingSmartZoom = false;
      final heading = _effectiveTargetHeading ?? _currentBearing;
      _currentBearing = heading;
      _beginModeTransition();
      controller.animateCamera(
        center: center,
        zoom: targetZoom,
        bearing: heading,
        nativeDuration: _kModeTransitionDuration,
      );
    }
  }

  void _syncTicker() {
    final shouldRun =
        widget.trackingMode.value == LocationTrackingMode.followHeadingUp &&
        _effectiveTargetHeading != null;
    if (shouldRun && !_bearingTicker.isTicking) {
      _lastTickElapsed = null;
      _bearingTicker.start();
    } else if (!shouldRun && _bearingTicker.isTicking) {
      _bearingTicker.stop();
    }
  }

  void _onBearingTick(Duration elapsed) {
    if (!mounted) return;
    final controller = ml.MapController.maybeOf(context);
    final target = _effectiveTargetHeading;
    if (controller == null ||
        target == null ||
        widget.trackingMode.value != LocationTrackingMode.followHeadingUp) {
      return;
    }

    if (_inModeTransition) {
      _lastTickElapsed = elapsed;
      return;
    }

    final dtSeconds = _lastTickElapsed == null
        ? 1.0 / 60.0
        : (elapsed - _lastTickElapsed!).inMicroseconds / 1e6;
    _lastTickElapsed = elapsed;
    if (dtSeconds <= 0) return;

    final alpha = 1.0 - math.exp(-dtSeconds / _kBearingTauSeconds);
    final nextBearing = lerpBearing(
      _currentBearing,
      target,
      alpha.clamp(0.05, 1.0),
    );
    if (shortestAngleDelta(_currentBearing, nextBearing).abs() < 0.04) {
      return;
    }
    _currentBearing = nextBearing;

    final center = _latestPos != null
        ? ml.Geographic(lat: _latestPos!.latitude, lon: _latestPos!.longitude)
        : ml.MapCamera.maybeOf(context)?.center;

    controller.moveCamera(
      center: center,
      bearing: _currentBearing,
    );
  }

  void _bindStreams() {
    final posStream = ref.watch(liveLocationProvider);
    final compassStream = ref.watch(liveCompassProvider);

    if (!identical(posStream, _boundPosStream)) {
      _boundPosStream = posStream;
      _posSub?.cancel();
      _posSub = posStream.listen(
        (pos) {
          _latestPos = pos;
          if (pos == null || !mounted) return;
          final mode = widget.trackingMode.value;
          if (mode != LocationTrackingMode.followNorthUp &&
              mode != LocationTrackingMode.followHeadingUp) {
            return;
          }
          _syncTicker();
          if (_inModeTransition) {
            return;
          }
          final controller = ml.MapController.maybeOf(context);
          if (controller == null) return;

          final center = ml.Geographic(lat: pos.latitude, lon: pos.longitude);
          final bearing = mode == LocationTrackingMode.followNorthUp
              ? 0.0
              : _currentBearing;

          if (_pendingSmartZoom) {
            _pendingSmartZoom = false;
            final currentZoom = ml.MapCamera.maybeOf(context)?.zoom ?? 14.0;
            final targetZoom = currentZoom < 14.0 ? 15.5 : currentZoom;
            _beginModeTransition();
            controller.animateCamera(
              center: center,
              zoom: targetZoom,
              bearing: bearing,
              nativeDuration: _kModeTransitionDuration,
            );
            return;
          }

          controller.moveCamera(
            center: center,
            bearing: bearing,
          );
        },
        onError: (_) {},
      );
    }

    if (!identical(compassStream, _boundCompassStream)) {
      _boundCompassStream = compassStream;
      _compassSub?.cancel();
      _compassSub = compassStream.listen(
        (reading) {
          _compassHeading = reading?.heading;
          if (mounted) _syncTicker();
        },
        onError: (_) {},
      );
    }
  }

  void _handlePointerMove(PointerMoveEvent e) {
    final start = _pointers[e.pointer];
    if (start == null) return;
    if ((e.position - start).distance > 8.0) {
      final mode = widget.trackingMode.value;
      if (mode == LocationTrackingMode.followNorthUp ||
          mode == LocationTrackingMode.followHeadingUp) {
        widget.trackingMode.value = LocationTrackingMode.freeTracking;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _bindStreams();

    // Translucent Listener detects physical pan/rotate drags (> 8px) over the
    // map canvas without consuming events, dropping follow mode to freeTracking.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointers[e.pointer] = e.position;
      },
      onPointerMove: _handlePointerMove,
      onPointerUp: (e) {
        _pointers.remove(e.pointer);
      },
      onPointerCancel: (e) {
        _pointers.remove(e.pointer);
      },
      child: const SizedBox.expand(),
    );
  }
}
