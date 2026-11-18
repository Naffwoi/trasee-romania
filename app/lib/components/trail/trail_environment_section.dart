import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:wanderer/models/live/trail_environment_models.dart';
import 'package:wanderer/provider/api_provider.dart';

class TrailEnvironmentSection extends ConsumerStatefulWidget {
  final String trailId;
  const TrailEnvironmentSection({super.key, required this.trailId});

  @override
  ConsumerState<TrailEnvironmentSection> createState() =>
      _TrailEnvironmentSectionState();
}

class _TrailEnvironmentSectionState
    extends ConsumerState<TrailEnvironmentSection> {
  TrailEnvironmentPayload? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.trailId.isEmpty) return;
    try {
      final res = await ref
          .read(apiProvider)
          .get<Map<String, dynamic>>(
            '/live/trail/${widget.trailId}/environment',
          );
      if (mounted && res.data != null) {
        setState(() => _data = TrailEnvironmentPayload.fromJson(res.data!));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null ||
        (data.weather == null &&
            data.gorgeFlood?.warning != true &&
            data.hazards.isEmpty)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final w = data.weather;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'METEO LA ALTITUDINE & ALERTE SATELIT',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (w != null)
                Text('${w.elevationM.round()} m', style: theme.textTheme.labelSmall),
            ],
          ),
          if (w != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Temp.',
                    value: '${w.temperatureC.toStringAsFixed(1)}°C',
                    sub: 'Resimțită ${w.apparentTempC.round()}°C',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatTile(
                    label: 'Vânt creastă',
                    value: '${w.ridgeWindPeakKmh.round()} km/h',
                    sub: '0°C: ${w.freezingLevelM.round()} m',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatTile(
                    label: 'Zăpadă',
                    value: '${w.snowDepthCm.round()} cm',
                    sub: 'Open-Meteo',
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (w != null && w.ridgeWindSeverity != 'none')
                _AlertBadge(
                  icon: FontAwesomeIcons.wind,
                  text:
                      'Vânt puternic pe creastă (${w.ridgeWindPeakKmh.round()} km/h)',
                  danger: w.ridgeWindSeverity == 'danger',
                ),
              if (w != null && w.thunderstormRisk)
                const _AlertBadge(
                  icon: FontAwesomeIcons.bolt,
                  text: 'Risc de furtună electrică',
                  danger: false,
                ),
              if (data.gorgeFlood?.warning == true)
                _AlertBadge(
                  icon: FontAwesomeIcons.water,
                  text:
                      'Debit crescut în chei (${data.gorgeFlood!.ratioToMedian}x · GloFAS)',
                  danger: data.gorgeFlood!.severity == 'danger',
                ),
              for (final hz in data.hazards)
                _AlertBadge(
                  icon: hz.hazardType == 'wildfire'
                      ? FontAwesomeIcons.fire
                      : FontAwesomeIcons.tree,
                  text: hz.title,
                  danger: hz.severity == 'danger',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  const _StatTile({
    required this.label,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.bodySmall),
          Text(
            value,
            style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            sub,
            style: t.labelSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _AlertBadge extends StatelessWidget {
  final FaIconData icon;
  final String text;
  final bool danger;
  const _AlertBadge({
    required this.icon,
    required this.text,
    required this.danger,
  });

  @override
  Widget build(BuildContext context) {
    final bg = danger ? const Color(0x24DC2626) : const Color(0x24F59E0B);
    final fg = danger ? const Color(0xFFB91C1C) : const Color(0xFF92400E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaIcon(icon, size: 12, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
