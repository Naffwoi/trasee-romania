import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpx/gpx.dart';
import 'package:path/path.dart' as p;

final breadcrumbSlabStoreProvider = Provider<BreadcrumbSlabStore?>(
  (ref) => null,
);

/// Crash-safe, $O(\Delta k)$ append-only binary store for the active session's
/// GPS breadcrumb (`active_breadcrumb_v1.bin`).
///
/// Layout per point (`24 bytes`, little-endian):
/// - `0..7`   (`Float64`): latitude
/// - `8..15`  (`Float64`): longitude
/// - `16..19` (`Float32`): elevation in metres (`double.nan` when absent)
/// - `20..23` (`Uint32`):  UTC epoch seconds (`0` when absent)
///
/// Replaces the 10-second full-track `PolylineUtil.encode` + 3× `.toList()`
/// allocations in `NavigationScreen._persistNow`, reducing an 8-hour recording
/// checkpoint from rewriting 28,800 points to appending 24–120 bytes.
class BreadcrumbSlabStore {
  BreadcrumbSlabStore._(this.filePath) {
    _sanitizeAndSyncCursor();
  }

  factory BreadcrumbSlabStore.forDirectory(Directory dir) {
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return BreadcrumbSlabStore._(p.join(dir.path, fileName));
  }

  static const String fileName = 'active_breadcrumb_v1.bin';
  static const int recordBytes = 24;

  final String filePath;
  int _persistedCount = 0;

  int get persistedCount => _persistedCount;

  void _sanitizeAndSyncCursor() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        _persistedCount = 0;
        return;
      }
      final len = file.lengthSync();
      final rem = len % recordBytes;
      if (rem != 0) {
        final raf = file.openSync(mode: FileMode.append);
        try {
          raf.truncateSync(len - rem);
        } finally {
          raf.closeSync();
        }
      }
      _persistedCount = (len - rem) ~/ recordBytes;
    } catch (_) {
      _persistedCount = 0;
    }
  }

  /// Appends only `breadcrumb[_persistedCount .. breadcrumb.length - 1]` to
  /// disk. Returns the number of newly appended points.
  int appendFromBreadcrumb(List<Wpt> breadcrumb) {
    if (breadcrumb.isEmpty) return 0;
    if (breadcrumb.length < _persistedCount) {
      // Session was reset without calling clear() — rewrite cleanly.
      clear();
    }
    final delta = breadcrumb.length - _persistedCount;
    if (delta <= 0) return 0;

    final bytes = Uint8List(delta * recordBytes);
    final bd = ByteData.sublistView(bytes);
    var writeCount = 0;

    for (var i = _persistedCount; i < breadcrumb.length; i++) {
      final wpt = breadcrumb[i];
      final lat = wpt.lat;
      final lon = wpt.lon;
      if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) {
        continue;
      }
      final base = writeCount * recordBytes;
      bd.setFloat64(base, lat, Endian.little);
      bd.setFloat64(base + 8, lon, Endian.little);
      final ele = wpt.ele;
      bd.setFloat32(
        base + 16,
        (ele != null && ele.isFinite) ? ele : double.nan,
        Endian.little,
      );
      final sec = wpt.time == null
          ? 0
          : (wpt.time!.toUtc().millisecondsSinceEpoch ~/ 1000).clamp(
              0,
              0xFFFFFFFF,
            );
      bd.setUint32(base + 20, sec, Endian.little);
      writeCount++;
    }

    if (writeCount == 0) {
      _persistedCount = breadcrumb.length;
      return 0;
    }

    try {
      final slice = writeCount == delta
          ? bytes
          : Uint8List.sublistView(bytes, 0, writeCount * recordBytes);
      File(filePath).writeAsBytesSync(
        slice,
        mode: FileMode.append,
        flush: false,
      );
      _persistedCount = breadcrumb.length;
      return writeCount;
    } catch (_) {
      return 0;
    }
  }

  /// Reads all persisted `24-byte` records back into [Wpt] models.
  List<Wpt> readAllWaypoints() {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return const <Wpt>[];
      _sanitizeAndSyncCursor();
      final bytes = file.readAsBytesSync();
      final count = bytes.length ~/ recordBytes;
      if (count == 0) return const <Wpt>[];

      final bd = ByteData.sublistView(bytes);
      final out = <Wpt>[];
      for (var i = 0; i < count; i++) {
        final base = i * recordBytes;
        final lat = bd.getFloat64(base, Endian.little);
        final lon = bd.getFloat64(base + 8, Endian.little);
        if (!lat.isFinite || !lon.isFinite) continue;
        final rawEle = bd.getFloat32(base + 16, Endian.little);
        final sec = bd.getUint32(base + 20, Endian.little);
        out.add(
          Wpt(
            lat: lat,
            lon: lon,
            ele: rawEle.isFinite ? rawEle : null,
            time: sec > 0
                ? DateTime.fromMillisecondsSinceEpoch(sec * 1000, isUtc: true)
                : null,
          ),
        );
      }
      _persistedCount = count;
      return out;
    } catch (_) {
      return const <Wpt>[];
    }
  }

  void clear() {
    _persistedCount = 0;
    try {
      final file = File(filePath);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }
}
