/**
 * Pure-math solar ephemeris adapted from mourner/suncalc v2 (BSD-2-Clause, Volodymyr Agafonkin)
 * and Jean Meeus, Astronomical Algorithms (2nd ed., Chapters 12, 15, 16, 22, 25).
 * Zero external API keys or network calls.
 */

const RAD = Math.PI / 180;
const DAY_MS = 86_400_000;
const J1970 = 2440588;
const J2000 = 2451545;
const J0 = 0.0009;

export interface SunPosition {
	/** Clockwise degrees from true North in `[0, 360)`. */
	azimuthDeg: number;
	/** Apparent solar altitude in degrees (includes Bennett/Meeus atmospheric refraction). */
	altitudeDeg: number;
	/** Geometric solar altitude in degrees (without atmospheric refraction). */
	trueAltitudeDeg: number;
}

export interface SunTimes {
	solarNoon: Date;
	nadir: Date;
	sunrise: Date | null;
	sunset: Date | null;
	dawn: Date | null;
	dusk: Date | null;
	goldenHour: Date | null;
	polarState: "normal" | "midnight_sun" | "polar_night";
}

function toMs(date: Date | number): number {
	return typeof date === "number" ? date : date.getTime();
}

function fromJulianDaysSinceJ2000(d: number): Date {
	return new Date((d + J2000 + 0.5 - J1970) * DAY_MS);
}

function toDays(ms: number): number {
	return ms / DAY_MS - 0.5 + J1970 - J2000;
}

function deltaTSeconds(d: number): number {
	const y = 2000 + d / 365.2425;
	if (y < 2005) {
		const t = y - 2000;
		return 63.86 + t * (0.3345 + t * (-0.060374 + t * 0.0017275));
	}
	if (y < 2050) {
		const t = y - 2000;
		return 62.92 + t * (0.32217 + t * 0.005589);
	}
	const t = (y - 1820) / 100;
	return -20 + 32 * t * t - 0.5628 * (2150 - y);
}

function toDaysTT(d: number): number {
	return d + deltaTSeconds(d) / 86400;
}

function siderealTime(d: number, lw: number): number {
	return RAD * (280.46061837 + 360.98564736629 * d) - lw;
}

/** Atmospheric refraction correction in radians (Meeus Ch. 16.4). */
export function astroRefractionRad(hRad: number): number {
	const hClamped = hRad < 0 ? 0 : hRad;
	return 0.0002967 / Math.tan(hClamped + 0.00312536 / (hClamped + 0.08901179));
}

function sunCoords(dTT: number): { ra: number; dec: number } {
	const t = dTT / 36525;
	const L0 = RAD * (280.46646 + t * (36000.76983 + t * 0.0003032));
	const M = RAD * (357.52911 + t * (35999.05029 - t * 0.0001537));
	const sinM = Math.sin(M);
	const cosM = Math.cos(M);
	const C =
		RAD *
		((1.914602 - t * (0.004817 + 0.000014 * t)) * sinM +
			(0.019993 - 0.000101 * t) * 2 * sinM * cosM +
			0.000289 * sinM * (3 - 4 * sinM * sinM));
	const omega = RAD * (125.04 - 1934.136 * t);
	const lambda = L0 + C - RAD * (0.00569 + 0.00478 * Math.sin(omega));
	const eps =
		RAD * (23.439291 - t * (0.0130042 + t * (0.00000016 - t * 0.000000504))) +
		RAD * 0.00256 * Math.cos(omega);

	return {
		ra: Math.atan2(Math.cos(eps) * Math.sin(lambda), Math.cos(lambda)),
		dec: Math.asin(Math.sin(eps) * Math.sin(lambda)),
	};
}

function northClockwiseAzimuthDeg(H: number, phi: number, dec: number): number {
	const deg =
		(Math.atan2(Math.sin(H), Math.cos(H) * Math.sin(phi) - Math.tan(dec) * Math.cos(phi)) / RAD +
			540) %
		360;
	return deg < 0 ? deg + 360 : deg === 0 ? 0 : deg;
}

function geometricAltitudeRad(H: number, phi: number, dec: number): number {
	const s = Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(H);
	return Math.asin(Math.min(1, Math.max(-1, s)));
}

/** Computes Sun azimuth (North-clockwise) and apparent/true altitude at a given timestamp and coordinate. */
export function getSunPosition(date: Date | number, lat: number, lon: number): SunPosition {
	const cLat = Math.min(90, Math.max(-90, Number.isFinite(lat) ? lat : 0));
	const cLon = Number.isFinite(lon) ? lon : 0;
	const lw = RAD * -cLon;
	const phi = RAD * cLat;
	const d = toDays(toMs(date));
	const coords = sunCoords(toDaysTT(d));
	const H = siderealTime(d, lw) - coords.ra;
	const hRad = geometricAltitudeRad(H, phi, coords.dec);
	const refrRad = hRad >= -0.02 ? astroRefractionRad(hRad) : 0;

	return {
		azimuthDeg: northClockwiseAzimuthDeg(H, phi, coords.dec),
		altitudeDeg: (hRad + refrRad) / RAD,
		trueAltitudeDeg: hRad / RAD,
	};
}

function wrapPi(a: number): number {
	return a - 2 * Math.PI * Math.round(a / (2 * Math.PI));
}

function solarTransit(dt: number, lw: number): number {
	let cur = dt;
	for (let i = 0; i < 3; i++) {
		const H = wrapPi(siderealTime(cur, lw) - sunCoords(toDaysTT(cur)).ra);
		cur -= H / (2 * Math.PI);
	}
	return cur;
}

function solveAltitudeCrossing(
	h0Rad: number,
	aIn: number,
	bIn: number,
	sa: number,
	sb: number,
	dt: number,
	lw: number,
	phi: number,
	decT: number,
): number {
	const s0 = Math.sin(h0Rad);
	const rising = sa < sb;
	if (!((sa - s0) * (sb - s0) <= 0)) {
		return Number.NaN;
	}

	let a = aIn;
	let b = bIn;
	const denom = Math.cos(phi) * Math.cos(decT);
	const cosH0 = Math.abs(denom) > 1e-12 ? (s0 - Math.sin(phi) * Math.sin(decT)) / denom : 0;
	const H0 = cosH0 <= -1 ? Math.PI : cosH0 >= 1 ? 0 : Math.acos(cosH0);
	let d = dt + (rising ? -H0 : H0) / (2 * Math.PI);
	let dx = b - a;

	for (let iter = 0; iter < 32; iter++) {
		const c = sunCoords(toDaysTT(d));
		const H = siderealTime(d, lw) - c.ra;
		const k = Math.cos(phi) * Math.cos(c.dec);
		const f = Math.sin(phi) * Math.sin(c.dec) + k * Math.cos(H) - s0;
		if ((f < 0) === rising) {
			a = d;
		} else {
			b = d;
		}

		const deriv = 2 * Math.PI * k * Math.sin(H);
		const step = Math.abs(deriv) > 1e-12 ? f / deriv : Number.POSITIVE_INFINITY;
		if (d + step > a && d + step < b && Math.abs(step) <= Math.abs(dx) / 2) {
			dx = step;
			d += step;
			if (Math.abs(step) < 1e-5) return d;
		} else {
			dx = (b - a) / 2;
			d = a + dx;
			if (b - a < 1e-8) return d;
		}
	}
	return d;
}

/** Computes solar noon, sunrise, sunset, civil dawn/dusk, and polar day/night state. */
export function getSunTimes(date: Date | number, lat: number, lon: number): SunTimes {
	const cLat = Math.min(89.999, Math.max(-89.999, Number.isFinite(lat) ? lat : 0));
	const cLon = Number.isFinite(lon) ? lon : 0;
	const lw = RAD * -cLon;
	const phi = RAD * cLat;
	const anchorD = toDays(toMs(date));
	const lonDays = J0 + lw / (2 * Math.PI);
	const dt = solarTransit(Math.round(anchorD - lonDays) + lonDays, lw);

	const decNoon = sunCoords(toDaysTT(dt)).dec;
	const sNoon = Math.cos(phi - decNoon);
	const sNadir1 = -Math.cos(phi + sunCoords(toDaysTT(dt - 0.5)).dec);
	const sNadir2 = -Math.cos(phi + sunCoords(toDaysTT(dt + 0.5)).dec);

	const solvePair = (angleDeg: number): [Date | null, Date | null] => {
		const h0 = angleDeg * RAD;
		const jr = solveAltitudeCrossing(h0, dt - 0.5, dt, sNadir1, sNoon, dt, lw, phi, decNoon);
		const js = solveAltitudeCrossing(h0, dt, dt + 0.5, sNoon, sNadir2, dt, lw, phi, decNoon);
		return [
			Number.isFinite(jr) ? fromJulianDaysSinceJ2000(jr) : null,
			Number.isFinite(js) ? fromJulianDaysSinceJ2000(js) : null,
		];
	};

	const [sunrise, sunset] = solvePair(-0.833);
	const [dawn, dusk] = solvePair(-6.0);
	const [, goldenHour] = solvePair(6.0);

	const sSunset = Math.sin(-0.833 * RAD);
	let polarState: SunTimes["polarState"] = "normal";
	if (sunrise === null && sunset === null) {
		polarState = sNoon > sSunset ? "midnight_sun" : "polar_night";
	}

	return {
		solarNoon: fromJulianDaysSinceJ2000(dt),
		nadir: fromJulianDaysSinceJ2000(dt - 0.5),
		sunrise,
		sunset,
		dawn,
		dusk,
		goldenHour,
		polarState,
	};
}
