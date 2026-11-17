import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wanderer/models/live/trail_live_models.dart';
import 'package:wanderer/util/map/heading_math.dart' show shortestAngleDelta;
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
  bool isRo = true,
}) {
  return showModalBottomSheet<SosTriggerSubmission>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SosTriggerDialog(
      initialName: initialName,
      isRo: isRo,
    ),
  );
}

/// Floating `🆘 Ajutor` emergency button for `NavigationScreen`.
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
    final bg = isActive ? const Color(0xFFB91C1C) : const Color(0xFFDC2626);
    return Material(
      color: bg,
      elevation: 4,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        key: const ValueKey('nav-sos-btn'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🆘', style: TextStyle(fontSize: 15)),
              const SizedBox(width: 4),
              Text(
                isActive ? 'SOS' : (isRo ? 'Ajutor' : 'SOS'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SosTriggerDialog extends StatefulWidget {
  const SosTriggerDialog({
    super.key,
    this.initialName = '',
    this.isRo = true,
  });

  final String initialName;
  final bool isRo;

  @override
  State<SosTriggerDialog> createState() => _SosTriggerDialogState();
}

class _SosTriggerDialogState extends State<SosTriggerDialog> {
  SosReason _reason = SosReason.lost;
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  final TextEditingController _messageController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
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
        left: 20,
        right: 20,
        top: 12,
        bottom: 20 + bottomInset,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('🆘', style: TextStyle(fontSize: 24)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isRo
                        ? 'Solicită ajutor în apropiere'
                        : 'Request nearby SOS help',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Official 112 & Salvamont reminder box.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFFDC2626).withValues(alpha: 0.5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isRo
                        ? 'Pentru urgențe medicale sau pericol vital, sună imediat la 112 sau Salvamont!'
                        : 'For life-threatening or medical emergencies, call 112 or Mountain Rescue immediately!',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF991B1B),
                      fontWeight: FontWeight.w700,
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
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => _dialPhoneNumber('112'),
                          icon: const Icon(Icons.phone_in_talk, size: 16),
                          label: Text(isRo ? 'Sună 112' : 'Call 112'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('sos-call-salvamont-btn'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF991B1B),
                            side: const BorderSide(color: Color(0xFFDC2626)),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => _dialPhoneNumber('0725826668'),
                          icon: const Icon(Icons.terrain, size: 16),
                          label: const Text(
                            'Salvamont',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              isRo
                  ? 'Motivul solicitării (trimis drumeților pe o rază de 5 km)'
                  : 'Reason (broadcast to hikers within 5 km)',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
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
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              maxLength: 40,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: isRo ? 'Prenume / Nume (opțional)' : 'Name (optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLength: 200,
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: isRo
                    ? 'Ce s-a întâmplat / cu ce te pot ajuta?'
                    : 'How can nearby hikers help?',
                hintText: isRo
                    ? 'Ex: gleznă luxată, am nevoie de sprijin sau apă'
                    : 'E.g. sprained ankle, need water or support',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('sos-broadcast-submit-btn'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                Navigator.of(context).pop(
                  SosTriggerSubmission(
                    reason: _reason,
                    message: _messageController.text.trim(),
                    requesterName: _nameController.text.trim(),
                  ),
                );
              },
              icon: const Icon(Icons.campaign_rounded),
              label: Text(
                isRo
                    ? '🆘 Trimite SOS în rază de 5 km'
                    : '🆘 Broadcast SOS within 5 km',
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
/// alert is active (*„X persoane vin spre tine”*).
class MyActiveSosBanner extends StatelessWidget {
  const MyActiveSosBanner({
    super.key,
    required this.sos,
    required this.onResolve,
    this.isSubmitting = false,
    this.isRo = true,
  });

  final SosAlertModel sos;
  final VoidCallback onResolve;
  final bool isSubmitting;
  final bool isRo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = sos.responderCount;
    final String responderLine;
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
      final distM = sos.nearestDistanceM;
      final etaSec = sos.nearestEtaSec;
      final distText = (distM != null && distM > 0)
          ? (distM >= 1000
                ? '${(distM / 1000.0).toStringAsFixed(1)} km'
                : '${distM.round()} m')
          : null;
      final etaMin = (etaSec != null && etaSec > 0)
          ? math.max(1, (etaSec / 60.0).round())
          : null;
      if (distText != null && etaMin != null) {
        responderLine = isRo
            ? '$base · cel mai aproape la $distText (~$etaMin min)'
            : '$base · nearest $distText (~$etaMin min)';
      } else if (distText != null) {
        responderLine = '$base · $distText';
      } else {
        responderLine = base;
      }
    }

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
                const Text('🆘', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
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
                          ? 'Sunt în siguranță (Oprește SOS)'
                          : 'I am safe (Stop SOS)',
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

/// High-priority red rescue banner displayed to nearby hikers within 5 km when
/// another hiker triggers SOS, offering **„Vin să ajut”** + live DEM A* guidance.
class NearbySosResponderBanner extends StatelessWidget {
  const NearbySosResponderBanner({
    super.key,
    required this.sos,
    this.directDistanceMeters,
    this.rescueRoute,
    this.userHeadingDeg,
    required this.onRespondComing,
    required this.onCancelRespond,
    this.isSubmitting = false,
    this.isRo = true,
  });

  final SosAlertModel sos;
  final double? directDistanceMeters;
  final OffTrailRerouteResult? rescueRoute;
  final double? userHeadingDeg;
  final VoidCallback onRespondComing;
  final VoidCallback onCancelRespond;
  final bool isSubmitting;
  final bool isRo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveDistM = rescueRoute?.distanceM ?? directDistanceMeters;
    final distLabel = (effectiveDistM != null && effectiveDistM.isFinite)
        ? (effectiveDistM >= 1000
              ? '${(effectiveDistM / 1000.0).toStringAsFixed(2)} km'
              : '${effectiveDistM.round()} m')
        : null;
    final etaMin = rescueRoute != null
        ? math.max(1, (rescueRoute!.estimatedSeconds / 60.0).round())
        : null;
    final climbM = rescueRoute?.ascentM.round();

    final who = sos.requesterName.trim().isNotEmpty
        ? '${sos.requesterName.trim()} · ${sos.reason.label(isRo: isRo)}'
        : sos.reason.label(isRo: isRo);

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
                if (sos.amResponding && rescueRoute != null)
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
                              rescueRoute!.initialBearingDeg,
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
                        isRo
                            ? '🆘 Ajutor solicitat în apropiere!'
                            : '🆘 Nearby hiker needs help!',
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
            if (sos.amResponding && rescueRoute != null) ...[
              const SizedBox(height: 4),
              Text(
                '${rescueRoute!.instruction} · ${rescueRoute!.slopeAdvice}',
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
                        isRo ? 'Vin să ajut' : 'I am coming to help',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  )
                else ...[
                  Expanded(
                    child: Text(
                      isRo
                          ? 'Rută DEM A* activă pe hartă (${sos.responderCount} salvatori)'
                          : 'DEM A* rescue route active (${sos.responderCount} responders)',
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
