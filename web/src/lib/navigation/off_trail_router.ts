import {
	bearingDegrees,
	cardinalDirection,
	haversineMeters,
	interpolateTrackAtDistance,
	projectOntoSegment,
} from "./geo_math";
import { toblerHikingSpeedKmh } from "./eta_calculator";
import type {
	NavTrackPoint,
	OffTrailMode,
	OffTrailPoint,
	OffTrailRerouteResult,
} from "./types";

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;
const EARTH_RADIUS_M = 6371000;
const METERS_PER_DEG_LAT = DEG_TO_RAD * EARTH_RADIUS_M;

const MIN_CELL_SIZE_M = 15;
const MAX_CELL_SIZE_M = 35;
const MAX_GRID_DIM = 180;
const CLIFF_SLOPE_THRESHOLD = 0.75; // tan(~36.87 deg)
const STEEP_SLOPE_THRESHOLD = 0.50;

const SQRT5 = Math.hypot(1, 2);

const MOVES_16: readonly { dx: number; dy: number; steps: number; isKnight: boolean }[] = [
	// 8 King moves
	{ dx: 1, dy: 0, steps: 1, isKnight: false },
	{ dx: -1, dy: 0, steps: 1, isKnight: false },
	{ dx: 0, dy: 1, steps: 1, isKnight: false },
	{ dx: 0, dy: -1, steps: 1, isKnight: false },
	{ dx: 1, dy: 1, steps: Math.SQRT2, isKnight: false },
	{ dx: 1, dy: -1, steps: Math.SQRT2, isKnight: false },
	{ dx: -1, dy: 1, steps: Math.SQRT2, isKnight: false },
	{ dx: -1, dy: -1, steps: Math.SQRT2, isKnight: false },
	// 8 Knight moves
	{ dx: 1, dy: 2, steps: SQRT5, isKnight: true },
	{ dx: 2, dy: 1, steps: SQRT5, isKnight: true },
	{ dx: 2, dy: -1, steps: SQRT5, isKnight: true },
	{ dx: 1, dy: -2, steps: SQRT5, isKnight: true },
	{ dx: -1, dy: -2, steps: SQRT5, isKnight: true },
	{ dx: -2, dy: -1, steps: SQRT5, isKnight: true },
	{ dx: -2, dy: 1, steps: SQRT5, isKnight: true },
	{ dx: -1, dy: 2, steps: SQRT5, isKnight: true },
];

interface HeapNode {
	idx: number;
	f: number;
}

class MinHeap {
	private data: HeapNode[] = [];

	get size(): number {
		return this.data.length;
	}

	peek(): HeapNode | undefined {
		return this.data[0];
	}

	push(idx: number, f: number): void {
		const arr = this.data;
		arr.push({ idx, f });
		let i = arr.length - 1;
		while (i > 0) {
			const parent = (i - 1) >> 1;
			if (arr[parent].f <= arr[i].f) break;
			const tmp = arr[parent];
			arr[parent] = arr[i];
			arr[i] = tmp;
			i = parent;
		}
	}

	pop(): HeapNode | undefined {
		const arr = this.data;
		if (arr.length === 0) return undefined;
		const top = arr[0];
		const last = arr.pop()!;
		if (arr.length > 0) {
			arr[0] = last;
			let i = 0;
			const n = arr.length;
			while (true) {
				const left = (i << 1) + 1;
				const right = left + 1;
				let smallest = i;
				if (left < n && arr[left].f < arr[smallest].f) smallest = left;
				if (right < n && arr[right].f < arr[smallest].f) smallest = right;
				if (smallest === i) break;
				const tmp = arr[i];
				arr[i] = arr[smallest];
				arr[smallest] = tmp;
				i = smallest;
			}
		}
		return top;
	}
}

interface RejoinCandidate {
	lat: number;
	lon: number;
	ele: number;
	alongTrackM: number;
	remainingTrailSec: number;
	remainingTrailDistM: number;
	x: number;
	y: number;
	gx: number;
	gy: number;
	terminalCost: number;
}

function precomputeCumTrailSeconds(points: readonly NavTrackPoint[]): number[] {
	const n = points.length;
	const cumSec = new Array<number>(n).fill(0);
	for (let i = 1; i < n; i++) {
		const ds = Math.max(0, points[i].distanceM - points[i - 1].distanceM);
		const dEle = points[i].ele - points[i - 1].ele;
		const slope = ds > 0.1 ? dEle / ds : 0;
		const speedMs = (toblerHikingSpeedKmh(slope, false) * 1000) / 3600;
		cumSec[i] = cumSec[i - 1] + (ds > 0 ? ds / speedMs : 0);
	}
	return cumSec;
}

function interpolateArrayAtDistance(
	points: readonly NavTrackPoint[],
	values: readonly number[],
	alongM: number,
): number {
	const n = points.length;
	if (n === 0) return 0;
	if (n === 1 || alongM <= points[0].distanceM) return values[0];
	if (alongM >= points[n - 1].distanceM) return values[n - 1];

	let lo = 0;
	let hi = n - 1;
	while (lo < hi) {
		const mid = (lo + hi) >>> 1;
		if (points[mid].distanceM < alongM) lo = mid + 1;
		else hi = mid;
	}
	const i0 = Math.max(0, lo - 1);
	const span = points[i0 + 1].distanceM - points[i0].distanceM;
	const t = span > 1e-6 ? Math.min(1, Math.max(0, (alongM - points[i0].distanceM) / span)) : 0;
	return values[i0] + t * (values[i0 + 1] - values[i0]);
}

function createElevationSampler(
	sampler: (lat: number, lon: number) => number | null,
	trailPoints: readonly NavTrackPoint[],
	userLat: number,
	userLon: number,
	userEle?: number | null,
): (lat: number, lon: number) => number {
	// Pre-subsample trail points for fast IDW fallback when DEM sampler returns null.
	const idwAnchors: { lat: number; lon: number; ele: number }[] = [];
	if (userEle !== undefined && userEle !== null && Number.isFinite(userEle)) {
		idwAnchors.push({ lat: userLat, lon: userLon, ele: userEle });
	}
	if (trailPoints.length > 0) {
		const step = Math.max(1, Math.floor(trailPoints.length / 40));
		for (let i = 0; i < trailPoints.length; i += step) {
			const pt = trailPoints[i];
			if (Number.isFinite(pt.ele)) {
				idwAnchors.push({ lat: pt.lat, lon: pt.lon, ele: pt.ele });
			}
		}
		const last = trailPoints[trailPoints.length - 1];
		if (Number.isFinite(last.ele)) {
			idwAnchors.push({ lat: last.lat, lon: last.lon, ele: last.ele });
		}
	}

	return (lat: number, lon: number): number => {
		const sampled = sampler(lat, lon);
		if (sampled !== null && Number.isFinite(sampled)) {
			return sampled;
		}
		if (idwAnchors.length === 0) {
			return 0;
		}
		let weightSum = 0;
		let eleSum = 0;
		for (const a of idwAnchors) {
			const d = haversineMeters(lat, lon, a.lat, a.lon);
			const w = 1 / (d * d + 25);
			weightSum += w;
			eleSum += w * a.ele;
		}
		return weightSum > 0 ? eleSum / weightSum : 0;
	};
}

function evaluateEdgeCost(
	mode: OffTrailMode,
	d: number,
	eleFrom: number,
	eleTo: number,
	eleMid: number | null,
): number {
	if (d <= 0.01) return 0;
	const dEle = eleTo - eleFrom;
	const s = dEle / d;

	let maxAbsSlope = Math.abs(s);
	if (eleMid !== null) {
		const halfD = d * 0.5;
		const s1 = Math.abs((eleMid - eleFrom) / halfD);
		const s2 = Math.abs((eleTo - eleMid) / halfD);
		if (s1 > maxAbsSlope) maxAbsSlope = s1;
		if (s2 > maxAbsSlope) maxAbsSlope = s2;
	}

	let hazardMult = 1;
	if (maxAbsSlope > CLIFF_SLOPE_THRESHOLD) {
		hazardMult = 40;
	} else if (mode === "min-climb" && maxAbsSlope > STEEP_SLOPE_THRESHOLD) {
		hazardMult = 4;
	}

	if (mode === "shortest-safe") {
		const base = d + 1.0 * Math.max(0, dEle);
		return base * hazardMult;
	}

	// "min-climb": Tobler off-trail duration + climb & steep-descent penalties.
	const vKmh = toblerHikingSpeedKmh(s, false);
	const offTrailSec = d / ((0.6 * vKmh) / 3.6);
	const climbPenalty = 6.5 * Math.max(0, dEle);
	const steepDescentPenalty = s < -0.20 ? 2.0 * Math.abs(dEle) : 0;
	return (offTrailSec + climbPenalty + steepDescentPenalty) * hazardMult;
}

function segmentMaxSlopeRatio(
	aLat: number,
	aLon: number,
	bLat: number,
	bLon: number,
	evalEle: (lat: number, lon: number) => number,
	sampleStepM = 12,
): { maxAbsSlope: number; totalCostMinClimb: number; totalCostShortest: number } {
	const totalDist = haversineMeters(aLat, aLon, bLat, bLon);
	if (totalDist <= 0.1) {
		return { maxAbsSlope: 0, totalCostMinClimb: 0, totalCostShortest: 0 };
	}
	const steps = Math.max(1, Math.ceil(totalDist / sampleStepM));
	const stepD = totalDist / steps;
	let prevEle = evalEle(aLat, aLon);
	let maxAbsSlope = 0;
	let costMin = 0;
	let costShort = 0;

	for (let k = 1; k <= steps; k++) {
		const t = k / steps;
		const lat = aLat + t * (bLat - aLat);
		const lon = aLon + t * (bLon - aLon);
		const ele = evalEle(lat, lon);
		const slope = Math.abs((ele - prevEle) / stepD);
		if (slope > maxAbsSlope) maxAbsSlope = slope;
		costMin += evaluateEdgeCost("min-climb", stepD, prevEle, ele, null);
		costShort += evaluateEdgeCost("shortest-safe", stepD, prevEle, ele, null);
		prevEle = ele;
	}

	return { maxAbsSlope, totalCostMinClimb: costMin, totalCostShortest: costShort };
}

function smoothOffTrailPath(
	rawCoords: { lat: number; lon: number }[],
	mode: OffTrailMode,
	evalEle: (lat: number, lon: number) => number,
	preserveSafeThreshold: number,
): { lat: number; lon: number }[] {
	if (rawCoords.length <= 2) return rawCoords;

	// Line-of-sight string pulling that strictly rejects shortcuts through steep hazards or higher-cost terrain.
	const pruned: { lat: number; lon: number }[] = [rawCoords[0]];
	let anchorIdx = 0;

	while (anchorIdx < rawCoords.length - 1) {
		let bestNext = anchorIdx + 1;
		// Try farthest reachable vertex first (bounded lookahead to avoid large skips).
		const maxLook = Math.min(rawCoords.length - 1, anchorIdx + 12);
		for (let j = maxLook; j > anchorIdx + 1; j--) {
			const a = rawCoords[anchorIdx];
			const b = rawCoords[j];
			const chordCheck = segmentMaxSlopeRatio(a.lat, a.lon, b.lat, b.lon, evalEle, 12);
			if (chordCheck.maxAbsSlope > preserveSafeThreshold) continue;

			// Compare chord cost against the existing sub-path cost.
			let subPathCost = 0;
			for (let k = anchorIdx; k < j; k++) {
				const seg = segmentMaxSlopeRatio(
					rawCoords[k].lat,
					rawCoords[k].lon,
					rawCoords[k + 1].lat,
					rawCoords[k + 1].lon,
					evalEle,
					15,
				);
				subPathCost += mode === "min-climb" ? seg.totalCostMinClimb : seg.totalCostShortest;
			}
			const chordCost =
				mode === "min-climb" ? chordCheck.totalCostMinClimb : chordCheck.totalCostShortest;
			if (chordCost <= subPathCost * 1.03) {
				bestNext = j;
				break;
			}
		}
		pruned.push(rawCoords[bestNext]);
		anchorIdx = bestNext;
	}

	if (pruned.length <= 2) return pruned;

	// Light single-pass corner smoothing, reverting any move that increases slope past safe threshold.
	const smoothed: { lat: number; lon: number }[] = [pruned[0]];
	for (let i = 1; i < pruned.length - 1; i++) {
		const prev = smoothed[smoothed.length - 1];
		const curr = pruned[i];
		const next = pruned[i + 1];
		const candLat = 0.25 * prev.lat + 0.5 * curr.lat + 0.25 * next.lat;
		const candLon = 0.25 * prev.lon + 0.5 * curr.lon + 0.25 * next.lon;

		const s1 = segmentMaxSlopeRatio(prev.lat, prev.lon, candLat, candLon, evalEle, 12);
		const s2 = segmentMaxSlopeRatio(candLat, candLon, next.lat, next.lon, evalEle, 12);
		if (
			s1.maxAbsSlope <= preserveSafeThreshold &&
			s2.maxAbsSlope <= preserveSafeThreshold
		) {
			smoothed.push({ lat: candLat, lon: candLon });
		} else {
			smoothed.push(curr);
		}
	}
	smoothed.push(pruned[pruned.length - 1]);

	return smoothed;
}

/**
 * Multi-Target 16-neighbor A* off-trail router that finds an optimal terrain-aware
 * rejoin path from the user's off-trail location back onto the trail.
 */
export function computeOffTrailReroute(params: {
	userLat: number;
	userLon: number;
	userEle?: number | null;
	trailPoints: NavTrackPoint[];
	lastAlongTrackM: number;
	sampler: (lat: number, lon: number) => number | null;
	mode?: OffTrailMode;
	locale?: string;
}): OffTrailRerouteResult {
	const mode: OffTrailMode = params.mode ?? "min-climb";
	const isRo = (params.locale ?? "en").trim().toLowerCase().startsWith("ro");
	const evalEle = createElevationSampler(
		params.sampler,
		params.trailPoints,
		params.userLat,
		params.userLon,
		params.userEle,
	);

	if (params.trailPoints.length === 0) {
		const ele = evalEle(params.userLat, params.userLon);
		return {
			mode,
			points: [
				{
					lat: params.userLat,
					lon: params.userLon,
					ele,
					distanceM: 0,
					gradePct: 0,
				},
			],
			rejoinLat: params.userLat,
			rejoinLon: params.userLon,
			rejoinAlongTrackM: 0,
			rejoinEleM: ele,
			distanceM: 0,
			estimatedSeconds: 0,
			ascentM: 0,
			descentM: 0,
			maxSlopeDeg: 0,
			avoidedSteepHazard: false,
			initialBearingDeg: 0,
			instruction: isRo ? "Continuă spre traseu" : "Continue toward the trail",
			slopeAdvice: isRo ? "Pantă ușoară" : "Gentle slope",
		};
	}

	const trailPoints = params.trailPoints;
	const totalTrailDist = trailPoints[trailPoints.length - 1].distanceM;
	const cumTrailSec = precomputeCumTrailSeconds(trailPoints);
	const totalTrailSec = cumTrailSec[cumTrailSec.length - 1];

	// 1. Collect global nearest point + candidates in [lastAlong - 150, lastAlong + 1500].
	let nearestCross = Infinity;
	let nearestAlong = 0;
	let nearestLat = trailPoints[0].lat;
	let nearestLon = trailPoints[0].lon;
	for (let i = 0; i < trailPoints.length - 1; i++) {
		const a = trailPoints[i];
		const b = trailPoints[i + 1];
		const proj = projectOntoSegment(params.userLat, params.userLon, a.lat, a.lon, b.lat, b.lon);
		if (proj.crossTrackMeters < nearestCross) {
			nearestCross = proj.crossTrackMeters;
			nearestAlong = a.distanceM + proj.t * (b.distanceM - a.distanceM);
			nearestLat = proj.projectedLat;
			nearestLon = proj.projectedLon;
		}
	}
	if (trailPoints.length === 1) {
		nearestCross = haversineMeters(
			params.userLat,
			params.userLon,
			trailPoints[0].lat,
			trailPoints[0].lon,
		);
	}

	const candAlongSet: number[] = [nearestAlong];
	const minCand = Math.max(0, params.lastAlongTrackM - 150);
	const maxCand = Math.min(totalTrailDist, params.lastAlongTrackM + 1500);
	const span = Math.max(0, maxCand - minCand);
	const targetSamples = Math.min(35, Math.max(1, Math.ceil(span / 50) + 1));
	for (let k = 0; k < targetSamples; k++) {
		const d = targetSamples === 1 ? minCand : minCand + (span * k) / (targetSamples - 1);
		if (Math.abs(d - nearestAlong) > 15) {
			candAlongSet.push(d);
		}
	}

	// Local tangent frame centered at (userLat, userLon).
	const cosLat = Math.max(0.1, Math.cos(params.userLat * DEG_TO_RAD));
	const metersPerDegLon = METERS_PER_DEG_LAT * cosLat;
	const toLocal = (lat: number, lon: number) => ({
		x: (lon - params.userLon) * metersPerDegLon,
		y: (lat - params.userLat) * METERS_PER_DEG_LAT,
	});
	const toLatLon = (x: number, y: number) => ({
		lat: params.userLat + y / METERS_PER_DEG_LAT,
		lon: params.userLon + x / metersPerDegLon,
	});

	const rawTargets: Omit<RejoinCandidate, "gx" | "gy">[] = candAlongSet.map((along) => {
		const interp =
			Math.abs(along - nearestAlong) < 1e-6 && trailPoints.length > 1
				? { lat: nearestLat, lon: nearestLon }
				: interpolateTrackAtDistance(trailPoints, along);
		const local = toLocal(interp.lat, interp.lon);
		const remTrailSec = Math.max(
			0,
			totalTrailSec - interpolateArrayAtDistance(trailPoints, cumTrailSec, along),
		);
		const remTrailDist = Math.max(0, totalTrailDist - along);
		const terminalCost =
			mode === "min-climb" ? 0.30 * remTrailSec : 0.001 * remTrailDist;
		return {
			lat: interp.lat,
			lon: interp.lon,
			ele: evalEle(interp.lat, interp.lon),
			alongTrackM: along,
			remainingTrailSec: remTrailSec,
			remainingTrailDistM: remTrailDist,
			x: local.x,
			y: local.y,
			terminalCost,
		};
	});

	// Keep targets within reasonable Euclidean radius if trail is huge so cellSize <= 35m and grid <= 180x180.
	const maxAllowedSpan = (MAX_GRID_DIM - 1) * MAX_CELL_SIZE_M; // 6265m
	const nearestLocal = toLocal(nearestLat, nearestLon);
	const baseDist = Math.hypot(nearestLocal.x, nearestLocal.y);
	const detourPad = Math.min(500, Math.max(300, 0.5 * baseDist));

	let minX = 0;
	let maxX = 0;
	let minY = 0;
	let maxY = 0;
	const filteredTargets: Omit<RejoinCandidate, "gx" | "gy">[] = [];

	// Always include nearest target first.
	rawTargets.sort((a, b) => Math.hypot(a.x, a.y) - Math.hypot(b.x, b.y));
	for (const t of rawTargets) {
		const candMinX = Math.min(minX, t.x);
		const candMaxX = Math.max(maxX, t.x);
		const candMinY = Math.min(minY, t.y);
		const candMaxY = Math.max(maxY, t.y);
		if (
			filteredTargets.length > 0 &&
			(candMaxX - candMinX + 2 * detourPad > maxAllowedSpan ||
				candMaxY - candMinY + 2 * detourPad > maxAllowedSpan)
		) {
			continue;
		}
		minX = candMinX;
		maxX = candMaxX;
		minY = candMinY;
		maxY = candMaxY;
		filteredTargets.push(t);
	}

	minX -= detourPad;
	maxX += detourPad;
	minY -= detourPad;
	maxY += detourPad;

	const spanX = Math.max(150, maxX - minX);
	const spanY = Math.max(150, maxY - minY);
	const maxSpan = Math.max(spanX, spanY);

	let cellSize = Math.min(MAX_CELL_SIZE_M, Math.max(MIN_CELL_SIZE_M, maxSpan / 120));
	// Ensure cols <= 180 and rows <= 180 without exceeding MAX_CELL_SIZE_M.
	const requiredCellForDim = maxSpan / (MAX_GRID_DIM - 2);
	if (requiredCellForDim > cellSize) {
		cellSize = Math.min(MAX_CELL_SIZE_M, requiredCellForDim);
	}

	const cols = Math.min(MAX_GRID_DIM, Math.max(3, Math.ceil(spanX / cellSize) + 1));
	const rows = Math.min(MAX_GRID_DIM, Math.max(3, Math.ceil(spanY / cellSize) + 1));

	const worldToGrid = (x: number, y: number): { gx: number; gy: number } => ({
		gx: Math.min(cols - 1, Math.max(0, Math.round((x - minX) / cellSize))),
		gy: Math.min(rows - 1, Math.max(0, Math.round((y - minY) / cellSize))),
	});
	const gridToWorld = (gx: number, gy: number): { x: number; y: number } => ({
		x: minX + gx * cellSize,
		y: minY + gy * cellSize,
	});

	const startCell = worldToGrid(0, 0);
	const totalCells = cols * rows;
	const startIdx = startCell.gy * cols + startCell.gx;

	const targetMap = new Map<number, RejoinCandidate>();
	for (const t of filteredTargets) {
		const g = worldToGrid(t.x, t.y);
		const idx = g.gy * cols + g.gx;
		const existing = targetMap.get(idx);
		if (!existing || t.terminalCost < existing.terminalCost) {
			targetMap.set(idx, { ...t, gx: g.gx, gy: g.gy });
		}
	}
	const uniqueTargets = [...targetMap.values()];

	// Run Multi-Target Binary-Heap A*.
	const eleCache = new Float64Array(totalCells);
	eleCache.fill(NaN);
	const getCellEle = (gx: number, gy: number): number => {
		const idx = gy * cols + gx;
		const cached = eleCache[idx];
		if (!Number.isNaN(cached)) return cached;
		const w = gridToWorld(gx, gy);
		const ll = toLatLon(w.x, w.y);
		const e = evalEle(ll.lat, ll.lon);
		eleCache[idx] = e;
		return e;
	};

	// Admissible minimum per-meter cost rate.
	const minRate = mode === "min-climb" ? 1 / ((0.6 * 7.5) / 3.6) : 1.0; // 0.80 s/m vs 1.0 m/m
	const heuristic = (gx: number, gy: number): number => {
		let best = Infinity;
		for (const t of uniqueTargets) {
			const dist = Math.hypot(t.gx - gx, t.gy - gy) * cellSize;
			const hVal = minRate * dist + t.terminalCost;
			if (hVal < best) best = hVal;
		}
		return best;
	};

	const gScore = new Float64Array(totalCells);
	gScore.fill(Infinity);
	const parent = new Int32Array(totalCells);
	parent.fill(-1);
	const closed = new Uint8Array(totalCells);

	const pq = new MinHeap();
	gScore[startIdx] = 0;
	pq.push(startIdx, heuristic(startCell.gx, startCell.gy));

	let bestGoalCost = Infinity;
	let winningTarget: RejoinCandidate = uniqueTargets[0];
	let winningIdx = winningTarget.gy * cols + winningTarget.gx;

	while (pq.size > 0) {
		const top = pq.peek()!;
		if (top.f >= bestGoalCost) {
			break;
		}
		const cur = pq.pop()!;
		const idx = cur.idx;
		if (closed[idx]) continue;
		closed[idx] = 1;

		const targetHit = targetMap.get(idx);
		if (targetHit) {
			const goalCost = gScore[idx] + targetHit.terminalCost;
			if (goalCost < bestGoalCost) {
				bestGoalCost = goalCost;
				winningTarget = targetHit;
				winningIdx = idx;
			}
		}

		const gx = idx % cols;
		const gy = (idx - gx) / cols;
		const eleFrom = getCellEle(gx, gy);

		for (const mv of MOVES_16) {
			const nx = gx + mv.dx;
			const ny = gy + mv.dy;
			if (nx < 0 || nx >= cols || ny < 0 || ny >= rows) continue;
			const nIdx = ny * cols + nx;
			if (closed[nIdx]) continue;

			const d = mv.steps * cellSize;
			const eleTo = getCellEle(nx, ny);
			let eleMid: number | null = null;
			if (mv.isKnight || (Math.abs(mv.dx) === 1 && Math.abs(mv.dy) === 1)) {
				const midWorld = gridToWorld(gx + mv.dx * 0.5, gy + mv.dy * 0.5);
				const midLL = toLatLon(midWorld.x, midWorld.y);
				eleMid = evalEle(midLL.lat, midLL.lon);
			}

			const stepCost = evaluateEdgeCost(mode, d, eleFrom, eleTo, eleMid);
			const tentG = gScore[idx] + stepCost;
			if (tentG < gScore[nIdx]) {
				gScore[nIdx] = tentG;
				parent[nIdx] = idx;
				pq.push(nIdx, tentG + heuristic(nx, ny));
			}
		}
	}

	// Reconstruct coordinate path.
	const rawCoords: { lat: number; lon: number }[] = [];
	if (winningIdx === startIdx || parent[winningIdx] === -1) {
		rawCoords.push({ lat: params.userLat, lon: params.userLon });
		if (
			haversineMeters(params.userLat, params.userLon, winningTarget.lat, winningTarget.lon) > 1
		) {
			rawCoords.push({ lat: winningTarget.lat, lon: winningTarget.lon });
		}
	} else {
		const indices: number[] = [];
		let cur = winningIdx;
		while (cur !== -1) {
			indices.push(cur);
			if (cur === startIdx) break;
			cur = parent[cur];
		}
		indices.reverse();

		for (let i = 0; i < indices.length; i++) {
			if (i === 0) {
				rawCoords.push({ lat: params.userLat, lon: params.userLon });
			} else if (i === indices.length - 1) {
				rawCoords.push({ lat: winningTarget.lat, lon: winningTarget.lon });
			} else {
				const cellIdx = indices[i];
				const gx = cellIdx % cols;
				const gy = (cellIdx - gx) / cols;
				const w = gridToWorld(gx, gy);
				rawCoords.push(toLatLon(w.x, w.y));
			}
		}
	}

	// Measure raw path max slope to decide safe smoothing threshold.
	let rawMaxAbsSlope = 0;
	for (let i = 0; i < rawCoords.length - 1; i++) {
		const seg = segmentMaxSlopeRatio(
			rawCoords[i].lat,
			rawCoords[i].lon,
			rawCoords[i + 1].lat,
			rawCoords[i + 1].lon,
			evalEle,
			12,
		);
		if (seg.maxAbsSlope > rawMaxAbsSlope) rawMaxAbsSlope = seg.maxAbsSlope;
	}
	const safeSmoothThreshold =
		rawMaxAbsSlope <= CLIFF_SLOPE_THRESHOLD
			? Math.min(CLIFF_SLOPE_THRESHOLD, Math.max(0.45, rawMaxAbsSlope + 0.05))
			: rawMaxAbsSlope + 0.05;

	const smoothedCoords = smoothOffTrailPath(rawCoords, mode, evalEle, safeSmoothThreshold);

	// Build final OffTrailPoint array and metrics.
	const outPoints: OffTrailPoint[] = [];
	let cumDist = 0;
	let ascentM = 0;
	let descentM = 0;
	let estimatedSeconds = 0;
	let maxAbsSlope = 0;

	const eles = smoothedCoords.map((c) => evalEle(c.lat, c.lon));

	for (let i = 0; i < smoothedCoords.length; i++) {
		const c = smoothedCoords[i];
		if (i > 0) {
			const prev = smoothedCoords[i - 1];
			const d = haversineMeters(prev.lat, prev.lon, c.lat, c.lon);
			cumDist += d;
			const dEle = eles[i] - eles[i - 1];
			if (dEle > 0) ascentM += dEle;
			else if (dEle < 0) descentM += -dEle;

			const s = d > 0.1 ? dEle / d : 0;
			const absS = Math.abs(s);
			if (absS > maxAbsSlope) maxAbsSlope = absS;

			// Also check sub-samples along long smoothed segments for slope accuracy.
			if (d > 20) {
				const sub = segmentMaxSlopeRatio(prev.lat, prev.lon, c.lat, c.lon, evalEle, 15);
				if (sub.maxAbsSlope > maxAbsSlope) maxAbsSlope = sub.maxAbsSlope;
			}

			const v = toblerHikingSpeedKmh(s, false);
			estimatedSeconds += d > 0 ? d / ((0.6 * v) / 3.6) : 0;
		}

		let gradePct = 0;
		if (smoothedCoords.length >= 2) {
			if (i === 0) {
				const d = haversineMeters(c.lat, c.lon, smoothedCoords[1].lat, smoothedCoords[1].lon);
				gradePct = d > 0.1 ? ((eles[1] - eles[0]) / d) * 100 : 0;
			} else {
				const prev = smoothedCoords[i - 1];
				const d = haversineMeters(prev.lat, prev.lon, c.lat, c.lon);
				gradePct = d > 0.1 ? ((eles[i] - eles[i - 1]) / d) * 100 : 0;
			}
		}

		outPoints.push({
			lat: c.lat,
			lon: c.lon,
			ele: eles[i],
			distanceM: cumDist,
			gradePct,
		});
	}

	const maxSlopeDeg = Math.atan(maxAbsSlope) * RAD_TO_DEG;

	// Check whether direct chord encountered a steep cliff hazard (>36.87 deg) that the path avoided.
	const directCheck = segmentMaxSlopeRatio(
		params.userLat,
		params.userLon,
		winningTarget.lat,
		winningTarget.lon,
		evalEle,
		12,
	);
	const avoidedSteepHazard =
		directCheck.maxAbsSlope > CLIFF_SLOPE_THRESHOLD &&
		maxAbsSlope <= CLIFF_SLOPE_THRESHOLD;

	// Initial bearing ~35m ahead along the computed path.
	let initialBearingDeg = 0;
	if (outPoints.length >= 2) {
		const targetDist = Math.min(35, cumDist);
		let lookLat = outPoints[outPoints.length - 1].lat;
		let lookLon = outPoints[outPoints.length - 1].lon;
		for (let i = 1; i < outPoints.length; i++) {
			if (outPoints[i].distanceM >= targetDist) {
				const segSpan = outPoints[i].distanceM - outPoints[i - 1].distanceM;
				const frac =
					segSpan > 1e-6
						? Math.min(1, Math.max(0, (targetDist - outPoints[i - 1].distanceM) / segSpan))
						: 1;
				lookLat = outPoints[i - 1].lat + frac * (outPoints[i].lat - outPoints[i - 1].lat);
				lookLon = outPoints[i - 1].lon + frac * (outPoints[i].lon - outPoints[i - 1].lon);
				break;
			}
		}
		initialBearingDeg = bearingDegrees(params.userLat, params.userLon, lookLat, lookLon);
	}

	const dir = cardinalDirection(initialBearingDeg, isRo ? "ro" : "en");
	const distRounded = Math.round(cumDist);
	const climbRounded = Math.round(ascentM);
	const slopeRounded = Math.round(maxSlopeDeg);

	const instruction = isRo
		? avoidedSteepHazard
			? `Ocolește panta abruptă spre ${dir} (${distRounded} m până la potecă)`
			: `Urmează direcția ${dir} (${distRounded} m până la potecă)`
		: avoidedSteepHazard
			? `Contour around steep slope heading ${dir} (${distRounded} m to trail)`
			: `Head ${dir} (${distRounded} m to trail)`;

	let slopeAdvice: string;
	if (isRo) {
		if (avoidedSteepHazard) {
			slopeAdvice = `Evită zona abruptă · urcare +${climbRounded} m · pantă max ${slopeRounded}°`;
		} else if (ascentM > 10) {
			slopeAdvice = `Urcare +${climbRounded} m · pantă max ${slopeRounded}°`;
		} else {
			slopeAdvice = `Pantă ușoară · max ${slopeRounded}°`;
		}
	} else {
		if (avoidedSteepHazard) {
			slopeAdvice = `Steep hazard avoided · +${climbRounded} m climb · max slope ${slopeRounded}°`;
		} else if (ascentM > 10) {
			slopeAdvice = `Climb +${climbRounded} m · max slope ${slopeRounded}°`;
		} else {
			slopeAdvice = `Gentle slope · max ${slopeRounded}°`;
		}
	}

	return {
		mode,
		points: outPoints,
		rejoinLat: winningTarget.lat,
		rejoinLon: winningTarget.lon,
		rejoinAlongTrackM: winningTarget.alongTrackM,
		rejoinEleM: eles[eles.length - 1],
		distanceM: cumDist,
		estimatedSeconds,
		ascentM,
		descentM,
		maxSlopeDeg,
		avoidedSteepHazard,
		initialBearingDeg,
		instruction,
		slopeAdvice,
	};
}
