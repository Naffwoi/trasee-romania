import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';
import 'package:wanderer/store/breadcrumb_slab_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('breadcrumb_slab_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('appends only new points in 24-byte records and round-trips elevation/timestamps', () async {
    final store = BreadcrumbSlabStore.forDirectory(tempDir);
    final pts = <Wpt>[
      Wpt(
        lat: 45.408123,
        lon: 25.474219,
        ele: 2025.4,
        time: DateTime.utc(2026, 11, 18, 9, 0, 10),
      ),
      Wpt(
        lat: 45.408550,
        lon: 25.474800,
        ele: null, // missing altitude -> NaN sentinel
        time: DateTime.utc(2026, 11, 18, 9, 0, 15),
      ),
    ];

    final firstWrite = store.appendFromBreadcrumb(pts);
    expect(firstWrite, 2);
    expect(File(store.filePath).lengthSync(), 48);

    // Calling again with unchanged breadcrumb writes 0 bytes!
    expect(store.appendFromBreadcrumb(pts), 0);
    expect(File(store.filePath).lengthSync(), 48);

    // Appending 1 new fix writes exactly 24 bytes (total 72 bytes).
    pts.add(
      Wpt(
        lat: 45.409001,
        lon: 25.475102,
        ele: 2031.0,
        time: DateTime.utc(2026, 11, 18, 9, 0, 22),
      ),
    );
    expect(store.appendFromBreadcrumb(pts), 1);
    expect(File(store.filePath).lengthSync(), 72);

    // Cold-start reopen recovers all 3 points accurately.
    final reopened = BreadcrumbSlabStore.forDirectory(tempDir);
    final loaded = reopened.readAllWaypoints();
    expect(loaded, hasLength(3));
    expect(loaded[0].lat, closeTo(45.408123, 1e-9));
    expect(loaded[0].lon, closeTo(25.474219, 1e-9));
    expect(loaded[0].ele, closeTo(2025.4, 0.05));
    expect(loaded[0].time, DateTime.utc(2026, 11, 18, 9, 0, 10));
    expect(loaded[1].ele, isNull);
    expect(loaded[2].ele, closeTo(2031.0, 0.05));
  });

  test('truncates partial trailing bytes after mid-write OS crash without losing prefix', () async {
    final store = BreadcrumbSlabStore.forDirectory(tempDir);
    store.appendFromBreadcrumb(<Wpt>[
      Wpt(
        lat: 45.5001,
        lon: 25.5502,
        ele: 1650.0,
        time: DateTime.utc(2026, 11, 18, 11, 30, 0),
      ),
    ]);
    // Simulate a torn write of 11 stray bytes at power loss.
    File(store.filePath).writeAsBytesSync(
      Uint8List(11),
      mode: FileMode.append,
      flush: true,
    );
    expect(File(store.filePath).lengthSync(), 35);

    final recovered = BreadcrumbSlabStore.forDirectory(tempDir);
    final loaded = recovered.readAllWaypoints();
    expect(File(recovered.filePath).lengthSync(), 24);
    expect(loaded, hasLength(1));
    expect(loaded.single.lat, closeTo(45.5001, 1e-9));
  });
}
