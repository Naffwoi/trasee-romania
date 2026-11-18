<script lang="ts">
    import { page } from "$app/state";
    import directionCaret from "#lib/assets/svgs/caret-right-solid.svg";
    import GPX from "#lib/models/gpx/gpx.ts";
    import { haversineDistance } from "#lib/models/gpx/utils.ts";
    import type { Trail } from "#lib/models/trail.ts";
    import type { Waypoint } from "#lib/models/waypoint.ts";
    import { theme } from "#lib/stores/theme_store.ts";
    import { findStartAndEndPoints } from "#lib/util/geojson_util.ts";
    import {
        createMarkerFromWaypoint,
        createPopupFromTrail,
        FontawesomeMarker,
    } from "#lib/util/maplibre_util.ts";
    import { decodePolyline } from "#lib/util/polyline_util.ts";
    import { FullscreenControl } from "#lib/vendor/maplibre-fullscreen/fullscreen-control.ts";
    import MaplibreGraticule from "#lib/vendor/maplibre-graticule/maplibre-graticule.ts";
    import { CaretLayer } from "#lib/vendor/maplibre-layer-manager/caret-layer.ts";
    import { ensureTrailheadImages, withTrailheadIcons } from "#lib/util/trailhead_marker.ts";
    import { ClusterLayer } from "#lib/vendor/maplibre-layer-manager/cluster-layer.ts";
    import { baseMapStyles, type BaseLayer } from "#lib/vendor/maplibre-layer-manager/layers.ts";
    import { LayerManager } from "#lib/vendor/maplibre-layer-manager/maplibre-layer-manager.ts";
    import type { OverpassPopupActionFactory } from "#lib/vendor/maplibre-layer-manager/overpass-layer.ts";
    import { PreviewLayer } from "#lib/vendor/maplibre-layer-manager/preview-layer.ts";
    import { TerrainLayer } from "#lib/vendor/maplibre-layer-manager/terrain-layer.ts";
    import { TrailLayer } from "#lib/vendor/maplibre-layer-manager/trail-layer.ts";
    import { StyleSwitcherControl } from "#lib/vendor/maplibre-style-switcher/style-switcher-control.ts";
    import { UserLocationControl } from "#lib/vendor/maplibre-user-location/user-location-control.ts";
    import { clearHeartbeat, sendHeartbeat } from "#lib/live/live_client.ts";
    import type { Feature, FeatureCollection, GeoJSON } from "geojson";
    import * as M from "maplibre-gl";
    import "maplibre-gl/dist/maplibre-gl.css";
    import "#lib/util/maplibre_worker.ts";
    import { _, locale } from "svelte-i18n";
    import { onDestroy, onMount, untrack } from "svelte";

    interface Props {
        trails?: Trail[];
        serverClusters?: GeoJSON.FeatureCollection;
        gpx?: GPX;
        waypoints?: Waypoint[];
        markers?: M.Marker[];
        map?: M.Map | null;
        drawing?: boolean;
        displayWaypoints?: boolean;
        showElevation?: boolean;
        showInfoPopup?: boolean;
        showClusterPopups?: boolean;
        showGrid?: boolean;
        showStyleSwitcher?: boolean;
        showFullscreen?: boolean;
        showTerrain?: boolean;
        scalePosition?: M.ControlPosition;
        fitBounds?: "animate" | "instant" | "off";
        onmarkerdragend?:
            | ((marker: M.Marker, wpId?: string) => void)
            | undefined;
        elevationProfileContainer?: string | HTMLDivElement | undefined;
        mapOptions?: Partial<M.MapOptions> | undefined;
        activeTrail?: number | null;
        clusterTrails?: boolean;
        onsegmentdragend?: (data: {
            segment: number;
            event: M.MapMouseEvent;
        }) => void;
        onsegmentclick?: (data: {
            segment: number;
            event: M.MapMouseEvent;
        }) => void;
        onselect?: (trail: Trail) => void;
        onunselect?: (trail: Trail) => void;
        onfullscreen?: () => void;
        onmoveend?: (map: M.Map) => void;
        onzoom?: (map: M.Map) => void;
        onclick?: (event: M.MapMouseEvent & Object) => void;
        oncontextmenu?: (event: M.MapMouseEvent & Object) => void;
        onUnclusteredClick?: (
            event: M.MapMouseEvent & Object,
            trail: Trail,
        ) => void;
        oninit?: (map: M.Map) => void;
        onlocationerror?: (message: string) => void;
        autoGeolocateOnDrawing?: boolean;
        buildPoiAnchorAction?: OverpassPopupActionFactory;
        selectedPreviewTrail?: Trail | null;
        onTrailPinSelect?: (trail: Trail) => void;
        onMapBackgroundClick?: () => void;
        mobileChrome?: boolean;
        hideTrailRoute?: boolean;
        fitPaddingBottom?: number;
        onElevationMove?: (data: { distance: number; elevation: number; dPlus: number; gradePercent: number } | null) => void;
        onElevationSummary?: (summary: { minElevation: number | null; maxElevation: number | null; totalAscent: number }) => void;
    }

    let {
        trails = [],
        serverClusters = undefined,
        waypoints = [],
        markers = $bindable([]),
        map = $bindable(),
        drawing = false,
        displayWaypoints = true,
        showElevation = true,
        showInfoPopup = false,
        showClusterPopups = true,
        showGrid = false,
        showStyleSwitcher = true,
        showFullscreen = false,
        showTerrain = false,
        scalePosition = "top-left",
        fitBounds = "instant",
        elevationProfileContainer = undefined,
        mapOptions = undefined,
        activeTrail = $bindable(0),
        clusterTrails = false,
        onmarkerdragend,
        onsegmentdragend,
        onsegmentclick,
        onselect,
        onunselect,
        onfullscreen,
        onmoveend,
        onzoom,
        onclick,
        oncontextmenu,
        onUnclusteredClick,
        oninit,
        onlocationerror,
        autoGeolocateOnDrawing = false,
        buildPoiAnchorAction = undefined,
        selectedPreviewTrail = null,
        onTrailPinSelect = undefined,
        onMapBackgroundClick = undefined,
        mobileChrome = false,
        hideTrailRoute = false,
        fitPaddingBottom = 16,
        onElevationMove = undefined,
        onElevationSummary = undefined,
    }: Props = $props();

    type ElevationProfileControlInstance = InstanceType<
        Awaited<ReturnType<typeof loadElevationProfileControlModule>>["ElevationProfileControl"]
    >;

    let mapContainer: HTMLDivElement;
    let epc: ElevationProfileControlInstance | undefined;
    let graticule: MaplibreGraticule;

    let layerManager: LayerManager;
    let scale: { control: M.ScaleControl; position: M.ControlPosition } | undefined = $state.raw();
    $effect(() => {
        if (map && scale && scalePosition !== scale.position) {
            map.removeControl(scale.control);
            map.addControl(scale.control, scalePosition);
            scale.position = scalePosition;
        }
    });

    let elevationMarker: FontawesomeMarker;

    let draggingSegment: number | null = null;

    let hoveringTrail: boolean = false;

    let mapLoaded: boolean = $state(false);
    let terrainEnabled: boolean | null = null;
    let elevationProfileVisibilityPreference: boolean | null = null;

    const trailColors = [
        "#3549bb", // blue
        "#ff7f0e", // orange
        "#2ca02c", // green
        "#d62728", // red
        "#9467bd", // purple
        "#8c564b", // brown
        "#e377c2", // pink
        "#373642", // gray
        "#fae455", // yellow
        "#17becf", // teal
    ];

    let clusterPopup: M.Popup | null = null;
    let clusterPopupTrail: string | undefined;
    let clusterHighlight: M.Marker | undefined;

    $effect(() => {
        const popups = showClusterPopups;
        untrack(() => {
            clusterHighlight?.remove();
            if (!popups) {
                clusterPopup?.remove();
                map?.off("mousemove", unHighlightClusterDistanceNotifier);
            }
        });
    });

    let mapData = $derived(getData(trails, serverClusters));
    let gpxDataMap = $derived(mapData[0]);
    let clusterData = $derived(mapData[1]);
    let previewData = $derived(mapData[2]);

    $effect(() => {
        // Track dependencies for Svelte 5
        mapData;

        if (map && mapLoaded) {
            untrack(() => initMap(map?.loaded() ?? false));
        }
    });
    $effect(() => {
        adjustTrailFocus(activeTrail);
    });
    $effect(() => {
        toggleEpcTheme();
    });
    $effect(() => {
        if (drawing && map && layerManager) {
            untrack(() => startDrawing());
        } else if (map && layerManager) {
            untrack(() => stopDrawing());
        }
    });
    $effect(() => {
        if (showGrid) {
            if (!graticule) {
                graticule = new MaplibreGraticule({
                    minZoom: 0,
                    maxZoom: 20,
                    showLabels: true,
                    labelType: "hdms",
                    labelSize: 10,
                    labelColor: "#858585",
                    longitudePosition: "top",
                    latitudePosition: "right",
                    paint: {
                        "line-opacity": 0.8,
                        "line-color": "rgba(0,0,0,0.2)",
                    },
                });
            }
            map?.addControl(graticule);
        } else {
            if (graticule) {
                map?.removeControl(graticule);
            }
        }
    });
    $effect(() => {
        waypoints;
        displayWaypoints;
        untrack(() => {
            syncWaypointMarkers();
            refreshElevationProfile();
        });
    });

    function getData(
        trails: Trail[],
        serverClusters?: GeoJSON.FeatureCollection
    ): [
        Record<string, FeatureCollection>,
        FeatureCollection,
        FeatureCollection,
    ] {
        let clusterData: FeatureCollection = serverClusters ?? {
            type: "FeatureCollection",
            features: [],
        };
        let previewData: FeatureCollection = {
            type: "FeatureCollection",
            features: [],
        };
        let gpxDataMap: Record<string, FeatureCollection> = {};

        trails.forEach((t) => {
            if (t.id) {
                let fc: FeatureCollection | null = null;
                if (t.expand?.gpx) {
                    fc = t.expand.gpx.toGeoJSON();
                } else if (t.expand?.gpx_data) {
                    fc = GPX.parse(t.expand.gpx_data).toGeoJSON();
                } else if (!clusterTrails && t.polyline) {
                    const coords = decodePolyline(t.polyline, 5);
                    if (coords.length >= 2) {
                        fc = {
                            type: "FeatureCollection",
                            features: [
                                {
                                    type: "Feature",
                                    properties: {},
                                    geometry: {
                                        type: "LineString",
                                        coordinates: coords,
                                    },
                                },
                            ],
                        };
                    }
                }

                if (fc) {
                    fc.features.forEach((f) => {
                        if (f.properties) {
                            f.properties.bounding_box_diagonal =
                                t.bounding_box_diagonal;
                        }
                    });
                    gpxDataMap[t.id] = fc;
                }
            }

            if (clusterTrails) {
                if (!serverClusters && t.lat !== undefined && t.lon !== undefined) {
                    clusterData.features.push({
                        id: t.id,
                        type: "Feature",
                        properties: {
                            trail: t.id,
                            bounding_box_diagonal: t.bounding_box_diagonal,
                            category_icon: t.expand?.category?.icon ?? "",
                            subcategory_id: t.subcategory ?? "",
                        },
                        geometry: {
                            type: "Point",
                            coordinates: [t.lon ?? 0, t.lat ?? 0],
                        },
                    } as Feature);
                }

                if (t.polyline) {
                    previewData.features.push({
                        id: t.id,
                        type: "Feature",
                        properties: {
                            trail: t.id,
                            bounding_box_diagonal: t.bounding_box_diagonal,
                            category_icon: t.expand?.category?.icon ?? "",
                            subcategory_id: t.subcategory ?? "",
                            color: trailColors[
                                hashStringToIndex(
                                    t.id ?? "",
                                    trailColors.length,
                                )
                            ],
                        },
                        geometry: {
                            type: "LineString",
                            coordinates: decodePolyline(t.polyline, 5),
                        },
                    });
                }
            }
        });

        return [gpxDataMap, clusterData, previewData];
    }

    function initMap(mapLoaded: boolean) {
        if (!map || !layerManager) {
            return;
        }

        refreshElevationProfile();
        syncElevationProfileVisibility();

        trails.forEach((t) => {
            const layerId = t.id!;
            addTrailLayer(t, layerId, 0, gpxDataMap[layerId]);
        });

        Object.entries(layerManager.layers).forEach(([id, layer]) => {
            if (!(layer instanceof TrailLayer)) {
                return;
            }
            const isStillVisible = trails.some((t) => t.id === id);
            if (!isStillVisible) {
                removeCaretLayer();
                removeTrailLayer(id);
            }
        });

        if (clusterTrails) {
            addPreviewLayer(previewData);
            addClusterLayer(clusterData);
        }

        if (!drawing && fitBounds !== "off") {
            const currentBboxes = Object.values(gpxDataMap)
                .map((d) => d.bbox)
                .filter((b) => b !== undefined);

            if (
                activeTrail !== null &&
                trails[activeTrail] &&
                mapLoaded &&
                gpxDataMap[trails[activeTrail].id!]
            ) {
                focusTrail(trails[activeTrail]);
            } else if (currentBboxes.length > 0) {
                flyToBounds();
            }
        } else if (drawing && activeTrail !== null && mapLoaded) {
            const activeId = trails[activeTrail]?.id;
            if (activeId && gpxDataMap[activeId]) {
                addCaretLayer(gpxDataMap[activeId]);
            }
        }
    }

    function syncHillshadingVisibility() {
        if (!map?.getLayer("hillshading")) {
            terrainEnabled = null;
            return;
        }

        const isTerrainEnabled = Boolean(map.getTerrain());
        if (isTerrainEnabled === terrainEnabled) {
            return;
        }

        map.setLayoutProperty(
            "hillshading",
            "visibility",
            isTerrainEnabled ? "visible" : "none",
        );
        terrainEnabled = isTerrainEnabled;
    }

    $effect(() => {
        if (!map || !mapLoaded || trails.length !== 1) return;
        const trailId = trails[0]?.id;
        if (!trailId) return;
        untrack(() => {
            if (hideTrailRoute) {
                removeCaretLayer();
                removeTrailLayer(trailId);
            } else {
                addTrailLayer(trails[0], trailId, 0, gpxDataMap[trailId]);
                if (gpxDataMap[trailId]) {
                    addCaretLayer(gpxDataMap[trailId]);
                }
            }
        });
    });

    let selectedRouteRequest = 0;
    const selectedPolylineCache = new Map<string, string>();
    $effect(() => {
        const preview = selectedPreviewTrail;
        const ready = mapLoaded;
        if (!ready || !map || !layerManager) return;
        untrack(() => {
            void syncSelectedPreviewRoute(preview);
        });
    });

    async function syncSelectedPreviewRoute(preview: Trail | null) {
        const request = ++selectedRouteRequest;
        if (!map || !layerManager) return;

        layerManager.removeLayer("selected-trail-route");
        if (!preview?.id) return;

        let encoded =
            preview.hover_polyline ||
            preview.polyline ||
            selectedPolylineCache.get(preview.id);

        if (!encoded) {
            try {
                const res = await fetch("/api/v1/search/multi", {
                    method: "POST",
                    body: JSON.stringify({
                        queries: [
                            {
                                indexUid: "trails",
                                q: "",
                                filter: [`id = '${preview.id}'`],
                                attributesToRetrieve: ["id", "polyline"],
                                hitsPerPage: 1,
                            },
                        ],
                    }),
                });
                if (res.ok) {
                    const data = await res.json();
                    encoded = data?.results?.[0]?.hits?.[0]?.polyline;
                }
            } catch {
                // Ignore transient search error on selection preview.
            }
        }

        if (
            request !== selectedRouteRequest ||
            !map ||
            !layerManager ||
            !encoded
        ) {
            return;
        }
        selectedPolylineCache.set(preview.id, encoded);

        const coords = decodePolyline(encoded, 5);
        if (coords.length < 2) return;

        const isClosedLoop =
            coords.length >= 4 &&
            haversineDistance(
                coords[0][1],
                coords[0][0],
                coords[coords.length - 1][1],
                coords[coords.length - 1][0],
            ) <= 180;

        const lineGeoJson: GeoJSON.FeatureCollection = {
            type: "FeatureCollection",
            features: [
                {
                    type: "Feature",
                    properties: { trail: preview.id },
                    geometry: { type: "LineString", coordinates: coords },
                },
            ],
        };

        const sources: Record<string, M.SourceSpecification> = {
            "selected-trail-route": {
                type: "geojson",
                data: lineGeoJson,
            },
        };
        const layers: M.LayerSpecification[] = [];

        if (isClosedLoop) {
            sources["selected-trail-loop-fill"] = {
                type: "geojson",
                data: {
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: { trail: preview.id },
                            geometry: {
                                type: "Polygon",
                                coordinates: [[...coords, coords[0]]],
                            },
                        },
                    ],
                },
            };
            layers.push({
                id: "selected-trail-loop-fill",
                type: "fill",
                source: "selected-trail-loop-fill",
                paint: {
                    "fill-color": "#3549bb",
                    "fill-opacity": 0.22,
                },
            });
        }

        layers.push(
            {
                id: "selected-trail-casing",
                type: "line",
                source: "selected-trail-route",
                layout: { "line-cap": "round", "line-join": "round" },
                paint: { "line-color": "#ffffff", "line-width": 9 },
            },
            {
                id: "selected-trail-route",
                type: "line",
                source: "selected-trail-route",
                layout: { "line-cap": "round", "line-join": "round" },
                paint: { "line-color": "#3549bb", "line-width": 5 },
            },
            {
                id: "selected-trail-carets",
                type: "symbol",
                source: "selected-trail-route",
                minzoom: 8,
                layout: {
                    "symbol-placement": "line",
                    "symbol-spacing": 140,
                    "icon-image": "direction-caret",
                    "icon-size": 0.65,
                },
            },
        );

        const layerSpec: BaseLayer = {
            spec: {
                version: 8,
                name: "selected-trail-route",
                glyphs: "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
                sources,
                layers,
            },
        };
        layerManager.addLayer("selected-trail-route", layerSpec);

        let minLon = Infinity,
            minLat = Infinity,
            maxLon = -Infinity,
            maxLat = -Infinity;
        for (const [lon, lat] of coords) {
            if (lon < minLon) minLon = lon;
            if (lon > maxLon) maxLon = lon;
            if (lat < minLat) minLat = lat;
            if (lat > maxLat) maxLat = lat;
        }
        if (Number.isFinite(minLon) && Number.isFinite(minLat)) {
            map.fitBounds(
                [
                    [minLon, minLat],
                    [maxLon, maxLat],
                ],
                {
                    padding: { top: 135, left: 40, right: 40, bottom: 265 },
                    maxZoom: 15,
                    duration: 650,
                },
            );
        }
    }

    function hasElevationData(): boolean {
        const active = activeTrail !== null ? trails[activeTrail] : undefined;
        if (!active?.id) return false;
        if ((active.elevation_gain ?? 0) > 0 || (active.elevation_loss ?? 0) > 0) {
            return true;
        }
        const fc = gpxDataMap[active.id];
        if (!fc?.features?.length) return false;
        for (const f of fc.features) {
            const g = f.geometry;
            if (!g) continue;
            if (g.type === "LineString") {
                if (g.coordinates.some((c) => Number.isFinite(c?.[2]) && c[2] !== 0)) {
                    return true;
                }
            } else if (g.type === "MultiLineString") {
                if (
                    g.coordinates.some((seg) =>
                        seg.some((c) => Number.isFinite(c?.[2]) && c[2] !== 0),
                    )
                ) {
                    return true;
                }
            }
        }
        return false;
    }

    export function refreshElevationProfile() {
        const activeId = activeTrail !== null ? trails[activeTrail]?.id : null;
        if (activeId && gpxDataMap[activeId]) {
            void epc?.setData(gpxDataMap[activeId]!, waypoints).then(() => {
                if (epc) {
                    onElevationSummary?.(epc.getSummary());
                }
            });
        }
    }

    function syncElevationProfileVisibility() {
        if (
            showElevation &&
            Object.keys(gpxDataMap).length &&
            activeTrail !== null &&
            elevationProfileVisibilityPreference !== false &&
            hasElevationData()
        ) {
            epc?.showProfile();
        } else {
            epc?.hideProfile();
        }
    }

    function getBounds() {
        let minX = Infinity,
            minY = Infinity,
            maxX = -Infinity,
            maxY = -Infinity;

        for (const [xMin, yMin, xMax, yMax] of Object.values(gpxDataMap)
            .filter((d) => d.bbox !== undefined)
            .map((d) => d.bbox!)) {
            minX = Math.min(minX, xMin);
            minY = Math.min(minY, yMin);
            maxX = Math.max(maxX, xMax);
            maxY = Math.max(maxY, yMax);
        }

        if (
            minX < Infinity &&
            minY < Infinity &&
            maxX > -Infinity &&
            maxY > -Infinity
        ) {
            return new M.LngLatBounds([minX, minY, maxX, maxY]);
        } else {
            return new M.LngLatBounds([0, 0, 0, 0]);
        }
    }

    export function fitToBounds(bounds?: M.LngLatBoundsLike) {
        const activeId = activeTrail !== null ? trails[activeTrail]?.id : null;
        const boundsToFit =
            bounds ??
            (activeId && gpxDataMap[activeId]
                ? (gpxDataMap[activeId].bbox as M.LngLatBoundsLike)
                : getBounds());

        if (!boundsToFit || !map) {
            return;
        }

        map!.fitBounds(boundsToFit, {
            animate: fitBounds == "animate",
            padding: {
                top: mobileChrome ? 92 : 16,
                left: 36,
                right: 36,
                bottom:
                    Math.max(16, fitPaddingBottom) +
                    (epc?.isProfileShown && !elevationProfileContainer
                        ? 205
                        : 0),
            },
        });
    }

    function flyToBounds() {
        fitToBounds();
    }

    function removeTrailLayer(id: string) {
        layerManager.removeLayer(id);
    }

    function addTrailLayer(
        trail: Trail,
        id: string,
        index: number,
        geojson: GeoJSON.FeatureCollection | null | undefined,
    ) {
        if (!geojson || !map) {
            return;
        }
        const trailLayer = new TrailLayer(
            id,
            geojson,
            trailColors[
                clusterTrails
                    ? hashStringToIndex(id ?? "", trailColors.length)
                    : index % trailColors.length
            ],
            {
                listeners: {
                    onEnter: (e) =>
                        highlightTrail(id, trails[activeTrail ?? -1]?.id == id),

                    onLeave: (e) => unHighlightTrail(id),
                    onMouseUp: (e) => {
                        activeTrail = trails.findIndex((t) => t.id == trail.id);
                    },
                    onMouseMove: moveCrosshairToCursorPosition,
                    onMouseDown: (e) => handleDragStart(e, id),
                },
            },
        );

        layerManager.addLayer(id, trailLayer);

        if (!drawing && !clusterTrails) {
            addStartEndMarkers(trail, id, geojson);
        }
    }

    let clusterLayerRequest = 0;
    async function addClusterLayer(geojson: FeatureCollection) {
        if (!geojson || !map || !map.style) {
            return;
        }
        const request = ++clusterLayerRequest;
        const target = map, style = map.style;
        const markers = withTrailheadIcons(geojson, page.data.subcategories);
        await ensureTrailheadImages(target, markers);
        if (request !== clusterLayerRequest || map !== target || map.style !== style || !clusterTrails) return;
        layerManager.addLayer(
            "clusters",
            new ClusterLayer(target, markers, {
                "unclustered-point": {
                    onEnter: (e) => {
                        if (!window.matchMedia("(hover: hover)").matches) return;
                        if (map) map.getCanvas().style.cursor = "pointer";
                        if (onTrailPinSelect) return;
                        const id = (e as any).features[0].properties.id;
                        const trail = trails.find((t) => t.id === id);
                        if (!hasTrailDetails(trail)) return;
                        highlightCluster(trail, e.lngLat);
                    },
                    onLeave: () => {
                        if (map) map.getCanvas().style.cursor = "";
                        if (!showClusterPopups) unHighlightCluster();
                    },
                },
            }, {
                suppressUnclusteredZoom: Boolean(onTrailPinSelect),
            }),
        );
    }

    let previewLayerRequest = 0;
    async function addPreviewLayer(geojson: FeatureCollection) {
        if (!geojson || !map || !map.style) {
            return;
        }
        const request = ++previewLayerRequest;
        const target = map, style = map.style;
        const showStartMarker = page.data.settings?.behavior?.showTrailStartMarker ?? false;
        const lines = withTrailheadIcons(geojson, page.data.subcategories);
        if (showStartMarker) await ensureTrailheadImages(target, lines);
        if (request !== previewLayerRequest || map !== target || map.style !== style || !clusterTrails) return;
        const listener = {
            onEnter: (e: M.MapMouseEvent) => {
                if (!window.matchMedia("(hover: hover)").matches) return;
                if (map) map.getCanvas().style.cursor = "pointer";
                const trail = trails.find((t) => t.id === (e as any).features[0].properties.trail);
                if (!hasTrailDetails(trail)) return;
                highlightCluster(trail, e.lngLat);
            },
            onLeave: () => {
                if (map) map.getCanvas().style.cursor = "";
                if (!showClusterPopups) unHighlightCluster();
            },
        };
        layerManager.addLayer(
            "preview",
            new PreviewLayer(target, lines, {
                showStartMarker,
                listeners: { preview: listener, "preview-start-points": listener },
            }),
        );
    }

    function moveCrosshairToCursorPosition(e: M.MapMouseEvent) {
        epc?.moveCrosshair(e.lngLat.lat, e.lngLat.lng);
        moveElevationMarkerToCursorPosition(e);
    }

    function moveElevationMarkerToCursorPosition(e: M.MapMouseEvent) {
        elevationMarker.setLngLat(e.lngLat);
    }

    function handleDragStart(e: M.MapMouseEvent, id: string) {
        if (
            !drawing ||
            (e.originalEvent.target as HTMLElement | null)?.classList.contains(
                "route-anchor",
            )
        ) {
            return;
        }
        e.preventDefault();

        const features = map?.queryRenderedFeatures(e.point, {
            layers: [id],
        });
        const segmentId = features?.at(0)?.properties.segmentId;
        if (segmentId !== null) {
            draggingSegment = segmentId;
        }

        map?.on("mousemove", moveElevationMarkerToCursorPosition);
        map?.once("mouseup", (e2) => handleDragEnd(e2, e));
    }

    function handleDragEnd(end: M.MapMouseEvent, start: M.MapMouseEvent) {
        map?.off("mousemove", moveElevationMarkerToCursorPosition);
        epc?.hideCrosshair();
        const distanceDragged = Math.sqrt(
            Math.pow(end.originalEvent.x - start.originalEvent.x, 2) +
                Math.pow(end.originalEvent.y - start.originalEvent.y, 2),
        );
        if (distanceDragged < 0.5) {
            onsegmentclick?.({ segment: draggingSegment!, event: end });
        } else {
            onsegmentdragend?.({ segment: draggingSegment!, event: end });
        }
        draggingSegment = null;
    }

    function addCaretLayer(geojson: GeoJSON) {
        if (!map) {
            return;
        }
        if (map.getLayer("direction-carets")) {
            removeCaretLayer();
        }
        layerManager.addLayer(
            "direction-carets",
            new CaretLayer({ type: "geojson", data: geojson }),
        );
    }

    function removeCaretLayer() {
        layerManager?.removeLayer("direction-carets");
    }

    export function highlightTrail(
        id: string,
        showElevationMarker: boolean = false,
    ) {
        if (!id) {
            return;
        }
        if (showElevationMarker) {
            elevationMarker.setOpacity("1");
        }
        map?.setPaintProperty(id, "line-width", 7);
        if (map?.getLayer(id)) {
            hoveringTrail = true;
        }
        // map?.setPaintProperty(id, "line-color", "#2766e3");
    }

    export function unHighlightTrail(id: string | undefined) {
        if (!id || draggingSegment !== null) {
            return;
        }
        elevationMarker.setOpacity("0");
        epc?.hideCrosshair();
        hoveringTrail = false;
        if (map?.getLayer(id)) {
            map?.setPaintProperty(id, "line-width", 5);
        }
        // map?.setPaintProperty(id, "line-color", "#648ad5");
    }

    function hasTrailDetails(trail: Trail | undefined): trail is Trail {
        return Boolean(trail?.name?.trim());
    }

    export async function highlightCluster(
        trail: Trail,
        lnglat?: M.LngLatLike,
    ) {
        if (!map || !map.style || !hasTrailDetails(trail)) {
            return;
        }
        // Re-entering the same thin preview line keeps its popup at the opening position.
        if (showClusterPopups && clusterPopup?.isOpen() && clusterPopupTrail === trail.id) return;
        clusterPopup?.remove();
        clusterHighlight?.remove();
        if (!lnglat && (!Number.isFinite(trail.lon) || !Number.isFinite(trail.lat))) return;
        const position = lnglat ?? [trail.lon!, trail.lat!] as M.LngLatLike;
        if (!showClusterPopups) {
            const element = document.createElement("div");
            element.className = "trail-hover-marker";
            element.style.cssText = "width:20px;height:20px;border:3px solid white;border-radius:50%;box-shadow:0 0 0 3px #3549bb;pointer-events:none";
            clusterHighlight = new M.Marker({ element }).setLngLat(position).addTo(map);
            return;
        }
        clusterPopup = createPopupFromTrail(trail);
        clusterPopupTrail = trail.id;
        clusterPopup.setLngLat(position).addTo(map);
        clusterPopup.on("close", () => {
            unHighlightCluster(false);
        });
        map.on("mousemove", unHighlightClusterDistanceNotifier);
    }

    function unHighlightClusterDistanceNotifier(e: M.MapMouseEvent) {
        if (!clusterPopup || !map) {
            return;
        }
        const trailLayers = ["unclustered-point", "preview", "preview-start-points"].filter((id) => map!.getLayer(id));
        const onTrail = map.queryRenderedFeatures(e.point, { layers: trailLayers })
            .some((feature) => (feature.properties.trail ?? feature.properties.id) === clusterPopupTrail);
        if (
            !onTrail &&
            map.project(clusterPopup.getLngLat()).dist(map.project(e.lngLat)) >
            60
        ) {
            clusterPopup.remove();
            map.off("mousemove", unHighlightClusterDistanceNotifier);
        }
    }

    export async function unHighlightCluster(closePopup: boolean = true) {
        if (!map || !map.style) {
            return;
        }
        layerManager.removeLayer("cluster-highlight");
        clusterHighlight?.remove();
        if (closePopup) {
            clusterPopup?.remove();
        }
    }

    function adjustTrailFocus(activeTrail: number | null) {
        if (activeTrail !== null && trails[activeTrail] !== undefined) {
            if (
                !drawing &&
                fitBounds !== "off" &&
                Object.values(gpxDataMap).some((d) => d.bbox !== undefined)
            ) {
                untrack(() => focusTrail(trails[activeTrail]));
            }
        } else if (activeTrail === null && trails.length) {
            untrack(() => unFocusTrail());
        }
    }

    function focusTrail(trail: Trail) {
        activeTrail = trails.findIndex((t) => t.id == trail.id);
        if (activeTrail < 0) {
            activeTrail = null;
            return;
        }
        onselect?.(trail);

        try {
            refreshElevationProfile();
            syncElevationProfileVisibility();
            syncWaypointMarkers();
            if (trail.id && gpxDataMap[trail.id]) {
                addCaretLayer(gpxDataMap[trail.id]);
            }
            flyToBounds();
        } catch (e) {
            console.warn(e);
        }
    }

    function unFocusTrail(trail?: Trail) {
        if (trail) {
            onunselect?.(trail);
            unHighlightTrail(trail.id!);
        }

        activeTrail = null;
        flyToBounds();

        if (showElevation) {
            epc?.hideProfile();
        }
        hideWaypoints();
        removeCaretLayer();
    }

    function startDrawing() {
        if (!map) {
            return;
        }
        activeTrail ??= 0;
        map.getCanvas().style.cursor = "crosshair";
        if (trails[activeTrail]) {
            removeStartEndMarkers(trails[activeTrail].id);
        }

        if (autoGeolocateOnDrawing) {
            geolocate();
        }
    }

    function stopDrawing() {
        if (!map) {
            return;
        }
        syncWaypointMarkers();
        map.getCanvas().style.cursor = "inherit";

        if (activeTrail !== null && trails[activeTrail] && !clusterTrails) {
            const activeId = trails[activeTrail].id;
            addStartEndMarkers(
                trails[activeTrail],
                activeId,
                activeId ? gpxDataMap[activeId] : null,
            );
        }
    }

    function addStartEndMarkers(
        trail: Trail,
        id: string | undefined,
        geojson: GeoJSON | null | undefined,
    ) {
        if (
            !map ||
            !trail ||
            !id ||
            !(layerManager.layers[id] instanceof TrailLayer)
        ) {
            return;
        }

        const startMarker = new FontawesomeMarker(
            { icon: "fa fa-bullseye" },
            {},
        );
        layerManager.layers[id].markers.start = startMarker;

        if (!geojson) {
            if (trail.lon && trail.lat) {
                startMarker.setLngLat([trail.lon, trail.lat]).addTo(map);
            }
            return;
        }

        const startEndPoint = findStartAndEndPoints(geojson);

        if (!startEndPoint.length) {
            return;
        }

        const endMarker = new FontawesomeMarker(
            { icon: "fa fa-flag-checkered" },
            {},
        );
        layerManager.layers[id].markers.end = endMarker;

        startMarker.setLngLat(startEndPoint[0] as M.LngLatLike);
        endMarker.setLngLat(
            startEndPoint[startEndPoint.length - 1] as M.LngLatLike,
        );

        if (showInfoPopup) {
            const popup = createPopupFromTrail(trail);
            startMarker.setPopup(popup);
            endMarker.setPopup(popup);
        }

        startMarker.addTo(map);
        if (!clusterTrails) {
            endMarker.addTo(map);
        }
    }

    function removeStartEndMarkers(id: string | undefined) {
        if (!id) {
            return;
        }
        // The editor starts drawing before the map has added the trail's
        // layer; there are no markers to remove yet.
        layerManager.layers[id]?.markers?.start?.remove();
        layerManager.layers[id]?.markers?.end?.remove();
    }

    function showWaypoints() {
        if (!map) {
            return;
        }

        hideWaypoints();
        for (const waypoint of waypoints) {
            if (!markers.find((m) => m._element.id == waypoint.id)) {
                const marker = createMarkerFromWaypoint(
                    waypoint,
                    onmarkerdragend,
                );
                marker.addTo(map);
                markers.push(marker);
            }
        }
        markers = markers.filter((marker) => {
            if (!waypoints.find((w) => w.id == marker._element.id)) {
                marker.remove();
                return false;
            }
            return true;
        });
    }

    function syncWaypointMarkers() {
        if (displayWaypoints) {
            showWaypoints();
        } else {
            hideWaypoints();
        }
    }

    function hideWaypoints() {
        if (!map) {
            return;
        }
        for (const m of markers) {
            m.remove();
        }
        markers = [];
    }

    function toggleEpcTheme() {
        if ($theme == "dark") {
            epc?.toggleTheme({
                profileBackgroundColor: "rgba(96, 165, 250, 0.20)",
                elevationGridColor: "#ddd2",
                labelColor: "#ddd8",
                crosshairColor: "#fff5",
                tooltipBackgroundColor: "#242734",
                tooltipTextColor: "#fff",
            });
        } else {
            epc?.toggleTheme({
                profileBackgroundColor: "rgba(53, 73, 187, 0.16)",
                elevationGridColor: "#0002",
                labelColor: "#0009",
                crosshairColor: "#0005",
                tooltipBackgroundColor: "#fff",
                tooltipTextColor: "#000",
            });
        }
    }

    let geolocateControl: UserLocationControl | undefined;
    let mapPresencePos: { lat: number; lon: number } | null = null;
    let lastMapHeartbeatAt = 0;
    let mapPresenceTimer: ReturnType<typeof setInterval> | null = null;
    let removePresenceListeners: (() => void) | null = null;

    function maybeSendMapPresenceHeartbeat(force = false) {
        if (!mapPresencePos) return;
        if (typeof document !== "undefined" && document.visibilityState !== "visible") return;
        const now = Date.now();
        if (!force && now - lastMapHeartbeatAt < 40_000) return;
        lastMapHeartbeatAt = now;
        const singleTrailId = trails.length === 1 ? (trails[0]?.id ?? "") : "";
        void sendHeartbeat({
            trailId: singleTrailId,
            lat: mapPresencePos.lat,
            lon: mapPresencePos.lon,
            inNavigation: false,
        });
    }

    onMount(async () => {
        const initialState = {
            lng: 25.0,
            lat: 45.9,
            zoom: 6.5,
        };

        if (!mapContainer) {
            return;
        }

        for (const tileset of page.data.settings?.tilesets ?? []) {
            baseMapStyles[tileset.name] = tileset.url;
        }

        const mapLocale = $locale?.startsWith("ro")
            ? {
                  "AttributionControl.ToggleAttribution": "Comută atribuirea",
                  "AttributionControl.MapFeedback": "Semnalează o problemă pe hartă",
                  "FullscreenControl.Enter": "Ecran complet",
                  "FullscreenControl.Exit": "Ieși din ecran complet",
                  "GeolocateControl.FindMyLocation": "Găsește locația mea",
                  "GeolocateControl.LocationNotAvailable": "Locația nu este disponibilă",
                  "NavigationControl.ResetBearing": "Resetează orientarea spre nord",
                  "NavigationControl.ZoomIn": "Mărește",
                  "NavigationControl.ZoomOut": "Micșorează",
              }
            : undefined;

        const finalMapOptions: M.MapOptions = {
            ...{
                container: mapContainer,
                center: [initialState.lng, initialState.lat],
                zoom: initialState.zoom,
                ...(mapLocale ? { locale: mapLocale } : {}),
            },
            ...mapOptions,
        };
        map = new M.Map(finalMapOptions);

        layerManager = new LayerManager(map, { overpassActionFactory: buildPoiAnchorAction });

        elevationMarker = new FontawesomeMarker(
            {
                id: "elevation-marker",
                icon: "fa-regular fa-circle",
                fontSize: "xs",
                width: 4,
                backgroundColor: "bg-primary",
                fontColor: "white",
            },
            {},
        );
        elevationMarker.setLngLat([0, 0]).addTo(map);
        elevationMarker.setOpacity("0");

        let img = new Image(20, 20);
        const ensureDirectionCaretImage = () => {
            if (!map || !img.complete || img.naturalWidth <= 0) return;
            try {
                if (!map.style || !map.hasImage("direction-caret")) {
                    map.addImage("direction-caret", img);
                }
            } catch {
                // Ignore transient style swap race
            }
        };
        img.onload = ensureDirectionCaretImage;
        img.src = directionCaret;

        const switcherControl = new StyleSwitcherControl({
            styles: baseMapStyles,
            onchange: (state) => {
                layerManager.update(JSON.parse(JSON.stringify(state)));
            },
            state: JSON.parse(JSON.stringify(layerManager.state)),
        });

        map.addControl(
            new M.NavigationControl({
                showZoom: !mobileChrome,
                showCompass: true,
                visualizePitch: showTerrain,
            }),
        );
        scale = { control: new M.ScaleControl({ maxWidth: 120, unit: page.data.settings?.unit ?? "metric" }), position: scalePosition };
        map.addControl(scale.control, scalePosition);

        if (finalMapOptions.interactive !== false) {
            geolocateControl = new UserLocationControl({
                enableHighAccuracy: true,
                animate: fitBounds == "animate",
                onError: onlocationerror,
                onPositionUpdate: (fix) => {
                    mapPresencePos = { lat: fix.latitude, lon: fix.longitude };
                    maybeSendMapPresenceHeartbeat(false);
                },
                labels: {
                    locateMe: $_("locate-me"),
                    followNorthUp: $_("follow-north-up"),
                    followHeadingUp: $_("follow-heading-up"),
                    permissionDenied: $_("location-permission-denied"),
                    insecureContext: $_("location-insecure-context"),
                },
            });
            map.addControl(geolocateControl);

            // If user already granted geolocation permission and has the app open, share anonymous area presence
            if (typeof navigator !== "undefined" && navigator.permissions?.query && navigator.geolocation) {
                void navigator.permissions
                    .query({ name: "geolocation" })
                    .then((perm) => {
                        if (perm.state === "granted") {
                            navigator.geolocation.getCurrentPosition(
                                (pos) => {
                                    mapPresencePos = {
                                        lat: pos.coords.latitude,
                                        lon: pos.coords.longitude,
                                    };
                                    maybeSendMapPresenceHeartbeat(true);
                                },
                                () => {},
                                { enableHighAccuracy: false, maximumAge: 30_000, timeout: 8_000 },
                            );
                        }
                    })
                    .catch(() => {});
            }

            mapPresenceTimer = setInterval(() => {
                maybeSendMapPresenceHeartbeat(false);
            }, 45_000);

            const onPageHide = () => {
                if (mapPresencePos) {
                    void clearHeartbeat();
                }
            };
            const onVisibility = () => {
                if (document.visibilityState === "hidden" && mapPresencePos) {
                    void clearHeartbeat();
                } else if (document.visibilityState === "visible" && mapPresencePos) {
                    maybeSendMapPresenceHeartbeat(true);
                }
            };
            window.addEventListener("pagehide", onPageHide);
            document.addEventListener("visibilitychange", onVisibility);
            removePresenceListeners = () => {
                window.removeEventListener("pagehide", onPageHide);
                document.removeEventListener("visibilitychange", onVisibility);
            };
        }

        if (showStyleSwitcher) {
            map.addControl(switcherControl);
        }

        if (showElevation && !clusterTrails) {
            void loadElevationProfileControlModule().then(({ ElevationProfileControl }) => {
                if (!map) return;
                epc = new ElevationProfileControl({
                    visible: false,
                    size: "195px",
                    showButton: !elevationProfileContainer,
                    paddingTop: 28,
                    paddingBottom: 26,
                    profileBackgroundColor:
                        $theme == "light"
                            ? "rgba(53, 73, 187, 0.16)"
                            : "rgba(96, 165, 250, 0.20)",
                    backgroundColor: "bg-menu-background/95",
                    unit: page.data.settings?.unit ?? "metric",
                    profileLineWidth: 2.5,
                    displayDistanceGrid: true,
                    tooltipDisplayDPlus: false,
                    tooltipBackgroundColor: $theme == "light" ? "#fff" : "#242734",
                    tooltipTextColor: $theme == "light" ? "#000" : "#fff",
                    zoom: false,
                    container: elevationProfileContainer,
                    labels: {
                        after: $_("elevation-tooltip-after"),
                        elevation: $_("elevation-tooltip-elevation"),
                        grade: $_("elevation-tooltip-grade"),
                        speed: $_("elevation-tooltip-speed"),
                        toggleButton: $_("toggle-elevation-profile"),
                    },
                    onEnter: () => {
                        elevationMarker.setOpacity("1");
                    },
                    onLeave: () => {
                        elevationMarker.setOpacity("0");
                        onElevationMove?.(null);
                    },
                    onToggle: (visible) => {
                        elevationProfileVisibilityPreference = visible;
                    },
                    onMove: (data) => {
                        if (!hoveringTrail) {
                            elevationMarker.setLngLat(
                                data.position as M.LngLatLike,
                            );
                        }
                        onElevationMove?.({
                            distance: data.distance,
                            elevation: Number(data.position?.[2] ?? 0),
                            dPlus: data.dPlus,
                            gradePercent: data.gradePercent,
                        });
                    },
                });
                toggleEpcTheme();
                map.addControl(epc);
                refreshElevationProfile();
                syncElevationProfileVisibility();
            });
        }

        if (showFullscreen) {
            map.addControl(
                new FullscreenControl(() => {
                    onfullscreen?.();
                }, $_("toggle-fullscreen")),
                "bottom-right",
            );
        }

        if (showTerrain && page.data.settings?.terrain?.terrain) {
            map!.addControl(
                new M.TerrainControl({
                    source: "terrain",
                }),
            );
        }

        map.on("styledata", (e) => {
            if (showTerrain && page.data.settings?.terrain?.terrain) {
                layerManager.addLayer(
                    "terrain",
                    new TerrainLayer(
                        page.data.settings.terrain.terrain,
                        page.data.settings?.terrain?.hillshading,
                    ),
                );
                syncHillshadingVisibility();
            }
        });

        map.on("style.load", () => {
            ensureDirectionCaretImage();
            if (mapLoaded && clusterTrails) {
                void addClusterLayer(clusterData);
                void addPreviewLayer(previewData);
            }
        });

        map.on("render", () => {
            syncHillshadingVisibility();
        });

        map.on("moveend", (e) => {
            onmoveend?.(e.target);
        });

        map.on("zoom", (e) => {
            onzoom?.(e.target);
        });

        map.on("click", (e) => {
            if (onTrailPinSelect) {
                const pinLayers = ["unclustered-point"].filter((id) =>
                    map?.getLayer(id),
                );
                const pinHits = pinLayers.length
                    ? map!.queryRenderedFeatures(e.point, { layers: pinLayers })
                    : [];
                if (pinHits.length) {
                    const id = pinHits[0]?.properties?.id;
                    const trail = trails.find((t) => t.id === id);
                    if (trail) {
                        onTrailPinSelect(trail);
                    }
                    return;
                }
                const clusterLayers = ["clusters"].filter((id) =>
                    map?.getLayer(id),
                );
                const clusterHits = clusterLayers.length
                    ? map!.queryRenderedFeatures(e.point, {
                          layers: clusterLayers,
                      })
                    : [];
                if (clusterHits.length) {
                    return;
                }
                onMapBackgroundClick?.();
            }
            if (hoveringTrail && drawing) {
                return;
            }
            onclick?.(e);
        });

        // Touch screens cannot hover, so a tap opens the trail popup when in popup mode.
        map.on("click", ["unclustered-point", "preview", "preview-start-points"], (e) => {
            if (onTrailPinSelect) return;
            if (window.matchMedia("(hover: hover)").matches) return;
            const properties = e.features?.[0]?.properties;
            const trail = trails.find((t) => t.id === (properties?.trail ?? properties?.id));
            if (hasTrailDetails(trail)) highlightCluster(trail, e.lngLat);
        });

        map.on("contextmenu", (e) => {
            oncontextmenu?.(e);
        });

        map.on("load", () => {
            layerManager.init();
            initMap(true);
            oninit?.(map!);
            mapLoaded = true;
        });

        syncWaypointMarkers();
    });

    function geolocate() {
        if (!page.data.settings?.behavior) return;

        if (page.data.settings.behavior.allowAutoGeolocate === true) {
            geolocateControl?.trigger();
        }
    }

    onDestroy(() => {
        if (mapPresenceTimer) {
            clearInterval(mapPresenceTimer);
            mapPresenceTimer = null;
        }
        removePresenceListeners?.();
        removePresenceListeners = null;
        ++clusterLayerRequest;
        ++previewLayerRequest;
        ++selectedRouteRequest;
        clusterHighlight?.remove();
        map?.remove();
    });

    function handleKeydown(e: KeyboardEvent) {
        const target = e.target as HTMLElement;

        const isInputField =
            target.tagName === "INPUT" ||
            target.tagName === "TEXTAREA" ||
            target.isContentEditable;

        if (isInputField) {
            return;
        }

        if (e.key == "m") {
            if (trails.length === 1) {
                removeCaretLayer();
                removeTrailLayer(trails[0].id!);
            }
        }
    }

    function handleKeyup(e: KeyboardEvent) {
        const target = e.target as HTMLElement;

        const isInputField =
            target.tagName === "INPUT" ||
            target.tagName === "TEXTAREA" ||
            target.isContentEditable;

        if (isInputField) {
            return;
        }

        if (e.key == "m") {
            if (trails.length === 1) {
                const trailId = trails[0].id!;
                addTrailLayer(trails[0], trailId, 0, gpxDataMap[trailId]);
                addCaretLayer(gpxDataMap[trailId]);
            }
        } else if (e.key == "p") {
            if (showElevation) {
                epc?.toggleProfile();
            }
        }
    }

    function hashStringToIndex(str: string, max: number) {
        let hash = 0;
        for (let i = 0; i < str.length; i++) {
            hash = (hash << 5) - hash + str.charCodeAt(i);
            hash |= 0;
        }
        return Math.abs(hash) % max;
    }

    function loadElevationProfileControlModule() {
        return import("#lib/vendor/maplibre-elevation-profile/elevationprofile-control.ts");
    }
</script>

<svelte:window on:keydown={handleKeydown} on:keyup={handleKeyup} />
<div id="map" bind:this={mapContainer}></div>

<style lang="postcss">
    @reference "tailwindcss";
    @reference "../../../css/app.css";

    #map {
        width: 100%;
        height: 100%;
    }

    :global(.maplibregl-popup-content) {
        @apply bg-background rounded-md shadow-xl p-0 overflow-hidden pr-5;
    }

    :global(.maplibregl-popup-close-button) {
        top: 4px;
        right: 4px;
        line-height: 0;
        padding-bottom: 2.5px;
        @apply bg-menu-item-background-focus w-3 aspect-square rounded-full;
    }

    :global(
            .maplibregl-user-location-accuracy-circle,
            .maplibregl-user-location-dot
        ) {
        pointer-events: none;
    }
</style>
