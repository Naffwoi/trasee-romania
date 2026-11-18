import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanderer/models/live/trail_environment_models.dart';
import 'package:wanderer/provider/api_provider.dart';

class TrailheadStreetPreviewStrip extends ConsumerStatefulWidget {
  final double? lat;
  final double? lon;
  const TrailheadStreetPreviewStrip({super.key, this.lat, this.lon});

  @override
  ConsumerState<TrailheadStreetPreviewStrip> createState() =>
      _TrailheadStreetPreviewStripState();
}

class _TrailheadStreetPreviewStripState
    extends ConsumerState<TrailheadStreetPreviewStrip> {
  List<TrailheadStreetPhoto> _photos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lat = widget.lat;
    final lon = widget.lon;
    if (lat == null || lon == null || (lat == 0 && lon == 0)) return;
    try {
      final res = await ref
          .read(apiProvider)
          .get<Map<String, dynamic>>(
            '/live/street-preview',
            queryParameters: {
              'lat': lat.toStringAsFixed(6),
              'lon': lon.toStringAsFixed(6),
            },
          );
      final list = (res.data?['photos'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TrailheadStreetPhoto.fromJson)
          .toList();
      if (mounted) setState(() => _photos = list);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_photos.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ACCES & PARCARE LA INTRAREA ÎN TRASEU',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final p = _photos[i];
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    children: [
                      Image.network(
                        p.thumbUrl,
                        width: 144,
                        height: 96,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 144,
                          height: 96,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xD9242734),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${p.distanceM.round()} m · ${p.capturedAt.isNotEmpty ? p.capturedAt : p.provider}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
