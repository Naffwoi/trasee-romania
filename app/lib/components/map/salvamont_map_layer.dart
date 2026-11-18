import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;
import 'package:wanderer/components/map/map_marker_gestures.dart';
import 'package:wanderer/components/map/salvamont_point_sheet.dart';
import 'package:wanderer/components/map/screen_marker_layer.dart';
import 'package:wanderer/models/emergency/salvamont_models.dart';
import 'package:wanderer/provider/local_settings_provider.dart';
import 'package:wanderer/provider/salvamont_provider.dart';

class SalvamontMapLayer extends ConsumerStatefulWidget {
  const SalvamontMapLayer({
    super.key,
    this.forceVisible = false,
    this.refLat,
    this.refLon,
    this.refEle,
    this.isTrailRef = false,
    this.isRo = true,
    this.onRouteToPoint,
  });

  final bool forceVisible;
  final double? refLat;
  final double? refLon;
  final double? refEle;
  final bool isTrailRef;
  final bool isRo;
  final ValueChanged<SalvamontPoint>? onRouteToPoint;

  @override
  ConsumerState<SalvamontMapLayer> createState() => _SalvamontMapLayerState();
}

class _SalvamontMapLayerState extends ConsumerState<SalvamontMapLayer> {
  SalvamontDataset? _cachedDataset;
  List<ml.Marker> _allMarkers = const [];
  List<ml.Marker> _basesOnlyMarkers = const [];

  void _rebuildMarkersIfNeeded(SalvamontDataset dataset) {
    if (identical(_cachedDataset, dataset)) return;
    _cachedDataset = dataset;

    ml.Marker buildMarker(SalvamontPoint pt) {
      final isRefuge = pt.isRefuge;
      final dim = isRefuge ? 26.0 : 30.0;
      return ml.Marker(
        point: ml.Geographic(lat: pt.lat, lon: pt.lon),
        size: Size(dim, dim),
        child: MapMarkerGestures(
          key: ValueKey<String>('salvamont-marker-${pt.id}'),
          onTap: () {
            if (!mounted) return;
            showSalvamontPointSheet(
              context,
              point: pt,
              dataset: dataset,
              refLat: widget.refLat,
              refLon: widget.refLon,
              refEle: widget.refEle,
              isTrailRef: widget.isTrailRef,
              isRo: widget.isRo,
              onRouteToPoint: widget.onRouteToPoint,
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: isRefuge
                  ? const Color(0xFF334155)
                  : const Color(0xFF242734),
              borderRadius: BorderRadius.circular(isRefuge ? 7 : 8),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  isRefuge ? Icons.night_shelter_rounded : Icons.add_rounded,
                  color: Colors.white,
                  size: isRefuge ? 15 : 19,
                ),
                if (!isRefuge)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: Color(0xFFDC2626),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    _allMarkers = [for (final p in dataset.points) buildMarker(p)];
    _basesOnlyMarkers = [
      for (final p in dataset.points)
        if (!p.isRefuge) buildMarker(p),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.forceVisible || ref.watch(showSalvamontLayerProvider);
    if (!enabled) return const SizedBox.shrink();

    final camera = ml.MapCamera.maybeOf(context);
    if (camera == null || camera.zoom < 7.0) return const SizedBox.shrink();

    final ds = ref.watch(salvamontDatasetProvider).value;
    if (ds == null) return const SizedBox.shrink();

    _rebuildMarkersIfNeeded(ds);
    final markers = camera.zoom >= 9.5 ? _allMarkers : _basesOnlyMarkers;
    return ScreenMarkerLayer(markers: markers);
  }
}
