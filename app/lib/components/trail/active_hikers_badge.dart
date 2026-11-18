import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanderer/services/trail_live_service.dart';

/// Privacy-preserving live nearby users badge:
/// `🟢 X persoane în zonă` (hidden when 0).
class ActiveHikersBadge extends ConsumerStatefulWidget {
  const ActiveHikersBadge({
    super.key,
    this.trailId,
    this.lat,
    this.lon,
    this.countOverride,
    this.compact = false,
    this.showWhenZero = false,
    this.topPadding = 0,
  });

  final String? trailId;
  final double? lat;
  final double? lon;
  final int? countOverride;
  final bool compact;
  final bool showWhenZero;
  final double topPadding;

  @override
  ConsumerState<ActiveHikersBadge> createState() => _ActiveHikersBadgeState();
}

class _ActiveHikersBadgeState extends ConsumerState<ActiveHikersBadge> {
  int? _fetchedCount;
  String? _fetchedTrailId;

  @override
  void didUpdateWidget(covariant ActiveHikersBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.countOverride == null && widget.trailId != oldWidget.trailId) {
      _fetchedCount = null;
      _fetchedTrailId = null;
    }
  }

  void _loadSummaryIfConfigured() {
    final trailId = widget.trailId?.trim();
    if (trailId == null || trailId.isEmpty) return;
    final service = ref.read(trailLiveServiceProvider);
    if (service == null || !service.isConfigured) return;
    _fetchedTrailId = trailId;
    unawaited(
      service
          .fetchTrailSummary(
            trailId,
            lat: widget.lat,
            lon: widget.lon,
          )
          .then((summary) {
            if (!mounted || _fetchedTrailId != trailId || summary == null) {
              return;
            }
            setState(() {
              _fetchedCount = summary.activeHikers30m;
            });
          })
          .catchError((Object _) {
            // Offline or unreachable — keep badge hidden gracefully.
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.countOverride == null) {
      final service = ref.watch(trailLiveServiceProvider);
      if (_fetchedCount == null &&
          service != null &&
          service.isConfigured &&
          widget.trailId != null &&
          widget.trailId!.isNotEmpty &&
          _fetchedTrailId != widget.trailId!.trim()) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadSummaryIfConfigured();
        });
      }
    }

    final count = widget.countOverride ?? _fetchedCount;
    if (count == null) return const SizedBox.shrink();
    if (count <= 0 && !widget.showWhenZero) return const SizedBox.shrink();

    final isRo =
        Localizations.maybeLocaleOf(context)?.languageCode.startsWith('ro') ??
        true;
    final isActive = count > 0;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final String text;
    if (isRo) {
      text = count == 1 ? '1 persoană în zonă' : '$count persoane în zonă';
    } else {
      text = count == 1 ? '1 person nearby' : '$count people nearby';
    }

    final bgColor = isActive
        ? (isDark
              ? const Color(0xFF064E3B).withValues(alpha: 0.65)
              : const Color(0xFFECFDF5))
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final borderColor = isActive
        ? const Color(0xFF10B981).withValues(alpha: 0.55)
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
    final textColor = isActive
        ? (isDark ? const Color(0xFFA7F3D0) : const Color(0xFF065F46))
        : theme.colorScheme.onSurface.withValues(alpha: 0.72);
    final dotColor = isActive
        ? const Color(0xFF10B981)
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);

    final badge = Container(
      key: const ValueKey('active-hikers-badge'),
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 10 : 12,
        vertical: widget.compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: const Color(0xFF10B981).withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (widget.compact
                      ? theme.textTheme.labelSmall
                      : theme.textTheme.labelMedium)
                  ?.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );

    if (widget.topPadding > 0) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPadding),
        child: badge,
      );
    }
    return badge;
  }
}
