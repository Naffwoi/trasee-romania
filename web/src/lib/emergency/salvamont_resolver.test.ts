import { describe, expect, it } from "vitest";
import {
	getSalvamontDataset,
	resolveNearestSalvamont,
	resolveTrailSalvamontSummary,
} from "./salvamont_resolver";

describe("salvamont_resolver (offline Romania mountain rescue resolver)", () => {
	it("loads bundled salvamont_ro.json with valid E.164 phones on every service", () => {
		const ds = getSalvamontDataset();
		expect(ds.emergency112).toBe("112");
		expect(ds.nationalDispatchPhone).toBe("+40725826668");
		expect(ds.points.length).toBeGreaterThanOrEqual(55);
		for (const svc of Object.values(ds.services)) {
			expect(svc.primaryPhone).toMatch(/^\+40[237]\d{8}$/);
		}
	});

	it("detects multi-jurisdiction ridge border at Vf. Omu (PH / DB / BV)", () => {
		const res = resolveNearestSalvamont(45.4458, 25.4563, { userEle: 2505, locale: "ro" });
		expect(res.isMountainZone).toBe(true);
		expect(res.isRidgeBorderZone).toBe(true);
		expect(res.nearestBases.length).toBeGreaterThanOrEqual(2);
		expect(res.nearestBases[0].distanceM).toBeLessThan(6_000);

		const serviceIds = res.activeServices.map((s) => s.service.id);
		expect(serviceIds.length).toBeGreaterThanOrEqual(2);
		const counties = new Set(res.activeServices.map((s) => s.service.countyCode));
		expect(counties.size).toBeGreaterThanOrEqual(2);
	});

	it("detects Făgăraș crest border (SB / AG) and surfaces nearest unmanned refuge", () => {
		const res = resolveNearestSalvamont(45.6005, 24.6285, { userEle: 2260, locale: "ro" });
		expect(res.isMountainZone).toBe(true);
		expect(res.isRidgeBorderZone).toBe(true);
		const counties = new Set(res.activeServices.map((s) => s.service.countyCode));
		expect(counties.has("SB")).toBe(true);
		expect(counties.has("AG")).toBe(true);
		expect(res.nearestRefuge).not.toBeNull();
		expect(res.nearestRefuge!.point.name).toContain("Fereastra Zmeilor");
	});

	it("resolves single jurisdiction cleanly in interior massif (Păltiniș, Sibiu)", () => {
		const res = resolveNearestSalvamont(45.6530, 23.9332, { userEle: 1442, locale: "ro" });
		expect(res.isMountainZone).toBe(true);
		expect(res.isRidgeBorderZone).toBe(false);
		expect(res.activeServices[0].service.id).toBe("ro-sb-spj");
		expect(res.activeServices[0].service.primaryPhone).toBe("+40269216477");
		expect(res.nearestBases[0].distanceM).toBeLessThan(150);
	});

	it("suppresses distant Carpathian services in Munții Măcin / lowland (> 35 km)", () => {
		const res = resolveNearestSalvamont(45.2060, 28.1950, { locale: "ro" });
		expect(res.isMountainZone).toBe(false);
		expect(res.activeServices).toHaveLength(0);
		expect(res.emergency112).toBe("112");
		expect(res.nationalDispatchPhone).toBe("+40725826668");
	});

	it("computes TrailSalvamontSummary across a cross-county Bucegi trail", () => {
		const summary = resolveTrailSalvamontSummary([
			{ lat: 45.4096, lon: 25.5324, ele: 885 },
			{ lat: 45.4133, lon: 25.4704, ele: 2206 },
			{ lat: 45.3979, lon: 25.4414, ele: 1610 },
		]);
		expect(summary).not.toBeNull();
		expect(summary!.services.length).toBeGreaterThanOrEqual(2);
		expect(summary!.nearestBase.distanceM).toBeLessThan(100);
	});
});
