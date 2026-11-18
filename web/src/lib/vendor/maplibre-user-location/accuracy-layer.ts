import type { GeoJSONSource, Map as MapLibreMap } from "maplibre-gl";

const SOURCE_ID = "wanderer-user-accuracy-source";
const FILL_LAYER_ID = "wanderer-user-accuracy-fill";
const OUTLINE_LAYER_ID = "wanderer-user-accuracy-outline";
const SEGMENTS = 64;
const MIN_DISPLAY_ACCURACY_METERS = 5;
const MAX_DISPLAY_ACCURACY_METERS = 2000;
const METERS_PER_DEG_LAT = 111_132.92;
const DEG_TO_RAD = Math.PI / 180;

const UNIT_SIN = new Float64Array(SEGMENTS + 1);
const UNIT_COS = new Float64Array(SEGMENTS + 1);
for (let i = 0; i <= SEGMENTS; i++) {
	const rad = ((i * 360) / SEGMENTS) * DEG_TO_RAD;
	UNIT_SIN[i] = Math.sin(rad);
	UNIT_COS[i] = Math.cos(rad);
}

/**
 * Builds a 64-segment geodesic circle GeoJSON polygon representing GPS accuracy
 * in real meters (`5m <= accuracy <= 2000m`) using precomputed trig tables (zero @turf allocations).
 */
export function buildAccuracyCircleGeoJSON(
	lon: number,
	lat: number,
	accuracyMeters: number,
): GeoJSON.FeatureCollection {
	if (
		!Number.isFinite(lon) ||
		!Number.isFinite(lat) ||
		!Number.isFinite(accuracyMeters) ||
		accuracyMeters < MIN_DISPLAY_ACCURACY_METERS
	) {
		return { type: "FeatureCollection", features: [] };
	}
	const radiusM = Math.min(accuracyMeters, MAX_DISPLAY_ACCURACY_METERS);
	const dLatDeg = radiusM / METERS_PER_DEG_LAT;
	const cosLat = Math.max(0.05, Math.cos(lat * DEG_TO_RAD));
	const dLonDeg = radiusM / (METERS_PER_DEG_LAT * cosLat);

	const ring = new Array<[number, number]>(SEGMENTS + 1);
	for (let i = 0; i <= SEGMENTS; i++) {
		if (i === SEGMENTS) {
			ring[i] = [ring[0][0], ring[0][1]];
		} else {
			ring[i] = [lon + dLonDeg * UNIT_SIN[i], lat + dLatDeg * UNIT_COS[i]];
		}
	}
	return {
		type: "FeatureCollection",
		features: [
			{
				type: "Feature",
				properties: {},
				geometry: {
					type: "Polygon",
					coordinates: [ring],
				},
			},
		],
	};
}

export class AccuracyLayer {
	private map: MapLibreMap | null = null;
	private latestData: GeoJSON.FeatureCollection = { type: "FeatureCollection", features: [] };
	private lastLon = NaN;
	private lastLat = NaN;
	private lastAccuracyM = NaN;

	private readonly handleStyleLoad = () => {
		this.ensureLayers();
	};

	attach(map: MapLibreMap): void {
		this.detach();
		this.map = map;
		map.on("style.load", this.handleStyleLoad);
		if (this.isStyleReady()) {
			this.ensureLayers();
		}
	}

	update(lon: number, lat: number, accuracyMeters: number): void {
		if (!Number.isFinite(lon) || !Number.isFinite(lat) || !Number.isFinite(accuracyMeters)) {
			this.clear();
			return;
		}
		if (accuracyMeters < MIN_DISPLAY_ACCURACY_METERS) {
			if (this.latestData.features.length > 0) {
				this.clear();
			}
			return;
		}

		if (Number.isFinite(this.lastLon) && Number.isFinite(this.lastLat)) {
			const dy = (lat - this.lastLat) * METERS_PER_DEG_LAT;
			const dx =
				(lon - this.lastLon) * METERS_PER_DEG_LAT * Math.cos(lat * DEG_TO_RAD);
			const movedSq = dx * dx + dy * dy;
			const accRelDelta =
				this.lastAccuracyM > 0
					? Math.abs(accuracyMeters - this.lastAccuracyM) / this.lastAccuracyM
					: Infinity;
			if (movedSq < 1.5 * 1.5 && accRelDelta < 0.1) {
				return;
			}
		}

		this.lastLon = lon;
		this.lastLat = lat;
		this.lastAccuracyM = accuracyMeters;
		this.latestData = buildAccuracyCircleGeoJSON(lon, lat, accuracyMeters);
		this.syncData();
	}

	clear(): void {
		this.lastLon = NaN;
		this.lastLat = NaN;
		this.lastAccuracyM = NaN;
		this.latestData = { type: "FeatureCollection", features: [] };
		this.syncData();
	}

	detach(): void {
		if (!this.map) return;
		this.map.off("style.load", this.handleStyleLoad);
		try {
			if (this.map.getLayer(OUTLINE_LAYER_ID)) this.map.removeLayer(OUTLINE_LAYER_ID);
			if (this.map.getLayer(FILL_LAYER_ID)) this.map.removeLayer(FILL_LAYER_ID);
			if (this.map.getSource(SOURCE_ID)) this.map.removeSource(SOURCE_ID);
		} catch {
			// Map or style may already be destroyed
		}
		this.map = null;
		this.lastLon = NaN;
		this.lastLat = NaN;
		this.lastAccuracyM = NaN;
	}

	private isStyleReady(): boolean {
		if (!this.map) return false;
		try {
			const hasStyle =
				typeof this.map.getStyle === "function" ? Boolean(this.map.getStyle()) : true;
			return hasStyle && Boolean(this.map.isStyleLoaded());
		} catch {
			return false;
		}
	}

	private ensureLayers(): void {
		if (!this.map) return;
		try {
			const existingSource = this.map.getSource(SOURCE_ID) as GeoJSONSource | undefined;
			if (!existingSource) {
				this.map.addSource(SOURCE_ID, {
					type: "geojson",
					data: this.latestData,
				});
			} else {
				existingSource.setData(this.latestData);
			}
			if (!this.map.getLayer(FILL_LAYER_ID)) {
				this.map.addLayer({
					id: FILL_LAYER_ID,
					type: "fill",
					source: SOURCE_ID,
					paint: {
						"fill-color": "#4285F4",
						"fill-opacity": 0.12,
					},
				});
			}
			if (!this.map.getLayer(OUTLINE_LAYER_ID)) {
				this.map.addLayer({
					id: OUTLINE_LAYER_ID,
					type: "line",
					source: SOURCE_ID,
					paint: {
						"line-color": "#4285F4",
						"line-opacity": 0.3,
						"line-width": 1,
					},
				});
			}
		} catch {
			// Style may be mid-swap; style.load will re-hydrate layers
		}
	}

	private syncData(): void {
		if (!this.map) return;
		if (!this.map.getSource(SOURCE_ID) && this.isStyleReady()) {
			this.ensureLayers();
			return;
		}
		try {
			const source = this.map.getSource(SOURCE_ID) as GeoJSONSource | undefined;
			source?.setData(this.latestData);
		} catch {
			// Ignore transient style teardown errors
		}
	}
}
