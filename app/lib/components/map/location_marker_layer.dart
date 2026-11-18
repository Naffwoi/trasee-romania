import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:wanderer/provider/compass_heading_stream_provider.dart';
import 'package:wanderer/provider/foreground_position_stream_provider.dart';
import 'package:wanderer/provider/nav_session_hibernation_provider.dart';
import 'package:wanderer/util/map/heading_math.dart';

const Color kGoogleMapsBlue = Color(0xFF4285F4);

/// The on-map "you are here" indicator: a Google Maps blue dot with a white
/// border and a rotating radial-gradient flashlight cone behind it.
class LocationPuck extends StatelessWidget {
  const LocationPuck({
    super.key,
    this.size = 88,
    this.dotSize = 18,
    this.heading,
    this.headingAccuracy,
    this.showHeading = true,
  });

  /// Overall bounding box (matches the enclosing [ml.Marker]'s size) — also
  /// the cone's canvas when [showHeading] is on.
  final double size;

  /// Diameter of the static dot.
  final double dotSize;

  final double? heading;
  final double? headingAccuracy;

  /// Whether to draw the heading flashlight cone at all.
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final hasValidHeading =
        showHeading && heading != null && heading!.isFinite && heading! >= 0;
    final halfAngleDeg = coneHalfAngleFromAccuracy(headingAccuracy);

    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (hasValidHeading && size > dotSize)
              Transform.rotate(
                key: const ValueKey('gmaps-heading-cone'),
                angle: heading! * math.pi / 180.0,
                child: CustomPaint(
                  size: Size(size, size),
                  painter: _FlashlightConePainter(
                    halfAngleDeg: halfAngleDeg,
                  ),
                ),
              ),
            Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: kGoogleMapsBlue,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .35),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FlashlightConePainter extends CustomPainter {
  const _FlashlightConePainter({required this.halfAngleDeg});

  final double halfAngleDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    if (radius <= 0) return;
    final center = Offset(radius, size.height / 2);
    final sweepRadians = (halfAngleDeg * 2) * math.pi / 180.0;
    // -pi/2 is straight up (North = 0 deg)
    final startAngle = -math.pi / 2 - sweepRadians / 2;

    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          kGoogleMapsBlue.withValues(alpha: 0.72),
          kGoogleMapsBlue.withValues(alpha: 0.34),
          kGoogleMapsBlue.withValues(alpha: 0.0),
        ],
        stops: const [0.18, 0.62, 1.0],
      ).createShader(rect);

    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(rect, startAngle, sweepRadians, false)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FlashlightConePainter oldDelegate) =>
      oldDelegate.halfAngleDeg != halfAngleDeg;
}

class _AccuracyHaloPainter extends CustomPainter {
  const _AccuracyHaloPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    if (radius < 4) return;
    final center = Offset(radius, size.height / 2);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = kGoogleMapsBlue.withValues(alpha: 0.12);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = kGoogleMapsBlue.withValues(alpha: 0.30);

    canvas.drawCircle(center, radius, fillPaint);
    canvas.drawCircle(center, radius, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _AccuracyHaloPainter oldDelegate) => false;
}

/// Live location + compass layer for interactive maps.
/// Combines [liveLocationProvider] (GPS fix + accuracy) and [liveCompassProvider]
/// (device orientation azimuth while stationary or moving) and compensates for
/// the current [ml.MapCamera.bearing].
class LocationMarkerLayer extends ConsumerStatefulWidget {
  const LocationMarkerLayer({
    super.key,
    this.dotSize = 18,
    this.coneSize = 88,
  });

  final double dotSize;
  final double coneSize;

  @override
  ConsumerState<LocationMarkerLayer> createState() =>
      _LocationMarkerLayerState();
}

class _LocationMarkerLayerState extends ConsumerState<LocationMarkerLayer> {
  double? _cachedZoom;
  double? _cachedLat;
  double _cachedMetersPerPx = 0.0;

  double _resolveMetersPerPixel(
    ml.MapController? controller,
    ml.MapCamera? camera,
    double lat,
  ) {
    if (controller == null || camera == null) return 0.0;
    if (_cachedZoom != null &&
        _cachedLat != null &&
        (camera.zoom - _cachedZoom!).abs() < 0.02 &&
        (lat - _cachedLat!).abs() < 0.005) {
      return _cachedMetersPerPx;
    }
    try {
      final mpp = controller.getMetersPerPixelAtLatitude(lat);
      if (mpp.isFinite && mpp > 0) {
        _cachedZoom = camera.zoom;
        _cachedLat = lat;
        _cachedMetersPerPx = mpp;
        return mpp;
      }
    } catch (_) {
      // Ignore if controller is mocked or native projection is not ready yet.
    }
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    if (!shouldAcquireForegroundMapSensors(context, ref)) {
      return const SizedBox.shrink();
    }
    final controller = ml.MapController.maybeOf(context);
    final camera = ml.MapCamera.maybeOf(context);
    final cameraBearing = camera?.bearing ?? 0.0;

    final positionStream = ref.watch(liveLocationProvider);
    final compassStream = ref.watch(liveCompassProvider);

    return StreamBuilder<LocationMarkerPosition?>(
      stream: positionStream,
      builder: (context, posSnapshot) {
        final position = posSnapshot.data;
        if (position == null) return const SizedBox.shrink();

        final point = ml.Geographic(
          lat: position.latitude,
          lon: position.longitude,
        );

        double haloDiameterPx = 0;
        if (controller != null &&
            camera != null &&
            position.accuracy.isFinite &&
            position.accuracy >= 5.0) {
          final clampedMeters = position.accuracy.clamp(5.0, 2000.0);
          final mpp = _resolveMetersPerPixel(
            controller,
            camera,
            position.latitude,
          );
          if (mpp > 0) {
            haloDiameterPx = ((clampedMeters / mpp) * 2.0).clamp(0.0, 640.0);
          }
        }

        return StreamBuilder<CompassHeadingReading?>(
          stream: compassStream,
          builder: (context, compassSnapshot) {
            final compass = compassSnapshot.data;
            final double? rawWorldHeading =
                compass?.heading ??
                ((position.heading != null &&
                        position.heading!.isFinite &&
                        position.heading! >= 0)
                    ? position.heading
                    : null);
            final double? screenHeading = rawWorldHeading == null
                ? null
                : normalizeHeading(rawWorldHeading - cameraBearing);
            final double? accuracy = compass != null
                ? compass.accuracy
                : position.headingAccuracy;

            return ml.WidgetLayer(
              markers: [
                if (haloDiameterPx >= widget.dotSize + 6)
                  ml.Marker(
                    point: point,
                    size: Size(haloDiameterPx, haloDiameterPx),
                    child: const IgnorePointer(
                      child: SizedBox.expand(
                        child: CustomPaint(painter: _AccuracyHaloPainter()),
                      ),
                    ),
                  ),
                ml.Marker(
                  point: point,
                  size: Size(widget.coneSize, widget.coneSize),
                  child: LocationPuck(
                    size: widget.coneSize,
                    dotSize: widget.dotSize,
                    heading: screenHeading,
                    headingAccuracy: accuracy,
                    showHeading: true,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
