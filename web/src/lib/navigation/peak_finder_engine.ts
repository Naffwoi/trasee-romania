import type { DemTileGrid } from "./dem_tile_grid";
import {
	bearingDegrees,
	cardinalDirection,
	EARTH_RADIUS_M,
	haversineMeters,
	normalizeBearingDelta,
} from "./geo_math";
import { CURVATURE_REFRACTION_COEFF } from "./ridge_sunset_calculator";

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;
const EYE_HEIGHT_M = 1.7;
const PEAKS_CACHE_NAME = "wanderer-peaks-v1";
const ROMANIA_PEAKS_URL = "/data/romania_peaks_v1.json";

export interface PeakEntryDto {
	id: number;
	name: string;
	lat: number;
	lon: number;
	ele: number;
	prominenceM?: number;
	kind: "peak" | "pass";
}

interface ColumnarPeakCatalog {
	version: number;
	count: number;
	ids: number[];
	names: string[];
	lats: number[];
	lons: number[];
	eles: number[];
	prominences?: number[];
	kinds?: ("peak" | "pass")[];
}

export interface VisiblePeakResult {
	peak: PeakEntryDto;
	distanceM: number;
	bearingDeg: number;
	cardinal: string;
	elevationAngleDeg: number;
	visibility: "visible" | "unverified";
	score: number;
	tier: 0 | 1;
}

export interface HorizonPanorama {
	observerLat: number;
	observerLon: number;
	observerEleM: number;
	standingOnPeak: PeakEntryDto | null;
	nearDeg: Float32Array;
	midDeg: Float32Array;
	farDeg: Float32Array;
	visiblePeaks: VisiblePeakResult[];
}

function cellKey(latIdx: number, lonIdx: number): string {
	return `${latIdx}:${lonIdx}`;
}

/** Offline 3D horizon silhouette and DEM line-of-sight peak finder with angular NMS decluttering. */
export class OfflinePeakFinder {
	private readonly buckets = new Map<string, PeakEntryDto[]>();
	private readonly seenIds = new Set<number>();
	private romaniaLoaded = false;
	private readonly fetchedForeignCells = new Set<string>();

	static fromPeaks(peaks: readonly PeakEntryDto[]): OfflinePeakFinder {
		const inst = new OfflinePeakFinder();
		inst.ingestPeaks(peaks);
		inst.romaniaLoaded = true;
		return inst;
	}

	ingestPeaks(peaks: readonly PeakEntryDto[]): void {
		for (const p of peaks) {
			if (this.seenIds.has(p.id) || !Number.isFinite(p.lat) || !Number.isFinite(p.lon)) {
				continue;
			}
			this.seenIds.add(p.id);
			const key = cellKey(Math.floor(p.lat * 10), Math.floor(p.lon * 10));
			const arr = this.buckets.get(key);
			if (arr) {
				arr.push(p);
			} else {
				this.buckets.set(key, [p]);
			}
		}
	}

	async ensureLoaded(lat: number, lon: number, locale = "ro"): Promise<void> {
		if (typeof window === "undefined" || typeof fetch !== "function") return;

		if (!this.romaniaLoaded) {
			try {
				let resp: Response | undefined;
				const cache =
					typeof caches !== "undefined"
						? await caches.open(PEAKS_CACHE_NAME).catch(() => null)
						: null;
				if (cache) {
					resp = (await cache.match(ROMANIA_PEAKS_URL)) ?? undefined;
				}
				if (!resp) {
					const net = await fetch(ROMANIA_PEAKS_URL);
					if (net.ok) {
						resp = net;
						await cache?.put(ROMANIA_PEAKS_URL, net.clone()).catch(() => {});
					}
				}
				if (resp) {
					const cat = (await resp.json()) as ColumnarPeakCatalog;
					const parsed: PeakEntryDto[] = [];
					for (let i = 0; i < cat.count; i++) {
						parsed.push({
							id: cat.ids[i],
							name: cat.names[i],
							lat: cat.lats[i],
							lon: cat.lons[i],
							ele: cat.eles[i],
							prominenceM: cat.prominences?.[i] ?? 100,
							kind: cat.kinds?.[i] === "pass" ? "pass" : "peak",
						});
					}
					this.ingestPeaks(parsed);
					this.romaniaLoaded = true;
				}
			} catch {
				// Offline before first fetch
			}
		}

		const inRomania = lat >= 43.4 && lat <= 48.5 && lon >= 20.0 && lon <= 30.0;
		if (!inRomania) {
			const fKey = `${Math.floor(lat * 2)}_${Math.floor(lon * 2)}`;
			if (!this.fetchedForeignCells.has(fKey)) {
				this.fetchedForeignCells.add(fKey);
				const s = Math.floor(lat * 2) / 2 - 0.35;
				const w = Math.floor(lon * 2) / 2 - 0.35;
				const n = s + 1.2;
				const e = w + 1.2;
				const q = `[out:json][timeout:12];node["natural"="peak"]["name"](${s.toFixed(2)},${w.toFixed(2)},${n.toFixed(2)},${e.toFixed(2)});out body;`;
				const url = `/api/v1/overpass/interpreter?data=${encodeURIComponent(q)}`;
				try {
					const cache =
						typeof caches !== "undefined"
							? await caches.open(PEAKS_CACHE_NAME).catch(() => null)
							: null;
					let resp = cache ? ((await cache.match(url)) ?? undefined) : undefined;
					if (!resp) {
						const net = await fetch(url);
						if (net.ok) {
							resp = net;
							await cache?.put(url, net.clone()).catch(() => {});
						}
					}
					if (resp) {
						const data = (await resp.json()) as {
							elements?: Array<{
								id: number;
								lat: number;
								lon: number;
								tags?: Record<string, string>;
							}>;
						};
						const extra: PeakEntryDto[] = [];
						for (const el of data.elements ?? []) {
							const name =
								(locale.startsWith("ro") ? el.tags?.["name:ro"] : undefined) ??
								el.tags?.name;
							const ele = Number.parseFloat(el.tags?.ele ?? "");
							if (name && Number.isFinite(ele) && ele > 100) {
								extra.push({
									id: el.id,
									name,
									lat: el.lat,
									lon: el.lon,
									ele,
									prominenceM: 180,
									kind: "peak",
								});
							}
						}
						this.ingestPeaks(extra);
					}
				} catch {
					// Degrade gracefully offline outside Romania
				}
			}
		}
	}

	queryWithinRadius(lat: number, lon: number, maxRadiusM = 35_000): PeakEntryDto[] {
		const dLat = maxRadiusM / 111320;
		const dLon = maxRadiusM / (111320 * Math.max(0.1, Math.cos(lat * DEG_TO_RAD)));
		const minLatIdx = Math.floor((lat - dLat) * 10);
		const maxLatIdx = Math.floor((lat + dLat) * 10);
		const minLonIdx = Math.floor((lon - dLon) * 10);
		const maxLonIdx = Math.floor((lon + dLon) * 10);

		const candidates: PeakEntryDto[] = [];
		for (let li = minLatIdx; li <= maxLatIdx; li++) {
			for (let lj = minLonIdx; lj <= maxLonIdx; lj++) {
				const bucket = this.buckets.get(cellKey(li, lj));
				if (!bucket) continue;
				for (const p of bucket) {
					const dist = haversineMeters(lat, lon, p.lat, p.lon);
					if (dist <= maxRadiusM) {
						candidates.push(p);
					}
				}
			}
		}
		return candidates;
	}

	computePanorama(
		dem: Pick<DemTileGrid, "sampleElevation">,
		lat: number,
		lon: number,
		eleM: number | null,
		locale = "ro",
		maxRadiusM = 35_000,
	): HorizonPanorama {
		const demEle = dem.sampleElevation(lat, lon);
		const groundEle =
			eleM !== null && Number.isFinite(eleM)
				? demEle !== null
					? Math.max(eleM, demEle)
					: eleM
				: (demEle ?? 0);
		const observerH = groundEle + EYE_HEIGHT_M;

		const bins = 720;
		const nearDeg = new Float32Array(bins).fill(-15);
		const midDeg = new Float32Array(bins).fill(-15);
		const farDeg = new Float32Array(bins).fill(-15);

		const metersPerDegLat = DEG_TO_RAD * EARTH_RADIUS_M;
		const metersPerDegLon = metersPerDegLat * Math.max(0.05, Math.cos(lat * DEG_TO_RAD));

		for (let b = 0; b < bins; b++) {
			const azRad = b * 0.5 * DEG_TO_RAD;
			const dirE = Math.sin(azRad);
			const dirN = Math.cos(azRad);
			let maxNear = -15;
			let maxMid = -15;
			let maxFar = -15;

			let d = 60;
			while (d <= maxRadiusM) {
				const z = dem.sampleElevation(
					lat + (dirN * d) / metersPerDegLat,
					lon + (dirE * d) / metersPerDegLon,
				);
				if (z !== null) {
					const effZ = z - CURVATURE_REFRACTION_COEFF * d * d;
					const ang = Math.atan2(effZ - observerH, d) * RAD_TO_DEG;
					if (d <= 4_000 && ang > maxNear) maxNear = ang;
					if (d <= 12_000 && ang > maxMid) maxMid = ang;
					if (ang > maxFar) maxFar = ang;
				}
				d += d < 2000 ? 50 : d < 10000 ? 120 : 250;
			}
			nearDeg[b] = maxNear;
			midDeg[b] = Math.max(maxNear, maxMid);
			farDeg[b] = Math.max(midDeg[b], maxFar);
		}

		const candidates = this.queryWithinRadius(lat, lon, maxRadiusM);
		let standingOnPeak: PeakEntryDto | null = null;
		const visiblePeaks: VisiblePeakResult[] = [];

		for (const p of candidates) {
			const distM = haversineMeters(lat, lon, p.lat, p.lon);
			if (distM < 35) {
				if (!standingOnPeak || p.ele > standingOnPeak.ele) {
					standingOnPeak = p;
				}
				continue;
			}

			const brg = bearingDegrees(lat, lon, p.lat, p.lon);
			const azRad = brg * DEG_TO_RAD;
			const dirE = Math.sin(azRad);
			const dirN = Math.cos(azRad);

			const effPeakZ = p.ele - CURVATURE_REFRACTION_COEFF * distM * distM;
			const peakAngleDeg = Math.atan2(effPeakZ - observerH, distM) * RAD_TO_DEG;
			const graceDeg = Math.atan2(8.0, distM) * RAD_TO_DEG;

			let occluded = false;
			let anyDemSample = false;
			const stopDistM = Math.max(0, distM - Math.min(350, Math.max(120, distM * 0.085)));
			let s = 40;
			while (s < stopDistM) {
				const z = dem.sampleElevation(
					lat + (dirN * s) / metersPerDegLat,
					lon + (dirE * s) / metersPerDegLon,
				);
				if (z !== null) {
					anyDemSample = true;
					const effZ = z - CURVATURE_REFRACTION_COEFF * s * s;
					const terrainAng = Math.atan2(effZ - observerH, s) * RAD_TO_DEG;
					if (terrainAng > peakAngleDeg + graceDeg) {
						occluded = true;
						break;
					}
				}
				s += s < 1500 ? 35 : s < 8000 ? 80 : 180;
			}

			if (occluded) continue;

			const prom = p.prominenceM ?? 100;
			const score = prom * 2.0 + p.ele * 0.35 - (distM / 1000) * 8.0;
			visiblePeaks.push({
				peak: p,
				distanceM: distM,
				bearingDeg: brg,
				cardinal: cardinalDirection(brg, locale),
				elevationAngleDeg: peakAngleDeg,
				visibility: anyDemSample || distM <= 125 ? "visible" : "unverified",
				score,
				tier: 0,
			});
		}

		visiblePeaks.sort((a, b) => b.score - a.score);
		return {
			observerLat: lat,
			observerLon: lon,
			observerEleM: groundEle,
			standingOnPeak,
			nearDeg,
			midDeg,
			farDeg,
			visiblePeaks,
		};
	}

	/**
	 * Selects up to `maxLabels` decluttered visible peaks inside `[headingDeg - fovDeg/2, headingDeg + fovDeg/2]`
	 * using greedy angular NMS (5.5° primary tier, 2.75° secondary stacked tier).
	 */
	selectViewportPeaks(
		panorama: HorizonPanorama,
		headingDeg: number,
		fovDeg = 90,
		maxLabels = 8,
	): VisiblePeakResult[] {
		const halfFov = fovDeg / 2;
		const chosen: VisiblePeakResult[] = [];

		for (const cand of panorama.visiblePeaks) {
			const rel = normalizeBearingDelta(headingDeg, cand.bearingDeg);
			if (Math.abs(rel) > halfFov) continue;

			let tooClose = false;
			let needsTier1 = false;
			for (const existing of chosen) {
				const sep = Math.abs(normalizeBearingDelta(existing.bearingDeg, cand.bearingDeg));
				if (sep < 2.75) {
					tooClose = true;
					break;
				}
				if (sep < 5.5) {
					if (existing.tier === 0 && !needsTier1) {
						needsTier1 = true;
					} else {
						tooClose = true;
						break;
					}
				}
			}

			if (!tooClose) {
				chosen.push({ ...cand, tier: needsTier1 ? 1 : 0 });
				if (chosen.length >= maxLabels) break;
			}
		}

		return chosen.sort(
			(a, b) =>
				normalizeBearingDelta(headingDeg, a.bearingDeg) -
				normalizeBearingDelta(headingDeg, b.bearingDeg),
		);
	}
}
