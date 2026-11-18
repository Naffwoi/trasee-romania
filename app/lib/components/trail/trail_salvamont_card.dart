import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpx/gpx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wanderer/models/trail.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/salvamont_provider.dart';
import 'package:wanderer/util/emergency/salvamont_resolver.dart';

class TrailSalvamontCard extends ConsumerWidget {
  const TrailSalvamontCard({
    super.key,
    required this.trail,
    this.gpx,
  });

  final Trail trail;
  final Gpx? gpx;

  Future<void> _dial(String number) async {
    final uri = Uri(scheme: 'tel', path: number);
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ds = ref.watch(salvamontDatasetProvider).value;
    if (ds == null) return const SizedBox.shrink();

    final langCode = ref.watch(localeProvider)?.languageCode ?? 'ro';
    final isRo = !langCode.toLowerCase().startsWith('en');

    final pts = <({double lat, double lon, double? ele})>[];
    if (gpx != null) {
      for (final trk in gpx!.trks) {
        for (final seg in trk.trksegs) {
          for (final wpt in seg.trkpts) {
            if (wpt.lat != null && wpt.lon != null) {
              pts.add((lat: wpt.lat!, lon: wpt.lon!, ele: wpt.ele));
            }
          }
        }
      }
    }
    if (pts.isEmpty && trail.lat != null && trail.lon != null) {
      pts.add((lat: trail.lat!, lon: trail.lon!, ele: null));
    }

    final summary = resolveTrailSalvamontSummary(
      ds,
      pts,
      localeCode: isRo ? 'ro' : 'en',
    );
    if (summary == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final base = summary.nearestBase;
    final distStr = base.distanceM >= 1000
        ? '${(base.distanceM / 1000.0).toStringAsFixed(1)} km'
        : '${base.distanceM.round()} m';

    return Container(
      key: const ValueKey('trail-salvamont-card'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFF242734),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 17,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isRo
                      ? 'Acoperire Salvamont pe traseu'
                      : 'Salvamont Trail Coverage',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (summary.crossesCountyBorder)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
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
                    summary.countyCodes.join(' / '),
                    style: const TextStyle(
                      color: Color(0xFF92400E),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isRo
                ? 'Cea mai apropiată bază: ${base.point.name} ($distStr de traseu)'
                : 'Nearest base: ${base.point.name} ($distStr from trail)',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (summary.nearestRefuge != null) ...[
            const SizedBox(height: 3),
            Text(
              '⛺ ${summary.nearestRefuge!.point.name}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                backgroundColor: const Color(0xFFDC2626),
                side: BorderSide.none,
                labelStyle: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
                label: const Text('📞 112'),
                onPressed: () => _dial('112'),
              ),
              ActionChip(
                backgroundColor: const Color(0xFF242734),
                side: BorderSide.none,
                labelStyle: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
                label: const Text('0-SALVAMONT'),
                onPressed: () => _dial(ds.nationalDispatchPhone),
              ),
              for (final svcEntry in summary.services)
                ActionChip(
                  labelStyle: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                  label: Text(
                    '${svcEntry.service.shortName}: ${formatRoPhoneDisplay(svcEntry.service.primaryPhone)}',
                  ),
                  onPressed: () => _dial(svcEntry.service.primaryPhone),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
