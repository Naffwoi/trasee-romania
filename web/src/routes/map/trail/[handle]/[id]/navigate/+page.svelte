<script lang="ts">
    import { browser } from "$app/env";
    import { goto } from "$app/navigation";
    import { page } from "$app/state";
    import MetaTags from "#lib/components/base/meta_tags.svelte";
    import LiveElevationSheet from "#lib/components/navigation/live_elevation_sheet.svelte";
    import NavigationTopBanner from "#lib/components/navigation/navigation_top_banner.svelte";
    import GPX from "#lib/models/gpx/gpx.ts";
    import type { Trail } from "#lib/models/trail.ts";
    import {
        bearingDegrees,
        computeOffTrailReroute,
        DemTileGrid,
        EtaCalculator,
        extractRawTrackPoints,
        haversineMeters,
        reverseTrackPoints,
        RouteMapMatcher,
        synthesizeTrailManeuvers,
        type EtaSnapshot,
        type NavManeuver,
        type NavMatchResult,
        type NavTrackPoint,
        type OffTrailMode,
        type OffTrailRerouteResult,
    } from "#lib/navigation/index.ts";
    import { decodePolyline } from "#lib/util/polyline_util.ts";
    import { AccuracyLayer } from "#lib/vendor/maplibre-user-location/accuracy-layer.ts";
    import { CompassSensor } from "#lib/vendor/maplibre-user-location/compass-sensor.ts";
    import { normalizeHeading } from "#lib/vendor/maplibre-user-location/heading-math.ts";
    import { LocationPuckMarker } from "#lib/vendor/maplibre-user-location/location-puck-marker.ts";
    import type { FeatureCollection } from "geojson";
    import * as M from "maplibre-gl";
    import "maplibre-gl/dist/maplibre-gl.css";
    import { onDestroy, onMount } from "svelte";
    import { _, locale } from "svelte-i18n";

    interface Props {
        data: {
            trail: Trail;
        };
    }

    interface NavFixInput {
        lat: number;
        lon: number;
        accuracy?: number | null;
        ele?: number | null;
        altitude?: number | null;
        heading?: number | null;
        speed?: number | null;
        timestampMs?: number;
    }

    interface PersistedNavSession {
        active_nav_trail_id: string;
        reversed: boolean;
        paused: boolean;
        offTrailMode?: OffTrailMode;
    }

    const STORAGE_KEY = "wanderer_active_nav_session";
    const EMPTY_FC: FeatureCollection = { type: "FeatureCollection", features: [] };

    const SRC_WALKED = "nav-trail-walked";
    const SRC_UPCOMING = "nav-trail-upcoming";
    const SRC_BREADCRUMB = "nav-breadcrumb";
    const SRC_OFFTRAIL = "nav-offtrail";
    const SRC_REJOIN = "nav-rejoin-point";

    const LAYER_WALKED = "nav-trail-walked";
    const LAYER_UPCOMING_CASING = "nav-trail-upcoming-casing";
    const LAYER_UPCOMING = "nav-trail-upcoming";
    const LAYER_BREADCRUMB = "nav-breadcrumb";
    const LAYER_OFFTRAIL_CASING = "nav-offtrail-casing";
    const LAYER_OFFTRAIL_LINE = "nav-offtrail-line";
    const LAYER_REJOIN_POINT = "nav-rejoin-point";

    let { data }: Props = $props();
    const trail = $derived(data.trail);

    const trailWaypoints = $derived(
        (trail.expand?.waypoints_via_trail ?? []).map((w) => ({
            lat: w.lat,
            lon: w.lon,
            name: w.name,
        })),
    );

    const isCycling = $derived.by(() => {
        const cat = (trail.expand?.category?.name ?? trail.category ?? "").toLowerCase();
        return cat.includes("bik") || cat.includes("cycl") || cat.includes("mtb");
    });

    function buildBasePoints(t: Trail): NavTrackPoint[] {
        if (t.expand?.gpx) {
            const pts = extractRawTrackPoints(t.expand.gpx);
            if (pts.length > 0) return pts;
        }
        if (t.expand?.gpx_data) {
            try {
                const parsed = GPX.parse(t.expand.gpx_data);
                const pts = extractRawTrackPoints(parsed);
                if (pts.length > 0) return pts;
            } catch {
                // Fall back to polyline below if GPX XML cannot be parsed
            }
        }
        if (t.polyline) {
            const decoded = decodePolyline(t.polyline, 5);
            let dist = 0;
            return decoded.map(([lon, lat], i) => {
                if (i > 0) {
                    dist += haversineMeters(decoded[i - 1][1], decoded[i - 1][0], lat, lon);
                }
                return { lat, lon, ele: 0, distanceM: dist, gradePct: 0 };
            });
        }
        return [];
    }

    let mapContainer = $state<HTMLDivElement | undefined>();
    let activePoints = $state<NavTrackPoint[]>([]);
    let reversed = $state(false);
    let paused = $state(false);
    let offTrailMode = $state<OffTrailMode>("min-climb");
    let reroute = $state<OffTrailRerouteResult | null>(null);
    let matchResult = $state<NavMatchResult | null>(null);
    let alongTrackMeters = $state(0);
    let etaSnapshot = $state<EtaSnapshot | null>(null);
    let maneuvers = $state<NavManeuver[]>([]);
    let deviceHeading = $state<number | null>(null);
    let compassAccuracy = $state<number | null>(null);
    let userEle = $state<number | null>(null);
    let hasFix = $state(false);
    let justRejoined = $state(false);
    let isFollowing = $state(true);
    let is3D = $state(true);
    let sheetExpanded = $state(true);

    // Non-reactive runtime handles owned by onMount / onDestroy
    let map: M.Map | null = null;
    let compassSensor: CompassSensor | null = null;
    let locationPuck: LocationPuckMarker | null = null;
    let accuracyLayer: AccuracyLayer | null = null;
    let demGrid: DemTileGrid | null = null;
    let customDemSampler: ((lat: number, lon: number) => number | null) | null = null;
    let matcher: RouteMapMatcher | null = null;
    let etaCalc: EtaCalculator | null = null;
    let wakeLock: WakeLockSentinel | null = null;
    let watchId: number | null = null;
    let rejoinTimer: ReturnType<typeof setTimeout> | null = null;
    let breadcrumbCoords: [number, number][] = [];
    let latestFix: {
        lat: number;
        lon: number;
        accuracy: number;
        altitude: number | null;
        heading: number | null;
        speed: number | null;
    } | null = null;
    let lastReroutePos: { lat: number; lon: number } | null = null;
    let isProgrammaticMove = false;
    let hasCenteredOnUser = false;
    let userManuallyToggledReverse = false;
    let styleReady = false;
    let startMarker: M.Marker | null = null;
    let endMarker: M.Marker | null = null;
    let waypointMarkers: M.Marker[] = [];

    const maneuverState = $derived.by(() => {
        if (maneuvers.length === 0 || activePoints.length === 0) {
            return {
                current: null as NavManeuver | null,
                next: null as NavManeuver | null,
                distanceM: null as number | null,
            };
        }
        const totalDist = activePoints[activePoints.length - 1].distanceM;
        const distAt = (m: NavManeuver) => {
            const idx = Math.max(0, Math.min(activePoints.length - 1, m.begin_shape_index));
            return activePoints[idx].distanceM;
        };

        if (alongTrackMeters >= Math.max(0, totalDist - 15)) {
            return {
                current: maneuvers[maneuvers.length - 1],
                next: null,
                distanceM: 0,
            };
        }

        if (alongTrackMeters < 15 && maneuvers[0].type === 1 && maneuvers.length > 1) {
            return {
                current: maneuvers[0],
                next: maneuvers[1],
                distanceM: Math.max(0, distAt(maneuvers[1]) - alongTrackMeters),
            };
        }

        for (let i = 0; i < maneuvers.length; i++) {
            const m = maneuvers[i];
            const mDist = distAt(m);
            if (mDist > alongTrackMeters + 12) {
                return {
                    current: m,
                    next: maneuvers[i + 1] ?? null,
                    distanceM: Math.max(0, mDist - alongTrackMeters),
                };
            }
        }

        return {
            current: maneuvers[maneuvers.length - 1],
            next: null,
            distanceM: Math.max(0, totalDist - alongTrackMeters),
        };
    });

    function persistSession() {
        if (!browser || !trail.id) return;
        try {
            const payload: PersistedNavSession = {
                active_nav_trail_id: trail.id,
                reversed,
                paused,
                offTrailMode,
            };
            localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
            localStorage.setItem("active_nav_trail_id", trail.id);
        } catch {
            // Storage may be unavailable in private browsing or restricted contexts
        }
    }

    function clearPersistedSession() {
        if (!browser) return;
        try {
            localStorage.removeItem(STORAGE_KEY);
            localStorage.removeItem("active_nav_trail_id");
        } catch {
            // Ignore storage restrictions
        }
    }

    function loadPersistedSession(): PersistedNavSession | null {
        if (!browser || !trail.id) return null;
        try {
            const raw = localStorage.getItem(STORAGE_KEY);
            if (!raw) return null;
            const parsed = JSON.parse(raw) as Partial<PersistedNavSession>;
            if (parsed.active_nav_trail_id !== trail.id) return null;
            return {
                active_nav_trail_id: parsed.active_nav_trail_id,
                reversed: Boolean(parsed.reversed),
                paused: Boolean(parsed.paused),
                offTrailMode:
                    parsed.offTrailMode === "shortest-safe" ? "shortest-safe" : "min-climb",
            };
        } catch {
            return null;
        }
    }

    function activeLocaleCode(): string {
        return ($locale ?? "en").startsWith("ro") ? "ro" : "en";
    }

    function rebuildRouteEngines(
        base: NavTrackPoint[],
        nextReversed: boolean,
        options: { resetProgress?: boolean } = {},
    ) {
        const ordered = nextReversed ? reverseTrackPoints(base) : base;
        activePoints = ordered;
        reversed = nextReversed;
        if (ordered.length > 0) {
            matcher = new RouteMapMatcher(ordered);
            etaCalc = new EtaCalculator(ordered, { isCycling });
            maneuvers = synthesizeTrailManeuvers(ordered, {
                locale: activeLocaleCode(),
                waypoints: trailWaypoints,
            }).maneuvers;
            if (options.resetProgress !== false) {
                alongTrackMeters = 0;
                reroute = null;
                matchResult = null;
                lastReroutePos = null;
                etaSnapshot = etaCalc.compute(0, Date.now(), null);
            }
        } else {
            matcher = null;
            etaCalc = null;
            maneuvers = [];
            etaSnapshot = null;
        }
        syncStartEndMarkers();
        syncNavGeoJson();
    }

    function activeSampler(lat: number, lon: number): number | null {
        if (customDemSampler) {
            return customDemSampler(lat, lon);
        }
        return demGrid?.sampleElevation(lat, lon) ?? null;
    }

    function resolveHeadingDeg(): number | null {
        if (deviceHeading !== null && Number.isFinite(deviceHeading)) {
            return deviceHeading;
        }
        if (
            latestFix &&
            latestFix.speed !== null &&
            latestFix.speed >= 0.8 &&
            latestFix.heading !== null &&
            Number.isFinite(latestFix.heading)
        ) {
            return normalizeHeading(latestFix.heading);
        }
        return null;
    }

    function cameraPadding() {
        return {
            top: 112,
            left: 16,
            right: 16,
            bottom: sheetExpanded ? 250 : 112,
        };
    }

    function runProgrammaticCamera(fn: () => void) {
        isProgrammaticMove = true;
        try {
            fn();
        } finally {
            isProgrammaticMove = false;
        }
    }

    function updateFollowCamera(options: { forceZoom?: boolean; duration?: number } = {}) {
        if (!map || !isFollowing) return;
        const target = latestFix
            ? ([latestFix.lon, latestFix.lat] as [number, number])
            : activePoints.length > 0
              ? ([activePoints[0].lon, activePoints[0].lat] as [number, number])
              : null;
        if (!target) return;

        const heading = resolveHeadingDeg();
        const zoom =
            options.forceZoom || !hasCenteredOnUser ? 16.2 : Math.max(15.2, map.getZoom());

        runProgrammaticCamera(() => {
            map!.easeTo({
                center: target,
                zoom,
                pitch: is3D ? 50 : 0,
                bearing: heading ?? map!.getBearing(),
                padding: cameraPadding(),
                duration: options.duration ?? (hasCenteredOnUser ? 280 : 0),
            });
        });
    }

    function isStyleReady(): boolean {
        if (!map) return false;
        if (styleReady) return true;
        try {
            const hasStyle = typeof map.getStyle === "function" ? Boolean(map.getStyle()) : false;
            if (hasStyle && (map.isStyleLoaded() || map.loaded())) {
                styleReady = true;
                return true;
            }
            return false;
        } catch {
            return false;
        }
    }

    function buildSplitRouteGeoJson(): {
        walked: FeatureCollection;
        upcoming: FeatureCollection;
    } {
        if (activePoints.length < 2) {
            return { walked: EMPTY_FC, upcoming: EMPTY_FC };
        }
        const total = activePoints[activePoints.length - 1].distanceM;
        const splitM = Math.max(0, Math.min(total, alongTrackMeters));

        if (splitM <= 0.5) {
            return {
                walked: EMPTY_FC,
                upcoming: {
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: {},
                            geometry: {
                                type: "LineString",
                                coordinates: activePoints.map((p) => [p.lon, p.lat]),
                            },
                        },
                    ],
                },
            };
        }

        if (splitM >= total - 0.5) {
            return {
                walked: {
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: {},
                            geometry: {
                                type: "LineString",
                                coordinates: activePoints.map((p) => [p.lon, p.lat]),
                            },
                        },
                    ],
                },
                upcoming: EMPTY_FC,
            };
        }

        const walkedCoords: [number, number][] = [];
        const upcomingCoords: [number, number][] = [];
        let splitInserted = false;

        for (let i = 0; i < activePoints.length; i++) {
            const pt = activePoints[i];
            if (!splitInserted && pt.distanceM >= splitM && i > 0) {
                const prev = activePoints[i - 1];
                const span = pt.distanceM - prev.distanceM;
                const t = span > 1e-6 ? (splitM - prev.distanceM) / span : 0;
                const splitLon = prev.lon + (pt.lon - prev.lon) * t;
                const splitLat = prev.lat + (pt.lat - prev.lat) * t;
                walkedCoords.push([splitLon, splitLat]);
                upcomingCoords.push([splitLon, splitLat]);
                splitInserted = true;
            }
            if (!splitInserted) {
                walkedCoords.push([pt.lon, pt.lat]);
            } else {
                upcomingCoords.push([pt.lon, pt.lat]);
            }
        }

        return {
            walked:
                walkedCoords.length >= 2
                    ? {
                          type: "FeatureCollection",
                          features: [
                              {
                                  type: "Feature",
                                  properties: {},
                                  geometry: { type: "LineString", coordinates: walkedCoords },
                              },
                          ],
                      }
                    : EMPTY_FC,
            upcoming:
                upcomingCoords.length >= 2
                    ? {
                          type: "FeatureCollection",
                          features: [
                              {
                                  type: "Feature",
                                  properties: {},
                                  geometry: { type: "LineString", coordinates: upcomingCoords },
                              },
                          ],
                      }
                    : EMPTY_FC,
        };
    }

    function ensureBaseNavSourcesAndLayers() {
        if (!map || !isStyleReady()) return;
        try {
            for (const srcId of [
                SRC_WALKED,
                SRC_UPCOMING,
                SRC_BREADCRUMB,
                SRC_OFFTRAIL,
                SRC_REJOIN,
            ]) {
                if (!map.getSource(srcId)) {
                    map.addSource(srcId, { type: "geojson", data: EMPTY_FC });
                }
            }

            if (!map.getLayer(LAYER_WALKED)) {
                map.addLayer({
                    id: LAYER_WALKED,
                    type: "line",
                    source: SRC_WALKED,
                    layout: { "line-cap": "round", "line-join": "round" },
                    paint: { "line-color": "#94a3b8", "line-width": 5 },
                });
            }

            if (!map.getLayer(LAYER_UPCOMING_CASING)) {
                map.addLayer({
                    id: LAYER_UPCOMING_CASING,
                    type: "line",
                    source: SRC_UPCOMING,
                    layout: { "line-cap": "round", "line-join": "round" },
                    paint: { "line-color": "#ffffff", "line-width": 9 },
                });
            }

            if (!map.getLayer(LAYER_UPCOMING)) {
                map.addLayer({
                    id: LAYER_UPCOMING,
                    type: "line",
                    source: SRC_UPCOMING,
                    layout: { "line-cap": "round", "line-join": "round" },
                    paint: { "line-color": "#2563eb", "line-width": 5 },
                });
            }

            if (!map.getLayer(LAYER_BREADCRUMB)) {
                map.addLayer({
                    id: LAYER_BREADCRUMB,
                    type: "line",
                    source: SRC_BREADCRUMB,
                    layout: { "line-cap": "round", "line-join": "round" },
                    paint: { "line-color": "#06b6d4", "line-width": 3 },
                });
            }
        } catch {
            // Transient style teardown; style.load will re-hydrate
        }
    }

    function syncOffTrailLayers(activeReroute: OffTrailRerouteResult | null) {
        if (!map || !isStyleReady()) return;
        try {
            const offSrc = map.getSource(SRC_OFFTRAIL) as M.GeoJSONSource | undefined;
            const rejoinSrc = map.getSource(SRC_REJOIN) as M.GeoJSONSource | undefined;

            if (activeReroute && activeReroute.points.length >= 2) {
                offSrc?.setData({
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: { mode: activeReroute.mode },
                            geometry: {
                                type: "LineString",
                                coordinates: activeReroute.points.map((p) => [p.lon, p.lat]),
                            },
                        },
                    ],
                });
                rejoinSrc?.setData({
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: {},
                            geometry: {
                                type: "Point",
                                coordinates: [activeReroute.rejoinLon, activeReroute.rejoinLat],
                            },
                        },
                    ],
                });

                if (!map.getLayer(LAYER_OFFTRAIL_CASING)) {
                    map.addLayer({
                        id: LAYER_OFFTRAIL_CASING,
                        type: "line",
                        source: SRC_OFFTRAIL,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: { "line-color": "#ffffff", "line-width": 8 },
                    });
                }
                if (!map.getLayer(LAYER_OFFTRAIL_LINE)) {
                    map.addLayer({
                        id: LAYER_OFFTRAIL_LINE,
                        type: "line",
                        source: SRC_OFFTRAIL,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: {
                            "line-color": "#f97316",
                            "line-width": 4.5,
                            "line-dasharray": [2, 1.5],
                        },
                    });
                }
                if (!map.getLayer(LAYER_REJOIN_POINT)) {
                    map.addLayer({
                        id: LAYER_REJOIN_POINT,
                        type: "circle",
                        source: SRC_REJOIN,
                        paint: {
                            "circle-radius": 7,
                            "circle-color": "#f97316",
                            "circle-stroke-color": "#ffffff",
                            "circle-stroke-width": 2.5,
                        },
                    });
                }
            } else {
                for (const id of [LAYER_REJOIN_POINT, LAYER_OFFTRAIL_LINE, LAYER_OFFTRAIL_CASING]) {
                    if (map.getLayer(id)) {
                        map.removeLayer(id);
                    }
                }
                offSrc?.setData(EMPTY_FC);
                rejoinSrc?.setData(EMPTY_FC);
            }
        } catch {
            // Ignore during style swap
        }
    }

    function syncNavGeoJson() {
        if (!map || !isStyleReady()) return;
        ensureBaseNavSourcesAndLayers();
        try {
            const { walked, upcoming } = buildSplitRouteGeoJson();
            (map.getSource(SRC_WALKED) as M.GeoJSONSource | undefined)?.setData(walked);
            (map.getSource(SRC_UPCOMING) as M.GeoJSONSource | undefined)?.setData(upcoming);

            const breadcrumbData: FeatureCollection =
                breadcrumbCoords.length >= 2
                    ? {
                          type: "FeatureCollection",
                          features: [
                              {
                                  type: "Feature",
                                  properties: {},
                                  geometry: {
                                      type: "LineString",
                                      coordinates: breadcrumbCoords,
                                  },
                              },
                          ],
                      }
                    : EMPTY_FC;
            (map.getSource(SRC_BREADCRUMB) as M.GeoJSONSource | undefined)?.setData(
                breadcrumbData,
            );

            syncOffTrailLayers(reroute);
        } catch {
            // Ignore transient map teardown
        }
    }

    function makeEndpointDot(bgColor: string): HTMLDivElement {
        const el = document.createElement("div");
        el.style.cssText = `width:14px;height:14px;border-radius:9999px;background:${bgColor};border:2.5px solid #ffffff;box-shadow:0 2px 6px rgba(0,0,0,0.35);pointer-events:none;`;
        return el;
    }

    function syncStartEndMarkers() {
        startMarker?.remove();
        endMarker?.remove();
        startMarker = null;
        endMarker = null;
        if (!map || activePoints.length < 2) return;
        const first = activePoints[0];
        const last = activePoints[activePoints.length - 1];
        startMarker = new M.Marker({ element: makeEndpointDot("#10b981"), anchor: "center" })
            .setLngLat([first.lon, first.lat])
            .addTo(map);
        endMarker = new M.Marker({ element: makeEndpointDot("#dc2626"), anchor: "center" })
            .setLngLat([last.lon, last.lat])
            .addTo(map);
    }

    function recomputeRerouteForFix(
        fix: { lat: number; lon: number; altitude: number | null },
        matched: NavMatchResult,
        force = false,
    ): OffTrailRerouteResult | null {
        if (!matched.isOffTrail || activePoints.length === 0) {
            lastReroutePos = null;
            return null;
        }
        if (
            !force &&
            reroute &&
            lastReroutePos &&
            haversineMeters(lastReroutePos.lat, lastReroutePos.lon, fix.lat, fix.lon) < 15
        ) {
            return reroute;
        }
        const computed = computeOffTrailReroute({
            userLat: fix.lat,
            userLon: fix.lon,
            userEle:
                fix.altitude !== null && Number.isFinite(fix.altitude)
                    ? fix.altitude
                    : activeSampler(fix.lat, fix.lon) ?? matched.matchedEle,
            trailPoints: activePoints,
            lastAlongTrackM: matched.alongTrackMeters,
            sampler: activeSampler,
            mode: offTrailMode,
            locale: activeLocaleCode(),
        });
        lastReroutePos = { lat: fix.lat, lon: fix.lon };
        return computed;
    }

    function handleGpsFix(raw: NavFixInput) {
        if (!Number.isFinite(raw.lat) || !Number.isFinite(raw.lon)) return;
        const accuracy =
            raw.accuracy !== undefined && raw.accuracy !== null && Number.isFinite(raw.accuracy)
                ? raw.accuracy
                : 10;
        const altitude =
            raw.altitude !== undefined && raw.altitude !== null && Number.isFinite(raw.altitude)
                ? raw.altitude
                : raw.ele !== undefined && raw.ele !== null && Number.isFinite(raw.ele)
                  ? raw.ele
                  : null;
        const heading =
            raw.heading !== undefined && raw.heading !== null && Number.isFinite(raw.heading)
                ? raw.heading
                : null;
        const speed =
            raw.speed !== undefined && raw.speed !== null && Number.isFinite(raw.speed)
                ? raw.speed
                : null;
        const nowMs = raw.timestampMs ?? Date.now();

        // Auto-reverse on first fix if user starts near trail end
        if (!hasFix && !userManuallyToggledReverse && activePoints.length >= 2) {
            const firstPt = activePoints[0];
            const lastPt = activePoints[activePoints.length - 1];
            const distStart = haversineMeters(raw.lat, raw.lon, firstPt.lat, firstPt.lon);
            const distEnd = haversineMeters(raw.lat, raw.lon, lastPt.lat, lastPt.lon);
            if (distEnd <= 150 && distStart > 300) {
                rebuildRouteEngines(buildBasePoints(trail), !reversed);
                persistSession();
            }
        }

        hasFix = true;
        latestFix = { lat: raw.lat, lon: raw.lon, accuracy, altitude, heading, speed };

        locationPuck?.setPosition(raw.lon, raw.lat);
        accuracyLayer?.update(raw.lon, raw.lat, accuracy);
        const effHeading = resolveHeadingDeg();
        locationPuck?.setHeading(effHeading, compassAccuracy ?? (effHeading !== null ? 20 : null));

        if (!paused) {
            const lastBc = breadcrumbCoords[breadcrumbCoords.length - 1];
            if (
                !lastBc ||
                haversineMeters(lastBc[1], lastBc[0], raw.lat, raw.lon) >= 5
            ) {
                breadcrumbCoords.push([raw.lon, raw.lat]);
            }
        }

        if (matcher && etaCalc && activePoints.length > 0) {
            const wasOffTrail = matchResult?.isOffTrail ?? false;
            const matched = matcher.update({
                lat: raw.lat,
                lon: raw.lon,
                accuracy,
                heading,
                speed,
            });
            matchResult = matched;
            alongTrackMeters = matched.alongTrackMeters;

            const sampledEle =
                altitude !== null
                    ? altitude
                    : activeSampler(raw.lat, raw.lon) ?? matched.matchedEle;
            userEle = sampledEle;

            if (!paused && !matched.isOffTrail) {
                etaCalc.recordProgress(matched.alongTrackMeters, nowMs);
            }

            if (matched.isOffTrail) {
                reroute = recomputeRerouteForFix({ lat: raw.lat, lon: raw.lon, altitude }, matched);
                justRejoined = false;
            } else {
                if (wasOffTrail || reroute !== null) {
                    reroute = null;
                    lastReroutePos = null;
                    justRejoined = true;
                    if (rejoinTimer) clearTimeout(rejoinTimer);
                    rejoinTimer = setTimeout(() => {
                        justRejoined = false;
                    }, 3500);
                }
            }

            const offTrailExtra = reroute
                ? {
                      distanceM: reroute.distanceM,
                      durationSec: reroute.estimatedSeconds,
                      ascentM: reroute.ascentM,
                      rejoinAlongTrackM: reroute.rejoinAlongTrackM,
                  }
                : null;
            etaSnapshot = etaCalc.compute(matched.alongTrackMeters, nowMs, offTrailExtra);
        }

        syncNavGeoJson();

        if (isFollowing) {
            updateFollowCamera({ duration: hasCenteredOnUser ? 280 : 0 });
            hasCenteredOnUser = true;
        }
    }

    function handleCompassReading(headingDeg: number, accuracyDeg: number | null) {
        deviceHeading = normalizeHeading(headingDeg);
        compassAccuracy = accuracyDeg;
        locationPuck?.setHeading(deviceHeading, compassAccuracy);
        if (isFollowing && map) {
            runProgrammaticCamera(() => {
                map!.easeTo({
                    bearing: deviceHeading!,
                    duration: 120,
                    easing: (t) => t,
                });
            });
        }
    }

    function handleOffTrailModeChange(mode: OffTrailMode) {
        if (offTrailMode === mode) return;
        offTrailMode = mode;
        persistSession();
        if (latestFix && matchResult?.isOffTrail) {
            reroute = recomputeRerouteForFix(latestFix, matchResult, true);
            if (etaCalc && matchResult) {
                const offTrailExtra = reroute
                    ? {
                          distanceM: reroute.distanceM,
                          durationSec: reroute.estimatedSeconds,
                          ascentM: reroute.ascentM,
                          rejoinAlongTrackM: reroute.rejoinAlongTrackM,
                      }
                    : null;
                etaSnapshot = etaCalc.compute(matchResult.alongTrackMeters, Date.now(), offTrailExtra);
            }
            syncNavGeoJson();
        }
    }

    function handleReverseDirection() {
        userManuallyToggledReverse = true;
        const base = buildBasePoints(trail);
        rebuildRouteEngines(base, !reversed);
        persistSession();
        if (latestFix) {
            // Re-match current position onto the reversed track without altering breadcrumb
            if (matcher && etaCalc) {
                const matched = matcher.update({
                    lat: latestFix.lat,
                    lon: latestFix.lon,
                    accuracy: latestFix.accuracy,
                    heading: latestFix.heading,
                    speed: latestFix.speed,
                });
                matchResult = matched;
                alongTrackMeters = matched.alongTrackMeters;
                if (matched.isOffTrail) {
                    reroute = recomputeRerouteForFix(latestFix, matched, true);
                }
                const offTrailExtra = reroute
                    ? {
                          distanceM: reroute.distanceM,
                          durationSec: reroute.estimatedSeconds,
                          ascentM: reroute.ascentM,
                          rejoinAlongTrackM: reroute.rejoinAlongTrackM,
                      }
                    : null;
                etaSnapshot = etaCalc.compute(
                    matched.alongTrackMeters,
                    Date.now(),
                    offTrailExtra,
                );
            }
            syncNavGeoJson();
        }
    }

    function handleTogglePause() {
        paused = !paused;
        persistSession();
    }

    function handleRecenter() {
        isFollowing = true;
        void compassSensor?.requestPermissionFromGesture().then((granted) => {
            if (granted) {
                compassSensor?.start((reading) =>
                    handleCompassReading(reading.heading, reading.accuracy),
                );
            }
        });
        updateFollowCamera({ forceZoom: true, duration: 350 });
    }

    function handleTogglePitch() {
        is3D = !is3D;
        if (map) {
            runProgrammaticCamera(() => {
                map!.easeTo({
                    pitch: is3D ? 50 : 0,
                    duration: 300,
                });
            });
        }
    }

    function handleExitNavigation() {
        clearPersistedSession();
        const share = page.url.searchParams.get("share");
        const base = `/map/trail/${page.params.handle}/${page.params.id}`;
        void goto(share ? `${base}?share=${encodeURIComponent(share)}` : base);
    }

    onMount(() => {
        const base = buildBasePoints(trail);
        const restored = loadPersistedSession();
        if (restored) {
            paused = restored.paused;
            offTrailMode = restored.offTrailMode ?? "min-climb";
        }
        rebuildRouteEngines(base, restored?.reversed ?? false);
        persistSession();

        demGrid = new DemTileGrid();
        if (base.length > 0) {
            void demGrid.prefetchCorridor(base);
        }

        const initialCoord: [number, number] =
            activePoints.length > 0
                ? [activePoints[0].lon, activePoints[0].lat]
                : [trail.lon ?? 25.0, trail.lat ?? 45.9];
        const initialBearing =
            activePoints.length >= 2
                ? bearingDegrees(
                      activePoints[0].lat,
                      activePoints[0].lon,
                      activePoints[1].lat,
                      activePoints[1].lon,
                  )
                : 0;

        if (mapContainer) {
            map = new M.Map({
                container: mapContainer,
                style: "/styles/ofm.json",
                center: initialCoord,
                zoom: 16.2,
                pitch: is3D ? 50 : 0,
                bearing: initialBearing,
                attributionControl: false,
            });

            locationPuck = new LocationPuckMarker();
            locationPuck.attach(map);

            accuracyLayer = new AccuracyLayer();
            accuracyLayer.attach(map);

            const onStyleReady = () => {
                styleReady = true;
                ensureBaseNavSourcesAndLayers();
                syncNavGeoJson();
                syncStartEndMarkers();
            };

            map.on("style.load", onStyleReady);
            map.on("load", () => {
                onStyleReady();
                updateFollowCamera({ forceZoom: true, duration: 0 });
            });

            map.on("dragstart", (e) => {
                if (!isProgrammaticMove && e.originalEvent) {
                    isFollowing = false;
                }
            });
        }

        compassSensor = new CompassSensor();
        compassSensor.start((reading) => handleCompassReading(reading.heading, reading.accuracy));

        if (typeof navigator !== "undefined" && navigator.geolocation) {
            try {
                watchId = navigator.geolocation.watchPosition(
                    (pos) => {
                        handleGpsFix({
                            lat: pos.coords.latitude,
                            lon: pos.coords.longitude,
                            accuracy: pos.coords.accuracy,
                            altitude: pos.coords.altitude,
                            heading: pos.coords.heading,
                            speed: pos.coords.speed,
                            timestampMs: pos.timestamp || Date.now(),
                        });
                    },
                    () => {
                        // Geolocation errors remain non-fatal; test hook or retry can supply fixes
                    },
                    {
                        enableHighAccuracy: true,
                        maximumAge: 2000,
                        timeout: 15000,
                    },
                );
            } catch {
                // Ignore geolocation availability errors
            }
        }

        const acquireWakeLock = async () => {
            try {
                if (typeof navigator !== "undefined" && navigator.wakeLock?.request) {
                    wakeLock = await navigator.wakeLock.request("screen");
                }
            } catch {
                // Screen wake lock is best-effort
            }
        };
        void acquireWakeLock();

        const handleVisibilityChange = () => {
            if (typeof document !== "undefined" && document.visibilityState === "visible") {
                void acquireWakeLock();
            }
        };
        if (typeof document !== "undefined") {
            document.addEventListener("visibilitychange", handleVisibilityChange);
        }

        // Expose deterministic E2E test hook
        if (typeof window !== "undefined") {
            (window as unknown as Record<string, unknown>).__wandererNavTest = {
                pushFix: (fix: NavFixInput) => handleGpsFix(fix),
                setCompass: (headingDeg: number, accuracyDeg: number | null = 10) =>
                    handleCompassReading(headingDeg, accuracyDeg),
                setCustomDemSampler: (
                    sampler: ((lat: number, lon: number) => number | null) | null,
                ) => {
                    customDemSampler = sampler;
                    if (latestFix && matchResult?.isOffTrail) {
                        reroute = recomputeRerouteForFix(latestFix, matchResult, true);
                        if (etaCalc) {
                            const offTrailExtra = reroute
                                ? {
                                      distanceM: reroute.distanceM,
                                      durationSec: reroute.estimatedSeconds,
                                      ascentM: reroute.ascentM,
                                      rejoinAlongTrackM: reroute.rejoinAlongTrackM,
                                  }
                                : null;
                            etaSnapshot = etaCalc.compute(
                                matchResult.alongTrackMeters,
                                Date.now(),
                                offTrailExtra,
                            );
                        }
                        syncNavGeoJson();
                    }
                },
            };
        }

        return () => {
            if (typeof document !== "undefined") {
                document.removeEventListener("visibilitychange", handleVisibilityChange);
            }
        };
    });

    onDestroy(() => {
        if (watchId !== null && typeof navigator !== "undefined" && navigator.geolocation) {
            navigator.geolocation.clearWatch(watchId);
            watchId = null;
        }
        compassSensor?.stop();
        locationPuck?.remove();
        accuracyLayer?.detach();
        startMarker?.remove();
        endMarker?.remove();
        for (const m of waypointMarkers) m.remove();
        waypointMarkers = [];
        if (rejoinTimer) {
            clearTimeout(rejoinTimer);
            rejoinTimer = null;
        }
        void wakeLock?.release().catch(() => {});
        wakeLock = null;
        if (typeof window !== "undefined") {
            delete (window as unknown as Record<string, unknown>).__wandererNavTest;
        }
        map?.remove();
        map = null;
    });
</script>

<MetaTags title={`${trail.name} | ${$_("map")} | wanderer`} />

<main class="fixed inset-0 w-screen h-dvh overflow-hidden bg-background">
    <div bind:this={mapContainer} data-testid="nav-map" class="w-full h-full"></div>

    <!-- Top Navigation Banner -->
    <div
        class="fixed top-3 inset-x-3 z-30 max-w-xl mx-auto pointer-events-none"
    >
        {#if activePoints.length === 0}
            <div
                class="bg-menu-background/95 text-content rounded-2xl shadow-xl p-4 pointer-events-auto border border-input-border/60 flex items-center justify-between gap-3"
            >
                <span class="text-sm font-semibold">
                    {$_("nav-no-gpx", { default: "This trail has no GPX route for navigation." })}
                </span>
                <button
                    type="button"
                    onclick={handleExitNavigation}
                    class="px-3 py-1.5 rounded-full bg-red-600 text-white text-xs font-semibold cursor-pointer shrink-0"
                >
                    {$_("back", { default: "Back" })}
                </button>
            </div>
        {:else}
            <NavigationTopBanner
                {reroute}
                {offTrailMode}
                onModeChange={handleOffTrailModeChange}
                currentManeuver={maneuverState.current}
                nextManeuver={maneuverState.next}
                distanceToManeuverM={maneuverState.distanceM}
                {deviceHeading}
                waitingForGps={!hasFix}
                {justRejoined}
                trailName={trail.name}
            />
        {/if}
    </div>

    <!-- Floating Right Controls: 3D/2D Pitch Toggle & Recenter Pill -->
    <div
        class="fixed right-3 z-30 flex flex-col items-end gap-2 pointer-events-none transition-all duration-200"
        style="bottom: {sheetExpanded ? '248px' : '92px'};"
    >
        <button
            type="button"
            data-testid="nav-pitch-toggle"
            aria-pressed={is3D}
            aria-label={is3D
                ? $_("nav-switch-2d", { default: "2D" })
                : $_("nav-switch-3d", { default: "3D" })}
            onclick={handleTogglePitch}
            class="pointer-events-auto h-10 px-3 rounded-full bg-menu-background/95 backdrop-blur text-content border border-input-border/60 shadow-lg text-xs font-bold flex items-center gap-1.5 hover:bg-secondary-hover cursor-pointer"
        >
            <i class="fa-solid fa-cube text-[11px]" aria-hidden="true"></i>
            <span>{is3D ? $_("nav-switch-3d", { default: "3D" }) : $_("nav-switch-2d", { default: "2D" })}</span>
        </button>

        {#if !isFollowing}
            <button
                type="button"
                data-testid="nav-recenter-btn"
                onclick={handleRecenter}
                class="pointer-events-auto h-10 px-4 rounded-full bg-blue-600 hover:bg-blue-700 text-white shadow-lg text-xs font-bold flex items-center gap-2 cursor-pointer transition-colors"
            >
                <i class="fa-solid fa-crosshairs" aria-hidden="true"></i>
                <span>{$_("nav-recenter", { default: "Recenter" })}</span>
            </button>
        {/if}
    </div>

    <!-- Bottom Trip Bar & Live Elevation Sheet -->
    <div class="fixed bottom-0 inset-x-0 z-30 max-w-2xl mx-auto pointer-events-none">
        <LiveElevationSheet
            points={activePoints}
            {alongTrackMeters}
            eta={etaSnapshot}
            {reroute}
            {userEle}
            {paused}
            {reversed}
            bind:expanded={sheetExpanded}
            onTogglePause={handleTogglePause}
            onReverse={handleReverseDirection}
            onExit={handleExitNavigation}
        />
    </div>
</main>
