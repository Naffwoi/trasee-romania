import 'package:flutter/material.dart';
import 'package:wanderer/components/navigation/waze_report_sheet.dart';
import 'package:wanderer/models/live/trail_live_models.dart';

/// Non-blocking Waze confirmation card shown when the hiker is within `<150 m`
/// of an active report (or taps a report marker on the navigation map).
class WazeNearbyPrompt extends StatelessWidget {
  const WazeNearbyPrompt({
    super.key,
    required this.report,
    this.distanceMeters,
    required this.onVote,
    required this.onClose,
    this.isSubmitting = false,
    this.isRo = true,
  });

  final TrailReportModel report;
  final double? distanceMeters;
  final ValueChanged<TrailReportVoteType> onVote;
  final VoidCallback onClose;
  final bool isSubmitting;
  final bool isRo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = categoryAccentColor(report.category);
    final now = DateTime.now();
    final distLabel = (distanceMeters != null && distanceMeters!.isFinite)
        ? (distanceMeters! >= 1000
              ? '${(distanceMeters! / 1000.0).toStringAsFixed(1)} km'
              : '${distanceMeters!.round()} m')
        : null;

    return Card(
      key: const ValueKey('waze-nearby-prompt'),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: accent.withValues(alpha: 0.55), width: 1.5),
      ),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    report.category.emoji,
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              report.category.label(isRo: isRo),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (distLabel != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                distLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        report.isDryOrClosed
                            ? (report.category == TrailReportCategory.spring
                                  ? (isRo
                                        ? '⚠️ Secat momentan · ${report.confirmedAgoLabel(now, isRo: isRo)}'
                                        : '⚠️ Currently dry · ${report.confirmedAgoLabel(now, isRo: isRo)}')
                                  : (isRo
                                        ? '⚠️ Închis / Afectat · ${report.confirmedAgoLabel(now, isRo: isRo)}'
                                        : '⚠️ Closed / Affected · ${report.confirmedAgoLabel(now, isRo: isRo)}'))
                            : report.confirmedAgoLabel(now, isRo: isRo),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.72,
                          ),
                        ),
                      ),
                      if (report.note.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          report.note.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (report.photoVerified) ...[
                        const SizedBox(height: 4),
                        Container(
                          key: const ValueKey('report-photo-verified-badge'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(
                              alpha: 0.14,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            isRo
                                ? '✓ Foto verificată la fața locului'
                                : '✓ Verified on-site photo',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF047857),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                      if ((report.photoThumbUrl ?? report.photoUrl)
                              ?.startsWith('http') ==
                          true) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            report.photoThumbUrl ?? report.photoUrl!,
                            height: 88,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const SizedBox.shrink(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!report.isPermanent) ...[
              Text(
                isRo ? 'Mai este acolo?' : 'Still there?',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      key: const ValueKey('waze-vote-confirm'),
                      onPressed: isSubmitting
                          ? null
                          : () => onVote(TrailReportVoteType.confirm),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(
                          0xFF10B981,
                        ).withValues(alpha: 0.18),
                        foregroundColor: const Color(0xFF059669),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        isRo ? '👍 OK, mai este' : '👍 Yes, still there',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('waze-vote-dismiss'),
                      onPressed: isSubmitting
                          ? null
                          : () => onVote(TrailReportVoteType.dismiss),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        isRo ? '👎 Nu mai e' : '👎 Not there',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      key: const ValueKey('waze-vote-seasonal-ok'),
                      onPressed: isSubmitting
                          ? null
                          : () => onVote(TrailReportVoteType.seasonalOk),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(
                          0xFF0891B2,
                        ).withValues(alpha: 0.16),
                        foregroundColor: const Color(0xFF0E7490),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        report.category == TrailReportCategory.spring
                            ? (isRo ? '💧 Curge apă' : '💧 Flowing')
                            : (isRo ? '👍 Accesibil' : '👍 Good'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('waze-vote-seasonal-dry'),
                      onPressed: isSubmitting
                          ? null
                          : () => onVote(TrailReportVoteType.seasonalDry),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(
                        report.category == TrailReportCategory.spring
                            ? (isRo ? '⚠️ Secat momentan' : '⚠️ Dry now')
                            : (isRo ? '⚠️ Închis' : '⚠️ Closed'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const ValueKey('waze-vote-spam'),
                    tooltip: isRo ? 'Raportează spam' : 'Flag spam',
                    visualDensity: VisualDensity.compact,
                    onPressed: isSubmitting
                        ? null
                        : () => onVote(TrailReportVoteType.spam),
                    icon: Icon(
                      Icons.flag_outlined,
                      size: 18,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
