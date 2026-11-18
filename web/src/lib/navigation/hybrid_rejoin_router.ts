import { decodePolyline } from "#lib/util/polyline_util.ts";
import { toblerHikingSpeedKmh } from "./eta_calculator";
import {
	bearingDegrees,
	cardinalDirection,
	haversineMeters,
	projectOntoSegment,
} from "./geo_math";
import {
	computeLocalCurvedConnector,
	computeOffTrailReroute,
	createElevationSampler,
} from "./off_trail_router";
import {
	FAR_PREVIEW_THRESHOLD_METERS,
	type NavTrackPoint,
	type ObstaclePolygon,
	type OffTrailMode,
	type OffTrailPoint,
	type OffTrailRerouteResult,
	type PreferredCorridor,
} from "./types";

const RAD_TO_DEG = 180 / Math.PI;
const CONNECTOR_GAP_THRESHOLD_M = 25;
const PREFERRED_TRANSPORT_CLASSES = new Set([
	"path",
	"footway",
	"track",
	"steps",
	"pedestrian",
	"bridleway",
	"cycleway",
]);

export interface MapLibreFeatureQueryable {
	querySourceFeatures(
		sourceId: string,
		parameters?: { sourceLayer?: string },
	): Array<{
		geometry?: { type?: string; coordinates?: unknown } | null;
		properties?: Record<string, unknown> | null;
	}>;
}

export interface HybridOffTrailRerouteParams {
	userLat: number;
	userLon: number;
	userEle?: number | null;
	trailPoints: NavTrackPoint[];
	lastAlongTrackM: number;
	sampler: (lat: number, lon: number) => number | null;
	mode?: OffTrailMode;
	locale?: string;
	isCycling?: boolean;
	obstacles?: ObstaclePolygon[];
	preferredPaths?: PreferredCorridor[];
	map?: MapLibreFeatureQueryable | null;
	fetchImpl?: typeof fetch;
	timeoutMs?: number;
	precomputedLocal?: OffTrailRerouteResult | null;
	connectorSolver?: (params: {
		fromLat: number;
		fromLon: number;
		toLat: number;
		toLon: number;
	}) => Promise<Array<{ lat: number; lon: number }>>;
}

function toCoordPair(raw: unknown): [number, number] | null {
	if (!Array.isArray(raw) || raw.length < 2) return null;
	const lon = Number(raw[0]);
	const lat = Number(raw[1]);
	if (!Number.isFinite(lon) || !Number.isFinite(lat)) return null;
	return [lon, lat];
}

function coordsIntersectBbox(
	coords: readonly [number, number][],
	minLon: number,
	minLat: number,
	maxLon: number,
	maxLat: number,
): boolean {
	let cMinLon = Infinity;
	let cMaxLon = -Infinity;
	let cMinLat = Infinity;
	let cMaxLat = -Infinity;
	for (const [lon, lat] of coords) {
		if (lon < cMinLon) cMinLon = lon;
		if (lon > cMaxLon) cMaxLon = lon;
		if (lat < cMinLat) cMinLat = lat;
		if (lat > cMaxLat) cMaxLat = lat;
	}
	return cMaxLon >= minLon && cMinLon <= maxLon && cMaxLat >= minLat && cMinLat <= maxLat;
}

function extractOuterRing(rawRing: unknown): [number, number][] | null {
	if (!Array.isArray(rawRing) || rawRing.length < 3) return null;
	const out: [number, number][] = [];
	for (const pt of rawRing) {
		const pair = toCoordPair(pt);
		if (pair) out.push(pair);
	}
	return out.length >= 3 ? out : null;
}

/**
 * Safely extracts `building` and `water` obstacle polygons plus `path`/`footway`/`track`
 * preferred corridors from MapLibre's `"openmaptiles"` vector source within `bbox` (`[minLon, minLat, maxLon, maxLat]`).
 */
export function extractMapLibreObstacles(
	map: MapLibreFeatureQueryable | null | undefined,
	bbox: [number, number, number, number],
): { obstacles: ObstaclePolygon[]; preferredPaths: PreferredCorridor[] } {
	const obstacles: ObstaclePolygon[] = [];
	const preferredPaths: PreferredCorridor[] = [];
	if (!map || typeof map.querySourceFeatures !== "function") {
		return { obstacles, preferredPaths };
	}

	const minLon = Math.min(bbox[0], bbox[2]);
	const maxLon = Math.max(bbox[0], bbox[2]);
	const minLat = Math.min(bbox[1], bbox[3]);
	const maxLat = Math.max(bbox[1], bbox[3]);

	const seenPolyKeys = new Set<string>();
	const pushRingIfInBbox = (ring: [number, number][] | null) => {
		if (!ring || !coordsIntersectBbox(ring, minLon, minLat, maxLon, maxLat)) return;
		const first = ring[0];
		const mid = ring[Math.floor(ring.length / 2)];
		const key = `${ring.length}:${first[0].toFixed(6)},${first[1].toFixed(6)}:${mid[0].toFixed(6)},${mid[1].toFixed(6)}`;
		if (seenPolyKeys.has(key)) return;
		seenPolyKeys.add(key);
		obstacles.push({ rings: ring });
	};

	for (const sourceLayer of ["building", "water"] as const) {
		try {
			const features = map.querySourceFeatures("openmaptiles", { sourceLayer }) ?? [];
			for (const feat of features) {
				const geom = feat?.geometry;
				if (!geom || !geom.coordinates) continue;
				if (geom.type === "Polygon" && Array.isArray(geom.coordinates)) {
					pushRingIfInBbox(extractOuterRing(geom.coordinates[0]));
				} else if (geom.type === "MultiPolygon" && Array.isArray(geom.coordinates)) {
					for (const poly of geom.coordinates) {
						if (Array.isArray(poly)) {
							pushRingIfInBbox(extractOuterRing(poly[0]));
						}
					}
				}
				if (obstacles.length >= 450) break;
			}
		} catch {
			// Source or layer may not exist on satellite/raster styles; ignore safely.
		}
	}

	const seenPathKeys = new Set<string>();
	const pushLineIfInBbox = (rawLine: unknown) => {
		const coords = extractOuterRingForLine(rawLine);
		if (!coords || !coordsIntersectBbox(coords, minLon, minLat, maxLon, maxLat)) return;
		const first = coords[0];
		const last = coords[coords.length - 1];
		const key = `${coords.length}:${first[0].toFixed(6)},${first[1].toFixed(6)}:${last[0].toFixed(6)},${last[1].toFixed(6)}`;
		if (seenPathKeys.has(key)) return;
		seenPathKeys.add(key);
		preferredPaths.push({ coords });
	};

	try {
		const transportFeatures =
			map.querySourceFeatures("openmaptiles", { sourceLayer: "transportation" }) ?? [];
		for (const feat of transportFeatures) {
			const props = feat?.properties ?? {};
			const cls = String(props.class ?? "").toLowerCase();
			const subcls = String(props.subclass ?? "").toLowerCase();
			const highway = String(props.highway ?? "").toLowerCase();
			if (
				!PREFERRED_TRANSPORT_CLASSES.has(cls) &&
				!PREFERRED_TRANSPORT_CLASSES.has(subcls) &&
				!PREFERRED_TRANSPORT_CLASSES.has(highway)
			) {
				continue;
			}
			const geom = feat?.geometry;
			if (!geom || !geom.coordinates) continue;
			if (geom.type === "LineString") {
				pushLineIfInBbox(geom.coordinates);
			} else if (geom.type === "MultiLineString" && Array.isArray(geom.coordinates)) {
				for (const line of geom.coordinates) {
					pushLineIfInBbox(line);
				}
			}
			if (preferredPaths.length >= 300) break;
		}
	} catch {
		// Ignore missing sourceLayer safely.
	}

	return { obstacles, preferredPaths };
}

function extractOuterRingForLine(rawLine: unknown): [number, number][] | null {
	if (!Array.isArray(rawLine) || rawLine.length < 2) return null;
	const out: [number, number][] = [];
	for (const pt of rawLine) {
		const pair = toCoordPair(pt);
		if (pair) out.push(pair);
	}
	return out.length >= 2 ? out : null;
}

function findNearestTrailPoint(
	userLat: number,
	userLon: number,
	trailPoints: readonly NavTrackPoint[],
): { crossTrackM: number; lat: number; lon: number } {
	if (trailPoints.length === 1) {
		return {
			crossTrackM: haversineMeters(userLat, userLon, trailPoints[0].lat, trailPoints[0].lon),
			lat: trailPoints[0].lat,
			lon: trailPoints[0].lon,
		};
	}
	let bestCross = Infinity;
	let bestLat = trailPoints[0].lat;
	let bestLon = trailPoints[0].lon;
	for (let i = 0; i < trailPoints.length - 1; i++) {
		const a = trailPoints[i];
		const b = trailPoints[i + 1];
		const proj = projectOntoSegment(userLat, userLon, a.lat, a.lon, b.lat, b.lon);
		if (proj.crossTrackMeters < bestCross) {
			bestCross = proj.crossTrackMeters;
			bestLat = proj.projectedLat;
			bestLon = proj.projectedLon;
		}
	}
	return { crossTrackM: bestCross, lat: bestLat, lon: bestLon };
}

function dedupeConsecutiveCoords(coords: { lat: number; lon: number }[]): { lat: number; lon: number }[] {
	const out: { lat: number; lon: number }[] = [];
	for (const c of coords) {
		if (
			out.length === 0 ||
			haversineMeters(out[out.length - 1].lat, out[out.length - 1].lon, c.lat, c.lon) > 0.5
		) {
			out.push(c);
		}
	}
	return out;
}

/**
 * Hybrid Off-Trail Rejoin Orchestrator:
 * - Returns `null` when `> 3,000 m` from the trail (Calm Preview Mode).
 * - Computes optimal forward rejoin target and obstacle-aware Chaikin curved route locally first.
 * - Queries `POST /api/v1/valhalla/route` (`pedestrian` or `bicycle`, `ro-RO`, `use_hills`),
 *   stitches curved DEM/obstacle connectors if start/end gap `> 25 m`, enriches DEM elevations,
 *   and falls back seamlessly to the local curved A* route when offline or on error.
 */
export async function computeHybridOffTrailReroute(
	params: HybridOffTrailRerouteParams,
): Promise<OffTrailRerouteResult | null> {
	const { trailPoints, userLat, userLon } = params;
	if (trailPoints.length === 0) {
		return null;
	}

	const nearest = findNearestTrailPoint(userLat, userLon, trailPoints);
	if (nearest.crossTrackM > FAR_PREVIEW_THRESHOLD_METERS) {
		return null;
	}

	let obstacles = params.obstacles;
	let preferredPaths = params.preferredPaths;
	if (obstacles === undefined && params.map) {
		const padDeg = 0.008; // ~600-850m around user & nearest trail point
		const bbox: [number, number, number, number] = [
			Math.min(userLon, nearest.lon) - padDeg,
			Math.min(userLat, nearest.lat) - padDeg,
			Math.max(userLon, nearest.lon) + padDeg,
			Math.max(userLat, nearest.lat) + padDeg,
		];
		const extracted = extractMapLibreObstacles(params.map, bbox);
		obstacles = extracted.obstacles;
		if (preferredPaths === undefined) {
			preferredPaths = extracted.preferredPaths;
		}
	}

	const mode: OffTrailMode = params.mode ?? "min-climb";
	const isRo = (params.locale ?? "ro").trim().toLowerCase().startsWith("ro");
	const isCycling = params.isCycling ?? false;

	const localResult =
		params.precomputedLocal !== undefined
			? params.precomputedLocal
			: computeOffTrailReroute({
					userLat,
					userLon,
					userEle: params.userEle,
					trailPoints,
					lastAlongTrackM: params.lastAlongTrackM,
					sampler: params.sampler,
					mode,
					locale: params.locale ?? "ro",
					obstacles,
					preferredPaths,
				});

	if (localResult === null) {
		return null;
	}

	const fetchFn = params.fetchImpl ?? (typeof fetch === "function" ? fetch : undefined);
	if (!fetchFn) {
		return localResult;
	}

	const costing = isCycling ? "bicycle" : "pedestrian";
	const useHills = mode === "min-climb" ? 0.15 : 0.75;
	const requestBody = {
		locations: [
			{ lat: userLat, lon: userLon },
			{ lat: localResult.rejoinLat, lon: localResult.rejoinLon },
		],
		costing,
		language: "ro-RO",
		directions_options: {
			language: "ro-RO",
			units: "kilometers",
		},
		costing_options: isCycling
			? {
					bicycle: {
						use_hills: useHills,
						bicycle_type: "Mountain",
					},
				}
			: {
					pedestrian: {
						use_hills: useHills,
						walkway_factor: 0.85,
						max_hiking_difficulty: 3,
					},
				},
	};

	const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
	const timeoutId =
		controller !== null
			? setTimeout(() => controller.abort(), Math.max(500, params.timeoutMs ?? 4_500))
			: null;

	try {
		const res = await fetchFn("/api/v1/valhalla/route", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(requestBody),
			...(controller ? { signal: controller.signal } : {}),
		});
		if (!res.ok) {
			return localResult;
		}

		const data = (await res.json()) as {
			trip?: {
				summary?: { time?: number; length?: number };
				legs?: Array<{
					shape?: string;
					maneuvers?: Array<{ instruction?: string }>;
				}>;
			};
		};
		const legs = data?.trip?.legs;
		if (!Array.isArray(legs) || legs.length === 0 || typeof legs[0]?.shape !== "string") {
			return localResult;
		}

		const valhallaCoords: { lat: number; lon: number }[] = [];
		for (const leg of legs) {
			if (typeof leg?.shape !== "string" || leg.shape.length === 0) continue;
			const decoded = decodePolyline(leg.shape, 6);
			for (const [lon, lat] of decoded) {
				if (Number.isFinite(lat) && Number.isFinite(lon)) {
					valhallaCoords.push({ lat, lon });
				}
			}
		}

		if (valhallaCoords.length < 2) {
			return localResult;
		}

		const evalEle = createElevationSampler(
			params.sampler,
			trailPoints,
			userLat,
			userLon,
			params.userEle,
		);

		const stitched: { lat: number; lon: number }[] = [];
		let extraConnectorSeconds = 0;

		const firstVal = valhallaCoords[0];
		const startGapM = haversineMeters(userLat, userLon, firstVal.lat, firstVal.lon);
		if (startGapM > CONNECTOR_GAP_THRESHOLD_M) {
			const startConn = params.connectorSolver
				? await params.connectorSolver({
						fromLat: userLat,
						fromLon: userLon,
						toLat: firstVal.lat,
						toLon: firstVal.lon,
					})
				: computeLocalCurvedConnector({
						fromLat: userLat,
						fromLon: userLon,
						toLat: firstVal.lat,
						toLon: firstVal.lon,
						evalEle,
						mode,
						obstacles,
						preferredPaths,
					});
			for (let i = 0; i < startConn.length - 1; i++) {
				stitched.push(startConn[i]);
				const segD = haversineMeters(
					startConn[i].lat,
					startConn[i].lon,
					startConn[i + 1].lat,
					startConn[i + 1].lon,
				);
				const dEle =
					evalEle(startConn[i + 1].lat, startConn[i + 1].lon) -
					evalEle(startConn[i].lat, startConn[i].lon);
				const s = segD > 0.1 ? dEle / segD : 0;
				const v = toblerHikingSpeedKmh(s, isCycling);
				extraConnectorSeconds += segD > 0 ? segD / ((0.6 * v) / 3.6) : 0;
			}
		} else if (startGapM > 1) {
			stitched.push({ lat: userLat, lon: userLon });
		}

		for (const c of valhallaCoords) {
			stitched.push(c);
		}

		const lastVal = valhallaCoords[valhallaCoords.length - 1];
		const endGapM = haversineMeters(
			lastVal.lat,
			lastVal.lon,
			localResult.rejoinLat,
			localResult.rejoinLon,
		);
		if (endGapM > CONNECTOR_GAP_THRESHOLD_M) {
			const endConn = params.connectorSolver
				? await params.connectorSolver({
						fromLat: lastVal.lat,
						fromLon: lastVal.lon,
						toLat: localResult.rejoinLat,
						toLon: localResult.rejoinLon,
					})
				: computeLocalCurvedConnector({
						fromLat: lastVal.lat,
						fromLon: lastVal.lon,
						toLat: localResult.rejoinLat,
						toLon: localResult.rejoinLon,
						evalEle,
						mode,
						obstacles,
						preferredPaths,
					});
			for (let i = 1; i < endConn.length; i++) {
				const prev = endConn[i - 1];
				const cur = endConn[i];
				const segD = haversineMeters(prev.lat, prev.lon, cur.lat, cur.lon);
				const dEle = evalEle(cur.lat, cur.lon) - evalEle(prev.lat, prev.lon);
				const s = segD > 0.1 ? dEle / segD : 0;
				const v = toblerHikingSpeedKmh(s, isCycling);
				extraConnectorSeconds += segD > 0 ? segD / ((0.6 * v) / 3.6) : 0;
				stitched.push(cur);
			}
		} else if (endGapM > 1) {
			stitched.push({ lat: localResult.rejoinLat, lon: localResult.rejoinLon });
		}

		const cleanCoords = dedupeConsecutiveCoords(stitched);
		if (cleanCoords.length < 2) {
			return localResult;
		}

		const eles = cleanCoords.map((c) => evalEle(c.lat, c.lon));
		const outPoints: OffTrailPoint[] = [];
		let cumDist = 0;
		let ascentM = 0;
		let descentM = 0;
		let toblerTotalSec = 0;
		let maxAbsSlope = 0;

		for (let i = 0; i < cleanCoords.length; i++) {
			const c = cleanCoords[i];
			if (i > 0) {
				const prev = cleanCoords[i - 1];
				const d = haversineMeters(prev.lat, prev.lon, c.lat, c.lon);
				cumDist += d;
				const dEle = eles[i] - eles[i - 1];
				if (dEle > 0) ascentM += dEle;
				else if (dEle < 0) descentM += -dEle;

				const s = d > 0.1 ? dEle / d : 0;
				if (Math.abs(s) > maxAbsSlope) maxAbsSlope = Math.abs(s);
				const v = toblerHikingSpeedKmh(s, isCycling);
				toblerTotalSec += d > 0 ? d / (v / 3.6) : 0;
			}

			let gradePct = 0;
			if (i === 0) {
				const d = haversineMeters(c.lat, c.lon, cleanCoords[1].lat, cleanCoords[1].lon);
				gradePct = d > 0.1 ? ((eles[1] - eles[0]) / d) * 100 : 0;
			} else {
				const prev = cleanCoords[i - 1];
				const d = haversineMeters(prev.lat, prev.lon, c.lat, c.lon);
				gradePct = d > 0.1 ? ((eles[i] - eles[i - 1]) / d) * 100 : 0;
			}

			outPoints.push({
				lat: c.lat,
				lon: c.lon,
				ele: eles[i],
				distanceM: cumDist,
				gradePct,
			});
		}

		const valhallaTime = data.trip?.summary?.time;
		const estimatedSeconds =
			typeof valhallaTime === "number" && Number.isFinite(valhallaTime) && valhallaTime > 0
				? valhallaTime + extraConnectorSeconds
				: toblerTotalSec;

		const maxSlopeDeg = Math.atan(maxAbsSlope) * RAD_TO_DEG;

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
		const initialBearingDeg = bearingDegrees(userLat, userLon, lookLat, lookLon);
		const dir = cardinalDirection(initialBearingDeg, isRo ? "ro" : "en");
		const distRounded = Math.round(cumDist);
		const climbRounded = Math.round(ascentM);
		const slopeRounded = Math.round(maxSlopeDeg);

		const firstManeuverInstr = legs[0]?.maneuvers?.[0]?.instruction?.trim();
		const instruction =
			firstManeuverInstr && firstManeuverInstr.length > 0
				? firstManeuverInstr
				: isRo
					? `Urmează direcția ${dir} (${distRounded} m până la potecă)`
					: `Head ${dir} (${distRounded} m to trail)`;

		const slopeAdvice = isRo
			? ascentM > 10
				? `Urcare +${climbRounded} m · pantă max ${slopeRounded}°`
				: `Pantă ușoară · max ${slopeRounded}°`
			: ascentM > 10
				? `Climb +${climbRounded} m · max slope ${slopeRounded}°`
				: `Gentle slope · max ${slopeRounded}°`;

		return {
			mode,
			points: outPoints,
			rejoinLat: localResult.rejoinLat,
			rejoinLon: localResult.rejoinLon,
			rejoinAlongTrackM: localResult.rejoinAlongTrackM,
			rejoinEleM: eles[eles.length - 1],
			distanceM: cumDist,
			estimatedSeconds,
			ascentM,
			descentM,
			maxSlopeDeg,
			avoidedSteepHazard: localResult.avoidedSteepHazard,
			initialBearingDeg,
			instruction,
			slopeAdvice,
		};
	} catch {
		return localResult;
	} finally {
		if (timeoutId !== null) {
			clearTimeout(timeoutId);
		}
	}
}

/**
 * Computes an optional road/pedestrian/bicycle access route to the trailhead when the user
 * is in `> 3 km` Calm Preview Mode and explicitly taps "Rută de acces".
 */
export async function computeValhallaAccessRoute(
	userLat: number,
	userLon: number,
	startLat: number,
	startLon: number,
	isCycling = false,
	fetchImpl?: typeof fetch,
	sampler?: (lat: number, lon: number) => number | null,
): Promise<OffTrailPoint[] | null> {
	const fetchFn = fetchImpl ?? (typeof fetch === "function" ? fetch : undefined);
	if (
		!fetchFn ||
		!Number.isFinite(userLat) ||
		!Number.isFinite(userLon) ||
		!Number.isFinite(startLat) ||
		!Number.isFinite(startLon)
	) {
		return null;
	}

	const directDistM = haversineMeters(userLat, userLon, startLat, startLon);
	const costing =
		directDistM > 15_000 && !isCycling
			? "auto"
			: isCycling
				? "bicycle"
				: "pedestrian";

	try {
		const res = await fetchFn("/api/v1/valhalla/route", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({
				locations: [
					{ lat: userLat, lon: userLon },
					{ lat: startLat, lon: startLon },
				],
				costing,
				language: "ro-RO",
				directions_options: {
					language: "ro-RO",
					units: "kilometers",
				},
			}),
		});
		if (!res.ok) return null;

		const data = (await res.json()) as {
			trip?: { legs?: Array<{ shape?: string }> };
		};
		const legs = data?.trip?.legs;
		if (!Array.isArray(legs) || legs.length === 0) return null;

		const coords: { lat: number; lon: number }[] = [];
		for (const leg of legs) {
			if (typeof leg?.shape !== "string" || leg.shape.length === 0) continue;
			for (const [lon, lat] of decodePolyline(leg.shape, 6)) {
				if (Number.isFinite(lat) && Number.isFinite(lon)) {
					coords.push({ lat, lon });
				}
			}
		}

		const clean = dedupeConsecutiveCoords(coords);
		if (clean.length < 2) return null;

		const eles = clean.map((c) => {
			const s = sampler?.(c.lat, c.lon);
			return s !== undefined && s !== null && Number.isFinite(s) ? s : 0;
		});

		const out: OffTrailPoint[] = [];
		let cumDist = 0;
		for (let i = 0; i < clean.length; i++) {
			const c = clean[i];
			if (i > 0) {
				cumDist += haversineMeters(clean[i - 1].lat, clean[i - 1].lon, c.lat, c.lon);
			}
			let gradePct = 0;
			if (i === 0) {
				const d = haversineMeters(c.lat, c.lon, clean[1].lat, clean[1].lon);
				gradePct = d > 0.1 ? ((eles[1] - eles[0]) / d) * 100 : 0;
			} else {
				const d = haversineMeters(clean[i - 1].lat, clean[i - 1].lon, c.lat, c.lon);
				gradePct = d > 0.1 ? ((eles[i] - eles[i - 1]) / d) * 100 : 0;
			}
			out.push({
				lat: c.lat,
				lon: c.lon,
				ele: eles[i],
				distanceM: cumDist,
				gradePct,
			});
		}

		return out;
	} catch {
		return null;
	}
}
