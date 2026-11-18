import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';
import 'package:wanderer/util/gpx/conversion.dart';
import 'package:wanderer/util/gpx/offline_trail_transcoder.dart';

/// Builds a valid minimal binary Garmin `.fit` file containing 1 definition
/// message for `record` (global mesg 20) and 2 trackpoint data records.
Uint8List _buildSampleGarminFitFile() {
  final dataBytes = BytesBuilder();

  // Definition message: local mesg 0, little-endian (0), global mesg 20 (record), 4 fields:
  // field 253 (timestamp, uint32, 4B), field 0 (lat, sint32, 4B),
  // field 1 (lon, sint32, 4B), field 2 (altitude, uint16, 2B).
  dataBytes.add(<int>[
    0x40, // definition header, local 0
    0x00, // reserved
    0x00, // architecture: little-endian
    20, 0, // global mesg num = 20 (record)
    4, // num fields = 4
    253, 4, 0x86, // timestamp uint32
    0, 4, 0x85, // position_lat sint32
    1, 4, 0x85, // position_long sint32
    2, 2, 0x84, // altitude uint16 ((ele + 500) * 5)
  ]);

  int degToSemicircles(double deg) =>
      (deg * (2147483648.0 / 180.0)).round();

  void writeRecord({
    required int garminTs,
    required double lat,
    required double lon,
    required double eleM,
  }) {
    final rec = ByteData(1 + 4 + 4 + 4 + 2);
    rec.setUint8(0, 0x00); // data header, local mesg 0
    rec.setUint32(1, garminTs, Endian.little);
    rec.setInt32(5, degToSemicircles(lat), Endian.little);
    rec.setInt32(9, degToSemicircles(lon), Endian.little);
    rec.setUint16(13, ((eleM + 500.0) * 5.0).round(), Endian.little);
    dataBytes.add(rec.buffer.asUint8List());
  }

  writeRecord(garminTs: 1_164_000_000, lat: 45.4081, lon: 25.4742, eleM: 2025.0);
  writeRecord(garminTs: 1_164_000_030, lat: 45.4092, lon: 25.4755, eleM: 2042.4);

  final payload = dataBytes.toBytes();
  final header = ByteData(14);
  header.setUint8(0, 14); // header size
  header.setUint8(1, 0x20); // protocol v2.0
  header.setUint16(2, 2113, Endian.little); // profile version
  header.setUint32(4, payload.length, Endian.little); // data size
  header.setUint8(8, 0x2E); // '.'
  header.setUint8(9, 0x46); // 'F'
  header.setUint8(10, 0x49); // 'I'
  header.setUint8(11, 0x54); // 'T'
  header.setUint16(12, 0, Endian.little); // optional header CRC (0 = ignored)

  final out = BytesBuilder()
    ..add(header.buffer.asUint8List())
    ..add(payload)
    ..add(<int>[0, 0]); // 2-byte trailing file CRC
  return out.toBytes();
}

void main() {
  group('Offline pure-Dart KML / KMZ / FIT / TCX transcoder', () {
    test('parses KML LineString + Placemark waypoints and zipped KMZ archive in memory', () {
      const kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Jepii Mici Offline</name>
    <Placemark>
      <name>Cabana Caraiman</name>
      <Point><coordinates>25.4742,45.4081,2025</coordinates></Point>
    </Placemark>
    <Placemark>
      <name>Poteca Jepi</name>
      <LineString>
        <coordinates>
          25.5300,45.4100,910
          25.5100,45.4090,1450
          25.4742,45.4081,2025
        </coordinates>
      </LineString>
    </Placemark>
  </Document>
</kml>''';

      final kmlRes = transcodeTrailBytesIsolate((
        bytes: Uint8List.fromList(utf8.encode(kml)),
        ext: 'kml',
        fallbackName: 'jepi.kml',
      ));
      expect(kmlRes.gpx.metadata?.name, 'Jepii Mici Offline');
      expect(kmlRes.gpx.wpts, hasLength(1));
      expect(kmlRes.gpx.wpts.single.name, 'Cabana Caraiman');
      final trkPts = kmlRes.gpx.trks.single.trksegs.single.trkpts;
      expect(trkPts, hasLength(3));
      expect(trkPts.last.lat, closeTo(45.4081, 1e-6));
      expect(trkPts.last.ele, closeTo(2025.0, 0.1));

      // Now pack the KML inside a .kmz ZIP archive and verify in-memory extraction!
      final archive = Archive()
        ..addFile(ArchiveFile('doc.kml', utf8.encode(kml).length, utf8.encode(kml)));
      final kmzBytes = Uint8List.fromList(ZipEncoder().encode(archive));

      final kmzRes = transcodeTrailBytesIsolate((
        bytes: kmzBytes,
        ext: 'kmz',
        fallbackName: 'jepi.kmz',
      ));
      expect(kmzRes.gpx.trks.single.trksegs.single.trkpts, hasLength(3));
    });

    test('parses binary Garmin .fit semicircles, altitude scale/offset, and Garmin epoch', () {
      final fitBytes = _buildSampleGarminFitFile();
      final res = transcodeTrailBytesIsolate((
        bytes: fitBytes,
        ext: 'fit',
        fallbackName: 'garmin_fenix_bucegi.fit',
      ));

      final pts = res.gpx.trks.single.trksegs.single.trkpts;
      expect(pts, hasLength(2));
      expect(pts[0].lat, closeTo(45.4081, 1e-5));
      expect(pts[0].lon, closeTo(25.4742, 1e-5));
      expect(pts[0].ele, closeTo(2025.0, 0.25));
      expect(pts[1].ele, closeTo(2042.4, 0.25));
      expect(
        pts[1].time!.difference(pts[0].time!),
        const Duration(seconds: 30),
      );
      expect(res.gpxXml, contains('<trkpt'));
    });

    test('serializeAndBuildTrailIsolate produces XML + Trail metrics in one pass', () {
      final gpx = Gpx()
        ..trks = <Trk>[
          Trk(
            name: 'Creasta Făgăraș',
            trksegs: <Trkseg>[
              Trkseg(
                trkpts: <Wpt>[
                  Wpt(lat: 45.5990, lon: 24.7350, ele: 2480, time: DateTime.utc(2026, 8, 1, 8, 0)),
                  Wpt(lat: 45.5995, lon: 24.7362, ele: 2544, time: DateTime.utc(2026, 8, 1, 8, 20)),
                ],
              ),
            ],
          ),
        ];

      final out = serializeAndBuildTrailIsolate((
        gpx: gpx,
        plannedRoute: false,
        fallbackName: 'fagaras',
        movingDuration: const Duration(minutes: 18),
      ));

      expect(out.xml, contains('Creasta Făgăraș'));
      expect(out.trail.expand?.gpxData, out.xml);
      expect(out.trail.distance, greaterThan(80.0));
      expect(out.trail.movingDuration, 1080.0);
    });

    test('parses Garmin .tcx Trackpoint elements offline', () {
      const tcx = '''<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="Hiking">
      <Lap StartTime="2026-08-01T07:00:00Z">
        <Track>
          <Trackpoint>
            <Time>2026-08-01T07:00:00Z</Time>
            <Position>
              <LatitudeDegrees>45.4081</LatitudeDegrees>
              <LongitudeDegrees>25.4742</LongitudeDegrees>
            </Position>
            <AltitudeMeters>2025.0</AltitudeMeters>
          </Trackpoint>
          <Trackpoint>
            <Time>2026-08-01T07:01:00Z</Time>
            <Position>
              <LatitudeDegrees>45.4092</LatitudeDegrees>
              <LongitudeDegrees>25.4755</LongitudeDegrees>
            </Position>
            <AltitudeMeters>2042.4</AltitudeMeters>
          </Trackpoint>
        </Track>
      </Lap>
    </Activity>
  </Activities>
</TrainingCenterDatabase>''';

      final res = transcodeTrailBytesIsolate((
        bytes: Uint8List.fromList(utf8.encode(tcx)),
        ext: 'tcx',
        fallbackName: 'bucegi.tcx',
      ));
      final pts = res.gpx.trks.single.trksegs.single.trkpts;
      expect(pts, hasLength(2));
      expect(pts.first.lat, closeTo(45.4081, 1e-6));
      expect(pts.last.ele, closeTo(2042.4, 0.1));
      expect(pts.last.time!.difference(pts.first.time!), const Duration(minutes: 1));
    });
  });
}
