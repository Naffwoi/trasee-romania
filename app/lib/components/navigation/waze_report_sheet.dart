import 'package:flutter/material.dart';
import 'package:wanderer/models/live/trail_live_models.dart';

class WazeReportSubmission {
  const WazeReportSubmission({
    required this.category,
    required this.note,
  });

  final TrailReportCategory category;
  final String note;
}

Future<WazeReportSubmission?> showWazeReportSheet(
  BuildContext context, {
  bool isRo = true,
}) {
  return showModalBottomSheet<WazeReportSubmission>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => WazeReportSheet(isRo: isRo),
  );
}

Color categoryAccentColor(TrailReportCategory category) => switch (category) {
  TrailReportCategory.bear => const Color(0xFFDC2626),
  TrailReportCategory.shepherdDogs => const Color(0xFFEA580C),
  TrailReportCategory.fallenTreeTerrain => const Color(0xFFD97706),
  TrailReportCategory.iceMud => const Color(0xFF0284C7),
  TrailReportCategory.deer => const Color(0xFF16A34A),
  TrailReportCategory.spring => const Color(0xFF0891B2),
  TrailReportCategory.viewpoint => const Color(0xFF7C3AED),
  TrailReportCategory.shelter => const Color(0xFF0D9488),
};

String _shortCategoryLabel(TrailReportCategory cat, {required bool isRo}) {
  if (!isRo) {
    return switch (cat) {
      TrailReportCategory.bear => 'Bear',
      TrailReportCategory.shepherdDogs => 'Dogs',
      TrailReportCategory.fallenTreeTerrain => 'Obstacle',
      TrailReportCategory.iceMud => 'Ice / Mud',
      TrailReportCategory.deer => 'Wildlife',
      TrailReportCategory.spring => 'Spring',
      TrailReportCategory.viewpoint => 'Viewpoint',
      TrailReportCategory.shelter => 'Shelter',
    };
  }
  return switch (cat) {
    TrailReportCategory.bear => 'Urs',
    TrailReportCategory.shepherdDogs => 'Câini',
    TrailReportCategory.fallenTreeTerrain => 'Obstacol',
    TrailReportCategory.iceMud => 'Gheață / Noroi',
    TrailReportCategory.deer => 'Faună',
    TrailReportCategory.spring => 'Izvor',
    TrailReportCategory.viewpoint => 'Belvedere',
    TrailReportCategory.shelter => 'Adăpost',
  };
}

class WazeReportSheet extends StatefulWidget {
  const WazeReportSheet({
    super.key,
    this.isRo = true,
  });

  final bool isRo;

  @override
  State<WazeReportSheet> createState() => _WazeReportSheetState();
}

class _WazeReportSheetState extends State<WazeReportSheet> {
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _handleQuickTap(TrailReportCategory category) {
    Navigator.of(context).pop(
      WazeReportSubmission(
        category: category,
        note: _noteController.text.trim(),
      ),
    );
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
                    isRo ? 'Ce ai observat?' : 'What do you see?',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
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
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.95,
              children: [
                for (final cat in TrailReportCategory.values)
                  _buildQuickTile(context, cat, isRo: isRo),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              maxLength: 160,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: isRo
                    ? 'Notă scurtă opțională (înainte să apeși iconul)...'
                    : 'Optional short note (before tapping icon)...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickTile(
    BuildContext context,
    TrailReportCategory cat, {
    required bool isRo,
  }) {
    final theme = Theme.of(context);
    final isDeer = cat == TrailReportCategory.deer;
    final bgColor = isDeer
        ? const Color(0xFF16A34A).withValues(alpha: 0.10)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45);

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: ValueKey('waze-cat-${cat.apiValue}'),
        onTap: () => _handleQuickTap(cat),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(cat.emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(height: 4),
              Text(
                _shortCategoryLabel(cat, isRo: isRo),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
