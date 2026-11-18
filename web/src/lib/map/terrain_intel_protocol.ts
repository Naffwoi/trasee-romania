import * as maplibregl from "maplibre-gl";
import { DemTileGrid } from "#lib/navigation/dem_tile_grid";
import {
	renderAvalancheSlopeTileRgba,
	renderCastShadowTileRgba,
} from "#lib/navigation/slope_aspect";

export interface ParsedTerrainProtocolUrl {
	scheme: "terrain-slope" | "terrain-shade";
	z: number;
	x: number;
	y: number;
	azDeg: number | null;
	altDeg: number | null;
}

let sharedProtocolDem: DemTileGrid | null = null;
let protocolsRegistered = false;
let currentSunAzDeg = 215;
let currentSunAltDeg = 28;

/** Parses `terrain-slope://` or `terrain-shade://` tile URLs with optional sun vector query params. */
export function parseTerrainProtocolUrl(rawUrl: string): ParsedTerrainProtocolUrl | null {
	const m = rawUrl.match(/^(terrain-slope|terrain-shade):\/\/(\d+)\/(\d+)\/(\d+)(?:\?(.*))?$/);
	if (!m) return null;
	const scheme = m[1] as "terrain-slope" | "terrain-shade";
	const z = Number.parseInt(m[2], 10);
	const x = Number.parseInt(m[3], 10);
	const y = Number.parseInt(m[4], 10);
	if (!Number.isFinite(z) || !Number.isFinite(x) || !Number.isFinite(y)) return null;

	let azDeg: number | null = null;
	let altDeg: number | null = null;
	if (m[5]) {
		const sp = new URLSearchParams(m[5]);
		const azRaw = sp.get("az");
		const altRaw = sp.get("alt");
		if (azRaw !== null && Number.isFinite(Number(azRaw))) azDeg = Number(azRaw);
		if (altRaw !== null && Number.isFinite(Number(altRaw))) altDeg = Number(altRaw);
	}
	return { scheme, z, x, y, azDeg, altDeg };
}

/** Quantizes sun azimuth to 2-deg steps and altitude to 1-deg steps to maximize tile cache hits. */
export function quantizeSunTileQuery(azimuthDeg: number, altitudeDeg: number): string {
	const qAz = (((Math.round(azimuthDeg / 2) * 2) % 360) + 360) % 360;
	const qAlt = Math.max(-10, Math.min(90, Math.round(altitudeDeg)));
	return `az=${qAz}&alt=${qAlt}`;
}

/** Updates the active solar vector for `terrain-shade://` and returns its quantized query string. */
export function setTerrainShadeSunVector(azimuthDeg: number, altitudeDeg: number): string {
	currentSunAzDeg = azimuthDeg;
	currentSunAltDeg = altitudeDeg;
	return quantizeSunTileQuery(azimuthDeg, altitudeDeg);
}

async function encodeRgbaToPngArrayBuffer(
	rgba: Uint8ClampedArray,
	size: number,
): Promise<ArrayBuffer> {
	if (typeof OffscreenCanvas !== "undefined") {
		const canvas = new OffscreenCanvas(size, size);
		const ctx = canvas.getContext("2d");
		if (!ctx) return new ArrayBuffer(0);
		ctx.putImageData(new ImageData(new Uint8ClampedArray(rgba), size, size), 0, 0);
		const blob = await canvas.convertToBlob({ type: "image/png" });
		return blob.arrayBuffer();
	}
	if (typeof document !== "undefined") {
		const canvas = document.createElement("canvas");
		canvas.width = size;
		canvas.height = size;
		const ctx = canvas.getContext("2d");
		if (!ctx) return new ArrayBuffer(0);
		ctx.putImageData(new ImageData(new Uint8ClampedArray(rgba), size, size), 0, 0);
		const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
		return blob ? blob.arrayBuffer() : new ArrayBuffer(0);
	}
	return new ArrayBuffer(0);
}

async function ensureZ12Neighborhood(
	dem: DemTileGrid,
	z: number,
	x: number,
	y: number,
): Promise<void> {
	const scale = 1 << Math.max(0, z - 12);
	const z12X = Math.floor(x / scale);
	const z12Y = Math.floor(y / scale);
	const jobs: Promise<unknown>[] = [];
	for (let dy = -1; dy <= 1; dy++) {
		for (let dx = -1; dx <= 1; dx++) {
			jobs.push(dem.ensureTileLoaded(z12X + dx, z12Y + dy));
		}
	}
	await Promise.all(jobs);
}

/** Registers `terrain-slope://` and `terrain-shade://` MapLibre protocols backed by a shared `DemTileGrid`. */
export function registerTerrainIntelProtocols(dem?: DemTileGrid): DemTileGrid {
	if (dem) {
		sharedProtocolDem = dem;
	} else if (!sharedProtocolDem) {
		sharedProtocolDem = new DemTileGrid();
	}
	const activeDem = sharedProtocolDem;

	if (!protocolsRegistered && typeof window !== "undefined") {
		protocolsRegistered = true;

		maplibregl.addProtocol("terrain-slope", async (params) => {
			const parsed = parseTerrainProtocolUrl(params.url);
			if (!parsed || parsed.z < 12) return { data: new ArrayBuffer(0) };
			const grid = sharedProtocolDem ?? activeDem;
			await ensureZ12Neighborhood(grid, parsed.z, parsed.x, parsed.y);
			const rgba = renderAvalancheSlopeTileRgba(parsed.z, parsed.x, parsed.y, grid, 256);
			if (!rgba) return { data: new ArrayBuffer(0) };
			return { data: await encodeRgbaToPngArrayBuffer(rgba, 256) };
		});

		maplibregl.addProtocol("terrain-shade", async (params) => {
			const parsed = parseTerrainProtocolUrl(params.url);
			if (!parsed || parsed.z < 12) return { data: new ArrayBuffer(0) };
			const grid = sharedProtocolDem ?? activeDem;
			await ensureZ12Neighborhood(grid, parsed.z, parsed.x, parsed.y);
			const az = parsed.azDeg ?? currentSunAzDeg;
			const alt = parsed.altDeg ?? currentSunAltDeg;
			const rgba = renderCastShadowTileRgba(parsed.z, parsed.x, parsed.y, grid, az, alt, 256);
			if (!rgba) return { data: new ArrayBuffer(0) };
			return { data: await encodeRgbaToPngArrayBuffer(rgba, 256) };
		});
	}

	return activeDem;
}
