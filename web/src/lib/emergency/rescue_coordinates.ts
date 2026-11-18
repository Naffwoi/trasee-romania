const WGS84_A = 6_378_137.0;
const WGS84_F = 1.0 / 298.257223563;
const UTM_K0 = 0.9996;
const UTM_FALSE_EASTING = 500_000.0;
const UTM_FALSE_NORTHING = 10_000_000.0;
const MGRS_LAT_BANDS = "CDEFGHJKLMNPQRSTUVWXX";

const OLC_ALPHABET = "23456789CFGHJMPQRVWX";
const OLC_BASE = 20;
const OLC_PAIR_PRECISION = 8_000;
const OLC_GRID_COLS = 4;
const OLC_GRID_ROWS = 5;
const OLC_FINAL_LAT_PRECISION = 25_000_000;
const OLC_FINAL_LNG_PRECISION = 8_192_000;

export interface UtmCoordinate {
	zone: number;
	band: string;
	hemisphere: "N" | "S";
	easting: number;
	northing: number;
	formatted: string;
}

export interface PlusCodeArea {
	latitudeLo: number;
	longitudeLo: number;
	latitudeHi: number;
	longitudeHi: number;
	latitudeCenter: number;
	longitudeCenter: number;
	codeLength: number;
}

export interface NearbyLandmarkInput {
	name: string;
	lat: number;
	lon: number;
	eleM?: number | null;
}

export interface NearbyLandmarkRef {
	name: string;
	eleM: number | null;
	distanceM: number;
	bearingFromLandmarkRo: string;
	summaryRo: string;
	summaryAscii: string;
}

export interface RescueCoordinateInput {
	lat: number;
	lon: number;
	elevationM?: number | null;
	accuracyM?: number | null;
	reasonRo?: string;
	landmark?: NearbyLandmarkInput | null;
	now?: Date;
}

export interface RescueCoordinateBundle {
	wgs84Decimal: string;
	wgs84RawPair: string;
	wgs84Dms: string;
	utm: UtmCoordinate;
	plusCode: string;
	elevationM: number | null;
	accuracyM: number | null;
	nearestLandmark: NearbyLandmarkRef | null;
	sms113AsciiBody: string;
	clipboardFullCardRo: string;
}

/** Strips Romanian diacritics and non-GSM-7 characters for 160-char ASCII SMS framing. */
export function stripRomanianDiacritics(input: string): string {
	return input
		.replace(/[ăâĂÂ]/g, (m) => (m === m.toUpperCase() ? "A" : "a"))
		.replace(/[îÎ]/g, (m) => (m === m.toUpperCase() ? "I" : "i"))
		.replace(/[șşȘŞ]/g, (m) => (m === m.toUpperCase() ? "S" : "s"))
		.replace(/[țţȚŢ]/g, (m) => (m === m.toUpperCase() ? "T" : "t"))
		.replace(/[—–]/g, "-")
		.replace(/[^\x20-\x7E\n]/g, "");
}

function toRad(deg: number): number {
	return (deg * Math.PI) / 180.0;
}

function haversineM(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const R = 6_371_000.0;
	const dLat = toRad(lat2 - lat1);
	const dLon = toRad(lon2 - lon1);
	const a =
		Math.sin(dLat / 2) ** 2 +
		Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
	return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
}

function initialBearingDeg(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const p1 = toRad(lat1);
	const p2 = toRad(lat2);
	const dl = toRad(lon2 - lon1);
	const y = Math.sin(dl) * Math.cos(p2);
	const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl);
	return (((Math.atan2(y, x) * 180) / Math.PI) + 360) % 360;
}

function cardinal8Ro(bearingDeg: number): string {
	const dirs = ["N", "NE", "E", "SE", "S", "SV", "V", "NV"];
	return dirs[Math.round((((bearingDeg % 360) + 360) % 360) / 45) % 8];
}

function formatSingleDms(degVal: number, posHemi: string, negHemi: string): string {
	const hemi = degVal >= 0 ? posHemi : negHemi;
	const totalTenths = Math.round(Math.abs(degVal) * 36_000);
	const d = Math.floor(totalTenths / 36_000);
	const rem = totalTenths % 36_000;
	const m = Math.floor(rem / 600);
	const tenthsSec = rem % 600;
	const secWhole = Math.floor(tenthsSec / 10);
	const secFrac = tenthsSec % 10;
	return `${String(d).padStart(2, "0")}° ${String(m).padStart(2, "0")}' ${String(secWhole).padStart(2, "0")}.${secFrac}" ${hemi}`;
}

/** Formats WGS84 coordinates in carry-safe DMS without 60.0" rounding overflow. */
export function formatDmsCoordinate(lat: number, lon: number): string {
	return `${formatSingleDms(lat, "N", "S")}, ${formatSingleDms(lon, "E", "W")}`;
}

/** Converts WGS84 lat/lon to UTM using Karney (2011) 6th-order Krüger series. */
export function wgs84ToUtm(lat: number, lon: number): UtmCoordinate {
	const clampedLat = Math.max(-80.0, Math.min(84.0, lat));
	const normLon = ((((lon + 180.0) % 360.0) + 360.0) % 360.0) - 180.0;

	let zone = Math.floor((normLon + 180.0) / 6.0) + 1;
	const bandIdx = Math.max(0, Math.min(MGRS_LAT_BANDS.length - 1, Math.floor(clampedLat / 8.0 + 10.0)));
	const band = MGRS_LAT_BANDS.charAt(bandIdx);

	if (zone === 31 && band === "V" && normLon >= 3.0) {
		zone = 32;
	} else if (band === "X") {
		if (zone === 32 && normLon < 9.0) zone = 31;
		else if (zone === 32 && normLon >= 9.0) zone = 33;
		else if (zone === 34 && normLon < 21.0) zone = 33;
		else if (zone === 34 && normLon >= 21.0) zone = 35;
		else if (zone === 36 && normLon < 33.0) zone = 35;
		else if (zone === 36 && normLon >= 33.0) zone = 37;
	}

	const lam0 = toRad((zone - 1) * 6 - 180 + 3);
	const phi = toRad(clampedLat);
	const lam = toRad(normLon) - lam0;

	const e = Math.sqrt(WGS84_F * (2.0 - WGS84_F));
	const n = WGS84_F / (2.0 - WGS84_F);
	const n2 = n * n;
	const n3 = n2 * n;
	const n4 = n3 * n;
	const n5 = n4 * n;
	const n6 = n5 * n;

	const A = (WGS84_A / (1.0 + n)) * (1.0 + n2 / 4.0 + n4 / 64.0 + n6 / 256.0);
	const alpha = [
		0,
		0.5 * n - (2 / 3) * n2 + (5 / 16) * n3 + (41 / 180) * n4 - (127 / 288) * n5 + (7891 / 37800) * n6,
		(13 / 48) * n2 - (3 / 5) * n3 + (557 / 1440) * n4 + (281 / 630) * n5 - (1983433 / 1935360) * n6,
		(61 / 240) * n3 - (103 / 140) * n4 + (15061 / 26880) * n5 + (167603 / 181440) * n6,
		(49561 / 161280) * n4 - (179 / 168) * n5 + (6601661 / 7257600) * n6,
		(34729 / 80640) * n5 - (3418889 / 1995840) * n6,
		(212378941 / 319334400) * n6,
	];

	const tau = Math.tan(phi);
	const sigma = Math.sinh(e * Math.atanh((e * tau) / Math.sqrt(1.0 + tau * tau)));
	const tauPrime = tau * Math.sqrt(1.0 + sigma * sigma) - sigma * Math.sqrt(1.0 + tau * tau);

	const cosLam = Math.cos(lam);
	const sinLam = Math.sin(lam);
	const xiPrime = Math.atan2(tauPrime, cosLam);
	const etaPrime = Math.asinh(sinLam / Math.sqrt(tauPrime * tauPrime + cosLam * cosLam));

	let xi = xiPrime;
	let eta = etaPrime;
	for (let j = 1; j <= 6; j++) {
		xi += alpha[j] * Math.sin(2 * j * xiPrime) * Math.cosh(2 * j * etaPrime);
		eta += alpha[j] * Math.cos(2 * j * xiPrime) * Math.sinh(2 * j * etaPrime);
	}

	const easting = UTM_K0 * A * eta + UTM_FALSE_EASTING;
	const rawNorthing = UTM_K0 * A * xi;
	const northing = clampedLat < 0 ? rawNorthing + UTM_FALSE_NORTHING : rawNorthing;
	const hemisphere = clampedLat >= 0 ? "N" : "S";

	return {
		zone,
		band,
		hemisphere,
		easting,
		northing,
		formatted: `${zone}${band} ${Math.round(easting)} E ${Math.round(northing)} N`,
	};
}

/** Encodes lat/lon into an Apache-2.0 Open Location Code (Plus Code) of length 10 or 11. */
export function encodePlusCode(lat: number, lon: number, codeLength: 10 | 11 = 11): string {
	let latVal = Math.floor(lat * OLC_FINAL_LAT_PRECISION) + 90 * OLC_FINAL_LAT_PRECISION;
	if (latVal < 0) latVal = 0;
	const maxLatVal = 180 * OLC_FINAL_LAT_PRECISION;
	if (latVal >= maxLatVal) latVal = maxLatVal - 1;

	let lngVal = Math.floor(lon * OLC_FINAL_LNG_PRECISION) + 180 * OLC_FINAL_LNG_PRECISION;
	const maxLngVal = 360 * OLC_FINAL_LNG_PRECISION;
	lngVal = ((lngVal % maxLngVal) + maxLngVal) % maxLngVal;

	const chars = new Array<string>(16).fill("");
	chars[8] = "+";

	if (codeLength === 11) {
		latVal = Math.floor(latVal / 625);
		lngVal = Math.floor(lngVal / 256);
		const latDigit = latVal % OLC_GRID_ROWS;
		const lngDigit = lngVal % OLC_GRID_COLS;
		chars[11] = OLC_ALPHABET.charAt(latDigit * OLC_GRID_COLS + lngDigit);
		latVal = Math.floor(latVal / OLC_GRID_ROWS);
		lngVal = Math.floor(lngVal / OLC_GRID_COLS);
	} else {
		latVal = Math.floor(latVal / 3_125);
		lngVal = Math.floor(lngVal / 1_024);
	}

	chars[9] = OLC_ALPHABET.charAt(latVal % OLC_BASE);
	chars[10] = OLC_ALPHABET.charAt(lngVal % OLC_BASE);
	latVal = Math.floor(latVal / OLC_BASE);
	lngVal = Math.floor(lngVal / OLC_BASE);

	for (let i = 6; i >= 0; i -= 2) {
		chars[i] = OLC_ALPHABET.charAt(latVal % OLC_BASE);
		chars[i + 1] = OLC_ALPHABET.charAt(lngVal % OLC_BASE);
		latVal = Math.floor(latVal / OLC_BASE);
		lngVal = Math.floor(lngVal / OLC_BASE);
	}

	return chars.slice(0, codeLength + 1).join("");
}

/** Decodes a full Open Location Code back into its bounding box and center coordinates. */
export function decodePlusCode(rawCode: string): PlusCodeArea {
	const cleaned = rawCode.trim().toUpperCase().replace("+", "").replace(/0/g, "");
	if (cleaned.length < 2 || cleaned.length > 15) {
		throw new Error(`Invalid Plus Code: ${rawCode}`);
	}
	for (let i = 0; i < cleaned.length; i++) {
		if (OLC_ALPHABET.indexOf(cleaned.charAt(i)) === -1) {
			throw new Error(`Invalid character in Plus Code: ${rawCode}`);
		}
	}

	let normalLat = -90 * OLC_PAIR_PRECISION;
	let normalLng = -180 * OLC_PAIR_PRECISION;
	let pv = 160_000;
	const pairDigits = Math.min(cleaned.length, 10);

	for (let i = 0; i < pairDigits; i += 2) {
		normalLat += OLC_ALPHABET.indexOf(cleaned.charAt(i)) * pv;
		normalLng += OLC_ALPHABET.indexOf(cleaned.charAt(i + 1)) * pv;
		if (i < pairDigits - 2) pv /= OLC_BASE;
	}

	let latPrec = pv / OLC_PAIR_PRECISION;
	let lngPrec = pv / OLC_PAIR_PRECISION;
	let gridLat = 0;
	let gridLng = 0;

	if (cleaned.length > 10) {
		let rowPv = 625;
		let colPv = 256;
		for (let i = 10; i < cleaned.length; i++) {
			const d = OLC_ALPHABET.indexOf(cleaned.charAt(i));
			const row = Math.floor(d / OLC_GRID_COLS);
			const col = d % OLC_GRID_COLS;
			gridLat += row * rowPv;
			gridLng += col * colPv;
			if (i < cleaned.length - 1) {
				rowPv /= OLC_GRID_ROWS;
				colPv /= OLC_GRID_COLS;
			}
		}
		latPrec = rowPv / OLC_FINAL_LAT_PRECISION;
		lngPrec = colPv / OLC_FINAL_LNG_PRECISION;
	}

	const latLo = normalLat / OLC_PAIR_PRECISION + gridLat / OLC_FINAL_LAT_PRECISION;
	const lngLo = normalLng / OLC_PAIR_PRECISION + gridLng / OLC_FINAL_LNG_PRECISION;

	return {
		latitudeLo: latLo,
		longitudeLo: lngLo,
		latitudeHi: latLo + latPrec,
		longitudeHi: lngLo + lngPrec,
		latitudeCenter: latLo + latPrec / 2,
		longitudeCenter: lngLo + lngPrec / 2,
		codeLength: cleaned.length,
	};
}

/** Builds a platform-safe `sms:` URI (`&body=` on iOS/iPadOS, `?body=` on Android/Desktop). */
export function buildEmergencySmsHref(
	recipient: string,
	asciiBody: string,
	userAgent = typeof navigator !== "undefined" ? navigator.userAgent : "",
	maxTouchPoints = typeof navigator !== "undefined" ? navigator.maxTouchPoints ?? 0 : 0,
): string {
	const isIOS =
		/iPhone|iPad|iPod/i.test(userAgent) ||
		(/Macintosh/i.test(userAgent) && maxTouchPoints > 1);
	const sep = isIOS ? "&" : "?";
	return `sms:${recipient.trim()}${sep}body=${encodeURIComponent(asciiBody)}`;
}

/** Formats all offline rescue coordinate representations, SMS 113 ASCII payload, and clipboard card. */
export function formatRescueCoordinates(input: RescueCoordinateInput): RescueCoordinateBundle {
	const { lat, lon } = input;
	const ns = lat >= 0 ? "N" : "S";
	const ew = lon >= 0 ? "E" : "W";
	const wgs84Decimal = `${Math.abs(lat).toFixed(5)}° ${ns}, ${Math.abs(lon).toFixed(5)}° ${ew}`;
	const wgs84RawPair = `${lat.toFixed(5)}, ${lon.toFixed(5)}`;
	const wgs84Dms = formatDmsCoordinate(lat, lon);
	const utm = wgs84ToUtm(lat, lon);
	const plusCode = encodePlusCode(lat, lon, 11);

	const eleM =
		input.elevationM !== null &&
		input.elevationM !== undefined &&
		Number.isFinite(input.elevationM)
			? Math.round(input.elevationM)
			: null;
	const accM =
		input.accuracyM !== null &&
		input.accuracyM !== undefined &&
		Number.isFinite(input.accuracyM) &&
		input.accuracyM > 0
			? Math.max(1, Math.round(input.accuracyM))
			: null;

	let nearestLandmark: NearbyLandmarkRef | null = null;
	if (
		input.landmark &&
		Number.isFinite(input.landmark.lat) &&
		Number.isFinite(input.landmark.lon)
	) {
		const distM = Math.round(haversineM(input.landmark.lat, input.landmark.lon, lat, lon));
		const bearing = initialBearingDeg(input.landmark.lat, input.landmark.lon, lat, lon);
		const dirRo = cardinal8Ro(bearing);
		const distText = distM >= 1000 ? `${(distM / 1000).toFixed(1)}km` : `${distM}m`;
		const eleSuffix = input.landmark.eleM ? ` (${Math.round(input.landmark.eleM)}m)` : "";
		const summaryRo = `${distText} ${dirRo} de ${input.landmark.name}${eleSuffix}`;
		const asciiName = stripRomanianDiacritics(input.landmark.name).slice(0, 20).trim();
		nearestLandmark = {
			name: input.landmark.name,
			eleM: input.landmark.eleM ?? null,
			distanceM: distM,
			bearingFromLandmarkRo: dirRo,
			summaryRo,
			summaryAscii: `${distText} ${dirRo} ${asciiName}`,
		};
	}

	const now = input.now ?? new Date();
	const hh = String(now.getHours()).padStart(2, "0");
	const mm = String(now.getMinutes()).padStart(2, "0");
	const reasonClean = stripRomanianDiacritics(input.reasonRo ?? "Urgenta").slice(0, 14);
	const altLine =
		eleM !== null
			? `Alt:${eleM}m${accM !== null ? `(+/-${accM}m)` : ""}`
			: accM !== null
				? `GPS:+/-${accM}m`
				: "GPS:activ";

	const smsLines = [
		`SOS MUNTE [${reasonClean}]`,
		`WGS84:${wgs84RawPair}`,
		altLine,
		`UTM:${utm.zone}${utm.band} ${Math.round(utm.easting)} ${Math.round(utm.northing)}`,
		`Plus:${plusCode}`,
	];
	if (nearestLandmark) {
		smsLines.push(`Reper:${nearestLandmark.summaryAscii}`);
	}
	smsLines.push(`Ora:${hh}:${mm}`);
	const sms113AsciiBody = stripRomanianDiacritics(smsLines.join("\n")).slice(0, 160);

	const cardLines = [
		`FIȘĂ COORDONATE 112 / SALVAMONT`,
		`WGS84: ${wgs84Decimal} (${wgs84RawPair})`,
		`DMS: ${wgs84Dms}`,
		`UTM: ${utm.formatted}`,
		`Plus Code: ${plusCode}`,
		eleM !== null ? `Altitudine: ${eleM} m${accM !== null ? ` (±${accM} m)` : ""}` : "",
		nearestLandmark ? `Reper: ${nearestLandmark.summaryRo}` : "",
		`Ora: ${hh}:${mm}`,
	].filter(Boolean);

	return {
		wgs84Decimal,
		wgs84RawPair,
		wgs84Dms,
		utm,
		plusCode,
		elevationM: eleM,
		accuracyM: accM,
		nearestLandmark,
		sms113AsciiBody,
		clipboardFullCardRo: cardLines.join("\n"),
	};
}
