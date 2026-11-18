import rawDataset from "#lib/data/salvamont_ro.json";
import { bearingDegrees, cardinalDirection, haversineMeters } from "#lib/navigation/geo_math.ts";

export type SalvamontPointKind = "base" | "post" | "refuge" | "dispatch_hq";
export type SalvamontPermanence = "24_7" | "seasonal" | "shelter_unmanned";
export type SalvamontServiceLevel = "national" | "county" | "local" | "gendarmerie_info";

export interface SalvamontService {
	id: string;
	name: string;
	shortName: string;
	level: SalvamontServiceLevel;
	countyCode: string;
	ansmrId: number | null;
	primaryPhone: string;
	secondaryPhones: string[];
	phoneRoleRo: string;
	massifs: string[];
	website?: string;
}

export interface SalvamontPoint {
	id: string;
	name: string;
	kind: SalvamontPointKind;
	permanence: SalvamontPermanence;
	lat: number;
	lon: number;
	ele: number;
	massif: string;
	countyCode: string;
	serviceId: string;
	backupCountyServiceId?: string;
	directBasePhone?: string;
	osmIds: string[];
	source: "osm+ansmr" | "ansmr_curated";
}

export interface SalvamontDataset {
	version: number;
	generatedAt: string;
	emergency112: string;
	nationalDispatchPhone: string;
	nationalDispatchLabel: string;
	services: Record<string, SalvamontService>;
	points: SalvamontPoint[];
}

export interface ResolvedSalvamontPoint {
	point: SalvamontPoint;
	service: SalvamontService;
	backupCountyService: SalvamontService | null;
	effectivePhone: string;
	distanceM: number;
	bearingDeg: number;
	cardinal: string;
	deltaEleM: number | null;
}

export interface ResolvedSalvamontService {
	service: SalvamontService;
	nearestPoint: SalvamontPoint;
	distanceM: number;
}

export interface NearestSalvamontResolution {
	emergency112: string;
	nationalDispatchPhone: string;
	nationalDispatchLabel: string;
	isMountainZone: boolean;
	isRidgeBorderZone: boolean;
	borderCountyCodes: string[];
	nearestBases: ResolvedSalvamontPoint[];
	nearestRefuge: ResolvedSalvamontPoint | null;
	activeServices: ResolvedSalvamontService[];
	gendarmerieAdvisory: ResolvedSalvamontService | null;
	referenceMode: "user_gps" | "trail";
}

export interface ResolveSalvamontOptions {
	k?: number;
	userEle?: number | null;
	locale?: string;
	referenceMode?: "user_gps" | "trail";
}

export interface TrailSalvamontSummary {
	nearestBase: ResolvedSalvamontPoint;
	nearestRefuge: ResolvedSalvamontPoint | null;
	services: ResolvedSalvamontService[];
	isRidgeBorderTrail: boolean;
}

const MAX_MOUNTAIN_ZONE_M = 35_000;
const MAX_REFUGE_RADIUS_M = 15_000;
const BORDER_DELTA_M = 3_500;
const BORDER_RATIO = 1.35;
const BORDER_MAX_DIST_M = 12_000;

const dataset = rawDataset as unknown as SalvamontDataset;

/** Returns the offline bundled Romania Salvamont dataset. */
export function getSalvamontDataset(): SalvamontDataset {
	return dataset;
}

/** Formats an E.164 Romanian phone (+40XXXXXXXXX) into a readable local display string. */
export function formatRoPhoneDisplay(e164: string): string {
	if (e164.startsWith("+40") && e164.length === 12) {
		const local = `0${e164.slice(3)}`;
		return `${local.slice(0, 4)} ${local.slice(4, 7)} ${local.slice(7)}`;
	}
	return e164;
}

/** Resolves nearest operational Salvamont bases, unmanned refuges, and ridge-border jurisdictions offline. */
export function resolveNearestSalvamont(
	lat: number,
	lon: number,
	opts: ResolveSalvamontOptions = {},
): NearestSalvamontResolution {
	const k = Math.max(1, opts.k ?? 3);
	const lang = (opts.locale ?? "ro").toLowerCase().startsWith("ro") ? "ro" : "en";
	const referenceMode = opts.referenceMode ?? "user_gps";
	const userEle =
		opts.userEle !== undefined && opts.userEle !== null && Number.isFinite(opts.userEle)
			? opts.userEle
			: null;

	if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
		return {
			emergency112: dataset.emergency112,
			nationalDispatchPhone: dataset.nationalDispatchPhone,
			nationalDispatchLabel: dataset.nationalDispatchLabel,
			isMountainZone: false,
			isRidgeBorderZone: false,
			borderCountyCodes: [],
			nearestBases: [],
			nearestRefuge: null,
			activeServices: [],
			gendarmerieAdvisory: null,
			referenceMode,
		};
	}

	const operationalResolved: ResolvedSalvamontPoint[] = [];
	const refugesResolved: ResolvedSalvamontPoint[] = [];

	for (const pt of dataset.points) {
		const svc = dataset.services[pt.serviceId];
		if (!svc) continue;
		const backup = pt.backupCountyServiceId
			? (dataset.services[pt.backupCountyServiceId] ?? null)
			: null;
		const distM = haversineMeters(lat, lon, pt.lat, pt.lon);
		const brg = bearingDegrees(lat, lon, pt.lat, pt.lon);
		const card = cardinalDirection(brg, lang);
		const deltaEleM = userEle !== null && pt.ele > 0 ? Math.round(pt.ele - userEle) : null;
		const effectivePhone = pt.directBasePhone ?? svc.primaryPhone;

		const item: ResolvedSalvamontPoint = {
			point: pt,
			service: svc,
			backupCountyService: backup,
			effectivePhone,
			distanceM: distM,
			bearingDeg: brg,
			cardinal: card,
			deltaEleM,
		};

		if (pt.kind === "refuge") {
			refugesResolved.push(item);
		} else {
			operationalResolved.push(item);
		}
	}

	operationalResolved.sort((a, b) => a.distanceM - b.distanceM);
	refugesResolved.sort((a, b) => a.distanceM - b.distanceM);

	const primary = operationalResolved[0];
	const isMountainZone = Boolean(primary && primary.distanceM <= MAX_MOUNTAIN_ZONE_M);
	const nearestBases = isMountainZone ? operationalResolved.slice(0, k) : [];
	const nearestRefuge =
		refugesResolved.length > 0 && refugesResolved[0].distanceM <= MAX_REFUGE_RADIUS_M
			? refugesResolved[0]
			: null;

	const activeServices: ResolvedSalvamontService[] = [];
	if (isMountainZone && primary) {
		const d1 = Math.max(1, primary.distanceM);
		const seenServiceIds = new Set<string>([primary.service.id]);
		activeServices.push({
			service: primary.service,
			nearestPoint: primary.point,
			distanceM: primary.distanceM,
		});

		for (const cand of operationalResolved.slice(1)) {
			if (cand.service.level === "gendarmerie_info") continue;
			if (seenServiceIds.has(cand.service.id)) continue;
			const isWithinBorderMargin =
				cand.distanceM - primary.distanceM <= BORDER_DELTA_M ||
				(cand.distanceM / d1 <= BORDER_RATIO && cand.distanceM <= BORDER_MAX_DIST_M);
			if (isWithinBorderMargin) {
				seenServiceIds.add(cand.service.id);
				activeServices.push({
					service: cand.service,
					nearestPoint: cand.point,
					distanceM: cand.distanceM,
				});
				if (activeServices.length >= 3) break;
			}
		}
	}

	const borderCountyCodes = Array.from(new Set(activeServices.map((s) => s.service.countyCode)));
	const isRidgeBorderZone = activeServices.length >= 2;

	let gendarmerieAdvisory: ResolvedSalvamontService | null = null;
	const bzSvc = dataset.services["ro-bz-jandarmerie"];
	if (bzSvc && isMountainZone && primary) {
		const distNehoiu = haversineMeters(lat, lon, 45.4239, 26.2961);
		if (distNehoiu <= 25_000) {
			gendarmerieAdvisory = {
				service: bzSvc,
				nearestPoint: primary.point,
				distanceM: distNehoiu,
			};
		}
	}

	return {
		emergency112: dataset.emergency112,
		nationalDispatchPhone: dataset.nationalDispatchPhone,
		nationalDispatchLabel: dataset.nationalDispatchLabel,
		isMountainZone,
		isRidgeBorderZone,
		borderCountyCodes,
		nearestBases,
		nearestRefuge,
		activeServices,
		gendarmerieAdvisory,
		referenceMode,
	};
}

/** Summarizes Salvamont coverage and border jurisdictions across a trail's anchor points. */
export function resolveTrailSalvamontSummary(
	points: ReadonlyArray<{ lat: number; lon: number; ele?: number }>,
	locale = "ro",
): TrailSalvamontSummary | null {
	if (!points || points.length === 0) return null;
	const start = points[0];
	const mid = points[Math.floor(points.length / 2)];
	let highest = points[0];
	for (const p of points) {
		if ((p.ele ?? -Infinity) > (highest.ele ?? -Infinity)) {
			highest = p;
		}
	}

	const anchors = [start, mid, highest, points[points.length - 1]];
	let bestBase: ResolvedSalvamontPoint | null = null;
	let bestRefuge: ResolvedSalvamontPoint | null = null;
	const serviceBestMap = new Map<string, ResolvedSalvamontService>();

	for (const a of anchors) {
		const r = resolveNearestSalvamont(a.lat, a.lon, {
			userEle: a.ele ?? null,
			locale,
			referenceMode: "trail",
		});
		if (!r.isMountainZone) continue;
		if (r.nearestBases[0] && (!bestBase || r.nearestBases[0].distanceM < bestBase.distanceM)) {
			bestBase = r.nearestBases[0];
		}
		if (r.nearestRefuge && (!bestRefuge || r.nearestRefuge.distanceM < bestRefuge.distanceM)) {
			bestRefuge = r.nearestRefuge;
		}
		for (const s of r.activeServices) {
			const prev = serviceBestMap.get(s.service.id);
			if (!prev || s.distanceM < prev.distanceM) {
				serviceBestMap.set(s.service.id, s);
			}
		}
	}

	if (!bestBase) return null;
	const services = Array.from(serviceBestMap.values())
		.sort((a, b) => a.distanceM - b.distanceM)
		.slice(0, 3);

	return {
		nearestBase: bestBase,
		nearestRefuge: bestRefuge,
		services,
		isRidgeBorderTrail: services.length >= 2,
	};
}
