import 'dart:io';

import 'package:duration/duration.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:wanderer/actions/launch_navigation.dart';
import 'package:wanderer/components/base/wanderer_photo.dart';
import 'package:wanderer/components/trail/stat_chip.dart';
import 'package:wanderer/components/trail/trail_category_label.dart';
import 'package:wanderer/i18n/app_localizations.dart';
import 'package:wanderer/models/global_search_models.dart';
import 'package:wanderer/provider/auth_provider.dart';
import 'package:wanderer/provider/group_session_provider.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/trail/trail_provider.dart';
import 'package:wanderer/theme/colors.dart';
import 'package:wanderer/util/format.dart';
import 'package:wanderer/util/trail/curated_carpathian_photos.dart';

class SelectedTrailMapCard extends ConsumerStatefulWidget {
  final TrailSearchResult trail;
  final VoidCallback onOpenDetail;
  final VoidCallback onDismiss;

  const SelectedTrailMapCard({
    super.key,
    required this.trail,
    required this.onOpenDetail,
    required this.onDismiss,
  });

  @override
  ConsumerState<SelectedTrailMapCard> createState() =>
      _SelectedTrailMapCardState();
}

class _SelectedTrailMapCardState extends ConsumerState<SelectedTrailMapCard> {
  bool _isLaunching = false;

  Future<void> _startNavigation() async {
    if (_isLaunching) return;
    setState(() => _isLaunching = true);
    try {
      final fullTrail = await ref.read(trailProvider(widget.trail.id).future);
      if (!mounted) return;
      await launchNavigation(context: context, ref: ref, trail: fullTrail);
    } finally {
      if (mounted) setState(() => _isLaunching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trail = widget.trail;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(authProvider).value;
    final unit = ref.watch(unitProvider);
    final langCode = ref.watch(localeProvider)?.languageCode ?? 'ro';
    final isRo = !langCode.toLowerCase().startsWith('en');

    final String? localPath = trail.localPhotos.isNotEmpty
        ? trail.localPhotos.first
        : null;
    final String? localFile =
        trail.isLocal && localPath != null && File(localPath).existsSync()
        ? localPath
        : null;
    final String? curatedAssetPath =
        (localFile == null && isPlaceholderPhotoName(trail.summaryThumbnail))
        ? resolveCuratedCarpathianPhoto(
            name: trail.name,
            location: trail.location,
            lat: trail.geo.lat,
            lon: trail.geo.lng,
          )?.assetPath
        : null;
    final String? networkUrl =
        (localFile == null && curatedAssetPath == null && user != null)
        ? trail.getFileUrl(user.serverUrl, trail.summaryThumbnail, thumb: '600x0')
        : null;

    final primaryTag = trail.summaryTags?.firstOrNull;
    final diffLabel = trail.difficulty == 0
        ? l10n.easy
        : trail.difficulty == 1
        ? l10n.moderate
        : l10n.difficult;

    return Material(
      key: const ValueKey('selected-trail-map-card'),
      color: theme.cardColor,
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        ),
        child: InkWell(
          onTap: widget.onOpenDetail,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 82,
                        height: 82,
                        child: localFile != null
                            ? WandererPhoto.file(localFile)
                            : curatedAssetPath != null
                            ? Image.asset(curatedAssetPath, fit: BoxFit.cover)
                            : networkUrl != null
                            ? WandererPhoto.network(networkUrl)
                            : Container(
                                color: theme.colorScheme.secondaryContainer,
                                child: Center(
                                  child: SvgPicture.asset(
                                    'assets/svgs/empty_state_trail_${theme.brightness.name}.svg',
                                    height: 34,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  trail.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 34,
                                height: 34,
                                child: IconButton(
                                  key: const ValueKey(
                                    'selected-trail-dismiss-btn',
                                  ),
                                  padding: EdgeInsets.zero,
                                  tooltip: l10n.close,
                                  onPressed: widget.onDismiss,
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.65),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (trail.categoryId != null)
                                TrailCategoryLabel(
                                  categoryId: trail.categoryId!,
                                  subcategoryId: trail.subcategoryId,
                                ),
                              if (primaryTag != null && primaryTag.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.secondaryContainer,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    primaryTag,
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.75),
                                    ),
                                  ),
                                ),
                              Text(
                                diffLabel,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.65,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              StatChip(
                                icon: FontAwesomeIcons.ruler,
                                label: formatDistance(
                                  trail.distance,
                                  unit: unit,
                                ),
                              ),
                              StatChip(
                                icon: FontAwesomeIcons.clock,
                                label: Duration(
                                  seconds: (trailDisplayDuration(trail) ?? 0)
                                      .toInt(),
                                ).pretty(
                                  abbreviated: true,
                                  tersity: DurationTersity.minute,
                                ),
                              ),
                              StatChip(
                                icon: FontAwesomeIcons.arrowTrendUp,
                                label: formatElevation(
                                  trail.elevationGain,
                                  unit: unit,
                                ),
                              ),
                              if (trail.elevationLoss > 0)
                                StatChip(
                                  icon: FontAwesomeIcons.arrowTrendDown,
                                  label: formatElevation(
                                    trail.elevationLoss,
                                    unit: unit,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('selected-trail-group-btn'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => openGlobalGroupSheet(
                          context,
                          ref,
                          trailId: trail.id,
                          trailName: trail.name,
                        ),
                        icon: const Icon(Icons.group_outlined, size: 17),
                        label: Text(
                          isRo ? 'Grup' : 'Group',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        key: const ValueKey('selected-trail-navigate-btn'),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.brightness == Brightness.dark
                              ? theme.colorScheme.primary
                              : AppColors.primaryLight,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isLaunching ? null : _startNavigation,
                        icon: _isLaunching
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const FaIcon(
                                FontAwesomeIcons.locationArrow,
                                size: 14,
                              ),
                        label: Text(
                          l10n.navigate,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
