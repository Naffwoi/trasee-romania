import { describe, expect, it } from "vitest";
import { DemTileGrid } from "./dem_tile_grid";
import { EtaCalculator } from "./eta_calculator";
import {
	computeHorizonAngleDeg,
	computeLocalRidgeSunset,
	computeTrailSolarForecast,
} from "./ridge_sunset_calculator";
import type { NavTrackPoint } from "./types";

describe("Real Ridge Sunset vs. Live Trail ETA", () => {
	it("detects ridge sunset ~90+ min before astronomical sunset inside a deep western-walled valley", () => {
		const centerLat = 45.44;
		const centerLon = 25.50;
		const valleyDem = new DemTileGrid({
			customSampler: (_lat, lon) => (lon < 25.478 ? 2150 : 1100),
		});

		const westHorizon = computeHorizonAngleDeg(valleyDem, centerLat, centerLon, 1100, 250);
		expect(westHorizon.angleDeg).toBeGreaterThan(22);

		const refMs = Date.parse("2026-09-22T11:00:00Z");
		const res = computeLocalRidgeSunset(valleyDem, centerLat, centerLon, 1100, refMs);
		expect(res.ridgeSunsetMs).not.toBeNull();
		expect(res.astroSunsetMs).not.toBeNull();
		expect(res.minutesBeforeAstroSunset).toBeGreaterThan(80);
	});

	it("ignores a brief early-afternoon rock pinnacle shadow and finds the final evening ridge sunset", () => {
		const lat = 45.44;
		const lon = 25.50;
		const spireDem = new DemTileGrid({
			customSampler: (sLat, sLon) => {
				const dy = (sLat - lat) * 111320;
				const dx = (sLon - lon) * 111320 * Math.cos((lat * Math.PI) / 180);
				const dist = Math.hypot(dx, dy);
				const brg = ((Math.atan2(dx, dy) * 180) / Math.PI + 360) % 360;
				if (dist > 200 && dist < 500 && brg >= 208 && brg <= 214) {
					return 1900;
				}
				return 1200;
			},
		});

		const res = computeLocalRidgeSunset(
			spireDem,
			lat,
			lon,
			1200,
			Date.parse("2026-09-22T10:00:00Z"),
		);
		expect(res.minutesBeforeAstroSunset).toBeLessThan(15);
	});

	it("couples with EtaCalculator along remaining trail to classify daylight_safe -> ridge_shade -> night_danger", () => {
		const track: NavTrackPoint[] = Array.from({ length: 21 }, (_, i) => ({
			lat: 45.44 + i * 0.0036,
			lon: 25.50,
			ele: 1200 + i * 15,
			distanceM: i * 400,
			gradePct: 3.75,
		}));
		const valleyDem = new DemTileGrid({
			customSampler: (_lat, lon) => (lon < 25.48 ? 2250 : 1200),
		});
		const eta = new EtaCalculator(track);

		const safeForecast = computeTrailSolarForecast({
			points: track,
			etaCalc: eta,
			dem: valleyDem,
			alongTrackM: 0,
			nowMs: Date.parse("2026-11-18T09:00:00Z"),
		});
		expect(safeForecast.status).toBe("daylight_safe");

		const shadeForecast = computeTrailSolarForecast({
			points: track,
			etaCalc: eta,
			dem: valleyDem,
			alongTrackM: 0,
			nowMs: Date.parse("2026-11-18T12:15:00Z"),
		});
		expect(shadeForecast.status).toBe("ridge_shade");
		expect(shadeForecast.ridgeShadeAlongM).not.toBeNull();

		const nightForecast = computeTrailSolarForecast({
			points: track,
			etaCalc: eta,
			dem: valleyDem,
			alongTrackM: 0,
			nowMs: Date.parse("2026-11-18T14:15:00Z"),
		});
		expect(nightForecast.status).toBe("night_danger");
		expect(nightForecast.nightRemainingDistanceM).toBeGreaterThan(1500);
	});
});
