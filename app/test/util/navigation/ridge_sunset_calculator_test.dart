import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/ridge_sunset_calculator.dart';

void main() {
  group('RidgeSunsetCalculator + EtaCalculator coupling', () {
    test(
      'detects early ridge sunset in western-walled valley and classifies trail light status',
      () {
        final dem = DemTileGrid(
          customSampler: (lat, lon) => lon < 25.478 ? 2200.0 : 1150.0,
        );
        final track = List<NavTrackPoint>.generate(
          21,
          (i) => NavTrackPoint(
            lat: 45.44 + i * 0.0036,
            lon: 25.50,
            ele: 1150.0 + i * 15.0,
            distanceM: i * 400.0,
            gradePct: 3.75,
          ),
        );
        final eta = EtaCalculator.fromPoints(track);

        final morning = computeTrailSolarForecast(
          points: track,
          etaCalc: eta,
          dem: dem,
          alongTrackM: 0.0,
          now: DateTime.parse('2026-11-18T09:00:00Z'),
        );
        expect(morning.status, LightSafetyStatus.daylightSafe);

        final afternoon = computeTrailSolarForecast(
          points: track,
          etaCalc: eta,
          dem: dem,
          alongTrackM: 0.0,
          now: DateTime.parse('2026-11-18T12:15:00Z'),
        );
        expect(afternoon.status, LightSafetyStatus.ridgeShade);
        expect(
          afternoon.finishRidgeSunset.minutesBeforeAstroSunset,
          greaterThan(75),
        );
      },
    );
  });
}
