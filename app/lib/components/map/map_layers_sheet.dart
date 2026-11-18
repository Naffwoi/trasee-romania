import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:wanderer/provider/local_settings_provider.dart';

Future<void> showMapLayersSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(
      context,
    ).colorScheme.surface.withValues(alpha: 0.96),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const MapLayersSheet(),
  );
}

class MapLayersSheet extends ConsumerWidget {
  const MapLayersSheet({super.key});

  static const _baseOptions = <(String, String, FaIconData)>[
    ('default', 'Hartă Vectorială', FontAwesomeIcons.map),
    ('esri_satellite', 'Satelit (Esri HD)', FontAwesomeIcons.satellite),
    ('sentinel2_cloudless', 'Sentinel-2 Fără Nori', FontAwesomeIcons.globe),
    ('opentopomap', 'OpenTopoMap', FontAwesomeIcons.mountain),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(localSettingsProvider);
    final notifier = ref.read(localSettingsProvider.notifier);
    final ovMap = decodeMapOverlaysJson(settings.mapOverlaysJson);
    final theme = Theme.of(context);
    final recentDates = List<String>.generate(
      7,
      (i) => DateTime.now()
          .toUtc()
          .subtract(Duration(days: i + 1))
          .toIso8601String()
          .substring(0, 10),
    );
    final currentSatDate = (ovMap['satelliteDate'] as String?) ?? 'default';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Straturi hartă & satelit',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const FaIcon(FontAwesomeIcons.xmark, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label, icon) in _baseOptions)
                  ChoiceChip(
                    avatar: FaIcon(icon, size: 13),
                    label: Text(label),
                    selected: settings.mapBaseStyle == key,
                    onSelected: (_) => notifier.setMapBaseStyle(key),
                  ),
              ],
            ),
            const Divider(height: 24),
            Text('Siguranță montană & teren', style: theme.textTheme.labelLarge),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Baze și refugii Salvamont'),
              value: settings.showSalvamontLayer,
              onChanged: notifier.setShowSalvamontLayer,
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Unghi pantă avalanșă (>27°/30°)'),
              value: settings.showAvalancheSlope,
              onChanged: notifier.setShowAvalancheSlope,
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Umbre solare pe relief'),
              value: settings.showSolarShadows,
              onChanged: notifier.setShowSolarShadows,
            ),
            const Divider(height: 20),
            Text('Satelit live & mediu', style: theme.textTheme.labelLarge),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Strat de zăpadă satelit (NASA NOAA-20)'),
              value: ovMap['snowCover'] == true,
              onChanged: (v) => notifier.toggleMapOverlay('snowCover', v),
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Satelit zilnic True Color (NASA)'),
              value: ovMap['dailySatellite'] == true,
              onChanged: (v) => notifier.toggleMapOverlay('dailySatellite', v),
            ),
            if (ovMap['snowCover'] == true || ovMap['dailySatellite'] == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DropdownButtonFormField<String>(
                  initialValue:
                      currentSatDate == 'default' ||
                              recentDates.contains(currentSatDate)
                          ? currentSatDate
                          : 'default',
                  decoration: const InputDecoration(
                    labelText: 'Data pasajului satelitar',
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'default',
                      child: Text('Ultimul pasaj disponibil'),
                    ),
                    for (final d in recentDates)
                      DropdownMenuItem(value: d, child: Text(d)),
                  ],
                  onChanged: (val) {
                    if (val != null) notifier.setSatellitePassDate(val);
                  },
                ),
              ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Radar precipitații live (RainViewer)'),
              value: ovMap['weatherRadar'] == true,
              onChanged: (v) => notifier.toggleMapOverlay('weatherRadar', v),
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Doborâturi / tăieri recente (GFW)'),
              value: ovMap['forestDisturbance'] == true,
              onChanged: (v) =>
                  notifier.toggleMapOverlay('forestDisturbance', v),
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Marcaje turistice (Waymarked Trails)'),
              value: ovMap['waymarkedHiking'] == true,
              onChanged: (v) => notifier.toggleMapOverlay('waymarkedHiking', v),
            ),
          ],
        ),
      ),
    );
  }
}
