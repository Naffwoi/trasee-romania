import destination from "@turf/destination";
import type { GeoJSONSource, Map as MapLibreMap } from "maplibre-gl";

const SOURCE_ID = "wanderer-user-accuracy-source";
const FILL_LAYER_ID = "wanderer-user-accuracy-fill";
const OUTLINE_LAYER_ID = "wanderer-user-accuracy-outline";
const SEGMENTS = 64;
const MIN_DISPLAY_ACCURACY_METERS = 5;
const MAX_DISPLAY_ACCURACY_METERS = 2000;

/**
 * Builds a 64-segment geodesic circle GeoJSON polygon representing GPS accuracy
 * in real meters (`5m <= accuracy <= 2000m`). Returns an empty collection below `5m`.
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
    const radiusKm = Math.min(accuracyMeters, MAX_DISPLAY_ACCURACY_METERS) / 1000;
    const ring: [number, number][] = [];
    for (let i = 0; i <= SEGMENTS; i++) {
        const bearing = (i * 360) / SEGMENTS;
        const pt = destination([lon, lat], radiusKm, bearing, { units: "kilometers" });
        ring.push(pt.geometry.coordinates as [number, number]);
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

/**
 * Manages the GeoJSON source and fill/outline layers for the GPS accuracy halo
 * and re-attaches them automatically whenever MapLibre swaps base styles.
 */
export class AccuracyLayer {
    private map: MapLibreMap | null = null;
    private latestData: GeoJSON.FeatureCollection = { type: "FeatureCollection", features: [] };
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
        this.latestData = buildAccuracyCircleGeoJSON(lon, lat, accuracyMeters);
        this.syncData();
    }

    clear(): void {
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
    }

    private isStyleReady(): boolean {
        if (!this.map) return false;
        try {
            const hasStyle = typeof this.map.getStyle === "function" ? Boolean(this.map.getStyle()) : true;
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
        }
        try {
            const source = this.map.getSource(SOURCE_ID) as GeoJSONSource | undefined;
            source?.setData(this.latestData);
        } catch {
            // Ignore transient style teardown errors
        }
    }
}
