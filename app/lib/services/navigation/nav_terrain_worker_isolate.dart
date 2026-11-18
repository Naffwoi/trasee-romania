import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/navigation/dem_tile_grid.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';
import 'package:wanderer/util/navigation/off_trail_router.dart';
import 'package:wanderer/util/route/track_position_matcher.dart';

class WorkerMatchResponse {
  const WorkerMatchResponse({required this.detail, required this.eta});

  final TrackMatchDetail detail;
  final EtaSnapshot? eta;
}

class WorkerRerouteResponse {
  const WorkerRerouteResponse({
    required this.generation,
    required this.isHybrid,
    required this.result,
    required this.geoJsonString,
    required this.eta,
  });

  final int generation;
  final bool isHybrid;
  final OffTrailRerouteResult result;
  final String geoJsonString;
  final EtaSnapshot? eta;
}

/// Persistent background worker isolate holding resident trail geometry,
/// [TrackPositionMatcher] (`200m` spatial hash), [EtaCalculator], and
/// [DemTileGrid] (`.dem16` `Uint16` slabs + offline `.pmtiles`) for zero-jank
/// 60/120 FPS navigation.
class NavTerrainWorkerIsolate {
  NavTerrainWorkerIsolate._({
    required Isolate isolate,
    required ReceivePort receivePort,
    required SendPort workerPort,
    this.onHybridRerouteReady,
  }) : _isolate = isolate,
       _receivePort = receivePort,
       _workerPort = workerPort {
    _sub = _receivePort.listen(_handleWorkerMessage);
  }

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final SendPort _workerPort;
  final void Function(WorkerRerouteResponse hybrid)? onHybridRerouteReady;

  StreamSubscription<Object?>? _sub;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextReqId = 1;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  static Future<NavTerrainWorkerIsolate> spawn({
    required List<NavTrackPoint> trailPoints,
    required bool isCycling,
    required String localeCode,
    required String demTileUrlTemplate,
    required String cacheRootPath,
    required List<String> demArchivePaths,
    String? apiBaseUrl,
    String? deviceToken,
    void Function(WorkerRerouteResponse hybrid)? onHybridRerouteReady,
  }) async {
    final handshake = ReceivePort();
    final packed = Float64List(trailPoints.length * 5);
    for (var i = 0; i < trailPoints.length; i++) {
      final p = trailPoints[i];
      final base = i * 5;
      packed[base] = p.lat;
      packed[base + 1] = p.lon;
      packed[base + 2] = p.ele;
      packed[base + 3] = p.distanceM;
      packed[base + 4] = p.gradePct;
    }

    final isolate = await Isolate.spawn<_WorkerInitPayload>(
      _terrainWorkerEntryPoint,
      _WorkerInitPayload(
        replyPort: handshake.sendPort,
        packedTrail: TransferableTypedData.fromList(<TypedData>[packed]),
        pointCount: trailPoints.length,
        isCycling: isCycling,
        localeCode: localeCode,
        demTileUrlTemplate: demTileUrlTemplate,
        cacheRootPath: cacheRootPath,
        demArchivePaths: List<String>.from(demArchivePaths),
        apiBaseUrl: apiBaseUrl,
        deviceToken: deviceToken,
      ),
      debugName: 'NavTerrainWorkerIsolate',
    );

    final workerPort = await handshake.first as SendPort;
    handshake.close();

    final runtimePort = ReceivePort();
    workerPort.send(<Object?>[0, 'bind', runtimePort.sendPort]);

    return NavTerrainWorkerIsolate._(
      isolate: isolate,
      receivePort: runtimePort,
      workerPort: workerPort,
      onHybridRerouteReady: onHybridRerouteReady,
    );
  }

  void _handleWorkerMessage(Object? raw) {
    if (_disposed || raw is! List || raw.length < 2) return;
    final id = raw[0] as int;
    final kind = raw[1] as String;

    if (kind == 'hybrid_push') {
      final parsed = _decodeReroutePayload(raw);
      if (parsed != null) {
        onHybridRerouteReady?.call(parsed);
      }
      return;
    }

    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    switch (kind) {
      case 'match_ok':
        completer.complete(_decodeMatchPayload(raw));
      case 'reroute_ok':
        completer.complete(_decodeReroutePayload(raw));
      case 'ack':
      case 'null':
      case 'err':
        completer.complete(null);
    }
  }

  Future<WorkerMatchResponse?> matchFix({
    required double lat,
    required double lon,
    double? heading,
    double? headingAccuracy,
    double? speed,
    double? accuracy,
    required bool recordProgress,
    required int nowMs,
    OffTrailRerouteResult? activeOffTrail,
  }) async {
    if (_disposed) return null;
    final reqId = _nextReqId++;
    final completer = Completer<Object?>();
    _pending[reqId] = completer;

    _workerPort.send(<Object?>[
      reqId,
      'match',
      lat,
      lon,
      heading,
      headingAccuracy,
      speed,
      accuracy,
      recordProgress,
      nowMs,
      activeOffTrail?.distanceM,
      activeOffTrail?.estimatedSeconds,
      activeOffTrail?.ascentM,
      activeOffTrail?.rejoinAlongTrackM,
    ]);
    final res = await completer.future;
    return res is WorkerMatchResponse ? res : null;
  }

  Future<WorkerRerouteResponse?> computeReroute({
    required int generation,
    required Geographic userPos,
    double? userEleM,
    required double alongTrackM,
    required OffTrailMode mode,
    required String localeCode,
    required bool tryValhalla,
  }) async {
    if (_disposed) return null;
    final reqId = _nextReqId++;
    final completer = Completer<Object?>();
    _pending[reqId] = completer;

    _workerPort.send(<Object?>[
      reqId,
      'reroute',
      generation,
      userPos.lat,
      userPos.lon,
      userEleM,
      alongTrackM,
      mode.index,
      localeCode,
      tryValhalla,
    ]);
    final res = await completer.future;
    return res is WorkerRerouteResponse ? res : null;
  }

  Future<void> prefetchCorridor(List<Geographic> corridorPoints) async {
    if (_disposed || corridorPoints.isEmpty) return;
    final reqId = _nextReqId++;
    final completer = Completer<Object?>();
    _pending[reqId] = completer;

    final flat = Float64List(corridorPoints.length * 2);
    for (var i = 0; i < corridorPoints.length; i++) {
      flat[i * 2] = corridorPoints[i].lat;
      flat[i * 2 + 1] = corridorPoints[i].lon;
    }
    _workerPort.send(<Object?>[
      reqId,
      'prefetch',
      TransferableTypedData.fromList(<TypedData>[flat]),
    ]);
    await completer.future;
  }

  void cancelActiveReroutes(int newGeneration) {
    if (_disposed) return;
    _workerPort.send(<Object?>[0, 'cancel_reroute', newGeneration]);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      _workerPort.send(<Object?>[0, 'dispose']);
    } catch (_) {}
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    await _sub?.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static WorkerMatchResponse? _decodeMatchPayload(List<Object?> raw) {
    if (raw.length < 10) return null;
    final detail = TrackMatchDetail(
      isOffTrail: raw[2] as bool,
      alongTrackMeters: raw[3] as double,
      crossTrackMeters: raw[4] as double,
      matchedPoint: Geographic(lat: raw[5] as double, lon: raw[6] as double),
      segmentIndex: raw[7] as int,
      consecutiveOffTrailFixes: raw[8] as int,
    );
    final etaRaw = raw[9] as List<Object?>?;
    final eta = etaRaw == null ? null : _decodeEta(etaRaw);
    return WorkerMatchResponse(detail: detail, eta: eta);
  }

  static WorkerRerouteResponse? _decodeReroutePayload(List<Object?> raw) {
    if (raw.length < 21) return null;
    final gen = raw[2] as int;
    final isHybrid = raw[3] as bool;
    final mode = OffTrailMode.values[raw[4] as int];
    final packedPts = (raw[5] as TransferableTypedData)
        .materialize()
        .asFloat64List();
    final pts = <OffTrailPoint>[];
    for (var i = 0; i + 4 < packedPts.length; i += 5) {
      pts.add(
        OffTrailPoint(
          lat: packedPts[i],
          lon: packedPts[i + 1],
          ele: packedPts[i + 2],
          distanceM: packedPts[i + 3],
          gradePct: packedPts[i + 4],
        ),
      );
    }
    final result = OffTrailRerouteResult(
      mode: mode,
      points: pts,
      rejoinPoint: Geographic(lat: raw[6] as double, lon: raw[7] as double),
      rejoinAlongTrackM: raw[8] as double,
      rejoinEleM: raw[9] as double,
      distanceM: raw[10] as double,
      estimatedSeconds: raw[11] as int,
      ascentM: raw[12] as double,
      descentM: raw[13] as double,
      maxSlopeDeg: raw[14] as double,
      avoidedSteepHazard: raw[15] as bool,
      initialBearingDeg: raw[16] as double,
      instruction: raw[17] as String,
      slopeAdvice: raw[18] as String,
    );
    final geoBytes = (raw[19] as TransferableTypedData)
        .materialize()
        .asUint8List();
    final etaRaw = raw[20] as List<Object?>?;
    return WorkerRerouteResponse(
      generation: gen,
      isHybrid: isHybrid,
      result: result,
      geoJsonString: utf8.decode(geoBytes),
      eta: etaRaw == null ? null : _decodeEta(etaRaw),
    );
  }

  static EtaSnapshot _decodeEta(List<Object?> e) {
    final peakEle = e[9] as double?;
    final peakDist = e[10] as double?;
    final peakGain = e[11] as double?;
    return EtaSnapshot(
      remainingDistanceM: e[0] as double,
      remainingSeconds: e[1] as int,
      arrivalTimeFormatted: e[2] as String,
      remainingAscentM: e[3] as double,
      remainingDescentM: e[4] as double,
      currentEleM: e[5] as double,
      currentGradePct: e[6] as double,
      progressRatio: e[7] as double,
      paceFactor: e[8] as double,
      nextPeak: (peakEle != null && peakDist != null && peakGain != null)
          ? EtaPeak(
              ele: peakEle,
              distanceAheadM: peakDist,
              gainAheadM: peakGain,
            )
          : null,
    );
  }
}

class _WorkerInitPayload {
  const _WorkerInitPayload({
    required this.replyPort,
    required this.packedTrail,
    required this.pointCount,
    required this.isCycling,
    required this.localeCode,
    required this.demTileUrlTemplate,
    required this.cacheRootPath,
    required this.demArchivePaths,
    this.apiBaseUrl,
    this.deviceToken,
  });

  final SendPort replyPort;
  final TransferableTypedData packedTrail;
  final int pointCount;
  final bool isCycling;
  final String localeCode;
  final String demTileUrlTemplate;
  final String cacheRootPath;
  final List<String> demArchivePaths;
  final String? apiBaseUrl;
  final String? deviceToken;
}

void _terrainWorkerEntryPoint(_WorkerInitPayload init) {
  final port = ReceivePort();
  init.replyPort.send(port.sendPort);

  final rawDoubles = init.packedTrail.materialize().asFloat64List();
  final trailPoints = List<NavTrackPoint>.generate(init.pointCount, (i) {
    final base = i * 5;
    return NavTrackPoint(
      lat: rawDoubles[base],
      lon: rawDoubles[base + 1],
      ele: rawDoubles[base + 2],
      distanceM: rawDoubles[base + 3],
      gradePct: rawDoubles[base + 4],
    );
  }, growable: false);

  final shape = List<Geographic>.generate(
    trailPoints.length,
    (i) => Geographic(lat: trailPoints[i].lat, lon: trailPoints[i].lon),
    growable: false,
  );
  final cumulative = List<double>.generate(
    trailPoints.length,
    (i) => trailPoints[i].distanceM,
    growable: false,
  );

  final matcher = TrackPositionMatcher(
    shape: shape,
    cumulativeMeters: cumulative,
  );
  final etaCalc = EtaCalculator.fromPoints(
    trailPoints,
    isCycling: init.isCycling,
  );
  final demGrid = DemTileGrid(
    tileUrlTemplate: init.demTileUrlTemplate,
    cacheRootProvider: () async => Directory(init.cacheRootPath),
    demArchivePaths: init.demArchivePaths,
  );

  final Dio? valhallaDio =
      (init.apiBaseUrl != null && init.apiBaseUrl!.isNotEmpty)
      ? Dio(
          BaseOptions(
            baseUrl: init.apiBaseUrl!,
            headers: <String, dynamic>{
              if (init.deviceToken != null && init.deviceToken!.isNotEmpty)
                'X-Device-Token': init.deviceToken,
            },
          ),
        )
      : null;

  SendPort? mainPort;
  var latestGen = 0;
  CancelToken? activeValhallaCancel;

  List<Object?> encodeEta(EtaSnapshot e) => <Object?>[
    e.remainingDistanceM,
    e.remainingSeconds,
    e.arrivalTimeFormatted,
    e.remainingAscentM,
    e.remainingDescentM,
    e.currentEleM,
    e.currentGradePct,
    e.progressRatio,
    e.paceFactor,
    e.nextPeak?.ele,
    e.nextPeak?.distanceAheadM,
    e.nextPeak?.gainAheadM,
  ];

  List<Object?> encodeReroute(
    int reqId,
    String tag,
    int gen,
    bool isHybrid,
    OffTrailRerouteResult r,
    EtaSnapshot? eta,
  ) {
    final packedPts = Float64List(r.points.length * 5);
    for (var i = 0; i < r.points.length; i++) {
      final p = r.points[i];
      final b = i * 5;
      packedPts[b] = p.lat;
      packedPts[b + 1] = p.lon;
      packedPts[b + 2] = p.ele;
      packedPts[b + 3] = p.distanceM;
      packedPts[b + 4] = p.gradePct;
    }
    final geoJsonMap = <String, Object?>{
      'type': 'FeatureCollection',
      'features': r.points.length < 2
          ? const <Object?>[]
          : <Object?>[
              <String, Object?>{
                'type': 'Feature',
                'properties': <String, Object?>{
                  'avoidedCliff': r.avoidedSteepHazard,
                },
                'geometry': <String, Object?>{
                  'type': 'LineString',
                  'coordinates': <List<double>>[
                    for (final p in r.points) <double>[p.lon, p.lat],
                  ],
                },
              },
            ],
    };
    final geoBytes = Uint8List.fromList(utf8.encode(jsonEncode(geoJsonMap)));
    return <Object?>[
      reqId,
      tag,
      gen,
      isHybrid,
      r.mode.index,
      TransferableTypedData.fromList(<TypedData>[packedPts]),
      r.rejoinPoint.lat,
      r.rejoinPoint.lon,
      r.rejoinAlongTrackM,
      r.rejoinEleM,
      r.distanceM,
      r.estimatedSeconds,
      r.ascentM,
      r.descentM,
      r.maxSlopeDeg,
      r.avoidedSteepHazard,
      r.initialBearingDeg,
      r.instruction,
      r.slopeAdvice,
      TransferableTypedData.fromList(<TypedData>[geoBytes]),
      eta == null ? null : encodeEta(eta),
    ];
  }

  port.listen((Object? raw) async {
    if (raw is! List || raw.length < 2) return;
    final reqId = raw[0] as int;
    final cmd = raw[1] as String;

    if (cmd == 'bind') {
      mainPort = raw[2] as SendPort;
      return;
    }
    if (cmd == 'cancel_reroute') {
      final gen = raw[2] as int;
      if (gen > latestGen) latestGen = gen;
      activeValhallaCancel?.cancel('superseded');
      activeValhallaCancel = null;
      return;
    }
    if (cmd == 'dispose') {
      activeValhallaCancel?.cancel('dispose');
      await demGrid.closeArchives();
      port.close();
      return;
    }

    final out = mainPort;
    if (out == null) return;

    try {
      if (cmd == 'match') {
        final pos = Geographic(lat: raw[2] as double, lon: raw[3] as double);
        final detail = matcher.matchDetailed(
          pos,
          heading: raw[4] as double?,
          headingAccuracy: raw[5] as double?,
          speed: raw[6] as double?,
          accuracy: raw[7] as double?,
        );
        if (detail == null) {
          out.send(<Object?>[reqId, 'null']);
          return;
        }
        final recordProgress = raw[8] as bool;
        final now = DateTime.fromMillisecondsSinceEpoch(raw[9] as int);
        if (recordProgress && !detail.isOffTrail) {
          etaCalc.recordProgress(detail.alongTrackMeters, now);
        }
        final eta = etaCalc.compute(
          detail.alongTrackMeters,
          now: now,
          offTrailDistanceM: raw[10] as double?,
          offTrailDurationSec: raw[11] as int?,
          offTrailAscentM: raw[12] as double?,
          rejoinAlongTrackM: raw[13] as double?,
        );
        out.send(<Object?>[
          reqId,
          'match_ok',
          detail.isOffTrail,
          detail.alongTrackMeters,
          detail.crossTrackMeters,
          detail.matchedPoint.lat,
          detail.matchedPoint.lon,
          detail.segmentIndex,
          detail.consecutiveOffTrailFixes,
          encodeEta(eta),
        ]);
        return;
      }

      if (cmd == 'prefetch') {
        final flat = (raw[2] as TransferableTypedData)
            .materialize()
            .asFloat64List();
        final pts = <Geographic>[];
        for (var i = 0; i + 1 < flat.length; i += 2) {
          pts.add(Geographic(lat: flat[i], lon: flat[i + 1]));
        }
        await demGrid.prefetchCorridor(pts);
        out.send(<Object?>[reqId, 'ack']);
        return;
      }

      if (cmd == 'reroute') {
        final gen = raw[2] as int;
        if (gen < latestGen) {
          out.send(<Object?>[reqId, 'null']);
          return;
        }
        latestGen = gen;
        activeValhallaCancel?.cancel('superseded');
        activeValhallaCancel = null;

        final userPos = Geographic(
          lat: raw[3] as double,
          lon: raw[4] as double,
        );
        final userEleM = raw[5] as double?;
        final alongM = raw[6] as double;
        final mode = OffTrailMode.values[raw[7] as int];
        final locale = raw[8] as String;
        final tryValhalla = raw[9] as bool;

        if (demGrid.sampleElevation(userPos.lat, userPos.lon) == null) {
          await demGrid.prefetchCorridor(<Geographic>[userPos]);
        }
        if (gen < latestGen) {
          out.send(<Object?>[reqId, 'null']);
          return;
        }

        final local = OffTrailRouter.compute(
          userPos: userPos,
          userEleM: userEleM,
          trailPoints: trailPoints,
          lastAlongTrackM: alongM,
          sampler: demGrid.sampleElevation,
          mode: mode,
          localeCode: locale,
          isCycling: init.isCycling,
          precomputedEta: etaCalc,
          isCancelled: () => gen < latestGen,
        );
        if (local == null || gen < latestGen) {
          out.send(<Object?>[reqId, 'null']);
          return;
        }

        final localEta = etaCalc.compute(
          alongM,
          offTrailDistanceM: local.distanceM,
          offTrailDurationSec: local.estimatedSeconds,
          offTrailAscentM: local.ascentM,
          rejoinAlongTrackM: local.rejoinAlongTrackM,
        );
        out.send(
          encodeReroute(reqId, 'reroute_ok', gen, false, local, localEta),
        );

        if (tryValhalla && valhallaDio != null && gen == latestGen) {
          final token = CancelToken();
          activeValhallaCancel = token;
          final hybrid = await OffTrailRouter.computeHybridWithValhalla(
            dio: valhallaDio,
            userPos: userPos,
            userEleM: userEleM,
            trailPoints: trailPoints,
            lastAlongTrackM: alongM,
            sampler: demGrid.sampleElevation,
            mode: mode,
            localeCode: locale,
            isCycling: init.isCycling,
            cancelToken: token,
            precomputedLocalResult: local,
            precomputedEta: etaCalc,
          );
          if (hybrid != null &&
              !identical(hybrid, local) &&
              gen == latestGen) {
            final hybridEta = etaCalc.compute(
              alongM,
              offTrailDistanceM: hybrid.distanceM,
              offTrailDurationSec: hybrid.estimatedSeconds,
              offTrailAscentM: hybrid.ascentM,
              rejoinAlongTrackM: hybrid.rejoinAlongTrackM,
            );
            out.send(
              encodeReroute(0, 'hybrid_push', gen, true, hybrid, hybridEta),
            );
          }
        }
      }
    } catch (_) {
      out.send(<Object?>[reqId, 'err']);
    }
  });
}
