import { describe, expect, it } from "vitest";
import { DemTileGrid } from "./dem_tile_grid";
import { OfflinePeakFinder, type PeakEntryDto } from "./peak_finder_engine";

const testPeaks: PeakEntryDto[] = [
	{
		id: 1,
		name: "Vf. Omu",
		lat: 45.44572,
		lon: 25.45628,
		ele: 2505,
		prominenceM: 1460,
		kind: "peak",
	},
	{
		id: 2,
		name: "Vf. Apropiat",
		lat: 45.4817,
		lon: 25.45628,
		ele: 1750,
		prominenceM: 300,
		kind: "peak",
	},
	{
		id: 3,
		name: "Vf. Ascuns În Spate",
		lat: 45.5536,
		lon: 25.45628,
		ele: 2150,
		prominenceM: 500,
		kind: "peak",
	},
	{
		id: 4,
		name: "Vf. Înalt Vizibil",
		lat: 45.5536,
		lon: 25.468,
		ele: 2540,
		prominenceM: 1200,
		kind: "peak",
	},
];

describe("OfflinePeakFinder (DEM Viewshed + k=0.13 Curvature + Decluttering)", () => {
	it("keeps foreground peak visible while culling lower-angle background peak behind intermediate ridge", () => {
		const obsLat = 45.44572;
		const obsLon = 25.45628;
		const dem = new DemTileGrid({
			customSampler: (lat) => (Math.abs(lat - 45.4817) < 0.0025 ? 1750 : 1500),
		});

		const finder = OfflinePeakFinder.fromPeaks(testPeaks.slice(1));
		const pano = finder.computePanorama(dem, obsLat, obsLon, 1500);
		const names = pano.visiblePeaks.map((p) => p.peak.name);

		expect(names).toContain("Vf. Apropiat");
		expect(names).toContain("Vf. Înalt Vizibil");
		expect(names).not.toContain("Vf. Ascuns În Spate");
	});

	it("identifies self-summit when standing within 35 m of Vf. Omu and marks peaks unverified when DEM is null", () => {
		const nullDem = new DemTileGrid({ customSampler: () => null });
		const finder = OfflinePeakFinder.fromPeaks(testPeaks);
		const pano = finder.computePanorama(nullDem, 45.44575, 25.4563, 2505);

		expect(pano.standingOnPeak?.name).toBe("Vf. Omu");
		expect(pano.visiblePeaks.some((p) => p.peak.name === "Vf. Omu")).toBe(false);
		expect(pano.visiblePeaks.every((p) => p.visibility === "unverified")).toBe(true);
	});

	it("applies angular NMS decluttering and 2-tier stem assignment within compass viewport", () => {
		const clustered: PeakEntryDto[] = Array.from({ length: 12 }, (_, i) => ({
			id: 100 + i,
			name: `Peak ${i}`,
			lat: 45.5,
			lon: 25.44 + i * 0.0015,
			ele: 1800 + i * 50,
			prominenceM: 100 + i * 40,
			kind: "peak",
		}));
		const flatDem = new DemTileGrid({ customSampler: () => 1200 });
		const finder = OfflinePeakFinder.fromPeaks(clustered);
		const pano = finder.computePanorama(flatDem, 45.44, 25.45, 1200);
		const selected = finder.selectViewportPeaks(pano, 5, 90, 6);

		expect(selected.length).toBeLessThanOrEqual(6);
		expect(selected.some((s) => s.peak.name === "Peak 11")).toBe(true);
	});
});
