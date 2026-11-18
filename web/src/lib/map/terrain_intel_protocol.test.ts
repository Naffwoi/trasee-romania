import { describe, expect, it } from "vitest";
import { defaultMapState, overlays } from "#lib/vendor/maplibre-layer-manager/layers.ts";
import { parseTerrainProtocolUrl, quantizeSunTileQuery } from "./terrain_intel_protocol";

describe("terrain_intel_protocol & MapState overlay definitions", () => {
	it("parses terrain-slope and terrain-shade ZXY URLs with optional az/alt query parameters", () => {
		expect(parseTerrainProtocolUrl("terrain-slope://12/2337/1468")).toEqual({
			scheme: "terrain-slope",
			z: 12,
			x: 2337,
			y: 1468,
			azDeg: null,
			altDeg: null,
		});
		expect(parseTerrainProtocolUrl("terrain-shade://13/4674/2936?az=234&alt=14.5")).toEqual({
			scheme: "terrain-shade",
			z: 13,
			x: 4674,
			y: 2936,
			azDeg: 234,
			altDeg: 14.5,
		});
		expect(parseTerrainProtocolUrl("https://example.com/12/1/2.png")).toBeNull();
	});

	it("quantizes sun azimuth to 2-deg steps and altitude to 1-deg steps to maximize tile cache hits", () => {
		expect(quantizeSunTileQuery(235.3, 14.2)).toBe("az=236&alt=14");
		expect(quantizeSunTileQuery(235.8, 14.4)).toBe("az=236&alt=14");
	});

	it("registers avalancheSlope and solarShadows in overlays and defaultMapState", () => {
		expect(overlays.avalancheSlope).toBeDefined();
		expect(overlays.solarShadows).toBeDefined();
		expect(defaultMapState.overlays.avalancheSlope).toBe(false);
		expect(defaultMapState.overlays.solarShadows).toBe(false);
	});
});
