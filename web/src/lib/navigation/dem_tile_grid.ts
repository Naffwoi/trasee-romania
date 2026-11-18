import {
	decodeDem16Slab,
	encodeDem16Slab,
	quantizeElevationMetersToTenths,
} from "./nav_terrain_codec";

const ZOOM = 12;
const NUM_TILES = 1 << ZOOM; // 4096
const MAX_MERCATOR_LAT = 85.05112878;
const DEFAULT_TILE_URL = "https://tiles.mapterhorn.com/12/{x}/{y}.webp";
const CACHE_NAME = "wanderer-dem-v1";
const SLAB_CACHE_NAME = "wanderer-dem16-v1";
const MAX_PREFETCH_TILES = 9;
const MAX_LRU_TILES = 48;
const WGS84_EQUATORIAL_CIRCUMFERENCE_M = 2 * Math.PI * 6378137.0;

export interface DecodedTile {
	width: number;
	height: number;
	elevationsTenths: Int16Array;
}

export interface DecodedTileInput {
	width: number;
	height: number;
	elevationsTenths?: Int16Array;
	elevations?: Float32Array;
}

export function webMercatorRowCellSizeMeters(
	zoom: number,
	tileY: number,
	row: number,
	tileSize: number,
): number {
	const numTiles = 1 << zoom;
	const yNorm = (tileY + (row + 0.5) / tileSize) / numTiles;
	const latRad = Math.atan(Math.sinh(Math.PI * (1 - 2 * yNorm)));
	return (WGS84_EQUATORIAL_CIRCUMFERENCE_M * Math.cos(latRad)) / (tileSize * numTiles);
}

function clampLat(lat: number): number {
	return Math.min(MAX_MERCATOR_LAT, Math.max(-MAX_MERCATOR_LAT, lat));
}

export function latLonToZ12TileFloat(lat: number, lon: number): { xFloat: number; yFloat: number } {
	const cLat = clampLat(lat);
	const wrappedLon = ((((lon + 180) % 360) + 360) % 360) - 180;
	const xFloat = ((wrappedLon + 180) / 360) * NUM_TILES;
	const latRad = (cLat * Math.PI) / 180;
	const yFloat =
		((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * NUM_TILES;
	return {
		xFloat: Math.min(NUM_TILES - 1e-9, Math.max(0, xFloat)),
		yFloat: Math.min(NUM_TILES - 1e-9, Math.max(0, yFloat)),
	};
}

function decodeTerrariumPixelsToTenths(
	rgba: Uint8ClampedArray,
	width: number,
	height: number,
): DecodedTile {
	const count = width * height;
	const elevationsTenths = new Int16Array(count);
	for (let i = 0; i < count; i++) {
		const offset = i * 4;
		const r = rgba[offset];
		const g = rgba[offset + 1];
		const b = rgba[offset + 2];
		const meters = r * 256 + g + b / 256 - 32768;
		elevationsTenths[i] = quantizeElevationMetersToTenths(meters);
	}
	return { width, height, elevationsTenths };
}

async function decodeBlobToRgba(
	blob: Blob,
): Promise<{ data: Uint8ClampedArray; width: number; height: number } | null> {
	if (typeof createImageBitmap === "function") {
		let bitmap: ImageBitmap | null = null;
		try {
			bitmap = await createImageBitmap(blob);
			const width = bitmap.width;
			const height = bitmap.height;

			if (typeof OffscreenCanvas !== "undefined") {
				const canvas = new OffscreenCanvas(width, height);
				const ctx = canvas.getContext("2d");
				if (!ctx) return null;
				ctx.drawImage(bitmap, 0, 0);
				const imgData = ctx.getImageData(0, 0, width, height);
				return { data: imgData.data, width, height };
			}

			if (typeof document !== "undefined") {
				const canvas = document.createElement("canvas");
				canvas.width = width;
				canvas.height = height;
				const ctx = canvas.getContext("2d");
				if (!ctx) return null;
				ctx.drawImage(bitmap, 0, 0);
				const imgData = ctx.getImageData(0, 0, width, height);
				return { data: imgData.data, width, height };
			}
		} catch {
			return null;
		} finally {
			bitmap?.close?.();
		}
	}

	if (
		typeof document !== "undefined" &&
		typeof URL !== "undefined" &&
		typeof Image !== "undefined"
	) {
		const objectUrl = URL.createObjectURL(blob);
		try {
			const img = await new Promise<HTMLImageElement>((resolve, reject) => {
				const el = new Image();
				el.onload = () => resolve(el);
				el.onerror = () => reject(new Error("dem_image_decode_failed"));
				el.src = objectUrl;
			});
			const width = img.naturalWidth || 512;
			const height = img.naturalHeight || 512;
			const canvas = document.createElement("canvas");
			canvas.width = width;
			canvas.height = height;
			const ctx = canvas.getContext("2d");
			if (!ctx) return null;
			ctx.drawImage(img, 0, 0);
			const imgData = ctx.getImageData(0, 0, width, height);
			return { data: imgData.data, width, height };
		} catch {
			return null;
		} finally {
			URL.revokeObjectURL(objectUrl);
		}
	}

	return null;
}

/**
 * Zoom-12 Mapterhorn Terrarium WebP DEM tile grid with `.dem16` quantized `Int16Array`
 * (`0.1 m`, `524 KB/tile` = `-50%` RAM) slabs, CacheStorage persistence, Web Worker
 * & SSR safety guards, and seamless cross-tile bilinear/pixel elevation interpolation.
 */
export class DemTileGrid {
	private readonly customSampler?: (lat: number, lon: number) => number | null;
	private readonly tileUrlTemplate: string;
	private readonly tiles = new Map<string, DecodedTile>();
	private readonly inFlight = new Map<string, Promise<void>>();

	constructor(options?: {
		customSampler?: (lat: number, lon: number) => number | null;
		tileUrlTemplate?: string;
	}) {
		this.customSampler = options?.customSampler;
		this.tileUrlTemplate = options?.tileUrlTemplate ?? DEFAULT_TILE_URL;
	}

	private putTileLru(key: string, tile: DecodedTile): void {
		this.tiles.delete(key);
		this.tiles.set(key, tile);
		while (this.tiles.size > MAX_LRU_TILES) {
			const oldest = this.tiles.keys().next().value;
			if (!oldest) break;
			this.tiles.delete(oldest);
		}
	}

	putDecodedTileForTest(x: number, y: number, tile: DecodedTileInput): void {
		const wrappedX = ((x % NUM_TILES) + NUM_TILES) % NUM_TILES;
		let tenths: Int16Array;
		if (tile.elevationsTenths) {
			tenths = tile.elevationsTenths;
		} else if (tile.elevations) {
			tenths = new Int16Array(tile.elevations.length);
			for (let i = 0; i < tile.elevations.length; i++) {
				tenths[i] = quantizeElevationMetersToTenths(tile.elevations[i]);
			}
		} else {
			tenths = new Int16Array(tile.width * tile.height);
		}
		this.putTileLru(`${ZOOM}/${wrappedX}/${y}`, {
			width: tile.width,
			height: tile.height,
			elevationsTenths: tenths,
		});
	}

	getDecodedTile(x: number, y: number): DecodedTile | undefined {
		if (y < 0 || y >= NUM_TILES) return undefined;
		const wrappedX = ((x % NUM_TILES) + NUM_TILES) % NUM_TILES;
		const key = `${ZOOM}/${wrappedX}/${y}`;
		const hit = this.tiles.get(key);
		if (hit) {
			this.tiles.delete(key);
			this.tiles.set(key, hit);
		}
		return hit;
	}

	async ensureTileLoaded(x: number, y: number): Promise<DecodedTile | undefined> {
		if (y < 0 || y >= NUM_TILES) return undefined;
		const wrappedX = ((x % NUM_TILES) + NUM_TILES) % NUM_TILES;
		await this.loadTile(wrappedX, y);
		return this.getDecodedTile(wrappedX, y);
	}

	async prefetchRadius(
		lat: number,
		lon: number,
		radiusM = 20_000,
		maxTiles = 36,
	): Promise<void> {
		if (this.customSampler || !Number.isFinite(lat) || !Number.isFinite(lon)) {
			return;
		}
		if (
			typeof fetch !== "function" ||
			(typeof createImageBitmap !== "function" && typeof document === "undefined")
		) {
			return;
		}
		const safeRadius = Math.min(40_000, Math.max(500, radiusM));
		const latPad = safeRadius / 111320;
		const cosLat = Math.max(0.1, Math.cos((lat * Math.PI) / 180));
		const lonPad = safeRadius / (111320 * cosLat);
		const center = latLonToZ12TileFloat(lat, lon);
		const tl = latLonToZ12TileFloat(lat + latPad, lon - lonPad);
		const br = latLonToZ12TileFloat(lat - latPad, lon + lonPad);

		const candidates: { x: number; y: number; distSq: number }[] = [];
		for (let ty = Math.floor(tl.yFloat); ty <= Math.floor(br.yFloat); ty++) {
			if (ty < 0 || ty >= NUM_TILES) continue;
			for (let tx = Math.floor(tl.xFloat); tx <= Math.floor(br.xFloat); tx++) {
				const wrappedX = ((tx % NUM_TILES) + NUM_TILES) % NUM_TILES;
				const dx = tx + 0.5 - center.xFloat;
				const dy = ty + 0.5 - center.yFloat;
				candidates.push({ x: wrappedX, y: ty, distSq: dx * dx + dy * dy });
			}
		}
		candidates.sort((a, b) => a.distSq - b.distSq);
		const chosen = candidates.slice(0, Math.max(1, Math.min(MAX_LRU_TILES, maxTiles)));
		await Promise.all(chosen.map(({ x, y }) => this.loadTile(x, y)));
	}

	samplePixelStitched(
		baseTileX: number,
		baseTileY: number,
		localX: number,
		localY: number,
	): number | null {
		const primary = this.getDecodedTile(baseTileX, baseTileY);
		if (!primary) return null;
		return this.samplePixel(baseTileX, baseTileY, localX, localY, primary);
	}

	async prefetchCorridor(
		points: { lat: number; lon: number }[],
		bufferM = 1500,
	): Promise<void> {
		if (this.customSampler || points.length === 0) {
			return;
		}
		if (
			typeof fetch !== "function" ||
			(typeof createImageBitmap !== "function" && typeof document === "undefined")
		) {
			return;
		}

		const safeBufferM = Math.max(0, Number.isFinite(bufferM) ? bufferM : 1500);
		const seen = new Set<string>();
		const tileCoords: { x: number; y: number }[] = [];

		const addTile = (tx: number, ty: number): boolean => {
			if (ty < 0 || ty >= NUM_TILES) return false;
			const wrappedX = ((tx % NUM_TILES) + NUM_TILES) % NUM_TILES;
			const key = `${ZOOM}/${wrappedX}/${ty}`;
			if (seen.has(key)) return false;
			seen.add(key);
			tileCoords.push({ x: wrappedX, y: ty });
			return tileCoords.length >= MAX_PREFETCH_TILES;
		};

		// Pass 1: prioritize tiles directly under the corridor points.
		const validPts: { lat: number; lon: number; cx: number; cy: number }[] = [];
		for (const pt of points) {
			if (!Number.isFinite(pt.lat) || !Number.isFinite(pt.lon)) continue;
			const { xFloat, yFloat } = latLonToZ12TileFloat(pt.lat, pt.lon);
			const cx = Math.floor(xFloat);
			const cy = Math.floor(yFloat);
			validPts.push({ lat: pt.lat, lon: pt.lon, cx, cy });
			if (addTile(cx, cy)) break;
		}

		// Pass 2: expand outward into buffer tiles closest to corridor points up to MAX_PREFETCH_TILES.
		if (tileCoords.length < MAX_PREFETCH_TILES && safeBufferM > 0) {
			const candidateList: { x: number; y: number; distSq: number }[] = [];
			const candSeen = new Set<string>(seen);

			for (const pt of validPts) {
				const latPad = safeBufferM / 111320;
				const cosLat = Math.max(0.1, Math.cos((pt.lat * Math.PI) / 180));
				const lonPad = safeBufferM / (111320 * cosLat);
				const tl = latLonToZ12TileFloat(pt.lat + latPad, pt.lon - lonPad);
				const br = latLonToZ12TileFloat(pt.lat - latPad, pt.lon + lonPad);

				const minX = Math.floor(tl.xFloat);
				const maxX = Math.floor(br.xFloat);
				const minY = Math.floor(tl.yFloat);
				const maxY = Math.floor(br.yFloat);

				for (let ty = minY; ty <= maxY; ty++) {
					if (ty < 0 || ty >= NUM_TILES) continue;
					for (let tx = minX; tx <= maxX; tx++) {
						const wrappedX = ((tx % NUM_TILES) + NUM_TILES) % NUM_TILES;
						const key = `${ZOOM}/${wrappedX}/${ty}`;
						if (candSeen.has(key)) continue;
						candSeen.add(key);
						const dx = tx - pt.cx;
						const dy = ty - pt.cy;
						candidateList.push({ x: wrappedX, y: ty, distSq: dx * dx + dy * dy });
					}
				}
			}

			candidateList.sort((a, b) => a.distSq - b.distSq);
			for (const c of candidateList) {
				if (addTile(c.x, c.y)) break;
			}
		}

		await Promise.all(tileCoords.map(({ x, y }) => this.loadTile(x, y)));
	}

	sampleElevation(lat: number, lon: number): number | null {
		if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
			return null;
		}

		if (this.customSampler) {
			return this.customSampler(lat, lon);
		}

		const { xFloat, yFloat } = latLonToZ12TileFloat(lat, lon);
		const tileX = Math.floor(xFloat);
		const tileY = Math.floor(yFloat);
		const primaryKey = `${ZOOM}/${tileX}/${tileY}`;
		const primaryTile = this.tiles.get(primaryKey);
		if (!primaryTile) {
			return null;
		}

		const w = primaryTile.width;
		const h = primaryTile.height;
		const px = (xFloat - tileX) * w - 0.5;
		const py = (yFloat - tileY) * h - 0.5;

		const x0 = Math.floor(px);
		const y0 = Math.floor(py);
		const fx = px - x0;
		const fy = py - y0;

		const e00 = this.samplePixel(tileX, tileY, x0, y0, primaryTile);
		const e10 = this.samplePixel(tileX, tileY, x0 + 1, y0, primaryTile);
		const e01 = this.samplePixel(tileX, tileY, x0, y0 + 1, primaryTile);
		const e11 = this.samplePixel(tileX, tileY, x0 + 1, y0 + 1, primaryTile);

		const top = e00 * (1 - fx) + e10 * fx;
		const bottom = e01 * (1 - fx) + e11 * fx;
		return top * (1 - fy) + bottom * fy;
	}

	private samplePixel(
		baseTileX: number,
		baseTileY: number,
		localX: number,
		localY: number,
		fallbackTile: DecodedTile,
	): number {
		const w = fallbackTile.width;
		const h = fallbackTile.height;

		let tx = baseTileX;
		let ty = baseTileY;
		let lx = localX;
		let ly = localY;

		if (lx < 0) {
			tx = ((tx - 1) % NUM_TILES + NUM_TILES) % NUM_TILES;
			lx += w;
		} else if (lx >= w) {
			tx = (tx + 1) % NUM_TILES;
			lx -= w;
		}

		if (ly < 0) {
			ty -= 1;
			ly += h;
		} else if (ly >= h) {
			ty += 1;
			ly -= h;
		}

		const neighbor =
			tx === baseTileX && ty === baseTileY
				? fallbackTile
				: this.tiles.get(`${ZOOM}/${tx}/${ty}`);

		if (neighbor && lx >= 0 && lx < neighbor.width && ly >= 0 && ly < neighbor.height) {
			return neighbor.elevationsTenths[ly * neighbor.width + lx] * 0.1;
		}

		const cx = Math.min(w - 1, Math.max(0, localX));
		const cy = Math.min(h - 1, Math.max(0, localY));
		return fallbackTile.elevationsTenths[cy * w + cx] * 0.1;
	}

	private async loadTile(x: number, y: number): Promise<void> {
		const key = `${ZOOM}/${x}/${y}`;
		if (this.tiles.has(key)) {
			return;
		}
		const existing = this.inFlight.get(key);
		if (existing) {
			return existing;
		}

		const url = this.tileUrlTemplate
			.replace("{z}", String(ZOOM))
			.replace("{x}", String(x))
			.replace("{y}", String(y));
		const slabUrl = `${url}#dem16`;

		const promise = (async () => {
			try {
				let slabCache: Cache | null = null;
				if (typeof caches !== "undefined") {
					try {
						slabCache = await caches.open(SLAB_CACHE_NAME);
						const cachedSlabRes = await slabCache.match(slabUrl);
						if (cachedSlabRes) {
							const decodedSlab = decodeDem16Slab(await cachedSlabRes.arrayBuffer());
							if (decodedSlab) {
								this.putTileLru(key, decodedSlab);
								return;
							}
						}
					} catch {
						slabCache = null;
					}
				}

				let response: Response | undefined;
				let cache: Cache | null = null;
				if (typeof caches !== "undefined") {
					try {
						cache = await caches.open(CACHE_NAME);
						response = (await cache.match(url)) ?? undefined;
					} catch {
						cache = null;
					}
				}

				if (!response) {
					const fetched = await fetch(url);
					if (!fetched.ok) return;
					response = fetched;
					if (cache) {
						try {
							await cache.put(url, fetched.clone());
						} catch {
							// Ignore CacheStorage quota or opaque errors.
						}
					}
				}

				const blob = await response.blob();
				const decoded = await decodeBlobToRgba(blob);
				if (!decoded) return;
				const tile = decodeTerrariumPixelsToTenths(decoded.data, decoded.width, decoded.height);
				this.putTileLru(key, tile);

				if (slabCache) {
					try {
						const slabBuf = encodeDem16Slab(tile.width, tile.height, tile.elevationsTenths);
						await slabCache.put(
							slabUrl,
							new Response(slabBuf, {
								headers: { "Content-Type": "application/octet-stream" },
							}),
						);
					} catch {
						// Ignore CacheStorage quota limits.
					}
				}
			} catch {
				// Gracefully degrade to null elevation when offline or tile blocked.
			} finally {
				this.inFlight.delete(key);
			}
		})();

		this.inFlight.set(key, promise);
		return promise;
	}
}
