import { describe, expect, it } from "vitest";
import {
	EmergencySpatialIndex,
	evaluateTowerLos,
	findBestGsm112SignalSpot,
} from "./gsm_viewshed";

describe("EmergencySpatialIndex & 4/3-Earth RF Viewshed", () => {
	const index = EmergencySpatialIndex.fromJson({
		v: 1,
		towers: [[4559000, 2550000, 1800, 35, 15, 1]],
		peaks: [[4550500, 2550200, 1680, 1, "Vf. Creasta Sudică"]],
	});

	it("detects blocked LOS in valley behind ridge and recommends safe uphill shoulder <= 400m", () => {
		const mockDem = {
			sampleElevation(lat: number, lon: number): number | null {
				if (lon > 25.5008) {
					return 1300 + (lon - 25.5000) * 80_000 * 1.2;
				}
				if (lat >= 45.5035 && lat <= 45.5055 && lon >= 25.4988) {
					return 1540;
				}
				const westGain = Math.max(0, (25.5000 - lon) * 78_000 * 0.25);
				return 1300 + westGain;
			},
		};

		const valleyLos = evaluateTowerLos(
			45.5000,
			25.5000,
			1300,
			index.findTowersWithin(45.5000, 25.5000, 25_000)[0],
			mockDem,
		);
		expect(valleyLos.losClass).toBe("blocked");

		const rec = findBestGsm112SignalSpot({
			lat: 45.5000,
			lon: 25.5000,
			dem: mockDem,
			index,
		});

		expect(rec.status).toBe("climb_recommended");
		expect(rec.walkDistanceM).toBeGreaterThanOrEqual(50);
		expect(rec.walkDistanceM).toBeLessThanOrEqual(400);
		expect(rec.targetLon).toBeLessThan(25.4995);
		expect(rec.losQuality === "clear_los" || rec.losQuality === "grazing_los").toBe(true);
		expect(rec.reachableTowerCount).toBe(1);
		expect(rec.instructionRo).toContain("m");
	});

	it("reports already_los immediately when current position has unobstructed tower LOS", () => {
		const flatDem = { sampleElevation: () => 1750 };
		const rec = findBestGsm112SignalSpot({
			lat: 45.5000,
			lon: 25.5000,
			dem: flatDem,
			index,
		});
		expect(rec.status).toBe("already_los");
		expect(rec.walkDistanceM).toBe(0);
	});
});
