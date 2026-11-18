import { describe, expect, it, vi } from "vitest";
import { AccuracyLayer, buildAccuracyCircleGeoJSON } from "./accuracy-layer";

describe("AccuracyLayer fast ring & dirty gating", () => {
	it("builds a closed 65-vertex geodesic polygon accurate to <0.5% in Romania", () => {
		const fc = buildAccuracyCircleGeoJSON(25.55, 45.44, 50);
		expect(fc.features).toHaveLength(1);
		const ring = (fc.features[0].geometry as GeoJSON.Polygon).coordinates[0];
		expect(ring).toHaveLength(65);
		expect(ring[0]).toEqual(ring[64]);
		// North vertex (bearing 0 -> i=0): ~50m north = +0.0004499 deg lat
		expect(ring[0][1] - 45.44).toBeCloseTo(50 / 111132, 5);
	});

	it("skips GeoJSONSource.setData on sub-1.5m jitter and updates when moved >=1.5m or accuracy shifts >=10%", () => {
		const setData = vi.fn();
		const fakeMap = {
			on: vi.fn(),
			off: vi.fn(),
			getStyle: () => ({}),
			isStyleLoaded: () => true,
			getSource: () => ({ setData }),
			getLayer: () => true,
			addLayer: vi.fn(),
		} as any;

		const layer = new AccuracyLayer();
		layer.attach(fakeMap);
		setData.mockClear();

		layer.update(25.55, 45.44, 20);
		expect(setData).toHaveBeenCalledTimes(1);

		// Sub-meter jitter (~0.5 m) and tiny accuracy delta (20 -> 20.5 m) -> 0 setData calls!
		layer.update(25.550004, 45.440003, 20.5);
		expect(setData).toHaveBeenCalledTimes(1);

		// Move ~5 m North -> triggers setData
		layer.update(25.55, 45.440045, 20.5);
		expect(setData).toHaveBeenCalledTimes(2);

		// Accuracy jump 20.5 -> 35 m (>10%) at same coord -> triggers setData
		layer.update(25.55, 45.440045, 35);
		expect(setData).toHaveBeenCalledTimes(3);
	});
});
