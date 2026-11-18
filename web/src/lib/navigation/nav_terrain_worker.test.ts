import { describe, expect, it } from "vitest";
import { DemTileGrid, latLonToZ12TileFloat, webMercatorRowCellSizeMeters } from "./dem_tile_grid";
import {
	decodeDem16Slab,
	encodeDem16Slab,
	packOffTrailPoints,
	packTrackPoints,
	parseGpxXmlFastToPackedTrack,
	quantizeElevationMetersToTenths,
	reversePackedTrackPoints,
	unpackOffTrailPoints,
	unpackTrackPoints,
} from "./nav_terrain_codec";
import { NavTerrainClient } from "./nav_terrain_client";
import type { NavTrackPoint } from "./types";

describe("nav_terrain_codec & .dem16 quantization", () => {
	it("quantizes Carpathian & Himalayan/Dead-Sea range elevations to Int16 (0.1m precision, 50% RAM)", () => {
		expect(quantizeElevationMetersToTenths(2544.36)).toBe(25444);
		expect(quantizeElevationMetersToTenths(-412.4)).toBe(-4124);
		expect(quantizeElevationMetersToTenths(99999)).toBe(32767);
		expect(quantizeElevationMetersToTenths(-99999)).toBe(-32768);

		const width = 512;
		const height = 512;
		const tenths = new Int16Array(width * height);
		tenths[0] = 9005; // 900.5 m
		tenths[width * height - 1] = 25054; // 2505.4 m

		const slab = encodeDem16Slab(width, height, tenths);
		// 8-byte header ("DEM6" + u16 width + u16 height) + 512*512*2 bytes = 524,296 bytes (~50% of 1,048,576 B Float32Array)
		expect(slab.byteLength).toBe(8 + 512 * 512 * 2);

		const decoded = decodeDem16Slab(slab);
		expect(decoded).not.toBeNull();
		expect(decoded!.width).toBe(512);
		expect(decoded!.height).toBe(512);
		expect(decoded!.elevationsTenths.byteLength).toBe(524_288);
		expect(decoded!.elevationsTenths[0]).toBe(9005);
		expect(decoded!.elevationsTenths[width * height - 1]).toBe(25054);
	});

	it("packs, reverses, and unpacks NavTrackPoint[] & OffTrailPoint[] losslessly", () => {
		const pts: NavTrackPoint[] = [
			{ lat: 45.440001, lon: 25.550002, ele: 912.4, distanceM: 0, gradePct: 8.5 },
			{ lat: 45.441001, lon: 25.550502, ele: 922.0, distanceM: 118.2, gradePct: 8.1 },
			{ lat: 45.442001, lon: 25.551002, ele: 940.5, distanceM: 236.9, gradePct: 15.6 },
		];
		const packed = packTrackPoints(pts);
		expect(packed).toBeInstanceOf(Float64Array);
		expect(packed.length).toBe(15);

		const unpacked = unpackTrackPoints(packed);
		expect(unpacked).toEqual(pts);

		const revPacked = reversePackedTrackPoints(packed);
		const rev = unpackTrackPoints(revPacked);
		expect(rev).toHaveLength(3);
		expect(rev[0].lat).toBeCloseTo(45.442001, 6);
		expect(rev[0].distanceM).toBe(0);
		expect(rev[2].lat).toBeCloseTo(45.440001, 6);
		expect(rev[2].distanceM).toBeCloseTo(236.9, 3);

		const offPacked = packOffTrailPoints(pts);
		expect(offPacked).toBeInstanceOf(Float32Array);
		const offUnpacked = unpackOffTrailPoints(offPacked);
		expect(offUnpacked[1].lat).toBeCloseTo(45.441001, 4);
		expect(offUnpacked[1].ele).toBeCloseTo(922.0, 1);
	});

	it("parses GPX XML (<trkpt> and route-only <rtept>) directly to packed Float64Array without DOMParser", () => {
		const gpx = `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>Bucegi</name><trkseg>
    <trkpt lat="45.400000" lon="25.500000"><ele>1000.5</ele></trkpt>
    <trkpt lon="25.500000" lat="45.400900"><ele>1012.5</ele></trkpt>
    <trkpt lat="45.401800" lon="25.500000"><ele>1020.0</ele></trkpt>
  </trkseg></trk>
</gpx>`;
		const packed = parseGpxXmlFastToPackedTrack(gpx);
		const pts = unpackTrackPoints(packed);
		expect(pts).toHaveLength(3);
		expect(pts[0].ele).toBeCloseTo(1000.5, 2);
		expect(pts[1].distanceM).toBeGreaterThan(95);
		expect(pts[1].distanceM).toBeLessThan(105);
		expect(pts[1].gradePct).toBeGreaterThan(10);
		expect(pts[2].distanceM).toBeGreaterThan(195);
	});

	it("computes obstacle-aware off-trail reroute, SOS rescue route, and stitched DEM tile accessors", async () => {
		const trail: NavTrackPoint[] = [];
		for (let i = 0; i <= 25; i++) {
			trail.push({
				lat: 45.44 + i * 0.00045,
				lon: 25.55,
				ele: 950 + i * 5,
				distanceM: i * 50,
				gradePct: 10,
			});
		}

		const client = new NavTerrainClient();
		client.setCustomDemSampler((lat, lon) => {
			const dLat = (lat - 45.4427) * 111132;
			const dLon = (lon - 25.5493) * 78108;
			return 960 + 50 * Math.exp(-(dLat * dLat + dLon * dLon) / (2 * 28 * 28));
		});
		await client.setTrack(trail);

		const res = await client.computeReroute({
			userLat: 45.4427,
			userLon: 25.5484,
			userEle: 960,
			lastAlongTrackM: 300,
			mode: "min-climb",
			locale: "ro",
			obstacles: [
				{
					rings: [
						[25.5491, 45.4425],
						[25.5495, 45.4425],
						[25.5495, 45.4430],
						[25.5491, 45.4430],
						[25.5491, 45.4425],
					],
				},
			],
			preferredPaths: [],
		});

		expect(res).not.toBeNull();
		expect(res!.points.length).toBeGreaterThanOrEqual(4);
		expect(res!.rejoinAlongTrackM).toBeGreaterThanOrEqual(290);

		const rescue = await client.computeRescueRoute({
			fromLat: 45.441,
			fromLon: 25.55,
			fromEle: 955,
			targetLat: 45.444,
			targetLon: 25.5485,
			targetEle: 980,
			mode: "min-climb",
			locale: "ro",
		});
		expect(rescue.points.length).toBeGreaterThanOrEqual(2);
		expect(rescue.distanceM).toBeGreaterThan(300);

		const grid = new DemTileGrid({ customSampler: () => 1425.3 });
		expect(grid.sampleElevation(45.5, 25.5)).toBeCloseTo(1425.3, 1);

		// Verify stitched DEM tile accessors for Solar/Avalanche/GSM consumers
		const stitchedGrid = new DemTileGrid();
		const { xFloat, yFloat } = latLonToZ12TileFloat(45.45, 25.46);
		const tx = Math.floor(xFloat);
		const ty = Math.floor(yFloat);
		const cellM = webMercatorRowCellSizeMeters(12, ty, 256, 512);
		expect(cellM).toBeGreaterThan(10);
		expect(cellM).toBeLessThan(20);

		const tA = new Float32Array(512 * 512).fill(1200.4);
		const tB = new Float32Array(512 * 512).fill(1215.6);
		stitchedGrid.putDecodedTileForTest(tx, ty, { width: 512, height: 512, elevations: tA });
		stitchedGrid.putDecodedTileForTest(tx + 1, ty, { width: 512, height: 512, elevations: tB });
		expect(stitchedGrid.getDecodedTile(tx, ty)?.elevationsTenths.byteLength).toBe(524_288);
		expect(stitchedGrid.samplePixelStitched(tx, ty, 512, 100)).toBeCloseTo(1215.6, 1);

		client.destroy();
	});
});
