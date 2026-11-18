import { toblerHikingSpeedKmh } from "./eta_calculator";
import {
	bearingDegrees,
	cardinalDirection,
	haversineMeters,
	interpolateTrackAtDistance,
	projectOntoSegment,
} from "./geo_math";
import {
	FAR_PREVIEW_THRESHOLD_METERS,
	type NavTrackPoint,
	type ObstaclePolygon,
	type OffTrailMode,
	type OffTrailPoint,
	type OffTrailRerouteResult,
	type PreferredCorridor,
} from "./types";

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;
const EARTH_RADIUS_M = 6371000;
const METERS_PER_DEG_LAT = DEG_TO_RAD * EARTH_RADIUS_M;

const MIN_CELL_SIZE_M = 15;
const MIN_OBSTACLE_CELL_SIZE_M = 8;
const MAX_CELL_SIZE_M = 35;
const MAX_GRID_DIM = 180;
const CLIFF_SLOPE_THRESHOLD = 0.75; // tan(~36.87 deg)
const STEEP_SLOPE_THRESHOLD = 0.50;
const OBSTACLE_EDGE_BUFFER_M = 8;
const PREFERRED_PATH_COST_MULT = 0.65;

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

interface LocalPoly {
	pts: { x: number; y: number }[];
	minX: number;
	maxX: number;
	minY: number;
	maxY: number;
}

interface LocalCorridor {
	pts: { x: number; y: number }[];
}

function buildLocalPolygons(
	obstacles: readonly ObstaclePolygon[] | undefined,
	toLocal: (lat: number, lon: number) => { x: number; y: number },
): LocalPoly[] {
	if (!obstacles || obstacles.length === 0) return [];
	const out: LocalPoly[] = [];
	for (const obs of obstacles) {
		if (!obs?.rings || obs.rings.length < 3) continue;
		const pts: { x: number; y: number }[] = [];
		let minX = Infinity;
		let maxX = -Infinity;
		let minY = Infinity;
		let maxY = -Infinity;
		for (const v of obs.rings) {
			if (!Array.isArray(v) || v.length < 2) continue;
			const lon = v[0];
			const lat = v[1];
			if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
			const loc = toLocal(lat, lon);
			pts.push(loc);
			if (loc.x < minX) minX = loc.x;
			if (loc.x > maxX) maxX = loc.x;
			if (loc.y < minY) minY = loc.y;
			if (loc.y > maxY) maxY = loc.y;
		}
		// Drop duplicate closing vertex if identical to first vertex so edge iteration is uniform.
		if (
			pts.length >= 4 &&
			Math.abs(pts[0].x - pts[pts.length - 1].x) < 1e-6 &&
			Math.abs(pts[0].y - pts[pts.length - 1].y) < 1e-6
		) {
			pts.pop();
		}
		if (pts.length >= 3) {
			out.push({ pts, minX, maxX, minY, maxY });
		}
	}
	return out;
}

function buildLocalCorridors(
	corridors: readonly PreferredCorridor[] | undefined,
	toLocal: (lat: number, lon: number) => { x: number; y: number },
): LocalCorridor[] {
	if (!corridors || corridors.length === 0) return [];
	const out: LocalCorridor[] = [];
	for (const cor of corridors) {
		if (!cor?.coords || cor.coords.length < 2) continue;
		const pts: { x: number; y: number }[] = [];
		for (const v of cor.coords) {
			if (!Array.isArray(v) || v.length < 2) continue;
			const lon = v[0];
			const lat = v[1];
			if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
			pts.push(toLocal(lat, lon));
		}
		if (pts.length >= 2) {
			out.push({ pts });
		}
	}
	return out;
}

function pointInPolyXY(px: number, py: number, poly: LocalPoly): boolean {
	if (px < poly.minX || px > poly.maxX || py < poly.minY || py > poly.maxY) {
		return false;
	}
	const pts = poly.pts;
	const n = pts.length;
	let inside = false;
	for (let i = 0, j = n - 1; i < n; j = i++) {
		const xi = pts[i].x;
		const yi = pts[i].y;
		const xj = pts[j].x;
		const yj = pts[j].y;
		if (yi > py !== yj > py) {
			const intersectX = ((xj - xi) * (py - yi)) / (yj - yi) + xi;
			if (px < intersectX) {
				inside = !inside;
			}
		}
	}
	return inside;
}

function distSqPointToSegmentXY(
	px: number,
	py: number,
	ax: number,
	ay: number,
	bx: number,
	by: number,
): number {
	const dx = bx - ax;
	const dy = by - ay;
	const lenSq = dx * dx + dy * dy;
	if (lenSq <= 1e-9) {
		return (px - ax) * (px - ax) + (py - ay) * (py - ay);
	}
	const t = Math.min(1, Math.max(0, ((px - ax) * dx + (py - ay) * dy) / lenSq));
	const projX = ax + t * dx;
	const projY = ay + t * dy;
	return (px - projX) * (px - projX) + (py - projY) * (py - projY);
}

function isPointBlockedXY(
	px: number,
	py: number,
	polys: readonly LocalPoly[],
	bufferM: number,
): boolean {
	if (polys.length === 0) return false;
	const bufSq = bufferM * bufferM;
	for (const poly of polys) {
		if (
			px < poly.minX - bufferM ||
			px > poly.maxX + bufferM ||
			py < poly.minY - bufferM ||
			py > poly.maxY + bufferM
		) {
			continue;
		}
		if (pointInPolyXY(px, py, poly)) {
			return true;
		}
		if (bufferM > 0) {
			const pts = poly.pts;
			const n = pts.length;
			for (let i = 0; i < n; i++) {
				const a = pts[i];
				const b = pts[(i + 1) % n];
				if (distSqPointToSegmentXY(px, py, a.x, a.y, b.x, b.y) < bufSq) {
					return true;
				}
			}
		}
	}
	return false;
}

function cross2D(ox: number, oy: number, ax: number, ay: number, bx: number, by: number): number {
	return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox);
}

function onSegment2D(
	px: number,
	py: number,
	qx: number,
	qy: number,
	rx: number,
	ry: number,
): boolean {
	return (
		qx <= Math.max(px, rx) + 1e-6 &&
		qx >= Math.min(px, rx) - 1e-6 &&
		qy <= Math.max(py, ry) + 1e-6 &&
		qy >= Math.min(py, ry) - 1e-6
	);
}

function segmentsIntersectXY(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number,
	dx: number,
	dy: number,
): boolean {
	const d1 = cross2D(cx, cy, dx, dy, ax, ay);
	const d2 = cross2D(cx, cy, dx, dy, bx, by);
	const d3 = cross2D(ax, ay, bx, by, cx, cy);
	const d4 = cross2D(ax, ay, bx, by, dx, dy);

	if (((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))) {
		return true;
	}
	if (Math.abs(d1) <= 1e-9 && onSegment2D(cx, cy, ax, ay, dx, dy)) return true;
	if (Math.abs(d2) <= 1e-9 && onSegment2D(cx, cy, bx, by, dx, dy)) return true;
	if (Math.abs(d3) <= 1e-9 && onSegment2D(ax, ay, cx, cy, bx, by)) return true;
	if (Math.abs(d4) <= 1e-9 && onSegment2D(ax, ay, dx, dy, bx, by)) return true;
	return false;
}

function segmentHitsObstaclesXY(
	ax: number,
	ay: number,
	bx: number,
	by: number,
	polys: readonly LocalPoly[],
	bufferM: number,
): boolean {
	if (polys.length === 0) return false;
	const segMinX = Math.min(ax, bx) - bufferM;
	const segMaxX = Math.max(ax, bx) + bufferM;
	const segMinY = Math.min(ay, by) - bufferM;
	const segMaxY = Math.max(ay, by) + bufferM;

	for (const poly of polys) {
		if (
			segMaxX < poly.minX ||
			segMinX > poly.maxX ||
			segMaxY < poly.minY ||
			segMinY > poly.maxY
		) {
			continue;
		}
		if (
			pointInPolyXY(ax, ay, poly) ||
			pointInPolyXY(bx, by, poly) ||
			pointInPolyXY((ax + bx) * 0.5, (ay + by) * 0.5, poly)
		) {
			return true;
		}
		const pts = poly.pts;
		const n = pts.length;
		for (let i = 0; i < n; i++) {
			const p0 = pts[i];
			const p1 = pts[(i + 1) % n];
			if (segmentsIntersectXY(ax, ay, bx, by, p0.x, p0.y, p1.x, p1.y)) {
				return true;
			}
		}
	}

	if (bufferM > 0) {
		const segLen = Math.hypot(bx - ax, by - ay);
		const steps = Math.max(1, Math.ceil(segLen / 4));
		for (let k = 0; k <= steps; k++) {
			const t = k / steps;
			const sx = ax + t * (bx - ax);
			const sy = ay + t * (by - ay);
			if (isPointBlockedXY(sx, sy, polys, bufferM)) {
				return true;
			}
		}
	}

	return false;
}

function rasterizePreferredCorridors(
	corridors: readonly LocalCorridor[],
	cols: number,
	rows: number,
	minX: number,
	minY: number,
	cellSize: number,
): Uint8Array {
	const mask = new Uint8Array(cols * rows);
	if (corridors.length === 0) return mask;
	const radius = Math.max(10, 0.85 * cellSize);
	const radSq = radius * radius;

	for (const cor of corridors) {
		for (let i = 0; i < cor.pts.length - 1; i++) {
			const a = cor.pts[i];
			const b = cor.pts[i + 1];
			const gx0 = Math.max(0, Math.floor((Math.min(a.x, b.x) - radius - minX) / cellSize));
			const gx1 = Math.min(cols - 1, Math.ceil((Math.max(a.x, b.x) + radius - minX) / cellSize));
			const gy0 = Math.max(0, Math.floor((Math.min(a.y, b.y) - radius - minY) / cellSize));
			const gy1 = Math.min(rows - 1, Math.ceil((Math.max(a.y, b.y) + radius - minY) / cellSize));

			for (let gy = gy0; gy <= gy1; gy++) {
				const wy = minY + gy * cellSize;
				for (let gx = gx0; gx <= gx1; gx++) {
					const wx = minX + gx * cellSize;
					if (distSqPointToSegmentXY(wx, wy, a.x, a.y, b.x, b.y) <= radSq) {
						mask[gy * cols + gx] = 1;
					}
				}
			}
		}
	}
	return mask;
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

export function createElevationSampler(
	sampler: (lat: number, lon: number) => number | null,
	trailPoints: readonly NavTrackPoint[],
	userLat: number,
	userLon: number,
	userEle?: number | null,
): (lat: number, lon: number) => number {
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
		const base = 2.0 * d + 0.5 * Math.max(0, dEle);
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

function subdivideCornersForChaikin(
	pts: { lat: number; lon: number }[],
	maxCornerArmM = 28,
): { lat: number; lon: number }[] {
	if (pts.length <= 2) return pts;
	const out: { lat: number; lon: number }[] = [pts[0]];
	for (let i = 0; i < pts.length - 1; i++) {
		const a = pts[i];
		const b = pts[i + 1];
		const segLen = haversineMeters(a.lat, a.lon, b.lat, b.lon);
		const aIsInterior = i > 0;
		const bIsInterior = i + 1 < pts.length - 1;

		if (segLen > maxCornerArmM * 2.2 && (aIsInterior || bIsInterior)) {
			if (aIsInterior) {
				const t1 = maxCornerArmM / segLen;
				out.push({
					lat: a.lat + t1 * (b.lat - a.lat),
					lon: a.lon + t1 * (b.lon - a.lon),
				});
			}
			if (bIsInterior) {
				const t2 = 1 - maxCornerArmM / segLen;
				if (!aIsInterior || t2 > maxCornerArmM / segLen + 0.05) {
					out.push({
						lat: a.lat + t2 * (b.lat - a.lat),
						lon: a.lon + t2 * (b.lon - a.lon),
					});
				}
			}
		} else if (segLen > maxCornerArmM * 1.4 && (aIsInterior || bIsInterior)) {
			out.push({
				lat: 0.5 * (a.lat + b.lat),
				lon: 0.5 * (a.lon + b.lon),
			});
		}
		out.push(b);
	}
	return out;
}

function smoothOffTrailPath(
	rawCoords: { lat: number; lon: number }[],
	mode: OffTrailMode,
	evalEle: (lat: number, lon: number) => number,
	preserveSafeThreshold: number,
	segmentHitsBlocked?: (
		aLat: number,
		aLon: number,
		bLat: number,
		bLon: number,
		bufferM: number,
	) => boolean,
	hasPreferredPaths = false,
): { lat: number; lon: number }[] {
	if (rawCoords.length <= 2) return rawCoords;

	// Find first vertex outside obstacle so string-pulling never pulls a start-inside exit back through walls.
	let safePullStart = 0;
	if (segmentHitsBlocked) {
		while (
			safePullStart < rawCoords.length - 1 &&
			segmentHitsBlocked(
				rawCoords[safePullStart].lat,
				rawCoords[safePullStart].lon,
				rawCoords[safePullStart].lat,
				rawCoords[safePullStart].lon,
				0.5,
			)
		) {
			safePullStart++;
		}
	}

	const pruned: { lat: number; lon: number }[] = [];
	for (let i = 0; i <= safePullStart && i < rawCoords.length; i++) {
		pruned.push(rawCoords[i]);
	}
	let anchorIdx = Math.min(safePullStart, rawCoords.length - 1);

	const maxLookStep = hasPreferredPaths ? 4 : 12;

	while (anchorIdx < rawCoords.length - 1) {
		let bestNext = anchorIdx + 1;
		const maxLook = Math.min(rawCoords.length - 1, anchorIdx + maxLookStep);
		for (let j = maxLook; j > anchorIdx + 1; j--) {
			const a = rawCoords[anchorIdx];
			const b = rawCoords[j];
			if (segmentHitsBlocked?.(a.lat, a.lon, b.lat, b.lon, 6)) {
				continue;
			}
			const chordCheck = segmentMaxSlopeRatio(a.lat, a.lon, b.lat, b.lon, evalEle, 12);
			if (chordCheck.maxAbsSlope > preserveSafeThreshold) continue;

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

	// Subdivide long arms next to corners so Chaikin 0.75/0.25 produces tight, obstacle-safe organic curves.
	let pts = subdivideCornersForChaikin(pruned, 28);

	// 2 passes of Chaikin corner-cutting (Q = 0.75 A + 0.25 B, R = 0.25 A + 0.75 B) validated against obstacles & slope.
	for (let pass = 0; pass < 2; pass++) {
		if (pts.length <= 2) break;
		const nextPts: { lat: number; lon: number }[] = [pts[0]];

		for (let i = 1; i < pts.length - 1; i++) {
			if (i <= safePullStart && pass === 0) {
				nextPts.push(pts[i]);
				continue;
			}
			const prev = pts[i - 1];
			const curr = pts[i];
			const next = pts[i + 1];

			// R on segment (prev -> curr): 0.25 * prev + 0.75 * curr
			const rPrev = {
				lat: 0.25 * prev.lat + 0.75 * curr.lat,
				lon: 0.25 * prev.lon + 0.75 * curr.lon,
			};
			// Q on segment (curr -> next): 0.75 * curr + 0.25 * next
			const qNext = {
				lat: 0.75 * curr.lat + 0.25 * next.lat,
				lon: 0.75 * curr.lon + 0.25 * next.lon,
			};

			const anchor = nextPts[nextPts.length - 1];
			const blockedAnchorR =
				segmentHitsBlocked?.(anchor.lat, anchor.lon, rPrev.lat, rPrev.lon, 1.5) ?? false;
			const blockedRQ =
				segmentHitsBlocked?.(rPrev.lat, rPrev.lon, qNext.lat, qNext.lon, 1.5) ?? false;
			const blockedTail =
				i === pts.length - 2
					? (segmentHitsBlocked?.(
							qNext.lat,
							qNext.lon,
							pts[pts.length - 1].lat,
							pts[pts.length - 1].lon,
							1.5,
						) ?? false)
					: false;

			if (!blockedAnchorR && !blockedRQ && !blockedTail) {
				const s1 = segmentMaxSlopeRatio(anchor.lat, anchor.lon, rPrev.lat, rPrev.lon, evalEle, 12);
				const s2 = segmentMaxSlopeRatio(rPrev.lat, rPrev.lon, qNext.lat, qNext.lon, evalEle, 12);
				const s3 =
					i === pts.length - 2
						? segmentMaxSlopeRatio(
								qNext.lat,
								qNext.lon,
								pts[pts.length - 1].lat,
								pts[pts.length - 1].lon,
								evalEle,
								12,
							)
						: { maxAbsSlope: 0 };

				if (
					s1.maxAbsSlope <= preserveSafeThreshold &&
					s2.maxAbsSlope <= preserveSafeThreshold &&
					s3.maxAbsSlope <= preserveSafeThreshold
				) {
					nextPts.push(rPrev, qNext);
					continue;
				}
			}

			nextPts.push(curr);
		}

		nextPts.push(pts[pts.length - 1]);
		pts = nextPts;
	}

	return pts;
}

/**
 * Multi-Target 16-neighbor A* off-trail router with building/water obstacle avoidance,
 * preferred footpath weighting, strictly forward rejoin selection, Chaikin curved geometry,
 * and >3 km Calm Preview Mode (`null`).
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
	obstacles?: ObstaclePolygon[];
	preferredPaths?: PreferredCorridor[];
}): OffTrailRerouteResult | null {
	const trailPoints = params.trailPoints;
	if (trailPoints.length === 0) {
		return null;
	}

	// 1. Find global nearest point on trail and enforce >3 km Calm Preview Mode in O(1).
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

	if (nearestCross > FAR_PREVIEW_THRESHOLD_METERS) {
		return null;
	}

	const mode: OffTrailMode = params.mode ?? "min-climb";
	const isRo = (params.locale ?? "en").trim().toLowerCase().startsWith("ro");
	const evalEle = createElevationSampler(
		params.sampler,
		trailPoints,
		params.userLat,
		params.userLon,
		params.userEle,
	);

	const totalTrailDist = trailPoints[trailPoints.length - 1].distanceM;
	const cumTrailSec = precomputeCumTrailSeconds(trailPoints);
	const totalTrailSec = cumTrailSec[cumTrailSec.length - 1];

	// 2. Sample strictly forward rejoin candidates in [max(0, lastAlongTrackM - 10), min(total, max(nearest, last) + max(600, 3 * cross))].
	const minCand = Math.max(0, params.lastAlongTrackM - 10);
	const maxCand = Math.min(
		totalTrailDist,
		Math.max(nearestAlong, params.lastAlongTrackM) + Math.max(600, 3.0 * nearestCross),
	);
	const candAlongSet: number[] = [];
	const clampedNearest = Math.min(maxCand, Math.max(minCand, nearestAlong));
	candAlongSet.push(clampedNearest);
	const forwardAnchor = Math.min(maxCand, Math.max(minCand, params.lastAlongTrackM));
	if (Math.abs(forwardAnchor - clampedNearest) > 5) {
		candAlongSet.push(forwardAnchor);
	}
	const span = Math.max(0, maxCand - minCand);
	const targetSamples = Math.min(40, Math.max(1, Math.ceil(span / 35) + 1));
	for (let k = 0; k < targetSamples; k++) {
		const d = targetSamples === 1 ? minCand : minCand + (span * k) / (targetSamples - 1);
		if (candAlongSet.every((existing) => Math.abs(existing - d) > 10)) {
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

	const localPolys = buildLocalPolygons(params.obstacles, toLocal);
	const localCorridors = buildLocalCorridors(params.preferredPaths, toLocal);

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
			mode === "min-climb" ? 1.0 * remTrailSec : 0.92 * remTrailDist;
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

	const maxAllowedSpan = (MAX_GRID_DIM - 1) * MAX_CELL_SIZE_M; // 6265m
	const nearestLocal = toLocal(nearestLat, nearestLon);
	const baseDist = Math.hypot(nearestLocal.x, nearestLocal.y);
	const detourPad = Math.min(500, Math.max(300, 0.5 * baseDist));

	let minX = 0;
	let maxX = 0;
	let minY = 0;
	let maxY = 0;
	const filteredTargets: Omit<RejoinCandidate, "gx" | "gy">[] = [];

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

	// Ensure grid bounds leave room around any overlapping obstacle polygons.
	for (const poly of localPolys) {
		if (poly.maxX >= minX && poly.minX <= maxX && poly.maxY >= minY && poly.minY <= maxY) {
			if (poly.maxX + 60 - Math.min(minX, poly.minX - 60) <= maxAllowedSpan) {
				minX = Math.min(minX, poly.minX - 60);
				maxX = Math.max(maxX, poly.maxX + 60);
			}
			if (poly.maxY + 60 - Math.min(minY, poly.minY - 60) <= maxAllowedSpan) {
				minY = Math.min(minY, poly.minY - 60);
				maxY = Math.max(maxY, poly.maxY + 60);
			}
		}
	}

	const spanX = Math.max(150, maxX - minX);
	const spanY = Math.max(150, maxY - minY);
	const maxSpan = Math.max(spanX, spanY);

	const minCell = localPolys.length > 0 ? MIN_OBSTACLE_CELL_SIZE_M : MIN_CELL_SIZE_M;
	let cellSize = Math.min(
		MAX_CELL_SIZE_M,
		Math.max(minCell, maxSpan / (localPolys.length > 0 ? 140 : 120)),
	);
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

	// Rasterize obstacles (+8m edge buffer) into blockedMask and preferred footpaths into preferredMask.
	const blockedMask = new Uint8Array(totalCells);
	if (localPolys.length > 0) {
		for (let gy = 0; gy < rows; gy++) {
			const wy = minY + gy * cellSize;
			for (let gx = 0; gx < cols; gx++) {
				const idx = gy * cols + gx;
				if (targetMap.has(idx)) continue;
				const wx = minX + gx * cellSize;
				if (isPointBlockedXY(wx, wy, localPolys, OBSTACLE_EDGE_BUFFER_M)) {
					blockedMask[idx] = 1;
				}
			}
		}
	}

	const preferredMask = rasterizePreferredCorridors(
		localCorridors,
		cols,
		rows,
		minX,
		minY,
		cellSize,
	);
	const hasPreferredPaths = localCorridors.length > 0;

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

	const baseMinRate = mode === "min-climb" ? 1 / ((0.6 * 7.5) / 3.6) : 2.0;
	const minRate = hasPreferredPaths ? baseMinRate * PREFERRED_PATH_COST_MULT : baseMinRate;
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
		const fromBlocked = blockedMask[idx] === 1;
		const wFrom = localPolys.length > 0 ? gridToWorld(gx, gy) : null;

		for (const mv of MOVES_16) {
			const nx = gx + mv.dx;
			const ny = gy + mv.dy;
			if (nx < 0 || nx >= cols || ny < 0 || ny >= rows) continue;
			const nIdx = ny * cols + nx;
			if (closed[nIdx]) continue;

			const toBlocked = blockedMask[nIdx] === 1;
			// Allow outward exit if startIdx fell inside an obstacle, but never enter blocked cells from outside.
			if (!fromBlocked && toBlocked) continue;

			if (!fromBlocked && wFrom !== null) {
				const wTo = gridToWorld(nx, ny);
				if (segmentHitsObstaclesXY(wFrom.x, wFrom.y, wTo.x, wTo.y, localPolys, 4)) {
					continue;
				}
			}

			const d = mv.steps * cellSize;
			const eleTo = getCellEle(nx, ny);
			let eleMid: number | null = null;
			if (mv.isKnight || (Math.abs(mv.dx) === 1 && Math.abs(mv.dy) === 1)) {
				const midWorld = gridToWorld(gx + mv.dx * 0.5, gy + mv.dy * 0.5);
				const midLL = toLatLon(midWorld.x, midWorld.y);
				eleMid = evalEle(midLL.lat, midLL.lon);
			}

			let stepCost = evaluateEdgeCost(mode, d, eleFrom, eleTo, eleMid);
			if (preferredMask[nIdx] === 1 || preferredMask[idx] === 1) {
				stepCost *= PREFERRED_PATH_COST_MULT;
			}
			if (fromBlocked && toBlocked) {
				stepCost *= 25;
			}

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

	const segmentHitsBlockedFn =
		localPolys.length > 0
			? (aLat: number, aLon: number, bLat: number, bLon: number, bufferM: number): boolean => {
					const la = toLocal(aLat, aLon);
					const lb = toLocal(bLat, bLon);
					return segmentHitsObstaclesXY(la.x, la.y, lb.x, lb.y, localPolys, bufferM);
				}
			: undefined;

	const smoothedCoords = smoothOffTrailPath(
		rawCoords,
		mode,
		evalEle,
		safeSmoothThreshold,
		segmentHitsBlockedFn,
		hasPreferredPaths,
	);

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

	const directCheck = segmentMaxSlopeRatio(
		params.userLat,
		params.userLon,
		winningTarget.lat,
		winningTarget.lon,
		evalEle,
		12,
	);
	const nearestDirectCheck = segmentMaxSlopeRatio(
		params.userLat,
		params.userLon,
		nearestLat,
		nearestLon,
		evalEle,
		12,
	);
	const avoidedSteepHazard =
		(directCheck.maxAbsSlope > CLIFF_SLOPE_THRESHOLD ||
			nearestDirectCheck.maxAbsSlope > CLIFF_SLOPE_THRESHOLD) &&
		maxAbsSlope <= CLIFF_SLOPE_THRESHOLD;

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

/**
 * Computes a short obstacle-aware and DEM-contouring curved connector between two coordinates,
 * used by the hybrid Valhalla router when start or end off-road gaps exceed 25m.
 */
export function computeLocalCurvedConnector(params: {
	fromLat: number;
	fromLon: number;
	toLat: number;
	toLon: number;
	evalEle: (lat: number, lon: number) => number;
	mode: OffTrailMode;
	obstacles?: ObstaclePolygon[];
	preferredPaths?: PreferredCorridor[];
}): { lat: number; lon: number }[] {
	const directDist = haversineMeters(params.fromLat, params.fromLon, params.toLat, params.toLon);
	if (!Number.isFinite(directDist) || directDist <= 2) {
		return [
			{ lat: params.fromLat, lon: params.fromLon },
			...(directDist > 0.1 ? [{ lat: params.toLat, lon: params.toLon }] : []),
		];
	}

	const syntheticTargetTrack: NavTrackPoint[] = [
		{
			lat: params.toLat,
			lon: params.toLon,
			ele: params.evalEle(params.toLat, params.toLon),
			distanceM: 0,
			gradePct: 0,
		},
	];

	const res = computeOffTrailReroute({
		userLat: params.fromLat,
		userLon: params.fromLon,
		userEle: params.evalEle(params.fromLat, params.fromLon),
		trailPoints: syntheticTargetTrack,
		lastAlongTrackM: 0,
		sampler: (lat, lon) => params.evalEle(lat, lon),
		mode: params.mode,
		obstacles: params.obstacles,
		preferredPaths: params.preferredPaths,
	});

	if (!res || res.points.length === 0) {
		return [
			{ lat: params.fromLat, lon: params.fromLon },
			{ lat: params.toLat, lon: params.toLon },
		];
	}
	return res.points.map((p) => ({ lat: p.lat, lon: p.lon }));
}

export interface DirectRescueRouteResult {
	mode: OffTrailMode;
	points: OffTrailPoint[];
	targetLat: number;
	targetLon: number;
	targetEleM: number;
	distanceM: number;
	estimatedSeconds: number;
	ascentM: number;
	descentM: number;
	maxSlopeDeg: number;
	avoidedSteepHazard: boolean;
	initialBearingDeg: number;
	instruction: string;
	slopeAdvice: string;
}

/**
 * Single-Target 16-neighbor Tobler DEM A* router that computes an optimal
 * terrain-aware rescue route from a responder's position directly to an SOS
 * requester's coordinates, avoiding cliffs (>36.9°) and minimizing hazardous climbs.
 */
export function computeDirectRescueRoute(params: {
	fromLat: number;
	fromLon: number;
	fromEle?: number | null;
	targetLat: number;
	targetLon: number;
	targetEle?: number | null;
	trailPoints?: NavTrackPoint[];
	sampler: (lat: number, lon: number) => number | null;
	mode?: OffTrailMode;
	locale?: string;
}): DirectRescueRouteResult {
	const mode: OffTrailMode = params.mode ?? "min-climb";
	const isRo = (params.locale ?? "ro").trim().toLowerCase().startsWith("ro");

	const anchorPoints: NavTrackPoint[] = [...(params.trailPoints ?? [])];
	if (
		params.targetEle !== undefined &&
		params.targetEle !== null &&
		Number.isFinite(params.targetEle)
	) {
		anchorPoints.push({
			lat: params.targetLat,
			lon: params.targetLon,
			ele: params.targetEle,
			distanceM: 0,
			gradePct: 0,
		});
	}

	const evalEle = createElevationSampler(
		params.sampler,
		anchorPoints,
		params.fromLat,
		params.fromLon,
		params.fromEle,
	);

	const directDist = haversineMeters(
		params.fromLat,
		params.fromLon,
		params.targetLat,
		params.targetLon,
	);

	if (!Number.isFinite(directDist) || directDist < 2) {
		const startEle =
			params.fromEle !== undefined && params.fromEle !== null && Number.isFinite(params.fromEle)
				? params.fromEle
				: evalEle(params.fromLat, params.fromLon);
		const endEle =
			params.targetEle !== undefined &&
			params.targetEle !== null &&
			Number.isFinite(params.targetEle)
				? params.targetEle
				: evalEle(params.targetLat, params.targetLon);
		return {
			mode,
			points: [
				{
					lat: params.fromLat,
					lon: params.fromLon,
					ele: startEle,
					distanceM: 0,
					gradePct: 0,
				},
				...(directDist > 0.05
					? [
							{
								lat: params.targetLat,
								lon: params.targetLon,
								ele: endEle,
								distanceM: directDist,
								gradePct: 0,
							},
						]
					: []),
			],
			targetLat: params.targetLat,
			targetLon: params.targetLon,
			targetEleM: endEle,
			distanceM: Number.isFinite(directDist) ? Math.max(0, directDist) : 0,
			estimatedSeconds: 0,
			ascentM: 0,
			descentM: 0,
			maxSlopeDeg: 0,
			avoidedSteepHazard: false,
			initialBearingDeg: 0,
			instruction: isRo ? "Ai ajuns la persoana în dificultate" : "Arrived at SOS location",
			slopeAdvice: isRo ? "La destinație" : "At target",
		};
	}

	const cosLat = Math.max(0.1, Math.cos(params.fromLat * DEG_TO_RAD));
	const metersPerDegLon = METERS_PER_DEG_LAT * cosLat;
	const toLocal = (lat: number, lon: number) => ({
		x: (lon - params.fromLon) * metersPerDegLon,
		y: (lat - params.fromLat) * METERS_PER_DEG_LAT,
	});
	const toLatLon = (x: number, y: number) => ({
		lat: params.fromLat + y / METERS_PER_DEG_LAT,
		lon: params.fromLon + x / metersPerDegLon,
	});

	const targetLocal = toLocal(params.targetLat, params.targetLon);
	const baseDist = Math.hypot(targetLocal.x, targetLocal.y);
	const detourPad = Math.min(600, Math.max(250, 0.4 * baseDist));

	const minX = Math.min(0, targetLocal.x) - detourPad;
	const maxX = Math.max(0, targetLocal.x) + detourPad;
	const minY = Math.min(0, targetLocal.y) - detourPad;
	const maxY = Math.max(0, targetLocal.y) + detourPad;

	const spanX = Math.max(150, maxX - minX);
	const spanY = Math.max(150, maxY - minY);
	const maxSpan = Math.max(spanX, spanY);

	let cellSize = Math.min(MAX_CELL_SIZE_M, Math.max(MIN_CELL_SIZE_M, maxSpan / 120));
	const requiredCellForDim = maxSpan / (MAX_GRID_DIM - 2);
	if (requiredCellForDim > cellSize) {
		cellSize = requiredCellForDim;
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
	const goalCell = worldToGrid(targetLocal.x, targetLocal.y);
	const totalCells = cols * rows;
	const startIdx = startCell.gy * cols + startCell.gx;
	const goalIdx = goalCell.gy * cols + goalCell.gx;

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

	const minRate = mode === "min-climb" ? 1 / ((0.6 * 7.5) / 3.6) : 2.0;
	const heuristic = (gx: number, gy: number): number =>
		minRate * Math.hypot(goalCell.gx - gx, goalCell.gy - gy) * cellSize;

	const gScore = new Float64Array(totalCells);
	gScore.fill(Infinity);
	const parent = new Int32Array(totalCells);
	parent.fill(-1);
	const closed = new Uint8Array(totalCells);

	const pq = new MinHeap();
	gScore[startIdx] = 0;
	pq.push(startIdx, heuristic(startCell.gx, startCell.gy));

	while (pq.size > 0) {
		const cur = pq.pop()!;
		const idx = cur.idx;
		if (closed[idx]) continue;
		closed[idx] = 1;

		if (idx === goalIdx) {
			break;
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

	const rawCoords: { lat: number; lon: number }[] = [];
	if (goalIdx === startIdx || parent[goalIdx] === -1) {
		rawCoords.push({ lat: params.fromLat, lon: params.fromLon });
		rawCoords.push({ lat: params.targetLat, lon: params.targetLon });
	} else {
		const indices: number[] = [];
		let cur = goalIdx;
		while (cur !== -1) {
			indices.push(cur);
			if (cur === startIdx) break;
			cur = parent[cur];
		}
		indices.reverse();

		for (let i = 0; i < indices.length; i++) {
			if (i === 0) {
				rawCoords.push({ lat: params.fromLat, lon: params.fromLon });
			} else if (i === indices.length - 1) {
				rawCoords.push({ lat: params.targetLat, lon: params.targetLon });
			} else {
				const cellIdx = indices[i];
				const gx = cellIdx % cols;
				const gy = (cellIdx - gx) / cols;
				const w = gridToWorld(gx, gy);
				rawCoords.push(toLatLon(w.x, w.y));
			}
		}
	}

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

	const eles = smoothedCoords.map((c, idx) => {
		if (
			idx === 0 &&
			params.fromEle !== undefined &&
			params.fromEle !== null &&
			Number.isFinite(params.fromEle)
		) {
			return params.fromEle;
		}
		if (
			idx === smoothedCoords.length - 1 &&
			params.targetEle !== undefined &&
			params.targetEle !== null &&
			Number.isFinite(params.targetEle)
		) {
			return params.targetEle;
		}
		return evalEle(c.lat, c.lon);
	});

	const outPoints: OffTrailPoint[] = [];
	let cumDist = 0;
	let ascentM = 0;
	let descentM = 0;
	let estimatedSeconds = 0;
	let maxAbsSlope = 0;

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
	const directCheck = segmentMaxSlopeRatio(
		params.fromLat,
		params.fromLon,
		params.targetLat,
		params.targetLon,
		evalEle,
		12,
	);
	const avoidedSteepHazard =
		directCheck.maxAbsSlope > CLIFF_SLOPE_THRESHOLD &&
		maxAbsSlope <= CLIFF_SLOPE_THRESHOLD;

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
		initialBearingDeg = bearingDegrees(params.fromLat, params.fromLon, lookLat, lookLon);
	}

	const dir = cardinalDirection(initialBearingDeg, isRo ? "ro" : "en");
	const distRounded = Math.round(cumDist);
	const climbRounded = Math.round(ascentM);
	const slopeRounded = Math.round(maxSlopeDeg);

	const instruction = isRo
		? avoidedSteepHazard
			? `Ocolește panta abruptă spre ${dir} (${distRounded} m până la SOS)`
			: `Mergi spre ${dir} (${distRounded} m până la SOS)`
		: avoidedSteepHazard
			? `Contour around steep slope heading ${dir} (${distRounded} m to SOS)`
			: `Head ${dir} (${distRounded} m to SOS)`;

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
		targetLat: params.targetLat,
		targetLon: params.targetLon,
		targetEleM: eles[eles.length - 1],
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
