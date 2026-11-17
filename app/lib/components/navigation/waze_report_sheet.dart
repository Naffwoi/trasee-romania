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
  TrailReportCategory _selected = TrailReportCategory.bear;
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
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
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    isRo
                        ? 'Raportează pe traseu'
                        : 'Report on trail',
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
            const SizedBox(height: 6),
            Text(
              isRo
                  ? 'Atenționări Temporare (expiră automat dacă nu sunt reconfirmate)'
                  : 'Temporary Waze Alerts (auto-expire unless reconfirmed)',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cat in TrailReportCategory.temporaryCategories)
                  _buildCategoryTile(context, cat, isRo: isRo),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              isRo
                  ? 'Repere Permanente pe Traseu (rămân pe hartă)'
                  : 'Permanent Trail Landmarks (stay on map)',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final cat in TrailReportCategory.permanentCategories)
                  _buildCategoryTile(context, cat, isRo: isRo),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _noteController,
              maxLength: 160,
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: isRo
                    ? 'Detalii scurte (opțional)'
                    : 'Short note (optional)',
                hintText: isRo
                    ? 'Ex: ursoaică cu pui lângă poiană / izvor cu debit bun'
                    : 'E.g. near clearing / strong water flow',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('waze-submit-report-btn'),
              style: FilledButton.styleFrom(
                backgroundColor: categoryAccentColor(_selected),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                Navigator.of(context).pop(
                  WazeReportSubmission(
                    category: _selected,
                    note: _noteController.text.trim(),
                  ),
                );
              },
              icon: Text(
                _selected.emoji,
                style: const TextStyle(fontSize: 18),
              ),
              label: Text(
                isRo
                    ? 'Adaugă pe hartă (${_selected.label(isRo: true)})'
                    : 'Post to map (${_selected.label(isRo: false)})',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryTile(
    BuildContext context,
    TrailReportCategory cat, {
    required bool isRo,
  }) {
    final theme = Theme.of(context);
    final selected = _selected == cat;
    final accent = categoryAccentColor(cat);

    return Material(
      color: selected
          ? accent.withValues(alpha: 0.16)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey('waze-cat-${cat.apiValue}'),
        onTap: () => setState(() => _selected = cat),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent : Colors.transparent,
              width: 1.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(cat.emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      cat.label(isRo: isRo),
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    Text(
                      cat.ttlBadgeLabel(isRo: isRo),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
