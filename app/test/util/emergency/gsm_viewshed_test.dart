import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/emergency/gsm_viewshed.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';

void main() {
  test(
    'recommends safe uphill shoulder <= 400m when valley is blocked by ridge and avoids >35 deg cliffs',
    () {
      final index = EmergencySpatialIndex.fromJson(const {
        'v': 1,
        'towers': [
          [4559000, 2550000, 1800, 35, 15, 1],
        ],
        'peaks': [
          [4550500, 2550200, 1680, 1, 'Vf. Creasta Sudică'],
        ],
      });

      final dem = DemTileGrid(
        customSampler: (lat, lon) {
          if (lon > 25.5008) {
            return 1300.0 + (lon - 25.5000) * 80000.0 * 1.2; // steep East cliff
          }
          if (lat >= 45.5035 && lat <= 45.5055 && lon >= 25.4988) {
            return 1540.0; // ridge blocking valley
          }
          final westGain = (25.5000 - lon) * 78000.0 * 0.25;
          return 1300.0 + (westGain > 0 ? westGain : 0.0);
        },
      );

      final rec = findBestGsm112SignalSpot(
        lat: 45.5000,
        lon: 25.5000,
        dem: dem,
        index: index,
      );

      expect(rec.status, GsmSignalStatus.climbRecommended);
      expect(rec.walkDistanceM, inInclusiveRange(50, 400));
      expect(rec.targetLon, lessThan(25.4995));
      expect(rec.reachableTowerCount, 1);
    },
  );
}
