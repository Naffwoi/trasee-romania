import 'dart:math' as math;

import 'package:maplibre/maplibre.dart';

enum FusedGpsSource {
  self,
  cooperative,
  groupTether;

  String get wireValue => switch (this) {
    FusedGpsSource.self => 'self',
    FusedGpsSource.cooperative => 'cooperative',
    FusedGpsSource.groupTether => 'group-tether',
  };
}

class SelfGpsObservation {
  const SelfGpsObservation({
    required this.lat,
    required this.lon,
    required this.accuracy,
    this.ele,
    required this.timestampMs,
  });

  final double lat;
  final double lon;
  final double accuracy;
  final double? ele;
  final int timestampMs;
}

class PeerGpsObservation {
  const PeerGpsObservation({
    required this.memberId,
    required this.lat,
    required this.lon,
    required this.accuracy,
    this.ele,
    required this.updatedAtMs,
  });

  final String memberId;
  final double lat;
  final double lon;
  final double accuracy;
  final double? ele;
  final int updatedAtMs;
}

class FusedGpsResult {
  const FusedGpsResult({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.source,
    required this.fusedPeerCount,
    this.coLocatedPeerIds = const <String>{},
  });

  final double lat;
  final double lon;
  final double accuracy;
  final FusedGpsSource source;
  final int fusedPeerCount;
  final Set<String> coLocatedPeerIds;

  Geographic get geographic => Geographic(lat: lat, lon: lon);
}

/// Best Linear Unbiased Estimator (Inverse-Variance Weighting) in local tangent
/// ENU coordinates for nearby live hiking group peers, guarded by a strict
/// proximity gate (`dist <= max(35 m, selfAcc + peerAcc)`) and freshness gate
/// (`age <= 12 s`), plus automatic `groupTether` when own GPS drops out `> 6 s`.
class CooperativeGpsFusion {
  const CooperativeGpsFusion._();

  static const int maxOwnFixAgeMs = 6000;
  static const int maxPeerAgeMs = 12000;
  static const double minProximityGateMeters = 35.0;
  static const double maxPeerAccuracyMeters = 60.0;
  static const double tetherLastKnownMaxDistM = 45.0;
  static const double sharpSelfAccuracyM = 12.0;

  static FusedGpsResult? fuse({
    required SelfGpsObservation? selfFix,
    required List<PeerGpsObservation> peers,
    Set<String> lastCoLocatedPeerIds = const <String>{},
    required int nowMs,
  }) {
    final hasValidSelfCoords =
        selfFix != null && selfFix.lat.isFinite && selfFix.lon.isFinite;
    final hasFreshSelf =
        selfFix != null &&
        hasValidSelfCoords &&
        (nowMs - selfFix.timestampMs) <= maxOwnFixAgeMs;

    if (!hasFreshSelf) {
      final tetherPeers = <PeerGpsObservation>[];
      for (final p in peers) {
        if (!p.lat.isFinite || !p.lon.isFinite) continue;
        if (!p.accuracy.isFinite ||
            p.accuracy <= 0.0 ||
            p.accuracy > maxPeerAccuracyMeters) {
          continue;
        }
        final ageMs = nowMs - p.updatedAtMs;
        if (ageMs > maxPeerAgeMs || ageMs < -5000) continue;

        var wasNearby = lastCoLocatedPeerIds.contains(p.memberId);
        if (!wasNearby && selfFix != null && hasValidSelfCoords) {
          final d = SphericalGreatCircle(
            Geographic(lat: selfFix.lat, lon: selfFix.lon),
          ).distanceTo(Geographic(lat: p.lat, lon: p.lon));
          if (d.isFinite && d <= tetherLastKnownMaxDistM) {
            wasNearby = true;
          }
        }
        if (wasNearby) {
          tetherPeers.add(p);
        }
      }

      if (tetherPeers.isEmpty) {
        return null;
      }

      final origin = tetherPeers.first;
      const mPerDegLat = 111320.0;
      final mPerDegLon =
          111320.0 * math.max(0.1, math.cos(origin.lat * math.pi / 180.0));

      var sumW = 0.0;
      var sumE = 0.0;
      var sumN = 0.0;
      final coLocated = <String>{};

      for (final p in tetherPeers) {
        coLocated.add(p.memberId);
        final e = (p.lon - origin.lon) * mPerDegLon;
        final n = (p.lat - origin.lat) * mPerDegLat;
        // 15 m formation dispersion -> hypot(peer.accuracy, 15.0) for 1 peer.
        final w = 1.0 / (p.accuracy * p.accuracy + 225.0);
        sumW += w;
        sumE += w * e;
        sumN += w * n;
      }

      return FusedGpsResult(
        lat: origin.lat + (sumN / sumW) / mPerDegLat,
        lon: origin.lon + (sumE / sumW) / mPerDegLon,
        accuracy: math.sqrt(1.0 / sumW),
        source: FusedGpsSource.groupTether,
        fusedPeerCount: tetherPeers.length,
        coLocatedPeerIds: coLocated,
      );
    }

    final selfAcc = (selfFix.accuracy.isFinite && selfFix.accuracy > 0.0)
        ? selfFix.accuracy
        : 15.0;
    final selfGeo = Geographic(lat: selfFix.lat, lon: selfFix.lon);
    final eligiblePeers = <PeerGpsObservation>[];
    final nextCoLocated = <String>{};

    for (final p in peers) {
      if (!p.lat.isFinite || !p.lon.isFinite) continue;
      if (!p.accuracy.isFinite ||
          p.accuracy <= 0.0 ||
          p.accuracy > maxPeerAccuracyMeters) {
        continue;
      }
      final ageMs = nowMs - p.updatedAtMs;
      if (ageMs > maxPeerAgeMs || ageMs < -5000) continue;

      final distM = SphericalGreatCircle(
        selfGeo,
      ).distanceTo(Geographic(lat: p.lat, lon: p.lon));
      if (!distM.isFinite) continue;

      final gateM = math.max(minProximityGateMeters, selfAcc + p.accuracy);
      if (distM <= tetherLastKnownMaxDistM || distM <= gateM) {
        nextCoLocated.add(p.memberId);
      }
      if (distM <= gateM) {
        eligiblePeers.add(p);
      }
    }

    if (selfAcc <= sharpSelfAccuracyM || eligiblePeers.isEmpty) {
      return FusedGpsResult(
        lat: selfFix.lat,
        lon: selfFix.lon,
        accuracy: selfAcc,
        source: FusedGpsSource.self,
        fusedPeerCount: 0,
        coLocatedPeerIds: nextCoLocated,
      );
    }

    const mPerDegLat = 111320.0;
    final mPerDegLon =
        111320.0 * math.max(0.1, math.cos(selfFix.lat * math.pi / 180.0));

    final wSelf = 1.0 / math.max(9.0, selfAcc * selfAcc);
    var sumW = wSelf;
    var sumE = 0.0;
    var sumN = 0.0;

    for (final p in eligiblePeers) {
      final e = (p.lon - selfFix.lon) * mPerDegLon;
      final n = (p.lat - selfFix.lat) * mPerDegLat;
      final w = 1.0 / (p.accuracy * p.accuracy + 64.0);
      sumW += w;
      sumE += w * e;
      sumN += w * n;
    }

    return FusedGpsResult(
      lat: selfFix.lat + (sumN / sumW) / mPerDegLat,
      lon: selfFix.lon + (sumE / sumW) / mPerDegLon,
      accuracy: math.sqrt(1.0 / sumW),
      source: FusedGpsSource.cooperative,
      fusedPeerCount: eligiblePeers.length,
      coLocatedPeerIds: nextCoLocated,
    );
  }
}
