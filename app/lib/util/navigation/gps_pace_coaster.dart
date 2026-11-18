import 'dart:math' as math;

import 'package:maplibre/maplibre.dart';
import 'package:wanderer/util/navigation/cooperative_gps_fusion.dart';
import 'package:wanderer/util/navigation/eta_calculator.dart';

enum GpsSignalState {
  good,
  cooperative,
  degraded,
  coasting;

  String get wireValue => switch (this) {
    GpsSignalState.good => 'good',
    GpsSignalState.cooperative => 'cooperative',
    GpsSignalState.degraded => 'degraded',
    GpsSignalState.coasting => 'coasting',
  };
}

class CoastingSnapshot {
  const CoastingSnapshot({
    required this.signalState,
    required this.suppressOffTrail,
    required this.effectiveAlongM,
    required this.lat,
    required this.lon,
    required this.ele,
    required this.effectiveAccuracyM,
  });

  final GpsSignalState signalState;
  final bool suppressOffTrail;
  final double effectiveAlongM;
  final double lat;
  final double lon;
  final double ele;
  final double effectiveAccuracyM;

  Geographic get geographic => Geographic(lat: lat, lon: lon);
}

/// Classifies GPS signal quality (`good | cooperative | degraded | coasting`),
/// suppresses false off-trail alarms under forest canopy (`accuracy > 25 m`
/// within `max(95 m, 2.2 * accuracy)`), and smoothly advances position along
/// [trackPoints] at `1 Hz` using Tobler speed / `paceFactor` for up to `180 s`
/// during complete GNSS signal blackouts.
class GpsPaceCoaster {
  GpsPaceCoaster(
    this.trackPoints, {
    this.isCycling = false,
  });

  final List<NavTrackPoint> trackPoints;
  final bool isCycling;

  static const double degradedAccuracyThresholdM = 25.0;
  static const double minCorridorFloorM = 95.0;
  static const double corridorAccuracyMultiplier = 2.2;
  static const int coastingTriggerGapMs = 6000;
  static const int maxCoastingDurationMs = 180000;
  static const double farPreviewThresholdM = 3000.0;

  double _effectiveAlongM = 0.0;
  double _lastCrossTrackM = 0.0;
  double _lastAccuracyM = 15.0;
  int? _lastFixAtMs;
  int? _lastTickAtMs;
  bool _hasFix = false;
  int _reconcileRemainingFixes = 0;

  double get totalDistanceM =>
      trackPoints.isEmpty ? 0.0 : trackPoints.last.distanceM;

  double get currentAlongM => _effectiveAlongM;

  CoastingSnapshot ingestFix({
    required double lat,
    required double lon,
    required double accuracy,
    required double matchedAlongM,
    required double crossTrackM,
    required bool isPaused,
    required double paceFactor,
    required int nowMs,
    FusedGpsSource fusedSource = FusedGpsSource.self,
  }) {
    final effAcc = (accuracy.isFinite && accuracy > 0.0) ? accuracy : 15.0;
    final clampedMatched = matchedAlongM.clamp(0.0, totalDistanceM);
    final dtSec = (_hasFix && _lastTickAtMs != null && nowMs > _lastTickAtMs!)
        ? math.min(180.0, (nowMs - _lastTickAtMs!) / 1000.0)
        : 0.0;

    final pacePredictedAlong = !_hasFix
        ? clampedMatched
        : (isPaused
              ? _effectiveAlongM
              : _advanceAlongByTime(_effectiveAlongM, dtSec, paceFactor));

    final isCooperative =
        fusedSource == FusedGpsSource.cooperative ||
        fusedSource == FusedGpsSource.groupTether;

    GpsSignalState signalState;
    var suppressOffTrail = false;

    if (effAcc > degradedAccuracyThresholdM) {
      final corridorLimit = math.max(
        minCorridorFloorM,
        corridorAccuracyMultiplier * effAcc,
      );
      signalState = GpsSignalState.degraded;
      if (crossTrackM <= corridorLimit) {
        suppressOffTrail = true;
        if (!_hasFix) {
          _effectiveAlongM = clampedMatched;
        } else {
          final blended = 0.35 * clampedMatched + 0.65 * pacePredictedAlong;
          _effectiveAlongM = math
              .max(_effectiveAlongM, blended)
              .clamp(0.0, totalDistanceM);
        }
        _reconcileRemainingFixes = 2;
      } else {
        _effectiveAlongM = clampedMatched;
        _reconcileRemainingFixes = 0;
      }
    } else {
      signalState = isCooperative
          ? GpsSignalState.cooperative
          : GpsSignalState.good;
      if (_hasFix &&
          _reconcileRemainingFixes > 0 &&
          (clampedMatched - _effectiveAlongM).abs() <=
              math.max(35.0, effAcc * 2.0)) {
        if (clampedMatched < _effectiveAlongM &&
            (_effectiveAlongM - clampedMatched) <= effAcc) {
          // Hold steady: avoid backward jump within GPS uncertainty circle.
        } else {
          _effectiveAlongM = (0.55 * clampedMatched + 0.45 * _effectiveAlongM)
              .clamp(0.0, totalDistanceM);
        }
        _reconcileRemainingFixes--;
      } else {
        _effectiveAlongM = clampedMatched;
        _reconcileRemainingFixes = 0;
      }
    }

    _hasFix = true;
    _lastFixAtMs = nowMs;
    _lastTickAtMs = nowMs;
    _lastCrossTrackM = crossTrackM;
    _lastAccuracyM = effAcc;

    final interp = interpolateAt(_effectiveAlongM);
    return CoastingSnapshot(
      signalState: signalState,
      suppressOffTrail: suppressOffTrail,
      effectiveAlongM: _effectiveAlongM,
      lat: suppressOffTrail ? interp.lat : lat,
      lon: suppressOffTrail ? interp.lon : lon,
      ele: interp.ele,
      effectiveAccuracyM: effAcc,
    );
  }

  /// Advances position along the trail at `1 Hz` when `> 6 s` have elapsed
  /// without any valid GPS fix, capped at `180 s` autonomous coasting.
  CoastingSnapshot? tickCoasting(
    int nowMs,
    double paceFactor, [
    bool isPaused = false,
  ]) {
    if (!_hasFix ||
        _lastFixAtMs == null ||
        trackPoints.length < 2 ||
        isPaused ||
        _lastCrossTrackM > farPreviewThresholdM) {
      return null;
    }

    final sinceFixMs = nowMs - _lastFixAtMs!;
    if (sinceFixMs <= coastingTriggerGapMs) {
      return null;
    }

    final capTimeMs = _lastFixAtMs! + maxCoastingDurationMs;
    final effectiveNowMs = math.min(nowMs, capTimeMs);
    final prevTickMs = _lastTickAtMs ?? _lastFixAtMs!;

    if (effectiveNowMs > prevTickMs) {
      final dtSec = (effectiveNowMs - prevTickMs) / 1000.0;
      _effectiveAlongM = _advanceAlongByTime(
        _effectiveAlongM,
        dtSec,
        paceFactor,
      );
      _lastTickAtMs = effectiveNowMs;
      _reconcileRemainingFixes = 3;
    }

    final coastedSec = math.min(180.0, sinceFixMs / 1000.0);
    final growingAcc = math.min(120.0, _lastAccuracyM + 0.45 * coastedSec);
    final interp = interpolateAt(_effectiveAlongM);

    return CoastingSnapshot(
      signalState: GpsSignalState.coasting,
      suppressOffTrail: true,
      effectiveAlongM: _effectiveAlongM,
      lat: interp.lat,
      lon: interp.lon,
      ele: interp.ele,
      effectiveAccuracyM: growingAcc,
    );
  }

  double _advanceAlongByTime(
    double startAlongM,
    double dtSec,
    double paceFactor,
  ) {
    if (dtSec <= 0.0 || trackPoints.length < 2 || totalDistanceM <= 0.0) {
      return startAlongM;
    }
    final safePace = (paceFactor.isFinite && paceFactor > 0.0)
        ? paceFactor.clamp(0.55, 1.85)
        : 1.0;

    var curAlong = startAlongM.clamp(0.0, totalDistanceM);
    var remainingSec = dtSec;
    const maxSubStepSec = 5.0;

    while (remainingSec > 1e-6 && curAlong < totalDistanceM) {
      final stepSec = math.min(remainingSec, maxSubStepSec);
      final interp = interpolateAt(curAlong);
      final speedMps =
          (toblerSpeedKmh(interp.slopeRatio, isCycling: isCycling) / 3.6) /
          safePace;
      curAlong = math.min(totalDistanceM, curAlong + stepSec * speedMps);
      remainingSec -= stepSec;
    }

    return curAlong;
  }

  ({double lat, double lon, double ele, double slopeRatio}) interpolateAt(
    double alongM,
  ) {
    if (trackPoints.isEmpty) {
      return (lat: 0.0, lon: 0.0, ele: 0.0, slopeRatio: 0.0);
    }
    if (trackPoints.length == 1 || alongM <= trackPoints.first.distanceM) {
      final first = trackPoints.first;
      return (
        lat: first.lat,
        lon: first.lon,
        ele: first.ele,
        slopeRatio: first.gradePct / 100.0,
      );
    }
    if (alongM >= trackPoints.last.distanceM) {
      final last = trackPoints.last;
      return (
        lat: last.lat,
        lon: last.lon,
        ele: last.ele,
        slopeRatio: last.gradePct / 100.0,
      );
    }

    var lo = 0;
    var hi = trackPoints.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (trackPoints[mid].distanceM <= alongM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final a = trackPoints[lo];
    final b = trackPoints[hi];
    final span = b.distanceM - a.distanceM;
    if (span <= 0.0) {
      return (
        lat: a.lat,
        lon: a.lon,
        ele: a.ele,
        slopeRatio: a.gradePct / 100.0,
      );
    }
    final t = ((alongM - a.distanceM) / span).clamp(0.0, 1.0);
    final slope = span > 0.5 ? (b.ele - a.ele) / span : b.gradePct / 100.0;
    return (
      lat: a.lat + (b.lat - a.lat) * t,
      lon: a.lon + (b.lon - a.lon) * t,
      ele: a.ele + (b.ele - a.ele) * t,
      slopeRatio: slope,
    );
  }
}
