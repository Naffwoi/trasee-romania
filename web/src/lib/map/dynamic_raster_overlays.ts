import type { StyleSpecification } from "maplibre-gl";

const DEFAULT_GLYPHS = "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf";
const OPENFREEMAP_PLANET_URL = "https://tiles.openfreemap.org/planet";
const EARTH_HALF_CIRCUM_M = 20037508.342789244;

let cachedRainViewer: { spec: StyleSpecification; fetchedAtMs: number } | null = null;
const RAINVIEWER_TTL_MS = 5 * 60_000;

/** Converts Slippy XYZ tile coordinates into an EPSG:3857 bounding box `[minX, minY, maxX, maxY]`. */
export function xyzToEpsg3857Bbox(z: number, x: number, y: number): [number, number, number, number] {
	const tileSpan = (2 * EARTH_HALF_CIRCUM_M) / Math.pow(2, z);
	const minX = -EARTH_HALF_CIRCUM_M + x * tileSpan;
	const maxX = minX + tileSpan;
	const maxY = EARTH_HALF_CIRCUM_M - y * tileSpan;
	const minY = maxY - tileSpan;
	return [minX, minY, maxX, maxY];
}

/** Builds a hybrid satellite MapLibre StyleSpecification layering vector trails, waterways, and mountain peaks. */
export function buildHybridSatelliteStyle(
	sourceId: string,
	tiles: string[],
	maxzoom: number,
	attribution: string,
): StyleSpecification {
	return {
		version: 8,
		glyphs: DEFAULT_GLYPHS,
		sources: {
			[sourceId]: {
				type: "raster",
				tiles,
				tileSize: 256,
				maxzoom,
				attribution,
			},
			openmaptiles: {
				type: "vector",
				url: OPENFREEMAP_PLANET_URL,
				attribution:
					'&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank">OpenStreetMap</a>',
			},
		},
		layers: [
			{
				id: sourceId,
				type: "raster",
				source: sourceId,
			},
			{
				id: "sat-hybrid-waterway",
				type: "line",
				source: "openmaptiles",
				"source-layer": "waterway",
				minzoom: 11,
				paint: {
					"line-color": "rgba(96, 165, 250, 0.72)",
					"line-width": 1.5,
				},
			},
			{
				id: "sat-hybrid-paths",
				type: "line",
				source: "openmaptiles",
				"source-layer": "transportation",
				minzoom: 12,
				filter: ["in", "class", "path", "track", "footway"],
				paint: {
					"line-color": "rgba(255, 255, 255, 0.55)",
					"line-width": 1.3,
					"line-dasharray": [2, 2],
				},
			},
			{
				id: "sat-hybrid-places",
				type: "symbol",
				source: "openmaptiles",
				"source-layer": "place",
				minzoom: 7,
				layout: {
					"text-field": ["coalesce", ["get", "name:ro"], ["get", "name"]],
					"text-font": ["Noto Sans Regular"],
					"text-size": ["interpolate", ["linear"], ["zoom"], 7, 11, 14, 14],
				},
				paint: {
					"text-color": "#F9FAFB",
					"text-halo-color": "rgba(20, 22, 30, 0.88)",
					"text-halo-width": 1.8,
				},
			},
			{
				id: "sat-hybrid-peaks",
				type: "symbol",
				source: "openmaptiles",
				"source-layer": "mountain_peak",
				minzoom: 10,
				layout: {
					"text-field": [
						"case",
						["has", "ele"],
						[
							"concat",
							"▲ ",
							["coalesce", ["get", "name:ro"], ["get", "name"], ""],
							"\n",
							["to-string", ["get", "ele"]],
							" m",
						],
						["concat", "▲ ", ["coalesce", ["get", "name:ro"], ["get", "name"], ""]],
					],
					"text-font": ["Noto Sans Bold"],
					"text-size": 11.5,
				},
				paint: {
					"text-color": "#FFFFFF",
					"text-halo-color": "rgba(20, 22, 30, 0.92)",
					"text-halo-width": 1.9,
				},
			},
		],
	};
}

/** Builds the NASA GIBS VIIRS NOAA-20 NDSI snow-cover raster overlay (`maxzoom: 8`). */
export function buildGibsSnowOverlaySpec(isoDate: string = "default"): StyleSpecification {
	const safeDate = /^\d{4}-\d{2}-\d{2}$/.test(isoDate) ? isoDate : "default";
	return {
		version: 8,
		name: "gibsSnowCover",
		sources: {
			gibsSnowCover: {
				type: "raster",
				tiles: [
					`https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_NOAA20_NDSI_Snow_Cover/default/${safeDate}/GoogleMapsCompatible_Level8/{z}/{y}/{x}.png`,
				],
				tileSize: 256,
				maxzoom: 8,
				attribution: "NASA EOSDIS GIBS (VIIRS NOAA-20 NDSI Snow Cover)",
			},
		},
		layers: [
			{
				id: "gibsSnowCover",
				type: "raster",
				source: "gibsSnowCover",
				paint: {
					"raster-opacity": 0.68,
					"raster-resampling": "linear",
				},
			},
		],
	};
}

/** Builds the NASA GIBS VIIRS NOAA-20 daily True Color raster overlay (`maxzoom: 9`). */
export function buildGibsTrueColorOverlaySpec(isoDate: string = "default"): StyleSpecification {
	const safeDate = /^\d{4}-\d{2}-\d{2}$/.test(isoDate) ? isoDate : "default";
	return {
		version: 8,
		name: "gibsTrueColor",
		sources: {
			gibsTrueColor: {
				type: "raster",
				tiles: [
					`https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_NOAA20_CorrectedReflectance_TrueColor/default/${safeDate}/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpg`,
				],
				tileSize: 256,
				maxzoom: 9,
				attribution: "NASA EOSDIS GIBS (VIIRS NOAA-20 True Color)",
			},
		},
		layers: [
			{
				id: "gibsTrueColor",
				type: "raster",
				source: "gibsTrueColor",
				paint: {
					"raster-opacity": 0.86,
				},
			},
		],
	};
}

/** Builds the UMD GLAD DIST-ALERT recent forest disturbance raster overlay (`maxzoom: 14`). */
export function buildGfwDisturbanceOverlaySpec(startIsoDate?: string): StyleSpecification {
	const cutoff =
		startIsoDate ?? new Date(Date.now() - 180 * 86_400_000).toISOString().slice(0, 10);
	return {
		version: 8,
		name: "gfwDisturbance",
		sources: {
			gfwDisturbance: {
				type: "raster",
				tiles: [
					`https://tiles.globalforestwatch.org/umd_glad_dist_alerts/latest/dynamic/{z}/{x}/{y}.png?render_type=true_color&alert_confidence=high&tree_cover_density_threshold=30&tree_cover_height_threshold=5&start_date=${cutoff}`,
				],
				tileSize: 256,
				maxzoom: 14,
				attribution: "UMD GLAD DIST-ALERT via Global Forest Watch (CC BY 4.0)",
			},
		},
		layers: [
			{
				id: "gfwDisturbance",
				type: "raster",
				source: "gfwDisturbance",
				paint: {
					"raster-opacity": 0.78,
				},
			},
		],
	};
}

/** Resolves the latest RainViewer radar frame capped at `maxzoom: 7` (cached 5 min). */
export async function resolveRainViewerOverlaySpec(
	fetchFn: typeof fetch = fetch,
): Promise<StyleSpecification | null> {
	if (cachedRainViewer && Date.now() - cachedRainViewer.fetchedAtMs < RAINVIEWER_TTL_MS) {
		return cachedRainViewer.spec;
	}
	try {
		const res = await fetchFn("https://api.rainviewer.com/public/weather-maps.json");
		if (!res.ok) return null;
		const data = (await res.json()) as {
			host?: string;
			radar?: { past?: Array<{ time: number; path: string }> };
		};
		const past = data.radar?.past ?? [];
		const latest = past[past.length - 1];
		if (!data.host || !latest?.path) return null;
		const spec: StyleSpecification = {
			version: 8,
			name: "rainViewerRadar",
			sources: {
				rainViewerRadar: {
					type: "raster",
					tiles: [`${data.host}${latest.path}/256/{z}/{x}/{y}/2/1_1.png`],
					tileSize: 256,
					maxzoom: 7,
					attribution:
						'Radar &copy; <a href="https://www.rainviewer.com" target="_blank">RainViewer</a>',
				},
			},
			layers: [
				{
					id: "rainViewerRadar",
					type: "raster",
					source: "rainViewerRadar",
					paint: {
						"raster-opacity": 0.65,
						"raster-resampling": "linear",
					},
				},
			],
		};
		cachedRainViewer = { spec, fetchedAtMs: Date.now() };
		return spec;
	} catch {
		return null;
	}
}
