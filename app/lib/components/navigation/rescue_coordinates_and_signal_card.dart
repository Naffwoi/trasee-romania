import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maplibre/maplibre.dart' show Geographic;
import 'package:url_launcher/url_launcher.dart';
import 'package:wanderer/util/emergency/gsm_viewshed.dart';
import 'package:wanderer/util/emergency/rescue_coordinates.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';

class RescueCoordinatesAndSignalCard extends StatefulWidget {
  const RescueCoordinatesAndSignalCard({
    super.key,
    required this.lat,
    required this.lon,
    this.elevationM,
    this.accuracyM,
    this.reasonRo = 'Urgență',
    this.demGrid,
    this.trailPoints = const <Geographic>[],
  });

  final double lat;
  final double lon;
  final double? elevationM;
  final double? accuracyM;
  final String reasonRo;
  final DemTileGrid? demGrid;
  final List<Geographic> trailPoints;

  @override
  State<RescueCoordinatesAndSignalCard> createState() =>
      _RescueCoordinatesAndSignalCardState();
}

class _RescueCoordinatesAndSignalCardState
    extends State<RescueCoordinatesAndSignalCard> {
  EmergencySpatialIndex? _index;
  GsmSignalRecommendation? _signalRec;
  bool _signalExpanded = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    EmergencySpatialIndex.loadFromAsset().then((idx) {
      if (mounted) setState(() => _index = idx);
    });
  }

  Future<void> _launchSms(String recipient, String asciiBody) async {
    final isIOS = !kIsWeb && Platform.isIOS;
    final uri = buildEmergencySmsUri(
      recipient: recipient,
      asciiBody: asciiBody,
      isIOS: isIOS,
    );
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _toggleSignalFinder() {
    setState(() {
      _signalExpanded = !_signalExpanded;
      if (_signalExpanded) {
        final idx =
            _index ?? EmergencySpatialIndex.fromJson(const <String, dynamic>{});
        final dem =
            widget.demGrid ??
            DemTileGrid(customSampler: (_, _) => widget.elevationM ?? 1200.0);
        _signalRec = findBestGsm112SignalSpot(
          lat: widget.lat,
          lon: widget.lon,
          dem: dem,
          index: idx,
          trailPoints: widget.trailPoints,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lm = _index?.findNearestLandmark(widget.lat, widget.lon);
    final bundle = formatRescueCoordinates(
      lat: widget.lat,
      lon: widget.lon,
      elevationM: widget.elevationM,
      accuracyM: widget.accuracyM,
      reasonRo: widget.reasonRo,
      landmark: lm != null
          ? (name: lm.name, lat: lm.lat, lon: lm.lon, eleM: lm.eleM)
          : null,
    );

    return Container(
      key: const ValueKey('rescue-coordinates-card'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.40,
        ),
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
                  'FIȘĂ COORDONATE 112 / SALVAMONT',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              InkWell(
                key: const ValueKey('rescue-copy-coords-btn'),
                onTap: () async {
                  await Clipboard.setData(
                    ClipboardData(text: bundle.clipboardFullCardRo),
                  );
                  if (!mounted) return;
                  setState(() => _copied = true);
                  Future<void>.delayed(const Duration(seconds: 2), () {
                    if (mounted) setState(() => _copied = false);
                  });
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF242734),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _copied ? '✓ Copiat' : 'Copiază tot',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            [
              'WGS84: ${bundle.wgs84Decimal}',
              'DMS:   ${bundle.wgs84Dms}',
              'UTM:   ${bundle.utm.formatted}',
              'Plus:  ${bundle.plusCode}',
              if (bundle.elevationM != null)
                'Alt:   ${bundle.elevationM} m${bundle.accuracyM != null ? ' (±${bundle.accuracyM} m)' : ''}${bundle.nearestLandmark != null ? ' · ${bundle.nearestLandmark!.summaryRo}' : ''}',
            ].join('\n'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('sos-sms-coords-btn'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      _launchSms('+40725826668', bundle.sms113AsciiBody),
                  icon: const Icon(Icons.sms_outlined, size: 15),
                  label: const Text(
                    'SMS Coordonate',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('sos-sms-113-btn'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _launchSms('113', bundle.sms113AsciiBody),
                  child: const Text(
                    'SMS 113 (STS)',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '112 folosește automat orice rețea disponibilă. SMS 113 necesită număr înregistrat prealabil la STS.',
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
            ),
          ),
          const SizedBox(height: 6),
          FilledButton.tonalIcon(
            key: const ValueKey('sos-gsm-viewshed-btn'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _toggleSignalFinder,
            icon: const Icon(Icons.cell_tower, size: 16),
            label: const Text(
              'Unde prind semnal 112? (Analiză relief)',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ),
          if (_signalExpanded && _signalRec != null) ...[
            const SizedBox(height: 6),
            Container(
              key: const ValueKey('sos-gsm-viewshed-result'),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                _signalRec!.instructionRo,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
