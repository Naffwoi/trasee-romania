import {
	type DemTileGrid,
	latLonToZ12TileFloat,
	webMercatorRowCellSizeMeters,
} from "./dem_tile_grid";

const RAD_TO_DEG = 180 / Math.PI;
const DEG_TO_RAD = Math.PI / 180;
const DEM_ZOOM = 12;

export interface SlopeAspectSample {
	slopeDeg: number;
	aspectDeg: number;
}

/**
 * Standard EAWS / CalTopo avalanche slope angle color ramp with 0.5-deg linear edge feathering.
 */
export function avalancheSlopeColorRgba(slopeDeg: number): [number, number, number, number] {
	if (!Number.isFinite(slopeDeg) || slopeDeg < 26.75) {
		return [0, 0, 0, 0];
	}
	if (slopeDeg < 27.25) {
		const t = (slopeDeg - 26.75) / 0.5;
		return [234, 179, 8, Math.round(115 * t)];
	}
	if (slopeDeg < 30.0) {
		return [234, 179, 8, 115];
	}
	if (slopeDeg < 35.0) {
		return [249, 115, 22, 140];
	}
	if (slopeDeg < 45.0) {
		return [220, 38, 38, 158];
	}
	if (slopeDeg < 50.0) {
		return [147, 51, 234, 165];
	}
	return [29, 78, 216, 175];
}

function mapChildTileToZ12Window(z: number, x: number, y: number): {
	z12X: number;
	z12Y: number;
	u0: number;
	v0: number;
	span: number;
} | null {
	if (z < DEM_ZOOM) return null;
	const scale = 1 << (z - DEM_ZOOM);
	const z12X = Math.floor(x / scale);
	const z12Y = Math.floor(y / scale);
	const span = 1 / scale;
	const u0 = (x - z12X * scale) * span;
	const v0 = (y - z12Y * scale) * span;
	return { z12X, z12Y, u0, v0, span };
}

/** Samples Horn 3x3 slope angle and aspect at a given lat/lon using Web Mercator row cell sizing. */
export function sampleSlopeAndAspect(
	dem: DemTileGrid,
	lat: number,
	lon: number,
): SlopeAspectSample | null {
	const { xFloat, yFloat } = latLonToZ12TileFloat(lat, lon);
	const tx = Math.floor(xFloat);
	const ty = Math.floor(yFloat);
	const tile = dem.getDecodedTile(tx, ty);
	if (!tile) return null;

	const w = tile.width;
	const h = tile.height;
	const col = Math.min(w - 1, Math.max(0, Math.floor((xFloat - tx) * w)));
	const row = Math.min(h - 1, Math.max(0, Math.floor((yFloat - ty) * h)));
	const cellM = webMercatorRowCellSizeMeters(DEM_ZOOM, ty, row, w);

	const nw = dem.samplePixelStitched(tx, ty, col - 1, row - 1)!;
	const n = dem.samplePixelStitched(tx, ty, col, row - 1)!;
	const ne = dem.samplePixelStitched(tx, ty, col + 1, row - 1)!;
	const wPx = dem.samplePixelStitched(tx, ty, col - 1, row)!;
	const ePx = dem.samplePixelStitched(tx, ty, col + 1, row)!;
	const sw = dem.samplePixelStitched(tx, ty, col - 1, row + 1)!;
	const s = dem.samplePixelStitched(tx, ty, col, row + 1)!;
	const se = dem.samplePixelStitched(tx, ty, col + 1, row + 1)!;

	const dzdx = (ne + 2 * ePx + se - (nw + 2 * wPx + sw)) / (8 * cellM);
	const dzdy = (sw + 2 * s + se - (nw + 2 * n + ne)) / (8 * cellM);
	const slopeDeg = Math.atan(Math.hypot(dzdx, dzdy)) * RAD_TO_DEG;
	const aspectDeg = ((Math.atan2(-dzdx, dzdy) * RAD_TO_DEG) + 360) % 360;
	return { slopeDeg, aspectDeg };
}

/**
 * Renders an RGBA avalanche slope tile using Horn's 3x3 finite-difference operator
 * with Mercator latitude cell-size correction and seamless cross-tile neighbor sampling.
 */
export function renderAvalancheSlopeTileRgba(
	z: number,
	x: number,
	y: number,
	dem: DemTileGrid,
	outSize: 256 | 512 = 256,
): Uint8ClampedArray | null {
	const win = mapChildTileToZ12Window(z, x, y);
	if (!win) return null;
	const baseTile = dem.getDecodedTile(win.z12X, win.z12Y);
	if (!baseTile) return null;

	const srcW = baseTile.width;
	const srcH = baseTile.height;
	const out = new Uint8ClampedArray(outSize * outSize * 4);

	for (let rOut = 0; rOut < outSize; rOut++) {
		const v = win.v0 + ((rOut + 0.5) / outSize) * win.span;
		const srcRow = Math.min(srcH - 1, Math.max(0, Math.round(v * srcH - 0.5)));
		const inv8Cell = 1 / (8 * webMercatorRowCellSizeMeters(DEM_ZOOM, win.z12Y, srcRow, srcW));

		for (let cOut = 0; cOut < outSize; cOut++) {
			const u = win.u0 + ((cOut + 0.5) / outSize) * win.span;
			const srcCol = Math.min(srcW - 1, Math.max(0, Math.round(u * srcW - 0.5)));

			const nw = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol - 1, srcRow - 1)!;
			const n = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol, srcRow - 1)!;
			const ne = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol + 1, srcRow - 1)!;
			const wPx = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol - 1, srcRow)!;
			const ePx = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol + 1, srcRow)!;
			const sw = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol - 1, srcRow + 1)!;
			const s = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol, srcRow + 1)!;
			const se = dem.samplePixelStitched(win.z12X, win.z12Y, srcCol + 1, srcRow + 1)!;

			const dzdx = (ne + 2 * ePx + se - (nw + 2 * wPx + sw)) * inv8Cell;
			const dzdy = (sw + 2 * s + se - (nw + 2 * n + ne)) * inv8Cell;
			const slopeDeg = Math.atan(Math.hypot(dzdx, dzdy)) * RAD_TO_DEG;

			const [cr, cg, cb, ca] = avalancheSlopeColorRgba(slopeDeg);
			const offset = (rOut * outSize + cOut) * 4;
			out[offset] = cr;
			out[offset + 1] = cg;
			out[offset + 2] = cb;
			out[offset + 3] = ca;
		}
	}
	return out;
}

/**
 * O(N^2) forward scanline horizon-ceiling propagation for cast mountain shadows on zoom-12 DEMs.
 */
export function renderCastShadowTileRgba(
	z: number,
	x: number,
	y: number,
	dem: DemTileGrid,
	sunAzimuthDeg: number,
	sunAltitudeDeg: number,
	outSize: 256 = 256,
): Uint8ClampedArray | null {
	const win = mapChildTileToZ12Window(z, x, y);
	if (!win) return null;
	const baseTile = dem.getDecodedTile(win.z12X, win.z12Y);
	if (!baseTile) return null;

	const out = new Uint8ClampedArray(outSize * outSize * 4);
	if (sunAltitudeDeg <= -0.833) {
		for (let i = 0; i < out.length; i += 4) {
			out[i] = 15;
			out[i + 1] = 23;
			out[i + 2] = 42;
			out[i + 3] = 130;
		}
		return out;
	}

	const srcW = baseTile.width;
	const srcH = baseTile.height;
	const decimate = Math.max(1, Math.round(srcW / outSize));
	const pad = outSize;
	const gridN = outSize * 2;
	const azRad = sunAzimuthDeg * DEG_TO_RAD;
	const sunDirX = Math.sin(azRad);
	const sunDirY = -Math.cos(azRad);

	const padOffsetCol = sunDirX >= 0 ? 0 : -pad;
	const padOffsetRow = sunDirY >= 0 ? 0 : -pad;

	const dxTile = sunDirX >= 0 ? 1 : -1;
	const dyTile = sunDirY >= 0 ? 1 : -1;
	const nxX = ((win.z12X + dxTile) % 4096 + 4096) % 4096;
	const nyY = win.z12Y + dyTile;
	const baseData = baseTile.elevationsTenths;
	const tileXNeighbor = dem.getDecodedTile(nxX, win.z12Y);
	const tileYNeighbor = nyY >= 0 && nyY < 4096 ? dem.getDecodedTile(win.z12X, nyY) : undefined;
	const tileXYNeighbor = nyY >= 0 && nyY < 4096 ? dem.getDecodedTile(nxX, nyY) : undefined;

	const elevGrid = new Float32Array(gridN * gridN);
	for (let gr = 0; gr < gridN; gr++) {
		const srcRow = (gr + padOffsetRow) * decimate;
		const inNeighborY = srcRow < 0 || srcRow >= srcH;
		const localY = inNeighborY ? (srcRow < 0 ? srcRow + srcH : srcRow - srcH) : srcRow;
		const clampY = srcRow < 0 ? 0 : srcRow >= srcH ? srcH - 1 : srcRow;
		const rowOffsetOut = gr * gridN;

		for (let gc = 0; gc < gridN; gc++) {
			const srcCol = (gc + padOffsetCol) * decimate;
			const inNeighborX = srcCol < 0 || srcCol >= srcW;
			const localX = inNeighborX ? (srcCol < 0 ? srcCol + srcW : srcCol - srcW) : srcCol;
			const clampX = srcCol < 0 ? 0 : srcCol >= srcW ? srcW - 1 : srcCol;

			let tenths: number;
			if (!inNeighborX && !inNeighborY) {
				tenths = baseData[srcRow * srcW + srcCol];
			} else if (inNeighborX && !inNeighborY) {
				tenths =
					tileXNeighbor && localX < tileXNeighbor.width && srcRow < tileXNeighbor.height
						? tileXNeighbor.elevationsTenths[srcRow * tileXNeighbor.width + localX]
						: baseData[srcRow * srcW + clampX];
			} else if (!inNeighborX && inNeighborY) {
				tenths =
					tileYNeighbor && srcCol < tileYNeighbor.width && localY < tileYNeighbor.height
						? tileYNeighbor.elevationsTenths[localY * tileYNeighbor.width + srcCol]
						: baseData[clampY * srcW + srcCol];
			} else {
				tenths =
					tileXYNeighbor && localX < tileXYNeighbor.width && localY < tileXYNeighbor.height
						? tileXYNeighbor.elevationsTenths[localY * tileXYNeighbor.width + localX]
						: baseData[clampY * srcW + clampX];
			}
			elevGrid[rowOffsetOut + gc] = tenths * 0.1;
		}
	}

	const cellM = webMercatorRowCellSizeMeters(DEM_ZOOM, win.z12Y, Math.floor(srcW / 2), outSize);
	const tanAlt = Math.tan(Math.max(0.5, sunAltitudeDeg) * DEG_TO_RAD);

	const ceiling = new Float32Array(elevGrid);

	const downX = -sunDirX;
	const downY = -sunDirY;
	const rStart = downY >= 0 ? 0 : gridN - 1;
	const rEnd = downY >= 0 ? gridN : -1;
	const rStep = downY >= 0 ? 1 : -1;
	const cStart = downX >= 0 ? 0 : gridN - 1;
	const cEnd = downX >= 0 ? gridN : -1;
	const cStep = downX >= 0 ? 1 : -1;

	const majorIsX = Math.abs(downX) >= Math.abs(downY);
	const minorFrac = majorIsX
		? Math.abs(downY) / Math.max(1e-6, Math.abs(downX))
		: Math.abs(downX) / Math.max(1e-6, Math.abs(downY));
	const stepDistM = cellM * Math.hypot(1, minorFrac);
	const dropPerStepM = stepDistM * tanAlt;

	for (let gr = rStart; gr !== rEnd; gr += rStep) {
		for (let gc = cStart; gc !== cEnd; gc += cStep) {
			const upC = gc - cStep;
			const upR = gr - rStep;
			let upwindCeiling = elevGrid[gr * gridN + gc];

			if (majorIsX) {
				if (upC >= 0 && upC < gridN) {
					const c0 = ceiling[gr * gridN + upC];
					const cDiag = upR >= 0 && upR < gridN ? ceiling[upR * gridN + upC] : c0;
					upwindCeiling = c0 * (1 - minorFrac) + cDiag * minorFrac - dropPerStepM;
				}
			} else {
				if (upR >= 0 && upR < gridN) {
					const c0 = ceiling[upR * gridN + gc];
					const cDiag = upC >= 0 && upC < gridN ? ceiling[upR * gridN + upC] : c0;
					upwindCeiling = c0 * (1 - minorFrac) + cDiag * minorFrac - dropPerStepM;
				}
			}

			const idx = gr * gridN + gc;
			if (upwindCeiling > ceiling[idx]) {
				ceiling[idx] = upwindCeiling;
			}
		}
	}

	for (let rOut = 0; rOut < outSize; rOut++) {
		const v = win.v0 + ((rOut + 0.5) / outSize) * win.span;
		const gr = Math.min(gridN - 1, Math.max(0, Math.round(v * outSize - 0.5) - padOffsetRow));
		for (let cOut = 0; cOut < outSize; cOut++) {
			const u = win.u0 + ((cOut + 0.5) / outSize) * win.span;
			const gc = Math.min(gridN - 1, Math.max(0, Math.round(u * outSize - 0.5) - padOffsetCol));
			const idx = gr * gridN + gc;
			const diffM = ceiling[idx] - elevGrid[idx];
			if (diffM > 0.25) {
				const alpha = Math.round(Math.min(1, diffM / 4.0) * 115);
				const outIdx = (rOut * outSize + cOut) * 4;
				out[outIdx] = 18;
				out[outIdx + 1] = 28;
				out[outIdx + 2] = 52;
				out[outIdx + 3] = alpha;
			}
		}
	}
	return out;
}
