import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/peak_finder_engine.dart';

void main() {
  group('OfflinePeakFinder (Dart)', () {
    test(
      'keeps foreground peak visible and culls occluded lower-angle background peak',
      () {
        const peaks = [
          PeakEntryModel(
            id: 1,
            name: 'Vf. Apropiat',
            lat: 45.48170,
            lon: 25.45628,
            ele: 1750,
            prominenceM: 300,
            kind: 'peak',
          ),
          PeakEntryModel(
            id: 2,
            name: 'Vf. Ascuns',
            lat: 45.55360,
            lon: 25.45628,
            ele: 2150,
            prominenceM: 500,
            kind: 'peak',
          ),
          PeakEntryModel(
            id: 3,
            name: 'Vf. Înalt',
            lat: 45.55360,
            lon: 25.46800,
            ele: 2540,
            prominenceM: 1200,
            kind: 'peak',
          ),
        ];
        final dem = DemTileGrid(
          customSampler: (lat, _) =>
              (lat - 45.4817).abs() < 0.0025 ? 1750.0 : 1500.0,
        );
        final finder = OfflinePeakFinder.fromPeaks(peaks);
        final pano = finder.computePanorama(dem, 45.44572, 25.45628, 1500.0);
        final names = pano.visiblePeaks.map((p) => p.peak.name).toList();

        expect(names, contains('Vf. Apropiat'));
        expect(names, contains('Vf. Înalt'));
        expect(names, isNot(contains('Vf. Ascuns')));
      },
    );
  });
}
