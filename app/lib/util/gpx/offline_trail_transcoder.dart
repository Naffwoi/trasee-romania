import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:gpx/gpx.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml_events.dart';

/// Top-level `compute()` entry point that transcodes `.kml`, `.kmz`, `.fit`, or
/// `.tcx` bytes into a validated [Gpx] model + serialized GPX XML string
/// 100% offline in pure Dart.
({Gpx gpx, String gpxXml}) transcodeTrailBytesIsolate(
  ({Uint8List bytes, String ext, String fallbackName}) args,
) {
  final ext = args.ext.toLowerCase();
  final stem = p.basenameWithoutExtension(args.fallbackName);
  final gpx = switch (ext) {
    'kml' => _parseKmlString(utf8.decode(args.bytes, allowMalformed: true), stem),
    'kmz' => _parseKmzArchive(args.bytes, stem),
    'fit' => _parseGarminFitBinary(args.bytes, stem),
    'tcx' => _parseTcxString(utf8.decode(args.bytes, allowMalformed: true), stem),
    _ => throw UnsupportedError('Unsupported offline trail format: .$ext'),
  };

  final hasPoints =
      gpx.wpts.isNotEmpty ||
      gpx.trks.any((t) => t.trksegs.any((s) => s.trkpts.isNotEmpty));
  if (!hasPoints) {
    throw const FormatException('Transcoded file contained zero usable points');
  }
  final xml = GpxWriter().asString(gpx);
  return (gpx: gpx, gpxXml: xml);
}

Gpx _parseKmzArchive(Uint8List bytes, String fallbackName) {
  final archive = ZipDecoder().decodeBytes(bytes);
  ArchiveFile? kmlEntry;
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final lower = file.name.toLowerCase();
    if (lower == 'doc.kml' || lower.endsWith('/doc.kml')) {
      kmlEntry = file;
      break;
    }
    if (kmlEntry == null && lower.endsWith('.kml')) {
      kmlEntry = file;
    }
  }
  if (kmlEntry == null) {
    throw const FormatException('KMZ archive contains no .kml entry');
  }
  final content = kmlEntry.content;
  final kmlText = utf8.decode(content, allowMalformed: true);
  return _parseKmlString(kmlText, fallbackName);
}

String _localTagName(String rawName) {
  final colon = rawName.indexOf(':');
  return colon >= 0 ? rawName.substring(colon + 1) : rawName;
}

Gpx _parseKmlString(String xmlText, String fallbackName) {
  final stack = <String>[];
  String? docName;
  String? currentPlacemarkName;
  String? currentPlacemarkDesc;
  var inPoint = false;
  var inLineOrTrack = false;
  DateTime? pendingGxWhen;
  final gxTrackPts = <Wpt>[];
  final segments = <Trkseg>[];
  final waypoints = <Wpt>[];
  final textBuf = StringBuffer();

  for (final event in parseEvents(xmlText)) {
    if (event is XmlStartElementEvent) {
      final tag = _localTagName(event.name);
      if (!event.isSelfClosing) {
        stack.add(tag);
        textBuf.clear();
        if (tag == 'Placemark') {
          currentPlacemarkName = null;
          currentPlacemarkDesc = null;
          inPoint = false;
          inLineOrTrack = false;
          gxTrackPts.clear();
          pendingGxWhen = null;
        } else if (tag == 'Point') {
          inPoint = true;
        } else if (tag == 'LineString' || tag == 'Track') {
          inLineOrTrack = true;
        }
      }
    } else if (event is XmlTextEvent) {
      textBuf.write(event.value);
    } else if (event is XmlCDATAEvent) {
      textBuf.write(event.value);
    } else if (event is XmlEndElementEvent) {
      final tag = _localTagName(event.name);
      final text = textBuf.toString().trim();
      textBuf.clear();

      final inPlacemark = stack.contains('Placemark');
      if (tag == 'name') {
        if (inPlacemark && currentPlacemarkName == null && text.isNotEmpty) {
          currentPlacemarkName = text;
        } else if (!inPlacemark && docName == null && text.isNotEmpty) {
          docName = text;
        }
      } else if (tag == 'description' && inPlacemark && text.isNotEmpty) {
        currentPlacemarkDesc = text;
      } else if (tag == 'coordinates' && text.isNotEmpty) {
        final parsed = _parseKmlCoordinatesTupleList(text);
        if (inPoint && parsed.isNotEmpty) {
          final first = parsed.first;
          waypoints.add(
            Wpt(
              lat: first.lat,
              lon: first.lon,
              ele: first.ele,
              name: currentPlacemarkName,
              desc: currentPlacemarkDesc,
            ),
          );
        } else if (inLineOrTrack && parsed.isNotEmpty) {
          segments.add(Trkseg(trkpts: parsed));
        }
      } else if (tag == 'when' && inLineOrTrack && text.isNotEmpty) {
        pendingGxWhen = DateTime.tryParse(text)?.toUtc();
      } else if (tag == 'coord' && inLineOrTrack && text.isNotEmpty) {
        final parts = text.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          final lon = double.tryParse(parts[0]);
          final lat = double.tryParse(parts[1]);
          final ele = parts.length >= 3 ? double.tryParse(parts[2]) : null;
          if (lat != null && lon != null && lat.isFinite && lon.isFinite) {
            gxTrackPts.add(
              Wpt(lat: lat, lon: lon, ele: ele, time: pendingGxWhen),
            );
          }
        }
      } else if (tag == 'Point') {
        inPoint = false;
      } else if (tag == 'LineString') {
        inLineOrTrack = false;
      } else if (tag == 'Track') {
        if (gxTrackPts.isNotEmpty) {
          segments.add(Trkseg(trkpts: List<Wpt>.from(gxTrackPts)));
          gxTrackPts.clear();
        }
        inLineOrTrack = false;
      }

      if (stack.isNotEmpty && stack.last == tag) {
        stack.removeLast();
      }
    }
  }

  final effectiveName = docName ?? fallbackName;
  return Gpx()
    ..metadata = (Metadata()..name = effectiveName)
    ..wpts = waypoints
    ..trks = segments.isEmpty
        ? <Trk>[]
        : <Trk>[Trk(name: effectiveName, trksegs: segments)];
}

List<Wpt> _parseKmlCoordinatesTupleList(String raw) {
  final out = <Wpt>[];
  for (final token in raw.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    final cols = token.split(',');
    if (cols.length < 2) continue;
    final lon = double.tryParse(cols[0]);
    final lat = double.tryParse(cols[1]);
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90.0 ||
        lon.abs() > 180.0) {
      continue;
    }
    final ele = cols.length >= 3 ? double.tryParse(cols[2]) : null;
    out.add(
      Wpt(
        lat: lat,
        lon: lon,
        ele: (ele != null && ele.isFinite) ? ele : null,
      ),
    );
  }
  return out;
}

Gpx _parseTcxString(String xmlText, String fallbackName) {
  final pts = <Wpt>[];
  double? tpLat;
  double? tpLon;
  double? tpEle;
  DateTime? tpTime;
  var inTrackpoint = false;
  final textBuf = StringBuffer();

  for (final event in parseEvents(xmlText)) {
    if (event is XmlStartElementEvent) {
      final tag = _localTagName(event.name);
      textBuf.clear();
      if (!event.isSelfClosing && tag == 'Trackpoint') {
        inTrackpoint = true;
        tpLat = null;
        tpLon = null;
        tpEle = null;
        tpTime = null;
      }
    } else if (event is XmlTextEvent) {
      textBuf.write(event.value);
    } else if (event is XmlEndElementEvent) {
      final tag = _localTagName(event.name);
      final text = textBuf.toString().trim();
      textBuf.clear();
      if (!inTrackpoint) continue;

      if (tag == 'LatitudeDegrees') {
        tpLat = double.tryParse(text);
      } else if (tag == 'LongitudeDegrees') {
        tpLon = double.tryParse(text);
      } else if (tag == 'AltitudeMeters') {
        tpEle = double.tryParse(text);
      } else if (tag == 'Time') {
        tpTime = DateTime.tryParse(text)?.toUtc();
      } else if (tag == 'Trackpoint') {
        if (tpLat != null &&
            tpLon != null &&
            tpLat.isFinite &&
            tpLon.isFinite) {
          pts.add(Wpt(lat: tpLat, lon: tpLon, ele: tpEle, time: tpTime));
        }
        inTrackpoint = false;
      }
    }
  }

  return Gpx()
    ..metadata = (Metadata()..name = fallbackName)
    ..trks = pts.isEmpty
        ? <Trk>[]
        : <Trk>[
            Trk(
              name: fallbackName,
              trksegs: <Trkseg>[Trkseg(trkpts: pts)],
            ),
          ];
}

class _FitFieldDef {
  const _FitFieldDef({
    required this.fieldNum,
    required this.size,
    required this.baseType,
  });

  final int fieldNum;
  final int size;
  final int baseType;
}

class _FitMesgDef {
  const _FitMesgDef({
    required this.globalMesgNum,
    required this.endian,
    required this.totalByteLength,
    required this.fields,
  });

  final int globalMesgNum;
  final Endian endian;
  final int totalByteLength;
  final List<_FitFieldDef> fields;
}

/// Pure-Dart Garmin `.fit` binary parser extracting `record` (`mesg_num == 20`)
/// trackpoints (`position_lat`, `position_long`, `altitude`, `enhanced_altitude`,
/// `timestamp`).
Gpx _parseGarminFitBinary(Uint8List bytes, String fallbackName) {
  if (bytes.length < 14) {
    throw const FormatException('FIT file too short');
  }
  final headerSize = bytes[0];
  if (headerSize < 12 || bytes.length < headerSize) {
    throw const FormatException('Invalid FIT header size');
  }
  if (bytes[8] != 0x2E ||
      bytes[9] != 0x46 ||
      bytes[10] != 0x49 ||
      bytes[11] != 0x54) {
    throw const FormatException('Missing .FIT magic signature');
  }

  final bd = ByteData.sublistView(bytes);
  final dataSize = bd.getUint32(4, Endian.little);
  final endOffset = (headerSize + dataSize).clamp(headerSize, bytes.length);

  // Garmin FIT epoch: 1989-12-31T00:00:00Z (`631065600` Unix seconds).
  const garminEpochUnixSec = 631065600;
  const semicirclesToDeg = 180.0 / 2147483648.0;

  final localDefs = List<_FitMesgDef?>.filled(16, null);
  final pts = <Wpt>[];
  var offset = headerSize;
  var lastTimestamp = 0;

  while (offset < endOffset) {
    final recordHeader = bytes[offset++];
    final isCompressedTs = (recordHeader & 0x80) != 0;

    if (!isCompressedTs && (recordHeader & 0x40) != 0) {
      // Definition message.
      final hasDevData = (recordHeader & 0x20) != 0;
      final localNum = recordHeader & 0x0F;
      if (offset + 5 > endOffset) break;
      offset++; // reserved
      final arch = bytes[offset++];
      final endian = arch == 0 ? Endian.little : Endian.big;
      final globalMesg = bd.getUint16(offset, endian);
      offset += 2;
      final numFields = bytes[offset++];
      if (offset + numFields * 3 > endOffset) break;

      final fields = <_FitFieldDef>[];
      var recordLen = 0;
      for (var i = 0; i < numFields; i++) {
        final fNum = bytes[offset++];
        final fSize = bytes[offset++];
        final fBase = bytes[offset++];
        fields.add(_FitFieldDef(fieldNum: fNum, size: fSize, baseType: fBase));
        recordLen += fSize;
      }

      if (hasDevData) {
        if (offset >= endOffset) break;
        final numDevFields = bytes[offset++];
        if (offset + numDevFields * 3 > endOffset) break;
        for (var i = 0; i < numDevFields; i++) {
          offset++; // dev field num
          final devSize = bytes[offset++];
          offset++; // dev data idx
          recordLen += devSize;
        }
      }

      localDefs[localNum] = _FitMesgDef(
        globalMesgNum: globalMesg,
        endian: endian,
        totalByteLength: recordLen,
        fields: fields,
      );
      continue;
    }

    // Data message (normal or compressed-timestamp).
    final int localNum;
    if (isCompressedTs) {
      localNum = (recordHeader >> 5) & 0x03;
      final timeOffset = recordHeader & 0x1F;
      lastTimestamp =
          (lastTimestamp & ~0x1F) +
          timeOffset +
          (timeOffset < (lastTimestamp & 0x1F) ? 0x20 : 0);
    } else {
      localNum = recordHeader & 0x0F;
    }

    final def = localDefs[localNum];
    if (def == null || offset + def.totalByteLength > endOffset) {
      break;
    }

    if (def.globalMesgNum == 20) {
      int? rawLat;
      int? rawLon;
      double? eleMeters;
      int? ts = isCompressedTs && lastTimestamp > 0 ? lastTimestamp : null;

      var cursor = offset;
      for (final f in def.fields) {
        switch (f.fieldNum) {
          case 0 when f.size == 4:
            final v = bd.getInt32(cursor, def.endian);
            if (v != 0x7FFFFFFF) rawLat = v;
          case 1 when f.size == 4:
            final v = bd.getInt32(cursor, def.endian);
            if (v != 0x7FFFFFFF) rawLon = v;
          case 2 when f.size == 2 && eleMeters == null:
            final v = bd.getUint16(cursor, def.endian);
            if (v != 0xFFFF) eleMeters = v / 5.0 - 500.0;
          case 78 when f.size == 4:
            final v = bd.getUint32(cursor, def.endian);
            if (v != 0xFFFFFFFF) eleMeters = v / 5.0 - 500.0;
          case 253 when f.size == 4:
            final v = bd.getUint32(cursor, def.endian);
            if (v != 0xFFFFFFFF) {
              ts = v;
              lastTimestamp = v;
            }
        }
        cursor += f.size;
      }

      if (rawLat != null && rawLon != null) {
        final lat = rawLat * semicirclesToDeg;
        final lon = rawLon * semicirclesToDeg;
        if (lat.abs() <= 90.0 && lon.abs() <= 180.0) {
          pts.add(
            Wpt(
              lat: lat,
              lon: lon,
              ele: eleMeters,
              time: ts != null
                  ? DateTime.fromMillisecondsSinceEpoch(
                      (garminEpochUnixSec + ts) * 1000,
                      isUtc: true,
                    )
                  : null,
            ),
          );
        }
      }
    }

    offset += def.totalByteLength;
  }

  return Gpx()
    ..metadata = (Metadata()..name = fallbackName)
    ..trks = pts.isEmpty
        ? <Trk>[]
        : <Trk>[
            Trk(
              name: fallbackName,
              trksegs: <Trkseg>[Trkseg(trkpts: pts)],
            ),
          ];
}
