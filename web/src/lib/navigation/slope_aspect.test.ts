import { describe, expect, it } from "vitest";
import { DemTileGrid, webMercatorRowCellSizeMeters } from "./dem_tile_grid";
import {
	avalancheSlopeColorRgba,
	renderAvalancheSlopeTileRgba,
	renderCastShadowTileRgba,
	sampleSlopeAndAspect,
} from "./slope_aspect";

function buildInclinedPlaneTile(
	z: number,
	tx: number,
	ty: number,
	slopeDegEast: number,
	size = 512,
): Float32Array {
	const elevations = new Float32Array(size * size);
	const tanSlope = Math.tan((slopeDegEast * Math.PI) / 180);
	const seamOriginCol = 2337 * size + size;
	for (let row = 0; row < size; row++) {
		const cellM = webMercatorRowCellSizeMeters(z, ty, row, size);
		for (let col = 0; col < size; col++) {
			const relCol = tx * size + col - seamOriginCol;
			elevations[row * size + col] = 1500 + relCol * cellM * tanSlope;
		}
	}
	return elevations;
}

describe("Horn 3x3 Avalanche Slope & Scanline Cast-Shadow Renderer", () => {
	it("recovers exact 38 deg slope at 45.5N with Mercator cos(lat) correction and maps to Crimson Red", () => {
		const tx = 2337;
		const ty = 1468;
		const dem = new DemTileGrid();
		dem.putDecodedTileForTest(tx, ty, {
			width: 512,
			height: 512,
			elevations: buildInclinedPlaneTile(12, tx, ty, 38.0),
		});
		dem.putDecodedTileForTest(tx + 1, ty, {
			width: 512,
			height: 512,
			elevations: buildInclinedPlaneTile(12, tx + 1, ty, 38.0),
		});

		const sample = sampleSlopeAndAspect(dem, 45.45, 25.46);
		expect(sample).not.toBeNull();
		expect(sample!.slopeDeg).toBeGreaterThan(37.7);
		expect(sample!.slopeDeg).toBeLessThan(38.3);

		const rgba = renderAvalancheSlopeTileRgba(12, tx, ty, dem, 256);
		expect(rgba).not.toBeNull();
		const midOffset = (128 * 256 + 128) * 4;
		expect(rgba![midOffset]).toBe(220);
		expect(rgba![midOffset + 1]).toBe(38);
		expect(rgba![midOffset + 2]).toBe(38);
		expect(rgba![midOffset + 3]).toBeGreaterThan(140);

		const rgbaNext = renderAvalancheSlopeTileRgba(12, tx + 1, ty, dem, 256)!;
		const rightEdgeOffset = (128 * 256 + 255) * 4;
		const leftEdgeOffset = (128 * 256 + 0) * 4;
		expect(rgba![rightEdgeOffset]).toBe(rgbaNext[leftEdgeOffset]);
		expect(rgba![rightEdgeOffset + 3]).toBe(rgbaNext[leftEdgeOffset + 3]);
	});

	it("renders < 27 deg terrain completely transparent and grades 28/32/47/52 deg into EAWS bands", () => {
		expect(avalancheSlopeColorRgba(24.0)[3]).toBe(0);
		expect(avalancheSlopeColorRgba(28.5)).toEqual([234, 179, 8, 115]);
		expect(avalancheSlopeColorRgba(32.0)).toEqual([249, 115, 22, 140]);
		expect(avalancheSlopeColorRgba(40.0)).toEqual([220, 38, 38, 158]);
		expect(avalancheSlopeColorRgba(47.0)).toEqual([147, 51, 234, 165]);
		expect(avalancheSlopeColorRgba(53.0)).toEqual([29, 78, 216, 175]);
	});

	it("sweeps cast shadows downwind behind a 600 m ridge in < 35 ms", () => {
		const tx = 2337;
		const ty = 1468;
		const elevations = new Float32Array(512 * 512).fill(1000);
		for (let r = 0; r < 512; r++) {
			for (let c = 380; c <= 390; c++) {
				elevations[r * 512 + c] = 1600;
			}
		}
		const dem = new DemTileGrid();
		dem.putDecodedTileForTest(tx, ty, { width: 512, height: 512, elevations });

		const t0 = performance.now();
		const shade = renderCastShadowTileRgba(12, tx, ty, dem, 90, 12, 256);
		const elapsedMs = performance.now() - t0;

		expect(shade).not.toBeNull();
		expect(elapsedMs).toBeLessThan(35);

		const shadedIdx = (128 * 256 + 175) * 4;
		const sunlitIdx = (128 * 256 + 220) * 4;
		expect(shade![shadedIdx + 3]).toBeGreaterThan(80);
		expect(shade![sunlitIdx + 3]).toBe(0);
	});
});
