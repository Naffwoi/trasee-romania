import { haversineMeters } from "./geo_math";
import type { NavTrackPoint, OffTrailPoint } from "./types";

export const TRACK_STRIDE = 5; // [lat, lon, ele, distanceM, gradePct]

const DEM16_MAGIC_0 = 0x44; // 'D'
const DEM16_MAGIC_1 = 0x45; // 'E'
const DEM16_MAGIC_2 = 0x4d; // 'M'
const DEM16_MAGIC_3 = 0x36; // '6'

/**
 * Quantizes elevation in meters to signed tenths of a meter (`Int16` range `-3276.8 m .. +3276.7 m`).
 * Covers Dead Sea (`-430 m`) through Carpathians (`0 .. 2,544 m`) with `0.1 m` resolution and clamps safely outside bounds.
 */
export function quantizeElevationMetersToTenths(eleM: number): number {
	if (!Number.isFinite(eleM)) return 0;
	const rounded = Math.round(eleM * 10);
	if (rounded > 32767) return 32767;
	if (rounded < -32768) return -32768;
	return rounded;
}

export function encodeDem16Slab(
	width: number,
	height: number,
	elevationsTenths: Int16Array,
): ArrayBuffer {
	const pixelBytes = width * height * 2;
	const buf = new ArrayBuffer(8 + pixelBytes);
	const header = new DataView(buf, 0, 8);
	header.setUint8(0, DEM16_MAGIC_0);
	header.setUint8(1, DEM16_MAGIC_1);
	header.setUint8(2, DEM16_MAGIC_2);
	header.setUint8(3, DEM16_MAGIC_3);
	header.setUint16(4, width, true);
	header.setUint16(6, height, true);
	new Int16Array(buf, 8, width * height).set(elevationsTenths.subarray(0, width * height));
	return buf;
}

export function decodeDem16Slab(
	buf: ArrayBuffer,
): { width: number; height: number; elevationsTenths: Int16Array } | null {
	if (buf.byteLength < 8) return null;
	const header = new DataView(buf, 0, 8);
	if (
		header.getUint8(0) !== DEM16_MAGIC_0 ||
		header.getUint8(1) !== DEM16_MAGIC_1 ||
		header.getUint8(2) !== DEM16_MAGIC_2 ||
		header.getUint8(3) !== DEM16_MAGIC_3
	) {
		return null;
	}
	const width = header.getUint16(4, true);
	const height = header.getUint16(6, true);
	const expectedBytes = 8 + width * height * 2;
	if (width === 0 || height === 0 || buf.byteLength < expectedBytes) {
		return null;
	}
	return {
		width,
		height,
		elevationsTenths: new Int16Array(buf, 8, width * height),
	};
}

export function packTrackPoints(points: readonly NavTrackPoint[]): Float64Array {
	const out = new Float64Array(points.length * TRACK_STRIDE);
	for (let i = 0; i < points.length; i++) {
		const p = points[i];
		const base = i * TRACK_STRIDE;
		out[base] = p.lat;
		out[base + 1] = p.lon;
		out[base + 2] = p.ele;
		out[base + 3] = p.distanceM;
		out[base + 4] = p.gradePct;
	}
	return out;
}

export function unpackTrackPoints(packed: Float64Array): NavTrackPoint[] {
	const count = Math.floor(packed.length / TRACK_STRIDE);
	const out = new Array<NavTrackPoint>(count);
	for (let i = 0; i < count; i++) {
		const base = i * TRACK_STRIDE;
		out[i] = {
			lat: packed[base],
			lon: packed[base + 1],
			ele: packed[base + 2],
			distanceM: packed[base + 3],
			gradePct: packed[base + 4],
		};
	}
	return out;
}

export function reversePackedTrackPoints(packed: Float64Array): Float64Array {
	const count = Math.floor(packed.length / TRACK_STRIDE);
	if (count === 0) return new Float64Array(0);
	const out = new Float64Array(count * TRACK_STRIDE);
	const totalDist = packed[(count - 1) * TRACK_STRIDE + 3];

	for (let i = 0; i < count; i++) {
		const srcIdx = count - 1 - i;
		const srcBase = srcIdx * TRACK_STRIDE;
		const dstBase = i * TRACK_STRIDE;
		out[dstBase] = packed[srcBase];
		out[dstBase + 1] = packed[srcBase + 1];
		out[dstBase + 2] = packed[srcBase + 2];
		out[dstBase + 3] = i === 0 ? 0 : Math.max(0, totalDist - packed[srcBase + 3]);
		out[dstBase + 4] = 0;
	}

	const rawEles = new Float64Array(count);
	for (let i = 0; i < count; i++) rawEles[i] = out[i * TRACK_STRIDE + 2];
	const smoothEles = new Float64Array(count);
	for (let i = 0; i < count; i++) {
		const radius = Math.min(2, i, count - 1 - i);
		let sum = 0;
		for (let k = i - radius; k <= i + radius; k++) {
			sum += rawEles[k];
		}
		smoothEles[i] = sum / (2 * radius + 1);
	}

	for (let i = 0; i < count; i++) {
		if (count < 2) {
			out[i * TRACK_STRIDE + 4] = 0;
			continue;
		}
		if (i > 0 && out[i * TRACK_STRIDE + 3] - out[(i - 1) * TRACK_STRIDE + 3] >= 15) {
			const run = out[i * TRACK_STRIDE + 3] - out[(i - 1) * TRACK_STRIDE + 3];
			out[i * TRACK_STRIDE + 4] = ((smoothEles[i] - smoothEles[i - 1]) / run) * 100;
			continue;
		}
		let i0 = i;
		while (i0 > 0 && out[i * TRACK_STRIDE + 3] - out[i0 * TRACK_STRIDE + 3] < 15) i0--;
		let i1 = i;
		while (i1 < count - 1 && out[i1 * TRACK_STRIDE + 3] - out[i * TRACK_STRIDE + 3] < 15) i1++;
		const run = out[i1 * TRACK_STRIDE + 3] - out[i0 * TRACK_STRIDE + 3];
		out[i * TRACK_STRIDE + 4] = run > 0.5 ? ((smoothEles[i1] - smoothEles[i0]) / run) * 100 : 0;
	}
	return out;
}

export function packOffTrailPoints(points: readonly OffTrailPoint[]): Float32Array {
	const out = new Float32Array(points.length * TRACK_STRIDE);
	for (let i = 0; i < points.length; i++) {
		const p = points[i];
		const base = i * TRACK_STRIDE;
		out[base] = p.lat;
		out[base + 1] = p.lon;
		out[base + 2] = p.ele;
		out[base + 3] = p.distanceM;
		out[base + 4] = p.gradePct;
	}
	return out;
}

export function unpackOffTrailPoints(packed: Float32Array): OffTrailPoint[] {
	const count = Math.floor(packed.length / TRACK_STRIDE);
	const out = new Array<OffTrailPoint>(count);
	for (let i = 0; i < count; i++) {
		const base = i * TRACK_STRIDE;
		out[i] = {
			lat: packed[base],
			lon: packed[base + 1],
			ele: packed[base + 2],
			distanceM: packed[base + 3],
			gradePct: packed[base + 4],
		};
	}
	return out;
}

const ATTR_LAT_RE = /\blat\s*=\s*(?:"([^"]+)"|'([^']+)')/;
const ATTR_LON_RE = /\blon\s*=\s*(?:"([^"]+)"|'([^']+)')/;
const ELE_TAG_RE = /<(?:[\w.-]+:)?ele[^>]*>([^<]*)<\/(?:[\w.-]+:)?ele>/;

/**
 * Zero-DOM streaming GPX track/route extractor. Scans `<trkpt>` (or `<rtept>` fallback) blocks
 * directly into contiguous typed buffers, avoiding `DOMParser` + `xml2js` 25 MB object graphs.
 */
export function parseGpxXmlFastToPackedTrack(xml: string): Float64Array {
	const hasTrkPt = /<(?:[\w.-]+:)?trkpt[\s>]/.test(xml);
	const tagRegex = hasTrkPt
		? /<(?:[\w.-]+:)?trkpt\b([^>]*?)(?:\/>|>([\s\S]*?)<\/(?:[\w.-]+:)?trkpt>)/g
		: /<(?:[\w.-]+:)?rtept\b([^>]*?)(?:\/>|>([\s\S]*?)<\/(?:[\w.-]+:)?rtept>)/g;

	const lats: number[] = [];
	const lons: number[] = [];
	const eles: number[] = [];
	let lastValidEle = 0;
	let hasAnyEle = false;

	for (const match of xml.matchAll(tagRegex)) {
		const attrs = match[1] ?? "";
		const inner = match[2] ?? "";
		const latMatch = ATTR_LAT_RE.exec(attrs);
		const lonMatch = ATTR_LON_RE.exec(attrs);
		if (!latMatch || !lonMatch) continue;
		const lat = Number(latMatch[1] ?? latMatch[2]);
		const lon = Number(lonMatch[1] ?? lonMatch[2]);
		if (!Number.isFinite(lat) || !Number.isFinite(lon)) continue;
		if (Math.abs(lat) > 90 || Math.abs(lon) > 180) continue;

		let ele = lastValidEle;
		if (inner.length > 0) {
			const eleMatch = ELE_TAG_RE.exec(inner);
			if (eleMatch) {
				const parsedEle = Number(eleMatch[1].trim());
				if (Number.isFinite(parsedEle)) {
					ele = parsedEle;
					lastValidEle = parsedEle;
					hasAnyEle = true;
				}
			}
		}

		if (
			lats.length > 0 &&
			Math.abs(lats[lats.length - 1] - lat) < 1e-9 &&
			Math.abs(lons[lons.length - 1] - lon) < 1e-9
		) {
			continue;
		}

		lats.push(lat);
		lons.push(lon);
		eles.push(ele);
	}

	const n = lats.length;
	if (n === 0) return new Float64Array(0);

	if (hasAnyEle) {
		let firstKnown = 0;
		for (let i = 0; i < n; i++) {
			if (eles[i] !== 0) {
				firstKnown = eles[i];
				break;
			}
		}
		for (let i = 0; i < n && eles[i] === 0; i++) {
			eles[i] = firstKnown;
		}
	}

	const dists = new Float64Array(n);
	for (let i = 1; i < n; i++) {
		dists[i] = dists[i - 1] + haversineMeters(lats[i - 1], lons[i - 1], lats[i], lons[i]);
	}

	const smoothEles = new Float64Array(n);
	for (let i = 0; i < n; i++) {
		const radius = Math.min(2, i, n - 1 - i);
		let sum = 0;
		for (let k = i - radius; k <= i + radius; k++) {
			sum += eles[k];
		}
		smoothEles[i] = sum / (2 * radius + 1);
	}

	const out = new Float64Array(n * TRACK_STRIDE);
	for (let i = 0; i < n; i++) {
		let gradePct = 0;
		if (n >= 2) {
			if (i > 0 && dists[i] - dists[i - 1] >= 15) {
				const run = dists[i] - dists[i - 1];
				gradePct = ((smoothEles[i] - smoothEles[i - 1]) / run) * 100;
			} else {
				let i0 = i;
				while (i0 > 0 && dists[i] - dists[i0] < 15) i0--;
				let i1 = i;
				while (i1 < n - 1 && dists[i1] - dists[i] < 15) i1++;
				const run = dists[i1] - dists[i0];
				gradePct = run > 0.5 ? ((smoothEles[i1] - smoothEles[i0]) / run) * 100 : 0;
			}
			gradePct = Math.min(100, Math.max(-100, gradePct));
		}
		const base = i * TRACK_STRIDE;
		out[base] = lats[i];
		out[base + 1] = lons[i];
		out[base + 2] = eles[i];
		out[base + 3] = dists[i];
		out[base + 4] = gradePct;
	}
	return out;
}
