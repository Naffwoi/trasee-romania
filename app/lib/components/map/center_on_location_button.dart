import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:wanderer/components/map/location_marker_layer.dart'
    show kGoogleMapsBlue;
import 'package:wanderer/i18n/app_localizations.dart';
import 'package:wanderer/provider/compass_heading_stream_provider.dart';
import 'package:wanderer/provider/foreground_position_stream_provider.dart';
import 'package:wanderer/provider/location_tracking_mode_provider.dart';
import 'package:wanderer/provider/nav_session_hibernation_provider.dart';

/// Round floating "center on my location" button supporting Google Maps
/// 3-state cycling (`freeTracking -> followNorthUp -> followHeadingUp -> followNorthUp`).
/// Disabled until there is a fix; legacy callers can omit [trackingMode] and
/// handle centering via [onPressed].
class CenterOnLocationButton extends ConsumerWidget {
  final ValueChanged<ml.Geographic> onPressed;
  final ValueNotifier<LocationTrackingMode>? trackingMode;

  const CenterOnLocationButton({
    super.key,
    required this.onPressed,
    this.trackingMode,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!shouldAcquireForegroundMapSensors(context, ref)) {
      return const SizedBox.shrink();
    }
    final posStream = ref.watch(liveLocationProvider);
    final compassStream = ref.watch(liveCompassProvider);

    return StreamBuilder<LocationMarkerPosition?>(
      stream: posStream,
      builder: (context, posSnapshot) {
        final position = posSnapshot.data;
        return StreamBuilder<CompassHeadingReading?>(
          stream: compassStream,
          builder: (context, compassSnapshot) {
            final hasHeading =
                compassSnapshot.data != null ||
                (position?.heading != null &&
                    position!.heading!.isFinite &&
                    position.heading! >= 0);

            Widget buildButton(LocationTrackingMode mode) {
              final isActive =
                  mode == LocationTrackingMode.followNorthUp ||
                  mode == LocationTrackingMode.followHeadingUp;
              final iconData = mode == LocationTrackingMode.followHeadingUp
                  ? FontAwesomeIcons.locationArrow
                  : FontAwesomeIcons.locationCrosshairs;

              return Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 4,
                shadowColor: Colors.black26,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: FaIcon(
                    iconData,
                    size: 18,
                    color: isActive ? kGoogleMapsBlue : null,
                  ),
                  tooltip: AppLocalizations.of(context)!.center_on_my_location,
                  onPressed: position == null
                      ? null
                      : () {
                          final notifier = trackingMode;
                          if (notifier != null) {
                            notifier.value = nextLocationTrackingMode(
                              notifier.value,
                              hasHeading: hasHeading,
                            );
                          }
                          onPressed(
                            ml.Geographic(
                              lat: position.latitude,
                              lon: position.longitude,
                            ),
                          );
                        },
                ),
              );
            }

            final notifier = trackingMode;
            if (notifier == null) {
              return buildButton(LocationTrackingMode.freeTracking);
            }
            return ValueListenableBuilder<LocationTrackingMode>(
              valueListenable: notifier,
              builder: (context, mode, _) => buildButton(mode),
            );
          },
        );
      },
    );
  }
}
