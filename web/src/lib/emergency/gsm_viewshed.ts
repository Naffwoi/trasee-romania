import type { DemTileGrid } from "#lib/navigation/dem_tile_grid.ts";

const R_EARTH_M = 6_371_000.0;
const R_EFF_4_3_M = (4.0 / 3.0) * R_EARTH_M;
const GSM_WAVELENGTH_M = 0.353;
const USER_HAND_ANTENNA_M = 1.7;
const MAX_TOWER_SEARCH_M = 30_000.0;
const MAX_SAFE_SLOPE_RATIO = 0.7;
const EMERGENCY_CACHE_NAME = "wanderer-emergency-v1";
const EMERGENCY_DATA_URL = "/data/romania_emergency_112.json";

export type GsmLosClass = "clear_los" | "grazing_los" | "diffracted" | "blocked";

export interface CellTowerEntry {
	lat: number;
	lon: number;
	groundEleM: number;
	mastHeightM: number;
	carrierMask: number;
	source: "osm" | "opencellid";
}

export interface LandmarkEntry {
	lat: number;
	lon: number;
	eleM: number;
	kind: 1 | 2 | 3;
	name: string;
}

export interface TowerLosEvaluation {
	losClass: GsmLosClass;
	distanceM: number;
	bearingDeg: number;
	minClearanceM: number;
	maxNu: number;
}

export interface GsmSignalRecommendation {
	status: "already_los" | "climb_recommended" | "no_los_within_400m";
	targetLat: number;
	targetLon: number;
	walkDistanceM: number;
	ascentM: number;
	estimatedWalkMinutes: number;
	bearingDeg: number;
	cardinalRo: string;
	onTrail: boolean;
	reachableTowerCount: number;
	nearestTowerDistanceKm: number;
	nearestTowerBearingRo: string;
	losQuality: GsmLosClass;
	instructionRo: string;
}

function toRad(d: number): number {
	return (d * Math.PI) / 180.0;
}

function haversineM(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const dLat = toRad(lat2 - lat1);
	const dLon = toRad(lon2 - lon1);
	const a =
		Math.sin(dLat / 2) ** 2 +
		Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
	return 2 * R_EARTH_M * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
}

function bearingDeg(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const p1 = toRad(lat1);
	const p2 = toRad(lat2);
	const dl = toRad(lon2 - lon1);
	const y = Math.sin(dl) * Math.cos(p2);
	const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
	return (((Math.atan2(y, x) * 180) / Math.PI) + 360) % 360;
}

function cardinal8Ro(deg: number): string {
	const dirs = ["N", "NE", "E", "SE", "S", "SV", "V", "NV"];
	return dirs[Math.round((((deg % 360) + 360) % 360) / 45) % 8];
}

function destinationPoint(
	lat: number,
	lon: number,
	distM: number,
	azDeg: number,
): { lat: number; lon: number } {
	const ang = distM / R_EARTH_M;
	const br = toRad(azDeg);
	const p1 = toRad(lat);
	const l1 = toRad(lon);
	const p2 = Math.asin(Math.sin(p1) * Math.cos(ang) + Math.cos(p1) * Math.sin(ang) * Math.cos(br));
	const l2 =
		l1 +
		Math.atan2(
			Math.sin(br) * Math.sin(ang) * Math.cos(p1),
			Math.cos(ang) - Math.sin(p1) * Math.sin(p2),
		);
	return { lat: (p2 * 180) / Math.PI, lon: (l2 * 180) / Math.PI };
}

function toblerSeconds(distM: number, deltaEleM: number): number {
	if (distM <= 1) return 0;
	const slope = deltaEleM / distM;
	const speedKmh = Math.max(0.8, 6.0 * Math.exp(-3.5 * Math.abs(slope + 0.05)));
	return distM / (speedKmh / 3.6);
}

let singletonIndexPromise: Promise<EmergencySpatialIndex> | null = null;

/** Offline 0.1-degree spatial hash index for Romania cell towers and Carpathian landmarks. */
export class EmergencySpatialIndex {
	readonly towers: readonly CellTowerEntry[];
	readonly landmarks: readonly LandmarkEntry[];
	private readonly towerBuckets = new Map<number, CellTowerEntry[]>();
	private readonly landmarkBuckets = new Map<number, LandmarkEntry[]>();

	private constructor(towers: CellTowerEntry[], landmarks: LandmarkEntry[]) {
		this.towers = towers;
		this.landmarks = landmarks;
		for (const t of towers) {
			const key = this.cellKey(t.lat, t.lon);
			const arr = this.towerBuckets.get(key);
			if (arr) arr.push(t);
			else this.towerBuckets.set(key, [t]);
		}
		for (const lm of landmarks) {
			const key = this.cellKey(lm.lat, lm.lon);
			const arr = this.landmarkBuckets.get(key);
			if (arr) arr.push(lm);
			else this.landmarkBuckets.set(key, [lm]);
		}
	}

	private cellKey(lat: number, lon: number): number {
		return Math.floor(lat * 10) * 100_000 + Math.floor(lon * 10);
	}

	static fromJson(raw: unknown): EmergencySpatialIndex {
		const obj = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
		const rawTowers = Array.isArray(obj.towers) ? obj.towers : [];
		const rawPeaks = Array.isArray(obj.peaks) ? obj.peaks : [];

		const towers: CellTowerEntry[] = [];
		for (const row of rawTowers) {
			if (!Array.isArray(row) || row.length < 6) continue;
			towers.push({
				lat: Number(row[0]) / 1e5,
				lon: Number(row[1]) / 1e5,
				groundEleM: Number(row[2]),
				mastHeightM: Number(row[3]),
				carrierMask: Number(row[4]),
				source: Number(row[5]) === 2 ? "opencellid" : "osm",
			});
		}

		const landmarks: LandmarkEntry[] = [];
		for (const row of rawPeaks) {
			if (!Array.isArray(row) || row.length < 5) continue;
			const kindNum = Number(row[3]);
			landmarks.push({
				lat: Number(row[0]) / 1e5,
				lon: Number(row[1]) / 1e5,
				eleM: Number(row[2]),
				kind: kindNum === 2 ? 2 : kindNum === 3 ? 3 : 1,
				name: String(row[4]),
			});
		}

		return new EmergencySpatialIndex(towers, landmarks);
	}

	static async loadCached(fetchImpl: typeof fetch = fetch): Promise<EmergencySpatialIndex> {
		if (singletonIndexPromise) return singletonIndexPromise;
		singletonIndexPromise = (async () => {
			try {
				let response: Response | undefined;
				let cache: Cache | null = null;
				if (typeof caches !== "undefined") {
					try {
						cache = await caches.open(EMERGENCY_CACHE_NAME);
						response = (await cache.match(EMERGENCY_DATA_URL)) ?? undefined;
					} catch {
						cache = null;
					}
				}
				if (!response) {
					const fetched = await fetchImpl(EMERGENCY_DATA_URL);
					if (fetched.ok) {
						response = fetched;
						if (cache) {
							await cache.put(EMERGENCY_DATA_URL, fetched.clone()).catch(() => {});
						}
					}
				}
				if (response) {
					const json = await response.json();
					return EmergencySpatialIndex.fromJson(json);
				}
			} catch {
				// Graceful empty index if unreachable without cache
			}
			return EmergencySpatialIndex.fromJson({ towers: [], peaks: [] });
		})();
		return singletonIndexPromise;
	}

	findTowersWithin(lat: number, lon: number, radiusM = MAX_TOWER_SEARCH_M): CellTowerEntry[] {
		const dLat = Math.ceil((radiusM / 111_320) * 10);
		const dLon = Math.ceil((radiusM / (111_320 * Math.max(0.2, Math.cos(toRad(lat))))) * 10);
		const baseLat = Math.floor(lat * 10);
		const baseLon = Math.floor(lon * 10);

		const matches: Array<{ tower: CellTowerEntry; distM: number }> = [];
		for (let gy = baseLat - dLat; gy <= baseLat + dLat; gy++) {
			for (let gx = baseLon - dLon; gx <= baseLon + dLon; gx++) {
				const bucket = this.towerBuckets.get(gy * 100_000 + gx);
				if (!bucket) continue;
				for (const t of bucket) {
					const d = haversineM(lat, lon, t.lat, t.lon);
					if (d <= radiusM) {
						matches.push({ tower: t, distM: d });
					}
				}
			}
		}
		matches.sort((a, b) => a.distM - b.distM);
		return matches.slice(0, 16).map((m) => m.tower);
	}

	findNearestLandmark(lat: number, lon: number, maxRadiusM = 15_000): LandmarkEntry | null {
		const dLat = Math.ceil((maxRadiusM / 111_320) * 10);
		const dLon = Math.ceil((maxRadiusM / (111_320 * Math.max(0.2, Math.cos(toRad(lat))))) * 10);
		const baseLat = Math.floor(lat * 10);
		const baseLon = Math.floor(lon * 10);

		let best: LandmarkEntry | null = null;
		let bestDist = maxRadiusM;
		for (let gy = baseLat - dLat; gy <= baseLat + dLat; gy++) {
			for (let gx = baseLon - dLon; gx <= baseLon + dLon; gx++) {
				const bucket = this.landmarkBuckets.get(gy * 100_000 + gx);
				if (!bucket) continue;
				for (const lm of bucket) {
					const d = haversineM(lat, lon, lm.lat, lm.lon);
					if (d < bestDist) {
						bestDist = d;
						best = lm;
					}
				}
			}
		}
		return best;
	}
}

/** Evaluates ITU-R 4/3-Earth 850 MHz Fresnel zone line-of-sight from user position to a cell tower. */
export function evaluateTowerLos(
	userLat: number,
	userLon: number,
	userGroundEleM: number,
	tower: CellTowerEntry,
	dem: Pick<DemTileGrid, "sampleElevation">,
): TowerLosEvaluation {
	const D = haversineM(userLat, userLon, tower.lat, tower.lon);
	const az = bearingDeg(userLat, userLon, tower.lat, tower.lon);
	if (D < 60) {
		return { losClass: "clear_los", distanceM: D, bearingDeg: az, minClearanceM: 50, maxNu: -3 };
	}

	const h0 = userGroundEleM + USER_HAND_ANTENNA_M;
	const towerGround = dem.sampleElevation(tower.lat, tower.lon) ?? tower.groundEleM;
	const hT = towerGround + tower.mastHeightM;

	let minClearanceM = Infinity;
	let minFresnelMarginM = Infinity;
	let maxNu = -Infinity;

	let d = 40.0;
	while (d < D - 30.0) {
		const t = d / D;
		const sLat = userLat + (tower.lat - userLat) * t;
		const sLon = userLon + (tower.lon - userLon) * t;
		const zTer = dem.sampleElevation(sLat, sLon);
		if (zTer !== null && Number.isFinite(zTer)) {
			const earthBulge = (d * (D - d)) / (2.0 * R_EFF_4_3_M);
			const hRay = h0 + t * (hT - h0) - earthBulge;
			const clearance = hRay - zTer;
			const rF1 = Math.sqrt((GSM_WAVELENGTH_M * d * (D - d)) / D);
			const nu = -Math.SQRT2 * (clearance / Math.max(0.5, rF1));

			if (clearance < minClearanceM) minClearanceM = clearance;
			if (clearance - 0.6 * rF1 < minFresnelMarginM) {
				minFresnelMarginM = clearance - 0.6 * rF1;
			}
			if (nu > maxNu) maxNu = nu;

			if (clearance < -25.0 && nu > 2.2) {
				return {
					losClass: "blocked",
					distanceM: D,
					bearingDeg: az,
					minClearanceM: clearance,
					maxNu: nu,
				};
			}
		}
		d += d < 4_000.0 ? 40.0 : 120.0;
	}

	if (minFresnelMarginM >= 0) {
		return { losClass: "clear_los", distanceM: D, bearingDeg: az, minClearanceM, maxNu };
	}
	if (minClearanceM >= 0) {
		return { losClass: "grazing_los", distanceM: D, bearingDeg: az, minClearanceM, maxNu };
	}
	if (minClearanceM >= -12.0 && maxNu <= 1.2) {
		return { losClass: "diffracted", distanceM: D, bearingDeg: az, minClearanceM, maxNu };
	}
	return { losClass: "blocked", distanceM: D, bearingDeg: az, minClearanceM, maxNu };
}

function isWalkablePathSafe(
	lat0: number,
	lon0: number,
	ele0: number,
	lat1: number,
	lon1: number,
	dem: Pick<DemTileGrid, "sampleElevation">,
): { safe: boolean; targetEle: number } {
	const totalDist = haversineM(lat0, lon0, lat1, lon1);
	const targetEle = dem.sampleElevation(lat1, lon1);
	if (targetEle === null || !Number.isFinite(targetEle)) return { safe: false, targetEle: ele0 };
	if (targetEle < ele0 - 15.0) return { safe: false, targetEle };

	const steps = Math.max(1, Math.ceil(totalDist / 35.0));
	let prevEle = ele0;
	const stepDist = totalDist / steps;
	for (let i = 1; i <= steps; i++) {
		const f = i / steps;
		const e = dem.sampleElevation(lat0 + (lat1 - lat0) * f, lon0 + (lon1 - lon0) * f);
		if (e === null) return { safe: false, targetEle };
		if (Math.abs(e - prevEle) / Math.max(10.0, stepDist) > MAX_SAFE_SLOPE_RATIO) {
			return { safe: false, targetEle };
		}
		prevEle = e;
	}
	return { safe: true, targetEle };
}

/** Finds the quickest safe uphill spot within 400m that achieves GSM line-of-sight. */
export function findBestGsm112SignalSpot(params: {
	lat: number;
	lon: number;
	dem: Pick<DemTileGrid, "sampleElevation">;
	index: EmergencySpatialIndex;
	trailPoints?: ReadonlyArray<{ lat: number; lon: number; distanceM?: number }>;
	alongTrackM?: number;
}): GsmSignalRecommendation {
	const { lat, lon, dem, index } = params;
	const towers = index.findTowersWithin(lat, lon, MAX_TOWER_SEARCH_M).slice(0, 12);
	const userEle = dem.sampleElevation(lat, lon) ?? 1200;

	if (towers.length === 0) {
		return {
			status: "no_los_within_400m",
			targetLat: lat,
			targetLon: lon,
			walkDistanceM: 0,
			ascentM: 0,
			estimatedWalkMinutes: 0,
			bearingDeg: 0,
			cardinalRo: "N",
			onTrail: false,
			reachableTowerCount: 0,
			nearestTowerDistanceKm: 0,
			nearestTowerBearingRo: "N",
			losQuality: "blocked",
			instructionRo:
				"Niciun releu GSM indexat pe o rază de 30 km. Urcă spre cea mai apropiată creastă deschisă și formează 112.",
		};
	}

	const evalSpot = (sLat: number, sLon: number, sEle: number) => {
		let losCount = 0;
		let bestClass: GsmLosClass = "blocked";
		let nearestDistM = Infinity;
		let nearestAz = 0;
		for (const t of towers) {
			const res = evaluateTowerLos(sLat, sLon, sEle, t, dem);
			if (res.losClass === "clear_los" || res.losClass === "grazing_los") {
				losCount++;
				if (res.losClass === "clear_los" || bestClass !== "clear_los") {
					bestClass = res.losClass;
				}
				if (res.distanceM < nearestDistM) {
					nearestDistM = res.distanceM;
					nearestAz = res.bearingDeg;
				}
			}
		}
		return { losCount, bestClass, nearestDistM, nearestAz };
	};

	const here = evalSpot(lat, lon, userEle);
	if (here.losCount > 0) {
		const km = Number((here.nearestDistM / 1000).toFixed(1));
		const dir = cardinal8Ro(here.nearestAz);
		return {
			status: "already_los",
			targetLat: lat,
			targetLon: lon,
			walkDistanceM: 0,
			ascentM: 0,
			estimatedWalkMinutes: 0,
			bearingDeg: here.nearestAz,
			cardinalRo: dir,
			onTrail: true,
			reachableTowerCount: here.losCount,
			nearestTowerDistanceKm: km,
			nearestTowerBearingRo: dir,
			losQuality: here.bestClass,
			instructionRo: `Ai deja linie vizuală spre ${here.losCount === 1 ? "un releu GSM" : `${here.losCount} relee GSM`} (cel mai apropiat la ${km} km ${dir}). Ridică telefonul și sună la 112.`,
		};
	}

	interface Candidate {
		lat: number;
		lon: number;
		onTrail: boolean;
	}
	const candidates: Candidate[] = [];

	if (params.trailPoints && params.trailPoints.length > 0) {
		for (const pt of params.trailPoints) {
			const d = haversineM(lat, lon, pt.lat, pt.lon);
			if (d >= 40 && d <= 400) {
				candidates.push({ lat: pt.lat, lon: pt.lon, onTrail: true });
			}
		}
	}

	for (const r of [50, 100, 150, 200, 250, 300, 350, 400]) {
		for (let az = 0; az < 360; az += 22.5) {
			const dest = destinationPoint(lat, lon, r, az);
			candidates.push({ lat: dest.lat, lon: dest.lon, onTrail: false });
		}
	}

	let bestWinner: {
		cand: Candidate;
		costSec: number;
		walkDistM: number;
		ascentM: number;
		losCount: number;
		bestClass: GsmLosClass;
		nearestDistM: number;
		nearestAz: number;
	} | null = null;

	for (const cand of candidates) {
		const check = isWalkablePathSafe(lat, lon, userEle, cand.lat, cand.lon, dem);
		if (!check.safe) continue;

		const spot = evalSpot(cand.lat, cand.lon, check.targetEle);
		if (spot.losCount === 0) continue;

		const walkDistM = haversineM(lat, lon, cand.lat, cand.lon);
		const ascentM = Math.max(0, check.targetEle - userEle);
		const walkSec = toblerSeconds(walkDistM, check.targetEle - userEle);
		const weightedCost =
			walkSec * (cand.onTrail ? 0.75 : 1.0) - (spot.bestClass === "clear_los" ? 15 : 0);

		if (!bestWinner || weightedCost < bestWinner.costSec) {
			bestWinner = {
				cand,
				costSec: weightedCost,
				walkDistM,
				ascentM,
				losCount: spot.losCount,
				bestClass: spot.bestClass,
				nearestDistM: spot.nearestDistM,
				nearestAz: spot.nearestAz,
			};
		}
	}

	if (bestWinner) {
		const walkM = Math.round(bestWinner.walkDistM);
		const climbM = Math.round(bestWinner.ascentM);
		const walkMin = Math.max(
			1,
			Math.round(toblerSeconds(bestWinner.walkDistM, bestWinner.ascentM) / 60),
		);
		const moveAz = bearingDeg(lat, lon, bestWinner.cand.lat, bestWinner.cand.lon);
		const moveDir = cardinal8Ro(moveAz);
		const towerKm = Number((bestWinner.nearestDistM / 1000).toFixed(1));
		const towerDir = cardinal8Ro(bestWinner.nearestAz);
		const whereLabel = bestWinner.cand.onTrail ? "pe potecă" : "în amonte";

		return {
			status: "climb_recommended",
			targetLat: bestWinner.cand.lat,
			targetLon: bestWinner.cand.lon,
			walkDistanceM: walkM,
			ascentM: climbM,
			estimatedWalkMinutes: walkMin,
			bearingDeg: moveAz,
			cardinalRo: moveDir,
			onTrail: bestWinner.cand.onTrail,
			reachableTowerCount: bestWinner.losCount,
			nearestTowerDistanceKm: towerKm,
			nearestTowerBearingRo: towerDir,
			losQuality: bestWinner.bestClass,
			instructionRo: `Urcă ${walkM} m ${whereLabel} spre ${moveDir} (+${climbM} m, ~${walkMin} min) pentru linie vizuală către ${bestWinner.losCount === 1 ? "1 releu GSM" : `${bestWinner.losCount} relee GSM`} (${towerKm} km ${towerDir}).`,
		};
	}

	return {
		status: "no_los_within_400m",
		targetLat: lat,
		targetLon: lon,
		walkDistanceM: 0,
		ascentM: 0,
		estimatedWalkMinutes: 0,
		bearingDeg: bearingDeg(lat, lon, towers[0].lat, towers[0].lon),
		cardinalRo: cardinal8Ro(bearingDeg(lat, lon, towers[0].lat, towers[0].lon)),
		onTrail: false,
		reachableTowerCount: 0,
		nearestTowerDistanceKm: Number(
			(haversineM(lat, lon, towers[0].lat, towers[0].lon) / 1000).toFixed(1),
		),
		nearestTowerBearingRo: cardinal8Ro(bearingDeg(lat, lon, towers[0].lat, towers[0].lon)),
		losQuality: "blocked",
		instructionRo:
			"Vale adâncă fără linie vizuală directă în primii 400 m. Continuă pe poteca marcată spre creastă/șa deschisă și încearcă apelul 112.",
	};
}
