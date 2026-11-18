import 'package:flutter/material.dart';
import 'package:wanderer/theme/colors.dart';
import 'package:wanderer/util/navigation/sun_calc.dart';

class SlopeLegendPill extends StatefulWidget {
  const SlopeLegendPill({super.key, this.isRo = true});
  final bool isRo;

  @override
  State<SlopeLegendPill> createState() => _SlopeLegendPillState();
}

class _SlopeLegendPillState extends State<SlopeLegendPill> {
  bool _showNote = false;

  Widget _band(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      label,
      style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w700),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('slope-legend-pill'),
      color: theme.colorScheme.surface.withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.isRo ? 'Pantă avalanșă' : 'Slope angle',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => setState(() => _showNote = !_showNote),
                  child: const Icon(Icons.info_outline, size: 14),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Wrap(
              spacing: 4,
              children: [
                _band('27–29°', const Color(0xFFEAB308), Colors.black),
                _band('30–34°', const Color(0xFFF97316), Colors.white),
                _band('35–44°', const Color(0xFFDC2626), Colors.white),
                _band('45–49°', const Color(0xFF9333EA), Colors.white),
                _band('50°+', const Color(0xFF1D4ED8), Colors.white),
              ],
            ),
            if (_showNote) ...[
              const SizedBox(height: 5),
              SizedBox(
                width: 240,
                child: Text(
                  widget.isRo
                      ? 'DEM ~30 m (Mapterhorn/Copernicus). Micro-relieful abrupt (<30 m) poate fi mai înclinat în teren.'
                      : 'Based on ~30 m DEM (Mapterhorn). Narrow <30 m features may be steeper.',
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10.5),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SolarTimeScrubberCard extends StatelessWidget {
  const SolarTimeScrubberCard({
    super.key,
    required this.lat,
    required this.lon,
    required this.simulatedTime,
    required this.onChanged,
  });

  final double lat;
  final double lon;
  final DateTime simulatedTime;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = simulatedTime.toLocal();
    final mins = (local.hour * 60 + local.minute).clamp(300, 1320);
    final sun = getSunPosition(simulatedTime, lat, lon);
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');

    return Card(
      key: const ValueKey('solar-time-scrubber'),
      color: theme.colorScheme.surface.withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.55),
        ),
      ),
      child: SizedBox(
        width: 268,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Umbre solare · $hh:$mm',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'Alt ${sun.altitudeDeg.round()}° · Az ${sun.azimuthDeg.round()}°',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.primaryLight,
                  thumbColor: AppColors.primaryLight,
                ),
                child: Slider(
                  min: 300,
                  max: 1320,
                  value: mins.toDouble(),
                  onChanged: (v) {
                    final m = v.round();
                    onChanged(
                      DateTime(
                        local.year,
                        local.month,
                        local.day,
                        m ~/ 60,
                        m % 60,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
