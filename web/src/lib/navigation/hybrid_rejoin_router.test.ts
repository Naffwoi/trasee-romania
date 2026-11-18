import { describe, expect, it, vi } from "vitest";
import { encodePolyline } from "#lib/util/polyline_util.ts";
import {
	computeHybridOffTrailReroute,
	computeValhallaAccessRoute,
	extractMapLibreObstacles,
} from "./hybrid_rejoin_router";
import type { NavTrackPoint, ObstaclePolygon } from "./types";

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

function makeStraightEastTrail(lengthM: number, stepM: number): NavTrackPoint[] {
	const count = Math.floor(lengthM / stepM) + 1;
	return Array.from({ length: count }, (_, i) => {
		const d = i * stepM;
		const { lat, lon } = offsetLatLon(d, 0);
		return { lat, lon, ele: 1000, distanceM: d, gradePct: 0 };
	});
}

describe("extractMapLibreObstacles", () => {
	it("extracts building/water polygons and path/footway/track corridors within bbox and catches missing source errors", () => {
		const b1 = offsetLatLon(50, -50);
		const b2 = offsetLatLon(90, -50);
		const b3 = offsetLatLon(90, -20);
		const b4 = offsetLatLon(50, -20);

		const far = offsetLatLon(5000, 5000);
		const p1 = offsetLatLon(20, -80);
		const p2 = offsetLatLon(120, -10);

		const mockMap = {
			querySourceFeatures: vi.fn((sourceId: string, params?: { sourceLayer?: string }) => {
				expect(sourceId).toBe("openmaptiles");
				if (params?.sourceLayer === "building") {
					return [
						{
							geometry: {
								type: "Polygon",
								coordinates: [
									[
										[b1.lon, b1.lat],
										[b2.lon, b2.lat],
										[b3.lon, b3.lat],
										[b4.lon, b4.lat],
										[b1.lon, b1.lat],
									],
								],
							},
							properties: { class: "school" },
						},
						{
							// Far outside bbox -> filtered out
							geometry: {
								type: "Polygon",
								coordinates: [
									[
										[far.lon, far.lat],
										[far.lon + 0.001, far.lat],
										[far.lon + 0.001, far.lat + 0.001],
										[far.lon, far.lat],
									],
								],
							},
							properties: {},
						},
					];
				}
				if (params?.sourceLayer === "water") {
					return [
						{
							geometry: {
								type: "MultiPolygon",
								coordinates: [
									[
										[
											[b1.lon, b1.lat],
											[b2.lon, b1.lat],
											[b3.lon, b3.lat],
											[b1.lon, b1.lat],
										],
									],
								],
							},
							properties: { class: "lake" },
						},
					];
				}
				if (params?.sourceLayer === "transportation") {
					return [
						{
							geometry: {
								type: "LineString",
								coordinates: [
									[p1.lon, p1.lat],
									[p2.lon, p2.lat],
								],
							},
							properties: { class: "path", subclass: "footway" },
						},
						{
							geometry: {
								type: "LineString",
								coordinates: [
									[p1.lon, p1.lat],
									[p2.lon, p2.lat],
								],
							},
							properties: { class: "motorway" },
						},
					];
				}
				return [];
			}),
		};

		const sw = offsetLatLon(-200, -200);
		const ne = offsetLatLon(400, 200);
		const extracted = extractMapLibreObstacles(mockMap, [sw.lon, sw.lat, ne.lon, ne.lat]);
		expect(extracted.obstacles).toHaveLength(2);
		expect(extracted.preferredPaths).toHaveLength(1);
		expect(extracted.preferredPaths[0].coords).toHaveLength(2);

		// Throwing map (e.g. raster style without "openmaptiles") returns empty arrays safely
		const throwingMap = {
			querySourceFeatures: () => {
				throw new Error("Source openmaptiles does not exist");
			},
		};
		expect(extractMapLibreObstacles(throwingMap, [sw.lon, sw.lat, ne.lon, ne.lat])).toEqual({
			obstacles: [],
			preferredPaths: [],
		});
	});
});

describe("computeHybridOffTrailReroute & computeValhallaAccessRoute", () => {
	it("uses Valhalla precision-6 curved OSM geometry, samples DEM elevations, and stitches >25m off-road connectors", async () => {
		const trail = makeStraightEastTrail(1000, 25);
		const userPos = offsetLatLon(200, -150);

		// Valhalla road starts 45m away from user (>25m gap) and ends 40m short of trail (>25m gap)
		const v0 = offsetLatLon(210, -110);
		const v1 = offsetLatLon(245, -85);
		const v2 = offsetLatLon(275, -60);
		const v3 = offsetLatLon(290, -40);
		const encodedShape = encodePolyline(
			[
				[v0.lat, v0.lon],
				[v1.lat, v1.lon],
				[v2.lat, v2.lon],
				[v3.lat, v3.lon],
			],
			6,
		);

		const fetchMock = vi.fn().mockResolvedValue(
			new Response(
				JSON.stringify({
					trip: {
						summary: { time: 185, length: 0.22 },
						legs: [
							{
								shape: encodedShape,
								maneuvers: [{ instruction: "Continuă pe poteca spre nord-est" }],
							},
						],
					},
				}),
				{ status: 200, headers: { "content-type": "application/json" } },
			),
		);

		const res = await computeHybridOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 980,
			trailPoints: trail,
			lastAlongTrackM: 200,
			sampler: (lat) => 1000 + (lat - BASE_LAT) * 2000,
			mode: "min-climb",
			locale: "ro",
			isCycling: false,
			fetchImpl: fetchMock as unknown as typeof fetch,
		});

		expect(res).not.toBeNull();
		expect(fetchMock).toHaveBeenCalledTimes(1);
		const [calledUrl, reqInit] = fetchMock.mock.calls[0];
		expect(calledUrl).toBe("/api/v1/valhalla/route");
		const parsedBody = JSON.parse(reqInit.body as string);
		expect(parsedBody.costing).toBe("pedestrian");
		expect(parsedBody.language).toBe("ro-RO");
		expect(parsedBody.costing_options.pedestrian.use_hills).toBe(0.15);

		// Starts at userPos, includes Valhalla curved points, and stitches to trail rejoin (>= 6 points)
		expect(res!.points.length).toBeGreaterThanOrEqual(6);
		expect(res!.points[0].lat).toBeCloseTo(userPos.lat, 5);
		expect(res!.points[0].lon).toBeCloseTo(userPos.lon, 5);
		expect(res!.points[res!.points.length - 1].lat).toBeCloseTo(res!.rejoinLat, 5);
		expect(res!.points[res!.points.length - 1].lon).toBeCloseTo(res!.rejoinLon, 5);
		expect(res!.rejoinAlongTrackM).toBeGreaterThanOrEqual(200);
		expect(Number.isFinite(res!.ascentM)).toBe(true);
		expect(Number.isFinite(res!.estimatedSeconds)).toBe(true);
		expect(res!.estimatedSeconds).toBeGreaterThan(0);
	});

	it("falls back cleanly to local obstacle + Chaikin curved A* when offline or Valhalla returns HTTP 502, and returns null when >3 km", async () => {
		const trail = makeStraightEastTrail(1000, 25);
		const userPos = offsetLatLon(200, -130);

		const c1 = offsetLatLon(140, -95);
		const c2 = offsetLatLon(300, -95);
		const c3 = offsetLatLon(300, -35);
		const c4 = offsetLatLon(140, -35);
		const building: ObstaclePolygon = {
			rings: [
				[c1.lon, c1.lat],
				[c2.lon, c2.lat],
				[c3.lon, c3.lat],
				[c4.lon, c4.lat],
				[c1.lon, c1.lat],
			],
		};

		const failingFetch = vi
			.fn()
			.mockResolvedValue(new Response(JSON.stringify({ message: "Bad Gateway" }), { status: 502 }));

		const fallbackRes = await computeHybridOffTrailReroute({
			userLat: userPos.lat,
			userLon: userPos.lon,
			userEle: 1000,
			trailPoints: trail,
			lastAlongTrackM: 200,
			sampler: () => 1000,
			mode: "shortest-safe",
			locale: "ro",
			isCycling: true,
			obstacles: [building],
			fetchImpl: failingFetch as unknown as typeof fetch,
		});

		expect(fallbackRes).not.toBeNull();
		expect(fallbackRes!.points.length).toBeGreaterThanOrEqual(6);
		const parsedBody = JSON.parse(failingFetch.mock.calls[0][1].body as string);
		expect(parsedBody.costing).toBe("bicycle");
		expect(parsedBody.costing_options.bicycle.use_hills).toBe(0.75);

		// > 3 km Preview Mode returns null without invoking fetch
		const farFetch = vi.fn();
		const farPos = offsetLatLon(200, -4500);
		const previewNull = await computeHybridOffTrailReroute({
			userLat: farPos.lat,
			userLon: farPos.lon,
			trailPoints: trail,
			lastAlongTrackM: 0,
			sampler: () => 1000,
			fetchImpl: farFetch as unknown as typeof fetch,
		});
		expect(previewNull).toBeNull();
		expect(farFetch).not.toHaveBeenCalled();
	});

	it("computes optional >3km preview access route via computeValhallaAccessRoute", async () => {
		const start = offsetLatLon(0, 0);
		const farUser = offsetLatLon(-8000, -6000); // 10 km away
		const mid = offsetLatLon(-4000, -3000);
		const shape = encodePolyline(
			[
				[farUser.lat, farUser.lon],
				[mid.lat, mid.lon],
				[start.lat, start.lon],
			],
			6,
		);

		const fetchMock = vi.fn().mockResolvedValue(
			new Response(
				JSON.stringify({
					trip: {
						summary: { time: 900, length: 10.0 },
						legs: [{ shape }],
					},
				}),
				{ status: 200 },
			),
		);

		const accessPts = await computeValhallaAccessRoute(
			farUser.lat,
			farUser.lon,
			start.lat,
			start.lon,
			false,
			fetchMock as unknown as typeof fetch,
			() => 850,
		);
		expect(accessPts).not.toBeNull();
		expect(accessPts!).toHaveLength(3);
		expect(accessPts![0].distanceM).toBe(0);
		expect(accessPts![2].distanceM).toBeGreaterThan(9_500);
		expect(accessPts![1].ele).toBe(850);
	});
});
