import 'package:flutter_test/flutter_test.dart';
import 'package:wanderer/models/trail.dart';
import 'package:wanderer/provider/trail/trail_filter_provider.dart';
import 'package:wanderer/util/trail/filter.dart';
import 'package:wanderer/util/trail/offline_filter_bounds.dart';

void main() {
  test(
    'TrailFilter.trainAccessible emits Meilisearch clause and filters local trails',
    () {
      final baseFilter = buildDefaultTrailFilter(kOfflineTrailFilterValues);
      expect(baseFilter.toFilterText().contains('train_accessible'), isFalse);

      final railFilter = baseFilter.copyWith(trainAccessible: true);
      expect(railFilter.toFilterText(), contains('train_accessible = true'));

      final now = DateTime.utc(2026, 11, 18);
      final busteniTrail = Trail(
        id: 't1',
        name: 'Bușteni – Urlătoarea',
        created: now,
        updated: now,
        trainAccessible: true,
        railStationName: 'Bușteni',
        railStationDistanceM: 640,
      );
      final retezatTrail = Trail(
        id: 't2',
        name: 'Cârnic – Lacul Bucura',
        created: now,
        updated: now,
        trainAccessible: false,
      );

      final filtered = applyTrailFilter([
        busteniTrail,
        retezatTrail,
      ], railFilter);
      expect(filtered.map((t) => t.id).toList(), ['t1']);
    },
  );
}
