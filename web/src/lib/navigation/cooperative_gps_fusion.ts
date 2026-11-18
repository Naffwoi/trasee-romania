import { EARTH_RADIUS_M, haversineMeters } from "./geo_math";
import type {
	FusedGpsResult,
	NavGpsFixWithMeta,
	PeerGpsObservation,
} from "./types";

const DEG_TO_RAD = Math.PI / 180;
const METERS_PER_DEG_LAT = DEG_TO_RAD * EARTH_RADIUS_M;
const MAX_PEER_AGE_MS = 12_000;
const MAX_PEER_ACCURACY_M = 60;
const GROUP_FORMATION_VARIANCE_M2 = 64; // 8m natural trail spacing variance

/**
 * Returns the set of peer memberIds currently co-located with `selfFix` (within `maxDistanceM`
 * or overlapping accuracy circles) and fresh (`<= 12s`), suitable for tracking `lastCoLocatedPeerIds`.
 */
export function findCoLocatedPeerIds(
	selfFix: { lat: number; lon: number; accuracy?: number | null },
	peers: readonly PeerGpsObservation[],
	nowMs: number = Date.now(),
	maxDistanceM = 45,
): Set<string> {
	const result = new Set<string>();
	if (!Number.isFinite(selfFix.lat) || !Number.isFinite(selfFix.lon)) {
		return result;
	}
	const selfAcc =
		selfFix.accuracy !== null &&
		selfFix.accuracy !== undefined &&
		Number.isFinite(selfFix.accuracy) &&
		selfFix.accuracy > 0
			? selfFix.accuracy
			: 15;

	for (const peer of peers) {
		if (
			!peer.memberId ||
			!Number.isFinite(peer.lat) ||
			!Number.isFinite(peer.lon) ||
			!Number.isFinite(peer.accuracy) ||
			!Number.isFinite(peer.updatedAtMs)
		) {
			continue;
		}
		if (nowMs - peer.updatedAtMs > MAX_PEER_AGE_MS) continue;
		if (peer.accuracy <= 0 || peer.accuracy > MAX_PEER_ACCURACY_M) continue;
		const dist = haversineMeters(selfFix.lat, selfFix.lon, peer.lat, peer.lon);
		if (dist <= Math.max(maxDistanceM, selfAcc + peer.accuracy)) {
			result.add(peer.memberId);
		}
	}
	return result;
}

/**
 * Inverse-Variance Weighting (BLUE) Cooperative GPS Fusion in a local ENU tangent frame,
 * guarded by a strict proximity & freshness gate so distant peers never pull the user's position.
 * Falls back to Group Tether when own GPS has dropped out (`selfFix === null`).
 */
export function fuseCooperativeGps(
	selfFix: NavGpsFixWithMeta | null,
	peers: readonly PeerGpsObservation[],
	lastCoLocatedPeerIds: ReadonlySet<string> = new Set(),
	nowMs: number = Date.now(),
): FusedGpsResult | null {
	if (selfFix === null) {
		let bestPeer: PeerGpsObservation | null = null;
		for (const peer of peers) {
			if (!lastCoLocatedPeerIds.has(peer.memberId)) continue;
			if (
				!Number.isFinite(peer.lat) ||
				!Number.isFinite(peer.lon) ||
				!Number.isFinite(peer.accuracy) ||
				!Number.isFinite(peer.updatedAtMs)
			) {
				continue;
			}
			if (peer.accuracy <= 0) continue;
			if (nowMs - peer.updatedAtMs > MAX_PEER_AGE_MS) continue;
			if (bestPeer === null || peer.accuracy < bestPeer.accuracy) {
				bestPeer = peer;
			}
		}
		if (bestPeer === null) {
			return null;
		}
		return {
			lat: bestPeer.lat,
			lon: bestPeer.lon,
			accuracy: Math.hypot(bestPeer.accuracy, 15),
			source: "group-tether",
			fusedPeerCount: 1,
		};
	}

	if (!Number.isFinite(selfFix.lat) || !Number.isFinite(selfFix.lon)) {
		return null;
	}

	const selfAcc =
		Number.isFinite(selfFix.accuracy) && selfFix.accuracy > 0 ? selfFix.accuracy : 15;

	const eligible: PeerGpsObservation[] = [];
	for (const peer of peers) {
		if (
			!Number.isFinite(peer.lat) ||
			!Number.isFinite(peer.lon) ||
			!Number.isFinite(peer.accuracy) ||
			!Number.isFinite(peer.updatedAtMs)
		) {
			continue;
		}
		if (nowMs - peer.updatedAtMs > MAX_PEER_AGE_MS) continue;
		if (peer.accuracy <= 0 || peer.accuracy > MAX_PEER_ACCURACY_M) continue;

		const dist = haversineMeters(selfFix.lat, selfFix.lon, peer.lat, peer.lon);
		if (dist <= Math.max(35, selfAcc + peer.accuracy)) {
			eligible.push(peer);
		}
	}

	if (selfAcc <= 12 || eligible.length === 0) {
		return {
			lat: selfFix.lat,
			lon: selfFix.lon,
			accuracy: selfAcc,
			source: "self",
			fusedPeerCount: 0,
		};
	}

	const cosLat = Math.max(1e-6, Math.cos(selfFix.lat * DEG_TO_RAD));
	const metersPerDegLon = METERS_PER_DEG_LAT * cosLat;

	const wSelf = 1 / Math.max(9, selfAcc ** 2);
	let sumW = wSelf;
	let sumEast = 0;
	let sumNorth = 0;

	for (const peer of eligible) {
		const eastM = (peer.lon - selfFix.lon) * metersPerDegLon;
		const northM = (peer.lat - selfFix.lat) * METERS_PER_DEG_LAT;
		const wPeer = 1 / (peer.accuracy ** 2 + GROUP_FORMATION_VARIANCE_M2);
		sumW += wPeer;
		sumEast += wPeer * eastM;
		sumNorth += wPeer * northM;
	}

	const fusedEastM = sumEast / sumW;
	const fusedNorthM = sumNorth / sumW;

	return {
		lat: selfFix.lat + fusedNorthM / METERS_PER_DEG_LAT,
		lon: selfFix.lon + fusedEastM / metersPerDegLon,
		accuracy: Math.sqrt(1 / sumW),
		source: "cooperative",
		fusedPeerCount: eligible.length,
	};
}
