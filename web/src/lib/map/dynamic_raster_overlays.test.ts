import { describe, expect, it, vi } from "vitest";
import {
	buildGfwDisturbanceOverlaySpec,
	buildGibsSnowOverlaySpec,
	buildGibsTrueColorOverlaySpec,
	buildHybridSatelliteStyle,
	resolveRainViewerOverlaySpec,
	xyzToEpsg3857Bbox,
} from "./dynamic_raster_overlays";

describe("dynamic_raster_overlays & hybrid satellite styles", () => {
	it("builds Esri HD hybrid style with maxzoom 18, {z}/{y}/{x} order, and openmaptiles peak labels", () => {
		const spec = buildHybridSatelliteStyle(
			"esriWorldImagery",
			[
				"https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
			],
			18,
			"Source: Esri",
		);
		const rasterSrc = spec.sources.esriWorldImagery as {
			type: string;
			maxzoom: number;
			tiles: string[];
		};
		expect(rasterSrc.type).toBe("raster");
		expect(rasterSrc.maxzoom).toBe(18);
		expect(rasterSrc.tiles[0]).toContain("{z}/{y}/{x}");
		expect(spec.sources.openmaptiles).toBeDefined();
		expect(spec.layers.some((l) => l.id === "sat-hybrid-peaks")).toBe(true);
	});

	it("uses VIIRS_NOAA20_NDSI_Snow_Cover at maxzoom 8 and supports default + explicit YYYY-MM-DD", () => {
		const defSpec = buildGibsSnowOverlaySpec();
		const src = defSpec.sources.gibsSnowCover as { maxzoom: number; tiles: string[] };
		expect(src.maxzoom).toBe(8);
		expect(src.tiles[0]).toContain(
			"VIIRS_NOAA20_NDSI_Snow_Cover/default/default/GoogleMapsCompatible_Level8/{z}/{y}/{x}.png",
		);

		const datedSpec = buildGibsTrueColorOverlaySpec("2026-11-17");
		const tcSrc = datedSpec.sources.gibsTrueColor as { maxzoom: number; tiles: string[] };
		expect(tcSrc.maxzoom).toBe(9);
		expect(tcSrc.tiles[0]).toContain(
			"VIIRS_NOAA20_CorrectedReflectance_TrueColor/default/2026-11-17/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpg",
		);
	});

	it("caps RainViewer radar source strictly at maxzoom 7 to avoid z>=8 watermark tiles", async () => {
		const fakeFetch = vi.fn().mockResolvedValue({
			ok: true,
			json: async () => ({
				host: "https://tilecache.rainviewer.com",
				radar: { past: [{ time: 1795000800, path: "/v2/radar/dbae827dc7fa" }] },
			}),
		});
		const spec = await resolveRainViewerOverlaySpec(fakeFetch as unknown as typeof fetch);
		expect(spec).not.toBeNull();
		const rvSrc = spec!.sources.rainViewerRadar as { maxzoom: number; tiles: string[] };
		expect(rvSrc.maxzoom).toBe(7);
		expect(rvSrc.tiles[0]).toBe(
			"https://tilecache.rainviewer.com/v2/radar/dbae827dc7fa/256/{z}/{x}/{y}/2/1_1.png",
		);
	});

	it("builds GFW umd_glad_dist_alerts visual overlay and converts XYZ to EPSG:3857 BBOX accurately", () => {
		const gfw = buildGfwDisturbanceOverlaySpec("2026-08-01");
		const gfwSrc = gfw.sources.gfwDisturbance as { tiles: string[] };
		expect(gfwSrc.tiles[0]).toContain("umd_glad_dist_alerts/latest/dynamic/{z}/{x}/{y}.png");
		expect(gfwSrc.tiles[0]).toContain("render_type=true_color");

		const [minX, minY, maxX, maxY] = xyzToEpsg3857Bbox(0, 0, 0);
		expect(Math.round(minX)).toBe(-20037508);
		expect(Math.round(maxX)).toBe(20037508);
		expect(maxY).toBeGreaterThan(minY);
	});
});
