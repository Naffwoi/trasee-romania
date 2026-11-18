import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maplibre/maplibre.dart' show Geographic;
import 'package:url_launcher/url_launcher.dart';
import 'package:wanderer/components/navigation/rescue_coordinates_and_signal_card.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/theme/colors.dart';
import 'package:wanderer/util/emergency/salvamont_resolver.dart';
import 'package:wanderer/util/map/heading_math.dart' show shortestAngleDelta;
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';

class SosTriggerSubmission {
  const SosTriggerSubmission({
    required this.reason,
    required this.message,
    required this.requesterName,
  });

  final SosReason reason;
  final String message;
  final String requesterName;
}

Future<void> _dialPhoneNumber(String number) async {
  final uri = Uri(scheme: 'tel', path: number);
  try {
    await launchUrl(uri);
  } catch (_) {
    // Ignore on simulators/devices without dialer capability.
  }
}

Future<SosTriggerSubmission?> showSosTriggerDialog(
  BuildContext context, {
  String initialName = '',
  bool isOnline = true,
  bool isRo = true,
  NearestSalvamontResolution? salvamontResolution,
  ValueChanged<SalvamontPoint>? onRouteToSalvamont,
  double? userLat,
  double? userLon,
  double? userEle,
  double? userAccuracy,
  DemTileGrid? demGrid,
  List<Geographic> trailPoints = const <Geographic>[],
}) {
  return showModalBottomSheet<SosTriggerSubmission>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SosTriggerDialog(
      initialName: initialName,
      isOnline: isOnline,
      isRo: isRo,
      salvamontResolution: salvamontResolution,
      onRouteToSalvamont: onRouteToSalvamont,
      userLat: userLat,
      userLon: userLon,
      userEle: userEle,
      userAccuracy: userAccuracy,
      demGrid: demGrid,
      trailPoints: trailPoints,
    ),
  );
}

/// Circular icon-only emergency SOS button for `NavigationScreen` (Waze-style, non-aggressive).
class SosFloatingButton extends StatelessWidget {
  const SosFloatingButton({
    super.key,
    required this.onPressed,
    this.isActive = false,
    this.isRo = true,
  });

  final VoidCallback onPressed;
  final bool isActive;
  final bool isRo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface.withValues(alpha: 0.94);
    return IconButton(
      key: const ValueKey('nav-sos-btn'),
      tooltip: isRo ? 'SOS Urgență' : 'SOS Emergency',
      onPressed: onPressed,
      icon: Icon(
        Icons.sos_rounded,
        color: isActive ? Colors.white : theme.colorScheme.onSurface,
        size: 21,
      ),
      style: IconButton.styleFrom(
        backgroundColor: isActive ? const Color(0xFFDC2626) : surface,
        side: BorderSide(
          color: isActive
              ? const Color(0xFFDC2626)
              : theme.colorScheme.outline.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class SosTriggerDialog extends StatefulWidget {
  const SosTriggerDialog({
    super.key,
    this.initialName = '',
    this.isOnline = true,
    this.isRo = true,
    this.salvamontResolution,
    this.onRouteToSalvamont,
    this.userLat,
    this.userLon,
    this.userEle,
    this.userAccuracy,
    this.demGrid,
    this.trailPoints = const <Geographic>[],
  });

  final String initialName;
  final bool isOnline;
  final bool isRo;
  final NearestSalvamontResolution? salvamontResolution;
  final ValueChanged<SalvamontPoint>? onRouteToSalvamont;
  final double? userLat;
  final double? userLon;
  final double? userEle;
  final double? userAccuracy;
  final DemTileGrid? demGrid;
  final List<Geographic> trailPoints;

  @override
  State<SosTriggerDialog> createState() => _SosTriggerDialogState();
}

class _SosTriggerDialogState extends State<SosTriggerDialog> {
  SosReason _reason = SosReason.lost;
  final TextEditingController _messageController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRo = widget.isRo;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: 16 + bottomInset,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    isRo ? 'SOS Urgență' : 'SOS Emergency',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFFDC2626),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('sos-ble-info-note'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.primaryLight.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.45 : 0.08,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.bluetooth_searching_rounded,
                    size: 17,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isRo
                          ? 'Dacă nu ai semnal mobil, alerta se trimite automat și prin Bluetooth drumeților din apropiere.'
                          : 'If you have no mobile signal, your alert is automatically sent via Bluetooth to nearby hikers.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.88,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('sos-call-112-btn'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB91C1C),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _dialPhoneNumber('112'),
                    icon: const Icon(Icons.phone_in_talk, size: 16),
                    label: const Text('112'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('sos-call-salvamont-btn'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF991B1B),
                      side: const BorderSide(color: Color(0xFFDC2626)),
                    ),
                    onPressed: () => _dialPhoneNumber('+40725826668'),
                    icon: const Icon(Icons.terrain, size: 16),
                    label: const Text(
                      '0-SALVAMONT',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.salvamontResolution != null &&
                widget.salvamontResolution!.isMountainZone &&
                widget.salvamontResolution!.nearestBases.isNotEmpty) ...[
              const SizedBox(height: 10),
              _SosNearestSalvamontCard(
                resolution: widget.salvamontResolution!,
                isRo: isRo,
                onRouteToSalvamont: widget.onRouteToSalvamont == null
                    ? null
                    : (pt) {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                        widget.onRouteToSalvamont!(pt);
                      },
              ),
            ],
            if (widget.userLat != null && widget.userLon != null) ...[
              const SizedBox(height: 10),
              RescueCoordinatesAndSignalCard(
                lat: widget.userLat!,
                lon: widget.userLon!,
                elevationM: widget.userEle,
                accuracyM: widget.userAccuracy,
                reasonRo: _reason.label(isRo: isRo),
                demGrid: widget.demGrid,
                trailPoints: widget.trailPoints,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in SosReason.values)
                  ChoiceChip(
                    key: ValueKey('sos-reason-${r.apiValue}'),
                    label: Text(r.label(isRo: isRo)),
                    selected: _reason == r,
                    onSelected: (_) => setState(() => _reason = r),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _messageController,
              maxLength: 200,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: isRo
                    ? 'Detalii scurte (opțional)...'
                    : 'Short details (optional)...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('sos-broadcast-submit-btn'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                Navigator.of(context).pop(
                  SosTriggerSubmission(
                    reason: _reason,
                    message: _messageController.text.trim(),
                    requesterName: widget.initialName.trim(),
                  ),
                );
              },
              child: Text(
                widget.isOnline
                    ? (isRo ? 'Trimite SOS în zonă' : 'Send SOS nearby')
                    : (isRo
                          ? 'Trimite SOS fără semnal · Bluetooth'
                          : 'Send offline SOS · Bluetooth'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live comforting status bar displayed to the requester while their own SOS
/// alert is active (*„X persoane vin spre tine”* / *„SOS fără semnal · trimis prin Bluetooth”*).
class MyActiveSosBanner extends StatelessWidget {
  const MyActiveSosBanner({
    super.key,
    required this.sos,
    required this.onResolve,
    this.isOnline = true,
    this.isSubmitting = false,
    this.isRo = true,
  });

  final SosAlertModel sos;
  final VoidCallback onResolve;
  final bool isOnline;
  final bool isSubmitting;
  final bool isRo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLocalUnconfirmed =
        sos.id.startsWith('local-') && !sos.bleServerConfirmed;
    final showOfflineBatteryTip = !isOnline || isLocalUnconfirmed;

    final String responderLine;
    if (isLocalUnconfirmed) {
      responderLine = isRo
          ? '📡 SOS fără semnal · trimis prin Bluetooth'
          : '📡 Offline SOS · sent via Bluetooth';
    } else {
      final count = sos.effectiveResponderCount;
      if (count <= 0) {
        responderLine = isRo
            ? 'SOS Activ · Alertă trimisă drumeților pe 5 km (0 persoane confirmate încă)'
            : 'SOS Active · Broadcast to hikers within 5 km (waiting for responders)';
      } else {
        final base = isRo
            ? (count == 1
                  ? 'SOS Activ · 1 persoană vine spre tine'
                  : 'SOS Activ · $count persoane vin spre tine')
            : (count == 1
                  ? 'SOS Active · 1 hiker is coming to you'
                  : 'SOS Active · $count hikers are coming to you');
        final distM = sos.nearestDistanceM ?? sos.bleNearestDistanceM;
        final etaSec = sos.nearestEtaSec;
        final bleEta = sos.bleNearestEtaMin;
        final distText = (distM != null && distM > 0)
            ? (distM >= 1000
                  ? '${(distM / 1000.0).toStringAsFixed(1)} km'
                  : '${distM.round()} m')
            : null;
        final etaMin = (etaSec != null && etaSec > 0)
            ? math.max(1, (etaSec / 60.0).round())
            : bleEta;
        if (distText != null && etaMin != null) {
          responderLine = isRo
              ? '$base · cel mai aproape la $distText (~$etaMin min)'
              : '$base · nearest $distText (~$etaMin min)';
        } else if (distText != null) {
          responderLine = '$base · $distText';
        } else if (etaMin != null) {
          responderLine = '$base · ~$etaMin min';
        } else {
          responderLine = base;
        }
      }
    }

    final bleAckCount = sos.bleAckCount;
    final bleEtaMin = sos.bleNearestEtaMin;
    final String? bleAckStatusLine;
    if (bleAckCount > 0) {
      final etaSuffix = bleEtaMin != null ? ' · ~$bleEtaMin min' : '';
      bleAckStatusLine = isRo
          ? (bleAckCount == 1
                ? '✓ Preluat prin Bluetooth de 1 drumeț$etaSuffix'
                : '✓ Preluat prin Bluetooth de $bleAckCount drumeți$etaSuffix')
          : '✓ Picked up via Bluetooth by $bleAckCount hiker(s)$etaSuffix';
    } else {
      bleAckStatusLine = null;
    }

    final String? bleServerRelayLine = sos.bleServerConfirmed
        ? (isRo
              ? '✓ Alertă ajunsă la server prin drumeț din apropiere'
              : '✓ Alert reached server via nearby hiker')
        : null;

    return Card(
      key: const ValueKey('my-active-sos-banner'),
      elevation: 6,
      color: const Color(0xFF991B1B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!isLocalUnconfirmed) ...[
                  const Text('🆘', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    responderLine,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (isLocalUnconfirmed && bleAckStatusLine == null) ...[
              const SizedBox(height: 3),
              Text(
                isRo
                    ? 'Alerta se transmite automat către drumeții din apropiere și va fi trimisă online imediat ce apare semnal.'
                    : 'Alert is automatically broadcast via Bluetooth and will sync online once signal returns.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ],
            if (bleAckStatusLine != null) ...[
              const SizedBox(height: 5),
              Text(
                bleAckStatusLine,
                key: const ValueKey('sos-ble-ack-status'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (bleServerRelayLine != null) ...[
              const SizedBox(height: 4),
              Text(
                bleServerRelayLine,
                key: const ValueKey('sos-ble-server-confirmed'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (showOfflineBatteryTip) ...[
              const SizedBox(height: 8),
              Container(
                key: const ValueKey('sos-offline-battery-tip'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                child: Text(
                  isRo
                      ? '🔋 Economisire baterie fără semnal: pornește Modul Avion, păstrează Bluetooth și GPS active și blochează ecranul.'
                      : '🔋 Offline battery saver: turn on Airplane Mode, keep Bluetooth and GPS active, and lock your screen.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.96),
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _dialPhoneNumber('112'),
                  icon: const Icon(Icons.phone, size: 15),
                  label: const Text('112'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('sos-resolve-mine-btn'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF991B1B),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: isSubmitting ? null : onResolve,
                    child: Text(
                      isRo
                          ? 'Am rezolvat / Anulează SOS'
                          : 'Resolved / Cancel SOS',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// High-priority red rescue banner displayed to nearby hikers within 5 km (or
/// over offline BLE mesh) when another hiker triggers SOS, offering
/// **„Vin în ajutor”** + live DEM A* guidance.
class NearbySosResponderBanner extends StatelessWidget {
  const NearbySosResponderBanner({
    super.key,
    required this.sos,
    this.directDistanceMeters,
    this.rescueRoute,
    this.userHeadingDeg,
    required this.onRespondComing,
    required this.onCancelRespond,
    this.isOnline = true,
    this.isSubmitting = false,
    this.isRo = true,
  });

  final SosAlertModel sos;
  final double? directDistanceMeters;
  final OffTrailRerouteResult? rescueRoute;
  final double? userHeadingDeg;
  final VoidCallback onRespondComing;
  final VoidCallback onCancelRespond;
  final bool isOnline;
  final bool isSubmitting;
  final bool isRo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = rescueRoute;
    final effectiveDistM = route?.distanceM ?? directDistanceMeters;
    final distLabel = (effectiveDistM != null && effectiveDistM.isFinite)
        ? (effectiveDistM >= 1000
              ? '${(effectiveDistM / 1000.0).toStringAsFixed(2)} km'
              : '${effectiveDistM.round()} m')
        : null;
    final etaMin = route != null
        ? math.max(1, (route.estimatedSeconds / 60.0).round())
        : null;
    final climbM = route?.ascentM.round();

    final who = sos.requesterName.trim().isNotEmpty
        ? '${sos.requesterName.trim()} · ${sos.reason.label(isRo: isRo)}'
        : sos.reason.label(isRo: isRo);

    final hopLabel = (sos.viaBluetooth && sos.bleHopCount > 0)
        ? (isRo
              ? 'releu ${sos.bleHopCount} ${sos.bleHopCount == 1 ? 'salt' : 'salturi'}'
              : '${sos.bleHopCount}-hop relay')
        : null;

    return Card(
      key: const ValueKey('nearby-sos-responder-banner'),
      elevation: 7,
      color: const Color(0xFFDC2626),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (sos.amResponding && route != null)
                  Container(
                    width: 40,
                    height: 40,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Transform.rotate(
                        angle:
                            shortestAngleDelta(
                              userHeadingDeg ?? 0.0,
                              route.initialBearingDeg,
                            ) *
                            math.pi /
                            180.0,
                        child: const Icon(
                          Icons.navigation,
                          color: Colors.white,
                          size: 23,
                        ),
                      ),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Text('🆘', style: TextStyle(fontSize: 20)),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sos.viaBluetooth
                            ? (isRo
                                  ? '🆘 Alertă SOS în apropiere · prin Bluetooth'
                                  : '🆘 Nearby SOS Alert · via Bluetooth')
                            : (isRo
                                  ? '🆘 Ajutor solicitat în apropiere!'
                                  : '🆘 Nearby hiker needs help!'),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          who,
                          if (distLabel != null) distLabel,
                          if (climbM != null && climbM > 0) '+$climbM m',
                          if (etaMin != null) '~$etaMin min',
                          if (hopLabel != null) hopLabel,
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.95),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (sos.message.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '„${sos.message.trim()}”',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (sos.amResponding && route != null) ...[
              const SizedBox(height: 4),
              Text(
                '${route.instruction} · ${route.slopeAdvice}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (!sos.amResponding)
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('sos-respond-btn'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFFB91C1C),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: isSubmitting ? null : onRespondComing,
                      icon: const Icon(Icons.directions_run, size: 18),
                      label: Text(
                        isRo ? 'Vin în ajutor' : 'I am coming to help',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  )
                else ...[
                  Expanded(
                    child: Text(
                      (!isOnline || sos.viaBluetooth)
                          ? (isRo
                                ? 'Rută de salvare offline activă pe hartă · confirmare trimisă prin Bluetooth'
                                : 'Offline rescue route active · confirmation sent via Bluetooth')
                          : (isRo
                                ? 'Rută DEM A* activă pe hartă (${sos.effectiveResponderCount} salvatori)'
                                : 'DEM A* rescue route active (${sos.effectiveResponderCount} responders)'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                  OutlinedButton(
                    key: const ValueKey('sos-cancel-respond-btn'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: isSubmitting ? null : onCancelRespond,
                    child: Text(isRo ? 'Anulează' : 'Cancel'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SosNearestSalvamontCard extends StatelessWidget {
  const _SosNearestSalvamontCard({
    required this.resolution,
    required this.isRo,
    this.onRouteToSalvamont,
  });

  final NearestSalvamontResolution resolution;
  final bool isRo;
  final ValueChanged<SalvamontPoint>? onRouteToSalvamont;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = resolution.nearestBases.first;
    final distStr = primary.distanceM >= 1000
        ? '${(primary.distanceM / 1000.0).toStringAsFixed(1)} km'
        : '${primary.distanceM.round()} m';

    return Container(
      key: const ValueKey('sos-salvamont-nearest-card'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${primary.point.name} ($distStr ${primary.cardinal})',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (resolution.isRidgeBorderZone)
                Container(
                  key: const ValueKey('sos-ridge-border-badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    isRo
                        ? 'Creastă ${resolution.borderCountyCodes.join(' / ')}'
                        : 'Ridge ${resolution.borderCountyCodes.join(' / ')}',
                    style: const TextStyle(
                      color: Color(0xFF92400E),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          if (resolution.nearestRefuge != null &&
              resolution.nearestRefuge!.distanceM < primary.distanceM) ...[
            const SizedBox(height: 3),
            Text(
              '⛺ ${resolution.nearestRefuge!.point.name} (${resolution.nearestRefuge!.distanceM >= 1000 ? '${(resolution.nearestRefuge!.distanceM / 1000.0).toStringAsFixed(1)} km' : '${resolution.nearestRefuge!.distanceM.round()} m'})',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final svcEntry in resolution.activeServices)
                OutlinedButton.icon(
                  key: ValueKey('sos-call-local-${svcEntry.service.id}'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                  onPressed: () =>
                      _dialPhoneNumber(svcEntry.service.primaryPhone),
                  icon: const Icon(Icons.call, size: 13),
                  label: Text(
                    '${svcEntry.service.shortName}: ${formatRoPhoneDisplay(svcEntry.service.primaryPhone)}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          if (onRouteToSalvamont != null) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('sos-route-to-salvamont-btn'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF242734),
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => onRouteToSalvamont!(primary.point),
              icon: const Icon(Icons.route, size: 15),
              label: Text(
                isRo
                    ? 'Rută pe teren spre ${primary.point.name}'
                    : 'Terrain route to ${primary.point.name}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
