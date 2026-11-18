import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/util/emergency/salvamont_resolver.dart';

Future<void> _dialE164(String number) async {
  final uri = Uri(scheme: 'tel', path: number);
  try {
    await launchUrl(uri);
  } catch (_) {}
}

Future<void> showSalvamontPointSheet(
  BuildContext context, {
  required SalvamontPoint point,
  required SalvamontDataset dataset,
  double? refLat,
  double? refLon,
  double? refEle,
  bool isTrailRef = false,
  bool isRo = true,
  ValueChanged<SalvamontPoint>? onRouteToPoint,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final svc = dataset.services[point.serviceId];
      final directPhone =
          point.directBasePhone ??
          svc?.primaryPhone ??
          dataset.nationalDispatchPhone;
      final res = (refLat != null && refLon != null)
          ? resolveNearestSalvamont(
              dataset,
              refLat,
              refLon,
              k: dataset.points.length,
              userEle: refEle,
              localeCode: isRo ? 'ro' : 'en',
              isTrailRef: isTrailRef,
            )
          : null;
      final allResolved = <ResolvedSalvamontPoint>[
        ...?res?.nearestBases,
        if (res?.nearestRefuge != null) res!.nearestRefuge!,
      ];
      final match = allResolved.where((r) => r.point.id == point.id).firstOrNull;

      final kindText = point.isRefuge
          ? (isRo ? 'Refugiu Salvamont (fără personal)' : 'Rescue Refuge (unmanned)')
          : (point.permanence == SalvamontPermanence.seasonal
                ? (isRo ? 'Post Salvamont sezonier' : 'Seasonal Rescue Post')
                : (isRo ? 'Bază Salvamont 24/7' : '24/7 Rescue Base'));

      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF242734),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  kindText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              point.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              point.ele > 0 ? '${point.massif} · ${point.ele} m' : point.massif,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (match != null && match.distanceM <= 60000) ...[
              const SizedBox(height: 4),
              Text(
                () {
                  final dStr = match.distanceM >= 1000
                      ? '${(match.distanceM / 1000.0).toStringAsFixed(1)} km'
                      : '${match.distanceM.round()} m';
                  final suffix = isTrailRef
                      ? (isRo ? 'de traseu' : 'from trail')
                      : (isRo ? 'de tine' : 'from you');
                  final eleStr = match.deltaEleM != null
                      ? ' · ${match.deltaEleM! >= 0 ? '+${match.deltaEleM}' : '${match.deltaEleM}'} m'
                      : '';
                  return '📍 $dStr ${match.cardinal} $suffix$eleStr';
                }(),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (svc != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  '${svc.name} · ${svc.phoneRoleRo}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _dialE164('112'),
                    icon: const Icon(Icons.phone_in_talk, size: 16),
                    label: const Text(
                      '112',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF242734),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _dialE164(dataset.nationalDispatchPhone),
                    icon: const Icon(Icons.terrain, size: 16),
                    label: const Text(
                      '0-SALVAMONT',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
            if (directPhone != dataset.nationalDispatchPhone) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _dialE164(directPhone),
                icon: const Icon(Icons.call, size: 16),
                label: Text(
                  '${svc?.shortName ?? 'Salvamont'} (${formatRoPhoneDisplay(directPhone)})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (onRouteToPoint != null) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('salvamont-sheet-route-btn'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF242734),
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  Navigator.of(ctx).pop();
                  onRouteToPoint(point);
                },
                icon: const Icon(Icons.route, size: 17),
                label: Text(
                  isRo ? 'Rută spre Baza Salvamont' : 'Route to Salvamont Base',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
