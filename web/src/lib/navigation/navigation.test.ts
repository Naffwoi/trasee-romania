import { describe, expect, it, vi } from "vitest";
import GPX from "#lib/models/gpx/gpx.ts";
import {
	bearingDegrees,
	cardinalDirection,
	computeOffTrailReroute,
	DemTileGrid,
	EtaCalculator,
	extractRawTrackPoints,
	haversineMeters,
	normalizeBearingDelta,
	reverseTrackPoints,
	RouteMapMatcher,
	synthesizeTrailManeuvers,
	toblerHikingSpeedKmh,
	type NavTrackPoint,
} from "./index";

const BASE_LAT = 45.5;
const BASE_LON = 25.5;
const M_PER_DEG_LAT = (Math.PI / 180) * 6371000;
const M_PER_DEG_LON = M_PER_DEG_LAT * Math.cos((BASE_LAT * Math.PI) / 180);

function offsetLatLon(eastM: number, northM: number): { lat: number; lon: number } {
	return {
		lat: BASE_LAT + northM / M_PER_DEG_LAT,
		lon: BASE_LON + eastM / M_PER_DEG_LON,
	};
}

function makeStraightEastTrail(
	lengthM: number,
	stepM: number,
	eleFn: (distM: number) => number = () => 1000,
): NavTrackPoint[] {
	const count = Math.floor(lengthM / stepM) + 1;
	const pts: NavTrackPoint[] = [];
	for (let i = 0; i < count; i++) {
		const d = i * stepM;
		const { lat, lon } = offsetLatLon(d, 0);
		pts.push({
			lat,
			lon,
			ele: eleFn(d),
			distanceM: d,
			gradePct: 0,
		});
	}
	for (let i = 0; i < pts.length; i++) {
		const prev = pts[Math.max(0, i - 1)];
		const next = pts[Math.min(pts.length - 1, i + 1)];
		const run = next.distanceM - prev.distanceM;
		pts[i].gradePct = run > 0 ? ((next.ele - prev.ele) / run) * 100 : 0;
	}
	return pts;
}

describe("geo_math", () => {
	it("computes haversine distance accurately and symmetrically", () => {
		expect(haversineMeters(BASE_LAT, BASE_LON, BASE_LAT, BASE_LON)).toBe(0);
		const p1 = offsetLatLon(0, 0);
		const p2 = offsetLatLon(300, 400);
		const d12 = haversineMeters(p1.lat, p1.lon, p2.lat, p2.lon);
		const d21 = haversineMeters(p2.lat, p2.lon, p1.lat, p1.lon);
		expect(d12).toBeCloseTo(500, 0);
		expect(d12).toBeCloseTo(d21, 6);
	});

	it("computes clockwise North=0 bearings and normalized deltas in [-180, 180]", () => {
		const origin = offsetLatLon(0, 0);
		const north = offsetLatLon(0, 200);
		const east = offsetLatLon(200, 0);
		const south = offsetLatLon(0, -200);
		const west = offsetLatLon(-200, 0);

		expect(bearingDegrees(origin.lat, origin.lon, north.lat, north.lon)).toBeCloseTo(0, 1);
		expect(bearingDegrees(origin.lat, origin.lon, east.lat, east.lon)).toBeCloseTo(90, 1);
		expect(bearingDegrees(origin.lat, origin.lon, south.lat, south.lon)).toBeCloseTo(180, 1);
		expect(bearingDegrees(origin.lat, origin.lon, west.lat, west.lon)).toBeCloseTo(270, 1);

		expect(normalizeBearingDelta(350, 10)).toBeCloseTo(20, 6);
		expect(normalizeBearingDelta(10, 350)).toBeCloseTo(-20, 6);
		expect(normalizeBearingDelta(90, 0)).toBeCloseTo(-90, 6);
		expect(normalizeBearingDelta(0, 180)).toBeCloseTo(180, 6);
	});

	it("formats localized RO and EN cardinal directions", () => {
		expect(cardinalDirection(0, "en")).toBe("N");
		expect(cardinalDirection(225, "en")).toBe("SW");
		expect(cardinalDirection(270, "en")).toBe("W");
		expect(cardinalDirection(315, "en")).toBe("NW");

		expect(cardinalDirection(225, "ro")).toBe("SV");
		expect(cardinalDirection(270, "ro")).toBe("V");
		expect(cardinalDirection(315, "ro")).toBe("NV");
	});

	it("extracts GPX points with smoothed elevation/grade and reverses them cleanly", () => {
		const pts = [0, 1, 2, 3, 4, 5, 6].map((i) => {
			const ll = offsetLatLon(i * 100, 0);
			return `<trkpt lat="${ll.lat}" lon="${ll.lon}"><ele>${1000 + i * 10}</ele></trkpt>`;
		});
		const gpx = GPX.parse(
			`<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>${pts.join("")}</trkseg></trk></gpx>`,
		);

		const extracted = extractRawTrackPoints(gpx);
		expect(extracted).toHaveLength(7);
		expect(extracted[0].distanceM).toBe(0);
		expect(extracted[6].distanceM).toBeCloseTo(600, 0);
		expect(extracted[3].ele).toBeCloseTo(1030, 1);
		expect(extracted[3].gradePct).toBeCloseTo(10, 0);

		const reversed = reverseTrackPoints(extracted);
		expect(reversed).toHaveLength(7);
		expect(reversed[0].distanceM).toBe(0);
		expect(reversed[6].distanceM).toBeCloseTo(extracted[6].distanceM, 3);
		expect(reversed[0].ele).toBeCloseTo(extracted[6].ele, 6);
		expect(reversed[3].gradePct).toBeCloseTo(-extracted[3].gradePct, 6);
	});
});

describe("RouteMapMatcher", () => {
	it("protects hairpin / out-and-back tracks from jumping legs", () => {
		// Outbound leg goes East 0..400m at y=0, U-turns at 400m, returns West at y=12m.
		const pts: NavTrackPoint[] = [];
		let dist = 0;
		const pushPt = (e: number, n: number) => {
			const ll = offsetLatLon(e, n);
			if (pts.length > 0) {
				const prev = pts[pts.length - 1];
				dist += haversineMeters(prev.lat, prev.lon, ll.lat, ll.lon);
			}
			pts.push({ lat: ll.lat, lon: ll.lon, ele: 900, distanceM: dist, gradePct: 0 });
		};
		for (let x = 0; x <= 400; x += 25) pushPt(x, 0);
		for (let x = 400; x >= 0; x -= 25) pushPt(x, 12);

		const matcher = new RouteMapMatcher(pts);

		// Walk along the outbound leg at y = 4m (4m from outbound, 8m from return leg).
		let lastResult = matcher.update({ ...offsetLatLon(0, 0), accuracy: 8, heading: 90, speed: 1.5 });
		expect(lastResult.isOffTrail).toBe(false);
		expect(lastResult.alongTrackMeters).toBeLessThan(30);

		for (let x = 25; x <= 300; x += 25) {
			lastResult = matcher.update({
				...offsetLatLon(x, 5),
				accuracy: 8,
				heading: 90,
				speed: 1.5,
			});
			expect(lastResult.isOffTrail).toBe(false);
			expect(lastResult.alongTrackMeters).toBeLessThan(400);
		}
		expect(lastResult.alongTrackMeters).toBeCloseTo(300, -1);
	});

	it("applies 3-fix confirmation, accuracy-adapted threshold, immediate >90m off-trail, and 22m rejoin snap", () => {
		const trail = makeStraightEastTrail(1000, 25);
		const matcher = new RouteMapMatcher(trail);

		// Start on-trail at 100m.
		const startRes = matcher.update({ ...offsetLatLon(100, 0), accuracy: 10 });
		expect(startRes.isOffTrail).toBe(false);
		expect(startRes.alongTrackMeters).toBeCloseTo(100, 0);

		// Accuracy = 40m -> threshold = max(35, min(75, 60)) = 60m -> 50m off-trail stays on-trail!
		for (let i = 0; i < 4; i++) {
			const res = matcher.update({ ...offsetLatLon(110 + i * 5, 50), accuracy: 40 });
			expect(res.isOffTrail).toBe(false);
			expect(res.consecutiveOffTrailFixes).toBe(0);
		}

		// Accuracy = 10m -> threshold = 35m -> 3 fixes at 50m off-trail triggers off-trail on the 3rd fix.
		const f1 = matcher.update({ ...offsetLatLon(130, 50), accuracy: 10 });
		expect(f1.isOffTrail).toBe(false);
		expect(f1.consecutiveOffTrailFixes).toBe(1);

		const f2 = matcher.update({ ...offsetLatLon(140, 50), accuracy: 10 });
		expect(f2.isOffTrail).toBe(false);
		expect(f2.consecutiveOffTrailFixes).toBe(2);

		const f3 = matcher.update({ ...offsetLatLon(150, 50), accuracy: 10 });
		expect(f3.isOffTrail).toBe(true);
		expect(f3.consecutiveOffTrailFixes).toBe(3);

		// Still at 28m (> 22m rejoinThreshold) -> remains off-trail.
		const stillOff = matcher.update({ ...offsetLatLon(400, 28), accuracy: 10 });
		expect(stillOff.isOffTrail).toBe(true);

		// Rejoin at 15m (<= 22m) at along=420m -> snaps alongTrackMeters to ~420m!
		const rejoined = matcher.update({ ...offsetLatLon(420, 15), accuracy: 10 });
		expect(rejoined.isOffTrail).toBe(false);
		expect(rejoined.consecutiveOffTrailFixes).toBe(0);
		expect(rejoined.alongTrackMeters).toBeCloseTo(420, 0);

		// Immediate entry on single fix > 90m.
		const jumpFar = matcher.update({ ...offsetLatLon(450, 115), accuracy: 10 });
		expect(jumpFar.isOffTrail).toBe(true);
		expect(jumpFar.crossTrackMeters).toBeGreaterThan(90);
	});
});

describe("EtaCalculator", () => {
	it("computes Tobler speeds, EMA pace adaptation, prominent peaks, and offTrailExtra", () => {
		expect(toblerHikingSpeedKmh(0)).toBeCloseTo(6 * Math.exp(-3.5 * 0.05), 4);
		expect(toblerHikingSpeedKmh(1.0)).toBe(0.7);
		expect(toblerHikingSpeedKmh(-0.05)).toBeCloseTo(6.0, 4);
		expect(toblerHikingSpeedKmh(0, true)).toBeCloseTo(18 * Math.exp(-2.8 * 0.03), 4);
		expect(toblerHikingSpeedKmh(2.0, true)).toBe(2.0);

		// 2000m trail: climbs from 1000m to a 1200m peak at 1000m, minor 15m bump at 1500m (<20m prominence), descends to 1050m.
		const trail = makeStraightEastTrail(2000, 50, (d) => {
			if (d <= 1000) return 1000 + 0.2 * d;
			if (d === 1500) return 1140; // +15m bump above 1125m baseline (< 20m prominence)
			return 1200 - 0.15 * (d - 1000);
		});

		const eta = new EtaCalculator(trail);
		const now = new Date(2026, 5, 1, 10, 0, 0).getTime();
		const snap0 = eta.compute(0, now);

		expect(snap0.remainingDistanceM).toBeCloseTo(2000, 0);
		expect(snap0.remainingAscentM).toBeCloseTo(207.5, 1);
		expect(snap0.remainingDescentM).toBeCloseTo(157.5, 1);
		expect(snap0.progressRatio).toBe(0);
		expect(snap0.arrivalTimeFormatted).toMatch(/^\d{2}:\d{2}$/);
		expect(snap0.nextPeak).not.toBeNull();
		expect(snap0.nextPeak!.ele).toBeCloseTo(1200, 0);
		expect(snap0.nextPeak!.distanceAheadM).toBeCloseTo(1000, 0);
		expect(snap0.nextPeak!.gainAheadM).toBeCloseTo(200, 0);

		// Sub-15m movement does not change paceFactor.
		eta.recordProgress(0, now);
		eta.recordProgress(10, now + 60_000);
		expect(eta.compute(10, now + 60_000).remainingSeconds).toBeCloseTo(
			new EtaCalculator(trail).compute(10, now + 60_000).remainingSeconds,
			4,
		);

		// Moving 200m much slower than Tobler increases remainingSeconds via EMA paceFactor.
		const baseAfter200 = new EtaCalculator(trail).compute(200, now).remainingSeconds;
		eta.recordProgress(200, now + 600_000);
		const slowAfter200 = eta.compute(200, now + 600_000).remainingSeconds;
		expect(slowAfter200).toBeGreaterThan(baseAfter200);

		// Once past peak (1100m), minor 8m bump is ignored -> nextPeak is null.
		const pastPeak = eta.compute(1100, now + 700_000);
		expect(pastPeak.nextPeak).toBeNull();

		// offTrailExtra adds off-trail distance/duration/ascent to remaining trail from rejoinAlongTrackM.
		const freshEta = new EtaCalculator(trail);
		const onTrailAt1000 = freshEta.compute(1000, now);
		const offTrailSnap = freshEta.compute(500, now, {
			distanceM: 250,
			durationSec: 400,
			ascentM: 35,
			rejoinAlongTrackM: 1000,
		});
		expect(offTrailSnap.remainingDistanceM).toBeCloseTo(onTrailAt1000.remainingDistanceM + 250, 1);
		expect(offTrailSnap.remainingSeconds).toBeCloseTo(onTrailAt1000.remainingSeconds + 400, 1);
		expect(offTrailSnap.remainingAscentM).toBeCloseTo(onTrailAt1000.remainingAscentM + 35, 1);
	});
});

describe("synthesizeTrailManeuvers and /api/v1/valhalla/navigate fallback", () => {
	it("detects turns, steep climbs/descents, peak, and nearby waypoints in RO and EN", () => {
		// Build an L-shaped route: 200m North (steep climb +18%), sharp 90° right turn East 200m (peak + steep descent -16%).
		const pts: { lat: number; lon: number; ele: number }[] = [];
		for (let n = 0; n <= 200; n += 10) {
			const ll = offsetLatLon(0, n);
			pts.push({ ...ll, ele: 1000 + n * 0.18 });
		}
		for (let e = 10; e <= 220; e += 10) {
			const ll = offsetLatLon(e, 200);
			pts.push({ ...ll, ele: 1036 - e * 0.16 });
		}
		const shelter = offsetLatLon(100, 215); // 15m off the trail (< 40m)

		const resRo = synthesizeTrailManeuvers(pts, {
			locale: "ro",
			waypoints: [{ lat: shelter.lat, lon: shelter.lon, name: "Refugiul Salvamont" }],
		});
		expect(resRo.shape).toHaveLength(pts.length);
		expect(resRo.shape[0]).toEqual([pts[0].lat, pts[0].lon]);
		expect(resRo.maneuvers[0].type).toBe(1);
		expect(resRo.maneuvers[resRo.maneuvers.length - 1].type).toBe(4);
		expect(resRo.maneuvers.some((m) => m.type === 10)).toBe(true); // Right turn
		expect(resRo.maneuvers.some((m) => m.instruction.includes("Urcare abruptă"))).toBe(true);
		expect(resRo.maneuvers.some((m) => m.instruction.includes("Coborâre abruptă"))).toBe(true);
		expect(resRo.maneuvers.some((m) => m.instruction.includes("Refugiul Salvamont"))).toBe(true);

		const resEn = synthesizeTrailManeuvers(pts, {
			locale: "en",
			waypoints: [{ lat: shelter.lat, lon: shelter.lon, name: "Mountain Hut" }],
		});
		expect(resEn.maneuvers.some((m) => m.instruction === "Turn right")).toBe(true);
		expect(resEn.maneuvers.some((m) => m.instruction.includes("Steep climb"))).toBe(true);
		expect(resEn.maneuvers.some((m) => m.instruction.includes("Steep descent"))).toBe(true);
		expect(resEn.maneuvers.some((m) => m.instruction.includes("Pass Mountain Hut"))).toBe(true);
	});

	it("returns HTTP 200 synthesized maneuvers from /api/v1/valhalla/navigate when Valhalla is unconfigured or fails", async () => {
		vi.resetModules();
		vi.doMock("#lib/server/valhalla.ts", () => ({ getValhallaUrl: () => null }));
		const modNull = await import("../../routes/api/v1/valhalla/navigate/+server");

		const reqEvent = {
			request: new Request("http://localhost/api/v1/valhalla/navigate", {
				method: "POST",
				body: JSON.stringify({
					shape: [offsetLatLon(0, 0), offsetLatLon(100, 0), offsetLatLon(100, 100)],
					costing: "pedestrian",
					language: "ro",
				}),
			}),
			locals: { user: { id: "u1" } },
			fetch: vi.fn(),
		} as unknown as Parameters<typeof modNull.POST>[0];

		const resNull = await modNull.POST(reqEvent);
		expect(resNull.status).toBe(200);
		const jsonNull = await resNull.json();
		expect(jsonNull.maneuvers.length).toBeGreaterThanOrEqual(2);
		expect(jsonNull.shape).toHaveLength(3);
		expect(reqEvent.fetch).not.toHaveBeenCalled();

		vi.resetModules();
		vi.doMock("#lib/server/valhalla.ts", () => ({ getValhallaUrl: () => "http://valhalla.local" }));
		const modErr = await import("../../routes/api/v1/valhalla/navigate/+server");
		const failingEvent = {
			request: new Request("http://localhost/api/v1/valhalla/navigate", {
				method: "POST",
				body: JSON.stringify({
					shape: [offsetLatLon(0, 0), offsetLatLon(100, 0), offsetLatLon(100, 100)],
					costing: "pedestrian",
					language: "en",
				}),
			}),
			locals: { user: { id: "u1" } },
			fetch: vi.fn().mockRejectedValue(new Error("connect ECONNREFUSED")),
		} as unknown as Parameters<typeof modErr.POST>[0];

		const resErr = await modErr.POST(failingEvent);
		expect(resErr.status).toBe(200);
		const jsonErr = await resErr.json();
		expect(jsonErr.maneuvers.length).toBeGreaterThanOrEqual(2);
		vi.doUnmock("#lib/server/valhalla.ts");
	});
});

describe("DemTileGrid", () => {
	it("is SSR-safe when browser globals are absent and supports customSampler", async () => {
		const ssrGrid = new DemTileGrid();
		await expect(
			ssrGrid.prefetchCorridor([offsetLatLon(0, 0), offsetLatLon(500, 500)]),
		).resolves.toBeUndefined();
		expect(ssrGrid.sampleElevation(BASE_LAT, BASE_LON)).toBeNull();

		const customGrid = new DemTileGrid({
			customSampler: (lat) => Math.round((lat - BASE_LAT) * 1000) + 1000,
		});
		await customGrid.prefetchCorridor([offsetLatLon(0, 0)]);
		expect(customGrid.sampleElevation(BASE_LAT, BASE_LON)).toBe(1000);
	});

	it("decodes Terrarium WebP tiles and caps prefetchCorridor at 9 tiles", async () => {
		const fakeRgba = new Uint8ClampedArray(512 * 512 * 4);
		// Terrarium 1500m: 1500 + 32768 = 34268 = 133 * 256 + 220
		for (let i = 0; i < 512 * 512; i++) {
			fakeRgba[i * 4] = 133;
			fakeRgba[i * 4 + 1] = 220;
			fakeRgba[i * 4 + 2] = 0;
			fakeRgba[i * 4 + 3] = 255;
		}
		const fetchMock = vi.fn().mockResolvedValue(new Response(new Uint8Array([1, 2, 3])));
		const origWindow = globalThis.window;
		const origFetch = globalThis.fetch;
		const origBitmap = globalThis.createImageBitmap;
		const origOffscreen = globalThis.OffscreenCanvas;

		try {
			(globalThis as Record<string, unknown>).window = {};
			globalThis.fetch = fetchMock as unknown as typeof fetch;
			(globalThis as Record<string, unknown>).createImageBitmap = vi.fn().mockResolvedValue({
				width: 512,
				height: 512,
				close: vi.fn(),
			});
			(globalThis as Record<string, unknown>).OffscreenCanvas = class {
				getContext() {
					return {
						drawImage: vi.fn(),
						getImageData: () => ({ data: fakeRgba }),
					};
				}
			} as unknown as typeof OffscreenCanvas;

			const grid = new DemTileGrid();
			// Large buffer spanning > 9 tiles must be capped at 9 fetches.
			await grid.prefetchCorridor([offsetLatLon(0, 0), offsetLatLon(50_000, 50_000)], 20_000);
			expect(fetchMock.mock.calls.length).toBeLessThanOrEqual(9);
			expect(fetchMock.mock.calls.length).toBeGreaterThan(0);

			const ele = grid.sampleElevation(BASE_LAT, BASE_LON);
			expect(ele).toBeCloseTo(1500, 1);
		} finally {
			(globalThis as Record<string, unknown>).window = origWindow;
			globalThis.fetch = origFetch;
			(globalThis as Record<string, unknown>).createImageBitmap = origBitmap;
			(globalThis as Record<string, unknown>).OffscreenCanvas = origOffscreen;
		}
	});
});

describe("computeOffTrailReroute", () => {
	it("contours around a synthetic 45° cliff/ravine between user and trail with maxSlopeDeg < 37", () => {
		const trail = makeStraightEastTrail(800, 25, () => 1000);
		const userPos = offsetLatLon(200, -140);

		// Steep 45° cliff ridge blocking direct North path (x in [80..320], y in [-85..-35]):
		// rises sharply from 1000m to 1055m over 25m (slope > 1.0 => > 45°).
		const cliffSampler = (lat: number, lon: number): number => {
			const e = (lon - BASE_LON) * M_PER_DEG_LON;
			const n = (lat - BASE_LAT) * M_PER_DEG_LAT;
			if (e >= 80 && e <= 320 && n >= -85 && n <= -35) {
				const distFromEdge = Math.min(n - -85, -35 - n);
				return 1000 + Math.min(55, distFromEdge * 2.2);
			}
			return 1000;
		};

		const reroute = computeOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 1000,
			trailPoints: trail,
			lastAlongTrackM: 180,
			sampler: cliffSampler,
			mode: "min-climb",
			locale: "ro",
		});

		expect(reroute.mode).toBe("min-climb");
		expect(reroute.points.length).toBeGreaterThan(2);
		expect(reroute.maxSlopeDeg).toBeLessThan(37);
		expect(reroute.avoidedSteepHazard).toBe(true);
		expect(reroute.distanceM).toBeGreaterThan(140);
		expect(reroute.initialBearingDeg).toBeGreaterThanOrEqual(0);
		expect(reroute.initialBearingDeg).toBeLessThan(360);
		expect(reroute.instruction).toContain("potecă");
		expect(reroute.slopeAdvice).toContain("abrupt");
	});

	it("falls back cleanly to IDW elevation interpolation when DEM sampler returns null", () => {
		const trail = makeStraightEastTrail(600, 25, (d) => 1100 + d * 0.05);
		const userPos = offsetLatLon(150, -100);

		const reroute = computeOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 1090,
			trailPoints: trail,
			lastAlongTrackM: 120,
			sampler: () => null,
			mode: "shortest-safe",
			locale: "en",
		});

		expect(reroute.mode).toBe("shortest-safe");
		expect(reroute.points.length).toBeGreaterThanOrEqual(2);
		expect(Number.isFinite(reroute.distanceM)).toBe(true);
		expect(Number.isFinite(reroute.rejoinEleM)).toBe(true);
		expect(reroute.distanceM).toBeGreaterThanOrEqual(95);
		expect(reroute.instruction).toContain("to trail");
	});

	it("contours around a synthetic 45° ravine and differentiates min-climb vs shortest-safe", () => {
		const trail = makeStraightEastTrail(800, 25, () => 1000);
		const userPos = offsetLatLon(200, -140);

		// Deep 45° ravine blocking direct path (drops -55m over 25m -> slope > 45°).
		const ravineSampler = (lat: number, lon: number): number => {
			const e = (lon - BASE_LON) * M_PER_DEG_LON;
			const n = (lat - BASE_LAT) * M_PER_DEG_LAT;
			if (e >= 100 && e <= 300 && n >= -85 && n <= -35) {
				const distFromEdge = Math.min(n - -85, -35 - n);
				return 1000 - Math.min(55, distFromEdge * 2.2);
			}
			return 1000;
		};

		const ravineReroute = computeOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 1000,
			trailPoints: trail,
			lastAlongTrackM: 180,
			sampler: ravineSampler,
			mode: "min-climb",
			locale: "en",
		});
		expect(ravineReroute.maxSlopeDeg).toBeLessThan(37);
		expect(ravineReroute.avoidedSteepHazard).toBe(true);

		// Moderate hill (30m climb over 100m = 30% slope, <37°) directly north vs flat detour around east side.
		const hillSampler = (lat: number, lon: number): number => {
			const e = (lon - BASE_LON) * M_PER_DEG_LON;
			const n = (lat - BASE_LAT) * M_PER_DEG_LAT;
			if (e >= 120 && e <= 280 && n >= -110 && n <= -10) {
				const dCenter = Math.hypot(e - 200, n - -60);
				return 1000 + Math.max(0, 35 - dCenter * 0.45);
			}
			return 1000;
		};

		const minClimb = computeOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 1000,
			trailPoints: trail,
			lastAlongTrackM: 180,
			sampler: hillSampler,
			mode: "min-climb",
			locale: "en",
		});
		const shortestSafe = computeOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 1000,
			trailPoints: trail,
			lastAlongTrackM: 180,
			sampler: hillSampler,
			mode: "shortest-safe",
			locale: "en",
		});

		expect(minClimb.ascentM).toBeLessThanOrEqual(shortestSafe.ascentM + 1e-6);
		expect(shortestSafe.distanceM).toBeLessThanOrEqual(minClimb.distanceM + 20);
	});
});

describe("additional edge cases across maneuvers and DEM bilinear interpolation", () => {
	it("detects slight and sharp turns with >= 60m spacing", () => {
		const pts: { lat: number; lon: number; ele: number }[] = [];
		// 0..100m North
		for (let n = 0; n <= 100; n += 10) pts.push({ ...offsetLatLon(0, n), ele: 500 });
		// 40° slight right (heading 40° for 120m)
		const rad40 = (40 * Math.PI) / 180;
		const pTurn1 = { e: 0, n: 100 };
		for (let d = 10; d <= 120; d += 10) {
			pts.push({
				...offsetLatLon(pTurn1.e + d * Math.sin(rad40), pTurn1.n + d * Math.cos(rad40)),
				ele: 500,
			});
		}
		// Sharp 130° left turn (heading 270° for 120m)
		const pTurn2 = { e: pTurn1.e + 120 * Math.sin(rad40), n: pTurn1.n + 120 * Math.cos(rad40) };
		for (let d = 10; d <= 120; d += 10) {
			pts.push({ ...offsetLatLon(pTurn2.e - d, pTurn2.n), ele: 500 });
		}

		const res = synthesizeTrailManeuvers(pts, { locale: "en" });
		expect(res.maneuvers.some((m) => m.type === 9)).toBe(true); // slightRight
		expect(res.maneuvers.some((m) => m.type === 14)).toBe(true); // sharpLeft
		for (const m of res.maneuvers) {
			expect(Number.isFinite(m.length)).toBe(true);
			expect(m.length).toBeGreaterThanOrEqual(0);
		}
	});

	it("performs bilinear interpolation across Terrarium DEM pixels", async () => {
		const fakeRgba = new Uint8ClampedArray(512 * 512 * 4);
		// Elevation varies linearly with x+y: ele = 1000 + x + y
		for (let y = 0; y < 512; y++) {
			for (let x = 0; x < 512; x++) {
				const ele = 1000 + x + y;
				const val = ele + 32768;
				const idx = (y * 512 + x) * 4;
				fakeRgba[idx] = Math.floor(val / 256);
				fakeRgba[idx + 1] = val % 256;
				fakeRgba[idx + 2] = 0;
				fakeRgba[idx + 3] = 255;
			}
		}

		const origWindow = globalThis.window;
		const origFetch = globalThis.fetch;
		const origBitmap = globalThis.createImageBitmap;
		const origOffscreen = globalThis.OffscreenCanvas;

		try {
			(globalThis as Record<string, unknown>).window = {};
			globalThis.fetch = vi
				.fn()
				.mockImplementation(() => Promise.resolve(new Response(new Uint8Array([1, 2, 3]))));
			(globalThis as Record<string, unknown>).createImageBitmap = vi.fn().mockResolvedValue({
				width: 512,
				height: 512,
				close: vi.fn(),
			});
			(globalThis as Record<string, unknown>).OffscreenCanvas = class {
				getContext() {
					return {
						drawImage: vi.fn(),
						getImageData: () => ({ data: fakeRgba }),
					};
				}
			} as unknown as typeof OffscreenCanvas;

			const grid = new DemTileGrid();
			await grid.prefetchCorridor([offsetLatLon(0, 0)], 0);
			const e1 = grid.sampleElevation(BASE_LAT, BASE_LON);
			const e2 = grid.sampleElevation(BASE_LAT + 0.0001, BASE_LON + 0.0001);
			expect(e1).not.toBeNull();
			expect(e2).not.toBeNull();
			expect(e1!).toBeGreaterThanOrEqual(1000);
			expect(e2!).not.toBe(e1!);
		} finally {
			(globalThis as Record<string, unknown>).window = origWindow;
			globalThis.fetch = origFetch;
			(globalThis as Record<string, unknown>).createImageBitmap = origBitmap;
			(globalThis as Record<string, unknown>).OffscreenCanvas = origOffscreen;
		}
	});
});
