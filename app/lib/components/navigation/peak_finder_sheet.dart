import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanderer/provider/compass_heading_stream_provider.dart';
import 'package:wanderer/theme/colors.dart';
import 'package:wanderer/util/format.dart';
import 'package:wanderer/util/map/heading_math.dart'
    show normalizeHeading, shortestAngleDelta;
import 'package:wanderer/util/navigation/eta_calculator.dart'
    show cardinalDirection;
import 'package:wanderer/util/navigation/peak_finder_engine.dart';

class PeakFinderSheet extends ConsumerStatefulWidget {
  const PeakFinderSheet({
    super.key,
    required this.panorama,
    required this.finder,
    required this.onSelectPeak,
  });

  final HorizonPanorama panorama;
  final OfflinePeakFinder finder;
  final ValueChanged<PeakEntryModel> onSelectPeak;

  @override
  ConsumerState<PeakFinderSheet> createState() => _PeakFinderSheetState();
}

class _PeakFinderSheetState extends ConsumerState<PeakFinderSheet> {
  double _manualOffsetDeg = 0.0;

  @override
  Widget build(BuildContext context) {
    final compassStream = ref.watch(liveCompassProvider);
    final theme = Theme.of(context);

    return StreamBuilder<CompassHeadingReading?>(
      stream: compassStream,
      builder: (context, snap) {
        final centerDeg = normalizeHeading(
          (snap.data?.heading ?? 0.0) + _manualOffsetDeg,
        );
        final visible = widget.finder.selectViewportPeaks(
          widget.panorama,
          centerDeg,
        );

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Material(
              key: const ValueKey('peak-finder-sheet'),
              color: theme.colorScheme.surface.withValues(alpha: 0.96),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.55),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.landscape_outlined, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Ce vârf văd în față?',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primaryLight,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${centerDeg.round()}° ${cardinalDirection(centerDeg)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    if (widget.panorama.standingOnPeak != null) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Ești pe ${widget.panorama.standingOnPeak!.name} (${widget.panorama.standingOnPeak!.ele} m)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    GestureDetector(
                      onHorizontalDragUpdate: (d) =>
                          setState(() => _manualOffsetDeg -= d.delta.dx * 0.3),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 155,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: _HorizonPainter(
                              panorama: widget.panorama,
                              centerDeg: centerDeg,
                              peaks: visible,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 165),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final vp = visible[i];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              vp.peak.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              '${vp.peak.ele} m · ${formatDistance(vp.distanceM)} · ${vp.bearingDeg.round()}° ${vp.cardinal}${vp.visibility == PeakVisibility.unverified ? ' · DEM parțial' : ''}',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            trailing: const Text(
                              'Pe hartă',
                              style: TextStyle(fontSize: 11),
                            ),
                            onTap: () {
                              Navigator.of(context).pop();
                              widget.onSelectPeak(vp.peak);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HorizonPainter extends CustomPainter {
  _HorizonPainter({
    required this.panorama,
    required this.centerDeg,
    required this.peaks,
  });

  final HorizonPanorama panorama;
  final double centerDeg;
  final List<VisiblePeakResult> peaks;
  static const double _fov = 90.0;

  void _paintBand(Canvas canvas, Size size, Float32List arr, Color color) {
    final path = Path()..moveTo(0, size.height);
    for (var x = 0.0; x <= size.width; x += 2.0) {
      final az = normalizeHeading(
        centerDeg - _fov / 2.0 + (x / size.width) * _fov,
      );
      final bin = (az * 2.0).round().clamp(0, 719);
      final y = size.height - ((arr[bin] + 8.0) / 34.0) * (size.height - 24.0);
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintBand(canvas, size, panorama.farDeg, const Color(0x4064748B));
    _paintBand(canvas, size, panorama.midDeg, const Color(0x61475569));
    _paintBand(canvas, size, panorama.nearDeg, const Color(0x9E242734));

    final stemPaint = Paint()
      ..color = const Color(0xBF94A3B8)
      ..strokeWidth = 1.2;
    for (final vp in peaks) {
      final rel = shortestAngleDelta(centerDeg, vp.bearingDeg);
      final px = ((rel + _fov / 2.0) / _fov) * size.width;
      final py =
          (size.height -
                  ((vp.elevationAngleDeg + 8.0) / 34.0) * (size.height - 24.0))
              .clamp(38.0, size.height - 12.0);
      canvas.drawLine(
        Offset(px, py),
        Offset(px, vp.tier == 1 ? 14.0 : 28.0),
        stemPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HorizonPainter old) =>
      (old.centerDeg - centerDeg).abs() > 0.25 ||
      !identical(old.panorama, panorama);
}
