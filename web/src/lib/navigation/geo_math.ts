import type GPX from "#lib/models/gpx/gpx.ts";
import { parseElevation } from "#lib/models/gpx/gpx-metrics-computation.ts";
import type Waypoint from "#lib/models/gpx/waypoint.ts";
import type { NavTrackPoint, SegmentProjection } from "./types";

export const EARTH_RADIUS_M = 6371000;
const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;
const METERS_PER_DEG_LAT = DEG_TO_RAD * EARTH_RADIUS_M;

const CARDINALS_EN = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"] as const;
const CARDINALS_RO = ["N", "NE", "E", "SE", "S", "SV", "V", "NV"] as const;

function clipLatitude(lat: number): number {
	return Math.min(Math.max(lat, -90), 90);
}

function wrapLongitude(lon: number): number {
	if (lon >= -180 && lon <= 180) return lon;
	const rem = (lon + 180) % 360;
	return (rem < 0 ? rem + 360 : rem) - 180;
}

/**
 * Great-circle Haversine distance in meters between two WGS84 coordinates.
 */
export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
	if (
		!Number.isFinite(lat1) ||
		!Number.isFinite(lon1) ||
		!Number.isFinite(lat2) ||
		!Number.isFinite(lon2)
	) {
		return 0;
	}
	const cLat1 = clipLatitude(lat1);
	const cLat2 = clipLatitude(lat2);
	const wLon1 = wrapLongitude(lon1);
	const wLon2 = wrapLongitude(lon2);

	const dLat = (cLat2 - cLat1) * DEG_TO_RAD;
	const dLon = (wLon2 - wLon1) * DEG_TO_RAD;
	const phi1 = cLat1 * DEG_TO_RAD;
	const phi2 = cLat2 * DEG_TO_RAD;

	const sinHalfLat = Math.sin(dLat / 2);
	const sinHalfLon = Math.sin(dLon / 2);
	const a =
		sinHalfLat * sinHalfLat +
		Math.cos(phi1) * Math.cos(phi2) * sinHalfLon * sinHalfLon;
	const clampedA = Math.min(1, Math.max(0, a));
	const c = 2 * Math.atan2(Math.sqrt(clampedA), Math.sqrt(1 - clampedA));
	return EARTH_RADIUS_M * c;
}

/**
 * Initial spherical bearing from point 1 to point 2, in `[0, 360)` degrees clockwise from North.
 */
export function bearingDegrees(lat1: number, lon1: number, lat2: number, lon2: number): number {
	if (
		!Number.isFinite(lat1) ||
		!Number.isFinite(lon1) ||
		!Number.isFinite(lat2) ||
		!Number.isFinite(lon2)
	) {
		return 0;
	}
	const phi1 = clipLatitude(lat1) * DEG_TO_RAD;
	const phi2 = clipLatitude(lat2) * DEG_TO_RAD;
	const dLon = (wrapLongitude(lon2) - wrapLongitude(lon1)) * DEG_TO_RAD;

	const y = Math.sin(dLon) * Math.cos(phi2);
	const x =
		Math.cos(phi1) * Math.sin(phi2) -
		Math.sin(phi1) * Math.cos(phi2) * Math.cos(dLon);
	if (Math.abs(x) < 1e-12 && Math.abs(y) < 1e-12) {
		return 0;
	}
	let deg = Math.atan2(y, x) * RAD_TO_DEG;
	deg = ((deg % 360) + 360) % 360;
	return deg >= 360 || deg === 0 ? 0 : deg;
}

/**
 * Shortest signed angular difference from `fromDeg` to `toDeg`, normalized to `[-180, 180]`.
 * Positive values indicate a clockwise/right turn; negative values indicate counter-clockwise/left.
 */
export function normalizeBearingDelta(fromDeg: number, toDeg: number): number {
	if (!Number.isFinite(fromDeg) || !Number.isFinite(toDeg)) {
		return 0;
	}
	let delta = (((toDeg - fromDeg) % 360) + 360) % 360;
	if (delta > 180) {
		delta -= 360;
	}
	return delta === 0 ? 0 : delta;
}

/**
 * Returns the 8-wind cardinal compass direction (`N`, `NE`, ..., `NW` / `NV`) for a bearing.
 */
export function cardinalDirection(bearingDeg: number, locale?: string): string {
	const normalized = Number.isFinite(bearingDeg) ? (((bearingDeg % 360) + 360) % 360) : 0;
	const idx = Math.round(normalized / 45) % 8;
	const isRo = (locale ?? "en").trim().toLowerCase().startsWith("ro");
	return isRo ? CARDINALS_RO[idx] : CARDINALS_EN[idx];
}

/**
 * Projects `(lat, lon)` onto line segment `(aLat, aLon) -> (bLat, bLon)` using
 * an equirectangular local tangent approximation, returning clamped `t in [0, 1]`
 * and spherical cross-track distance in meters.
 */
export function projectOntoSegment(
	lat: number,
	lon: number,
	aLat: number,
	aLon: number,
	bLat: number,
	bLon: number,
): SegmentProjection {
	const midLatRad = ((aLat + bLat) / 2) * DEG_TO_RAD;
	const cosMidLat = Math.max(1e-6, Math.cos(midLatRad));
	const metersPerDegLon = METERS_PER_DEG_LAT * cosMidLat;

	const abX = (bLon - aLon) * metersPerDegLon;
	const abY = (bLat - aLat) * METERS_PER_DEG_LAT;
	const apX = (lon - aLon) * metersPerDegLon;
	const apY = (lat - aLat) * METERS_PER_DEG_LAT;

	const segLenSq = abX * abX + abY * abY;
	let t = 0;
	if (segLenSq > 1e-12) {
		t = Math.min(1, Math.max(0, (apX * abX + apY * abY) / segLenSq));
	}

	const projectedLat = aLat + t * (bLat - aLat);
	const projectedLon = aLon + t * (bLon - aLon);
	const crossTrackMeters = haversineMeters(lat, lon, projectedLat, projectedLon);
	const segmentLengthMeters = haversineMeters(aLat, aLon, bLat, bLon);
	const bearing = segLenSq > 1e-12 ? bearingDegrees(aLat, aLon, bLat, bLon) : 0;

	return {
		t,
		crossTrackMeters,
		projectedLat,
		projectedLon,
		segmentLengthMeters,
		bearingDegrees: bearing,
	};
}

/**
 * Binary search returning the first index in sorted ascending `arr` with `arr[idx] >= value`.
 */
export function lowerBound(arr: readonly number[], value: number): number {
	let lo = 0;
	let hi = arr.length;
	while (lo < hi) {
		const mid = (lo + hi) >>> 1;
		if (arr[mid] < value) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
	return lo;
}

/**
 * Interpolates a `NavTrackPoint` along `points` at `alongTrackM` (clamped to `[0, totalDist]`).
 */
export function interpolateTrackAtDistance(
	points: readonly NavTrackPoint[],
	alongTrackM: number,
): {
	lat: number;
	lon: number;
	ele: number;
	gradePct: number;
	segmentIndex: number;
	t: number;
} {
	if (points.length === 0) {
		return { lat: 0, lon: 0, ele: 0, gradePct: 0, segmentIndex: 0, t: 0 };
	}
	if (points.length === 1) {
		const p = points[0];
		return { lat: p.lat, lon: p.lon, ele: p.ele, gradePct: p.gradePct, segmentIndex: 0, t: 0 };
	}

	const totalDist = points[points.length - 1].distanceM;
	const clamped = Math.min(totalDist, Math.max(0, alongTrackM));

	let lo = 0;
	let hi = points.length - 1;
	while (lo < hi) {
		const mid = (lo + hi) >>> 1;
		if (points[mid].distanceM < clamped) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}

	const segIdx = Math.min(points.length - 2, Math.max(0, lo > 0 ? lo - 1 : 0));
	const a = points[segIdx];
	const b = points[segIdx + 1];
	const segLen = b.distanceM - a.distanceM;
	const t = segLen > 1e-6 ? Math.min(1, Math.max(0, (clamped - a.distanceM) / segLen)) : 0;

	return {
		lat: a.lat + t * (b.lat - a.lat),
		lon: a.lon + t * (b.lon - a.lon),
		ele: a.ele + t * (b.ele - a.ele),
		gradePct: a.gradePct + t * (b.gradePct - a.gradePct),
		segmentIndex: segIdx,
		t,
	};
}

function collectRawWaypoints(gpx: GPX): Waypoint[] {
	const trackPts = gpx.flatten();
	if (trackPts.length > 0) {
		return trackPts;
	}
	const routePts: Waypoint[] = [];
	for (const rte of gpx.rte ?? []) {
		for (const pt of rte.rtept ?? []) {
			routePts.push(pt);
		}
	}
	return routePts;
}

function fillMissingElevations(rawEles: (number | undefined)[]): number[] {
	const n = rawEles.length;
	const filled = new Array<number>(n);
	let lastValidIdx = -1;

	for (let i = 0; i < n; i++) {
		const val = rawEles[i];
		if (val !== undefined && Number.isFinite(val)) {
			if (lastValidIdx === -1) {
				for (let k = 0; k <= i; k++) {
					filled[k] = val;
				}
			} else if (i - lastValidIdx > 1) {
				const startVal = filled[lastValidIdx];
				const span = i - lastValidIdx;
				for (let k = lastValidIdx + 1; k < i; k++) {
					filled[k] = startVal + ((val - startVal) * (k - lastValidIdx)) / span;
				}
				filled[i] = val;
			} else {
				filled[i] = val;
			}
			lastValidIdx = i;
		}
	}

	if (lastValidIdx === -1) {
		filled.fill(0);
	} else if (lastValidIdx < n - 1) {
		const tailVal = filled[lastValidIdx];
		for (let k = lastValidIdx + 1; k < n; k++) {
			filled[k] = tailVal;
		}
	}

	return filled;
}

function smoothFivePoint(values: readonly number[]): number[] {
	const n = values.length;
	const out = new Array<number>(n);
	for (let i = 0; i < n; i++) {
		// Symmetric radius preserves linear ramps at endpoints while smoothing interior points over 5 samples.
		const radius = Math.min(2, i, n - 1 - i);
		let sum = 0;
		for (let j = i - radius; j <= i + radius; j++) {
			sum += values[j];
		}
		out[i] = sum / (2 * radius + 1);
	}
	return out;
}

function computeSmoothedGrades(distances: readonly number[], elevations: readonly number[]): number[] {
	const n = distances.length;
	const grades = new Array<number>(n).fill(0);
	if (n < 2) return grades;

	for (let i = 0; i < n; i++) {
		let lo = i;
		while (lo > 0 && distances[i] - distances[lo] < 15) {
			lo--;
		}
		let hi = i;
		while (hi < n - 1 && distances[hi] - distances[i] < 15) {
			hi++;
		}
		const run = distances[hi] - distances[lo];
		if (run > 0.5) {
			const rawGrade = ((elevations[hi] - elevations[lo]) / run) * 100;
			grades[i] = Math.min(100, Math.max(-100, rawGrade));
		}
	}
	return grades;
}

/**
 * Extracts raw track points from a `GPX` object with cumulative `distanceM`,
 * 5-point smoothed elevation (`ele`), and smoothed slope grade (`gradePct`).
 */
export function extractRawTrackPoints(gpx: GPX): NavTrackPoint[] {
	const raw = collectRawWaypoints(gpx);
	const coords: { lat: number; lon: number; ele: number | undefined }[] = [];

	for (const pt of raw) {
		const lat = pt?.$?.lat;
		const lon = pt?.$?.lon;
		if (lat === undefined || lon === undefined || !Number.isFinite(lat) || !Number.isFinite(lon)) {
			continue;
		}
		coords.push({
			lat,
			lon,
			ele: parseElevation(pt.ele),
		});
	}

	const n = coords.length;
	if (n === 0) return [];

	const distances = new Array<number>(n);
	distances[0] = 0;
	for (let i = 1; i < n; i++) {
		distances[i] =
			distances[i - 1] +
			haversineMeters(coords[i - 1].lat, coords[i - 1].lon, coords[i].lat, coords[i].lon);
	}

	const filledEle = fillMissingElevations(coords.map((c) => c.ele));
	const smoothedEle = smoothFivePoint(filledEle);
	const grades = computeSmoothedGrades(distances, smoothedEle);

	const out: NavTrackPoint[] = new Array(n);
	for (let i = 0; i < n; i++) {
		out[i] = {
			lat: coords[i].lat,
			lon: coords[i].lon,
			ele: smoothedEle[i],
			distanceM: distances[i],
			gradePct: grades[i],
		};
	}
	return out;
}

/**
 * Reverses a track point array, recomputing `distanceM` from `0` and negating `gradePct`.
 */
export function reverseTrackPoints(points: NavTrackPoint[]): NavTrackPoint[] {
	const n = points.length;
	if (n === 0) return [];

	const reversed: NavTrackPoint[] = new Array(n);
	let cumDist = 0;

	for (let i = 0; i < n; i++) {
		const src = points[n - 1 - i];
		if (i > 0) {
			const prev = points[n - i];
			cumDist += haversineMeters(prev.lat, prev.lon, src.lat, src.lon);
		}
		reversed[i] = {
			lat: src.lat,
			lon: src.lon,
			ele: src.ele,
			distanceM: cumDist,
			gradePct: src.gradePct === 0 ? 0 : -src.gradePct,
		};
	}
	return reversed;
}
