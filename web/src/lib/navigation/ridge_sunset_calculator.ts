import type { DemTileGrid } from "./dem_tile_grid";
import type { EtaCalculator } from "./eta_calculator";
import { EARTH_RADIUS_M, interpolateTrackAtDistance } from "./geo_math";
import { getSunPosition, getSunTimes } from "./sun_calc";
import type { NavTrackPoint, OffTrailExtra } from "./types";

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;
const HIKER_EYE_HEIGHT_M = 1.7;
const SOLAR_UPPER_LIMB_DEG = 0.266;
/** Standard terrestrial optical refraction coefficient k = 0.13 => (1 - k) / (2 * R_earth). */
export const CURVATURE_REFRACTION_COEFF = (1 - 0.13) / (2 * EARTH_RADIUS_M);

export type LightSafetyStatus =
	| "daylight_safe"
	| "ridge_shade"
	| "twilight_warning"
	| "night_danger";

export interface RidgeSunsetResult {
	ridgeSunsetMs: number | null;
	astroSunsetMs: number | null;
	civilDuskMs: number | null;
	ridgeHorizonDeg: number;
	minutesBeforeAstroSunset: number;
	partialDemCoverage: boolean;
}

export interface TrailSolarForecast {
	status: LightSafetyStatus;
	finishRidgeSunset: RidgeSunsetResult;
	ridgeShadeAlongM: number | null;
	ridgeShadeTimeMs: number | null;
	astroSunsetAlongM: number | null;
	civilDuskAlongM: number | null;
	nightRemainingDistanceM: number;
}

/**
 * Adaptive 1D DEM ray-marching from (lat, lon, eleM + 1.7m) along `azimuthDeg` up to `maxDistM`.
 */
export function computeHorizonAngleDeg(
	dem: Pick<DemTileGrid, "sampleElevation">,
	lat: number,
	lon: number,
	eleM: number,
	azimuthDeg: number,
	maxDistM = 25_000,
): { angleDeg: number; partialDem: boolean } {
	const observerH = (Number.isFinite(eleM) ? eleM : 0) + HIKER_EYE_HEIGHT_M;
	const azRad = azimuthDeg * DEG_TO_RAD;
	const dirEast = Math.sin(azRad);
	const dirNorth = Math.cos(azRad);
	const metersPerDegLat = DEG_TO_RAD * EARTH_RADIUS_M;
	const cosLat = Math.max(0.05, Math.cos(lat * DEG_TO_RAD));
	const metersPerDegLon = metersPerDegLat * cosLat;

	let maxAngleDeg = 0;
	let partialDem = false;
	let d = 40;

	while (d <= maxDistM) {
		const sampleLat = lat + (dirNorth * d) / metersPerDegLat;
		const sampleLon = lon + (dirEast * d) / metersPerDegLon;
		const z = dem.sampleElevation(sampleLat, sampleLon);
		if (z === null) {
			partialDem = true;
		} else {
			const effectiveZ = z - CURVATURE_REFRACTION_COEFF * d * d;
			const angle = Math.atan2(effectiveZ - observerH, d) * RAD_TO_DEG;
			if (angle > maxAngleDeg) {
				maxAngleDeg = angle;
			}
		}

		if (d < 1500) {
			d += 25;
		} else if (d < 6000) {
			d += 60;
		} else {
			d += 150;
		}
	}

	return { angleDeg: maxAngleDeg, partialDem };
}

function sunlightMarginDeg(
	dem: Pick<DemTileGrid, "sampleElevation">,
	lat: number,
	lon: number,
	eleM: number,
	tsMs: number,
): { marginDeg: number; horizonDeg: number; partialDem: boolean; trueAltDeg: number } {
	const sun = getSunPosition(tsMs, lat, lon);
	if (sun.trueAltitudeDeg <= -0.833) {
		return {
			marginDeg: sun.trueAltitudeDeg + 0.833,
			horizonDeg: 0,
			partialDem: false,
			trueAltDeg: sun.trueAltitudeDeg,
		};
	}
	const { angleDeg, partialDem } = computeHorizonAngleDeg(dem, lat, lon, eleM, sun.azimuthDeg);
	return {
		marginDeg: sun.altitudeDeg + SOLAR_UPPER_LIMB_DEG - angleDeg,
		horizonDeg: angleDeg,
		partialDem,
		trueAltDeg: sun.trueAltitudeDeg,
	};
}

/**
 * Searches backwards from astronomical sunset toward solar noon in 10-min brackets
 * (with 6-step bisection refinement) to find the final local ridge sunset timestamp.
 */
export function computeLocalRidgeSunset(
	dem: Pick<DemTileGrid, "sampleElevation">,
	lat: number,
	lon: number,
	eleM: number,
	refDateMs: number,
): RidgeSunsetResult {
	const times = getSunTimes(refDateMs, lat, lon);
	const astroSunsetMs = times.sunset ? times.sunset.getTime() : null;
	const civilDuskMs = times.dusk ? times.dusk.getTime() : null;

	if (astroSunsetMs === null) {
		return {
			ridgeSunsetMs: null,
			astroSunsetMs: null,
			civilDuskMs,
			ridgeHorizonDeg: 0,
			minutesBeforeAstroSunset: 0,
			partialDemCoverage: false,
		};
	}

	const noonMs = times.solarNoon.getTime();
	const stepMs = 10 * 60_000;
	let tHigh = astroSunsetMs + 5 * 60_000;
	let evalHigh = sunlightMarginDeg(dem, lat, lon, eleM, tHigh);
	let partialDem = evalHigh.partialDem;

	let bracketLow: number | null = null;
	let bracketHigh = tHigh;

	for (let t = tHigh - stepMs; t >= noonMs; t -= stepMs) {
		const ev = sunlightMarginDeg(dem, lat, lon, eleM, t);
		if (ev.partialDem) partialDem = true;
		if (ev.marginDeg > 0 && evalHigh.marginDeg <= 0) {
			bracketLow = t;
			bracketHigh = t + stepMs;
			break;
		}
		evalHigh = ev;
		tHigh = t;
	}

	if (bracketLow === null) {
		const noonEval = sunlightMarginDeg(dem, lat, lon, eleM, noonMs);
		const finalMs = noonEval.marginDeg <= 0 ? noonMs : astroSunsetMs;
		return {
			ridgeSunsetMs: finalMs,
			astroSunsetMs,
			civilDuskMs,
			ridgeHorizonDeg: noonEval.horizonDeg,
			minutesBeforeAstroSunset: Math.max(0, Math.round((astroSunsetMs - finalMs) / 60_000)),
			partialDemCoverage: partialDem || noonEval.partialDem,
		};
	}

	let lo = bracketLow;
	let hi = bracketHigh;
	let horizonAtSet = evalHigh.horizonDeg;
	for (let i = 0; i < 6; i++) {
		const mid = 0.5 * (lo + hi);
		const ev = sunlightMarginDeg(dem, lat, lon, eleM, mid);
		if (ev.partialDem) partialDem = true;
		if (ev.marginDeg > 0) {
			lo = mid;
		} else {
			hi = mid;
			horizonAtSet = ev.horizonDeg;
		}
	}

	const ridgeSunsetMs = Math.round(0.5 * (lo + hi));
	return {
		ridgeSunsetMs,
		astroSunsetMs,
		civilDuskMs,
		ridgeHorizonDeg: horizonAtSet,
		minutesBeforeAstroSunset: Math.max(0, Math.round((astroSunsetMs - ridgeSunsetMs) / 60_000)),
		partialDemCoverage: partialDem,
	};
}

/** Couples 1D DEM horizon ray-marching with live EtaCalculator pace to forecast ridge-shade entry. */
export function computeTrailSolarForecast(params: {
	points: readonly NavTrackPoint[];
	etaCalc: EtaCalculator;
	dem: Pick<DemTileGrid, "sampleElevation">;
	alongTrackM: number;
	nowMs: number;
	offTrailExtra?: OffTrailExtra | null;
}): TrailSolarForecast {
	const { points, etaCalc, dem, alongTrackM, nowMs, offTrailExtra } = params;
	if (points.length === 0) {
		return {
			status: "daylight_safe",
			finishRidgeSunset: {
				ridgeSunsetMs: null,
				astroSunsetMs: null,
				civilDuskMs: null,
				ridgeHorizonDeg: 0,
				minutesBeforeAstroSunset: 0,
				partialDemCoverage: false,
			},
			ridgeShadeAlongM: null,
			ridgeShadeTimeMs: null,
			astroSunsetAlongM: null,
			civilDuskAlongM: null,
			nightRemainingDistanceM: 0,
		};
	}

	const totalDist = points[points.length - 1].distanceM;
	const endPt = points[points.length - 1];
	const finishRidgeSunset = computeLocalRidgeSunset(dem, endPt.lat, endPt.lon, endPt.ele, nowMs);

	const anchorM = offTrailExtra
		? Math.min(totalDist, Math.max(0, offTrailExtra.rejoinAlongTrackM))
		: Math.min(totalDist, Math.max(0, alongTrackM));
	const baseSecAnchor = etaCalc.baseSecondsAt(anchorM);
	const paceFactor = etaCalc.getPaceFactor();
	const leadSec = offTrailExtra ? Math.max(0, offTrailExtra.durationSec) : 0;

	const remSpan = Math.max(0, totalDist - anchorM);
	const numSamples = Math.min(30, Math.max(2, Math.ceil(remSpan / 500) + 1));
	const stepM = numSamples > 1 ? remSpan / (numSamples - 1) : 0;

	const samples: Array<{
		d: number;
		tMs: number;
		inShade: boolean;
		pastAstro: boolean;
		pastDusk: boolean;
	}> = [];

	for (let i = 0; i < numSamples; i++) {
		const d = i === numSamples - 1 ? totalDist : anchorM + i * stepM;
		const pt = interpolateTrackAtDistance(points, d);
		const dtSec = leadSec + Math.max(0, etaCalc.baseSecondsAt(d) - baseSecAnchor) * paceFactor;
		const tMs = nowMs + dtSec * 1000;
		const ev = sunlightMarginDeg(dem, pt.lat, pt.lon, pt.ele, tMs);
		const sampledDemEle = dem.sampleElevation(pt.lat, pt.lon);
		const effEle = sampledDemEle ?? pt.ele;
		const refined =
			sampledDemEle !== null && Math.abs(effEle - pt.ele) > 15
				? sunlightMarginDeg(dem, pt.lat, pt.lon, effEle, tMs)
				: ev;

		samples.push({
			d,
			tMs,
			inShade: refined.marginDeg <= 0,
			pastAstro: refined.trueAltDeg <= -0.833,
			pastDusk: refined.trueAltDeg <= -6.0,
		});
	}

	let ridgeIdx = -1;
	if (samples[samples.length - 1].inShade) {
		ridgeIdx = samples.length - 1;
		while (ridgeIdx > 0 && samples[ridgeIdx - 1].inShade) {
			ridgeIdx--;
		}
	}
	const astroHit = samples.find((s) => s.pastAstro) ?? null;
	const duskHit = samples.find((s) => s.pastDusk) ?? null;

	let status: LightSafetyStatus = "daylight_safe";
	if (duskHit) {
		status = "night_danger";
	} else if (astroHit) {
		status = "twilight_warning";
	} else if (ridgeIdx >= 0) {
		status = "ridge_shade";
	}

	const nightRemainingDistanceM = duskHit ? Math.max(0, totalDist - duskHit.d) : 0;

	return {
		status,
		finishRidgeSunset,
		ridgeShadeAlongM: ridgeIdx >= 0 ? samples[ridgeIdx].d : null,
		ridgeShadeTimeMs: ridgeIdx >= 0 ? samples[ridgeIdx].tMs : null,
		astroSunsetAlongM: astroHit ? astroHit.d : null,
		civilDuskAlongM: duskHit ? duskHit.d : null,
		nightRemainingDistanceM,
	};
}
