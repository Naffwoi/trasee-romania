<script lang="ts">
    import { browser } from "$app/env";
    import { goto } from "$app/navigation";
    import { page } from "$app/state";
    import MetaTags from "#lib/components/base/meta_tags.svelte";
    import GroupSheet from "#lib/components/navigation/group_sheet.svelte";
    import LiveElevationSheet from "#lib/components/navigation/live_elevation_sheet.svelte";
    import NavigationTopBanner from "#lib/components/navigation/navigation_top_banner.svelte";
    import SosModalAndBanner from "#lib/components/navigation/sos_modal_and_banner.svelte";
    import WazeNearbyPrompt from "#lib/components/navigation/waze_nearby_prompt.svelte";
    import WazeReportSheet from "#lib/components/navigation/waze_report_sheet.svelte";
    import {
        clearHeartbeat,
        connectLiveStream,
        createLiveGroup,
        createReport,
        fetchLiveGroup,
        fetchTrailLiveSummary,
        getSavedGroupSession,
        getVotedReportsMap,
        isReportVisibleOnMap,
        joinLiveGroup,
        leaveLiveGroup,
        mergeGroupMemberIntoList,
        mergeReportIntoList,
        mergeSosIntoList,
        normalizeGroupCode,
        pingLiveGroup,
        playSosTone,
        removeGroupMemberFromList,
        respondToSos,
        sendHeartbeat,
        subscribeWebPushIfSupported,
        triggerSos,
        updateSos,
        voteReport,
        type GroupMemberDto,
        type GroupSessionDto,
        type LiveStreamHandle,
        type ReportVoteType,
        type SosAlertDto,
        type SosReason,
        type TrailReportCategory,
        type TrailReportDto,
    } from "#lib/live/live_client.ts";
    import {
        syncGroupMapMarkers,
        syncReportMapMarkers,
        syncSosMapMarkers,
    } from "#lib/live/report_markers.ts";
    import GPX from "#lib/models/gpx/gpx.ts";
    import type { Trail } from "#lib/models/trail.ts";
    import {
        bearingDegrees,
        computeHybridOffTrailReroute,
        computeValhallaAccessRoute,
        EtaCalculator,
        extractMapLibreObstacles,
        extractRawTrackPoints,
        FAR_PREVIEW_THRESHOLD_METERS,
        findCoLocatedPeerIds,
        fuseCooperativeGps,
        GpsPaceCoaster,
        haversineMeters,
        NavTerrainClient,
        parseGpxXmlFastToPackedTrack,
        reverseTrackPoints,
        RouteMapMatcher,
        synthesizeTrailManeuvers,
        unpackTrackPoints,
        type DirectRescueRouteResult,
        type EtaSnapshot,
        type GpsSignalState,
        type NavManeuver,
        type NavMatchResult,
        type NavTrackPoint,
        type ObstaclePolygon,
        type OffTrailMode,
        type OffTrailPoint,
        type OffTrailRerouteResult,
        type PeerGpsObservation,
    } from "#lib/navigation/index.ts";
    import { PwaPowerGovernor } from "#lib/navigation/pwa_power_governor.ts";
    import { decodePolyline } from "#lib/util/polyline_util.ts";
    import { AccuracyLayer } from "#lib/vendor/maplibre-user-location/accuracy-layer.ts";
    import { CompassSensor } from "#lib/vendor/maplibre-user-location/compass-sensor.ts";
    import { normalizeHeading } from "#lib/vendor/maplibre-user-location/heading-math.ts";
    import { LocationPuckMarker } from "#lib/vendor/maplibre-user-location/location-puck-marker.ts";
    import { baseMapStyles } from "#lib/vendor/maplibre-layer-manager/layers.ts";
    import { LayerManager } from "#lib/vendor/maplibre-layer-manager/maplibre-layer-manager.ts";
    import { OverlayLayer } from "#lib/vendor/maplibre-layer-manager/overlay-layer.ts";
    import { StyleSwitcherControl } from "#lib/vendor/maplibre-style-switcher/style-switcher-control.ts";
    import type { FeatureCollection } from "geojson";
    import * as M from "maplibre-gl";
    import "maplibre-gl/dist/maplibre-gl.css";
    import * as workerUrls from "#lib/util/maplibre_worker.ts";
    import { onDestroy, onMount, untrack } from "svelte";
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

    const SRC_ROUTE = "nav-trail-route";
    const SRC_BREADCRUMB = "nav-breadcrumb";
    const SRC_OFFTRAIL = "nav-offtrail";
    const SRC_REJOIN = "nav-rejoin-point";
    const SRC_RESCUE = "nav-sos-rescue";
    const SRC_ACCESS = "nav-access-route";

    const LAYER_WALKED = "nav-trail-walked";
    const LAYER_UPCOMING_CASING = "nav-trail-upcoming-casing";
    const LAYER_UPCOMING = "nav-trail-upcoming";
    const LAYER_BREADCRUMB = "nav-breadcrumb";
    const LAYER_OFFTRAIL_CASING = "nav-offtrail-casing";
    const LAYER_OFFTRAIL_LINE = "nav-offtrail-line";
    const LAYER_REJOIN_POINT = "nav-rejoin-point";
    const LAYER_RESCUE_CASING = "nav-sos-rescue-casing";
    const LAYER_RESCUE_LINE = "nav-sos-rescue-line";
    const LAYER_ACCESS_CASING = "nav-access-casing";
    const LAYER_ACCESS_LINE = "nav-access-line";

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
            const fastPts = unpackTrackPoints(parseGpxXmlFastToPackedTrack(t.expand.gpx_data));
            if (fastPts.length > 0) return fastPts;
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
    let signalState = $state<GpsSignalState>("good");
    let effectiveAccuracyM = $state<number | null>(null);
    let isFarPreview = $state(false);
    let farFromTrailDistanceM = $state<number | null>(null);
    let accessRouteActive = $state(false);
    let accessRoutePoints = $state<OffTrailPoint[] | null>(null);

    // Live Community (Waze Reports, 30m Presence, Live Groups & 5 km SOS Rescue) reactive state
    let activeHikersCount = $state<number | null>(null);
    let liveReports = $state<TrailReportDto[]>([]);
    let liveSosAlerts = $state<SosAlertDto[]>([]);
    let liveUserPos = $state<{ lat: number; lon: number } | null>(null);
    let reportSheetOpen = $state(false);
    let sosModalOpen = $state(false);
    let groupSheetOpen = $state(false);
    let groupSession = $state<GroupSessionDto | null>(null);
    let groupBusy = $state(false);
    let savedGroupName = $state("");
    let liveBusy = $state(false);
    let votedReportMap = $state<Record<string, ReportVoteType>>({});
    let snoozedReportIds = $state<Record<string, boolean>>({});
    let activeRescueSosId = $state<string | null>(null);
    let activeRescueRoute = $state<DirectRescueRouteResult | null>(null);
    let pushSubscribed = $state(false);
    let pushSupported = $state(false);
    let bottomSheetWrapEl = $state<HTMLDivElement | null>(null);
    let bottomBarHeight = $state(0);

    const groupMembers = $derived(groupSession?.members ?? []);

    const floatingBottomPx = $derived(
        (bottomBarHeight > 0 ? bottomBarHeight : sheetExpanded ? 290 : 96) + 12,
    );

    $effect(() => {
        const el = bottomSheetWrapEl;
        if (!el) return;
        const measure = () => {
            const h = Math.round(el.getBoundingClientRect().height);
            if (h > 0 && h !== bottomBarHeight) {
                bottomBarHeight = h;
            }
        };
        measure();
        if (typeof ResizeObserver !== "undefined") {
            const obs = new ResizeObserver(measure);
            obs.observe(el);
            return () => obs.disconnect();
        }
    });

    // Non-reactive runtime handles owned by onMount / onDestroy
    let map: M.Map | null = null;
    let compassSensor: CompassSensor | null = null;
    let locationPuck: LocationPuckMarker | null = null;
    let accuracyLayer: AccuracyLayer | null = null;
    let terrainClient: NavTerrainClient | null = null;
    let powerGovernor: PwaPowerGovernor | null = null;
    let cachedBasePoints: NavTrackPoint[] = [];
    let customDemSampler: ((lat: number, lon: number) => number | null) | null = null;
    let customObstacles: ObstaclePolygon[] | null = null;
    let matcher: RouteMapMatcher | null = null;
    let etaCalc: EtaCalculator | null = null;
    let coaster: GpsPaceCoaster | null = null;
    let wakeLock: WakeLockSentinel | null = null;
    let watchId: number | null = null;
    let rejoinTimer: ReturnType<typeof setTimeout> | null = null;
    let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
    let coastingTimer: ReturnType<typeof setInterval> | null = null;
    let groupPingTimer: ReturnType<typeof setInterval> | null = null;
    let streamHandle: LiveStreamHandle | null = null;
    let reportMarkers: M.Marker[] = [];
    let sosMarkers: M.Marker[] = [];
    let groupMarkers: M.Marker[] = [];
    let coLocatedPeerIds = new Set<string>();
    const alertedSosIds = new Set<string>();
    let lastHeartbeatSentAt = 0;
    let lastRealFixMs: number | null = null;
    let lastHybridRerouteAt = 0;
    let lastHybridReroutePos: { lat: number; lon: number } | null = null;
    let hybridReqSeq = 0;
    let localRerouteSeq = 0;
    let lastGroupPingAt = 0;
    let lastGroupPingPos: { lat: number; lon: number } | null = null;
    let lastMySosPatchAt = 0;
    let lastMySosPos: { lat: number; lon: number } | null = null;
    let lastResponderUpdateAt = 0;
    let lastResponderPos: { lat: number; lon: number } | null = null;
    let lastRescueCalcPos: { lat: number; lon: number } | null = null;
    let breadcrumbCoords: [number, number][] = [];
    let lastSyncedBreadcrumbLen = 0;
    let routeSourceDirty = true;
    let lastPaintedProgressRatio = -1;
    let lastSyncedRerouteRef: OffTrailRerouteResult | null | undefined = undefined;
    let lastSyncedAccessRef: OffTrailPoint[] | null | undefined = undefined;
    let lastSyncedAccessActive: boolean | undefined = undefined;
    let lastSyncedRescueRef: DirectRescueRouteResult | null | undefined = undefined;
    let currentWatchHighAccuracy = true;
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

    const myActiveSos = $derived(
        liveSosAlerts.find((s) => s.isMine && s.status === "active") ?? null,
    );

    const nearbySos = $derived.by(() => {
        const urlSosId = page.url.searchParams.get("sos");
        const candidates = liveSosAlerts.filter((s) => !s.isMine && s.status === "active");
        if (candidates.length === 0) return null;

        const filtered = candidates.filter((s) => {
            if (urlSosId && s.id === urlSosId) return true;
            if (s.amResponding || activeRescueSosId === s.id) return true;
            if (liveUserPos) {
                return haversineMeters(liveUserPos.lat, liveUserPos.lon, s.lat, s.lon) <= 5000;
            }
            return Boolean(trail.id && s.trailId === trail.id);
        });
        if (filtered.length === 0) return null;

        filtered.sort((a, b) => {
            if (activeRescueSosId) {
                if (a.id === activeRescueSosId) return -1;
                if (b.id === activeRescueSosId) return 1;
            }
            if (urlSosId) {
                if (a.id === urlSosId) return -1;
                if (b.id === urlSosId) return 1;
            }
            if (!liveUserPos) return 0;
            const da = haversineMeters(liveUserPos.lat, liveUserPos.lon, a.lat, a.lon);
            const db = haversineMeters(liveUserPos.lat, liveUserPos.lon, b.lat, b.lon);
            return da - db;
        });

        return filtered[0];
    });

    const nearbyPromptCandidate = $derived.by(() => {
        if (!liveUserPos) return null;
        let best: { report: TrailReportDto; distanceM: number } | null = null;
        const nowMs = Date.now();
        for (const r of liveReports) {
            if (!isReportVisibleOnMap(r, nowMs)) continue;
            if (votedReportMap[r.id] || snoozedReportIds[r.id]) continue;
            const distM = haversineMeters(liveUserPos.lat, liveUserPos.lon, r.lat, r.lon);
            if (distM < 150 && (!best || distM < best.distanceM)) {
                best = { report: r, distanceM: distM };
            }
        }
        return best;
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
        routeSourceDirty = true;
        lastPaintedProgressRatio = -1;
        void terrainClient?.setTrack(ordered, false);
        if (ordered.length > 0) {
            matcher = new RouteMapMatcher(ordered);
            etaCalc = new EtaCalculator(ordered, { isCycling });
            coaster = new GpsPaceCoaster(ordered, { isCycling });
            maneuvers = synthesizeTrailManeuvers(ordered, {
                locale: activeLocaleCode(),
                waypoints: trailWaypoints,
            }).maneuvers;
            if (options.resetProgress !== false) {
                alongTrackMeters = 0;
                reroute = null;
                matchResult = null;
                lastReroutePos = null;
                lastHybridReroutePos = null;
                hybridReqSeq++;
                localRerouteSeq++;
                isFarPreview = false;
                farFromTrailDistanceM = null;
                accessRouteActive = false;
                accessRoutePoints = null;
                signalState = "good";
                etaSnapshot = etaCalc.compute(0, Date.now(), null);
            }
        } else {
            matcher = null;
            etaCalc = null;
            coaster = null;
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
        return terrainClient?.sampleElevationSync(lat, lon) ?? null;
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

    function buildFullRouteGeoJson(): FeatureCollection {
        if (activePoints.length < 2) return EMPTY_FC;
        return {
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
        };
    }

    function applyRouteProgressGradient() {
        if (!map || !isStyleReady() || activePoints.length < 2) return;
        const total = activePoints[activePoints.length - 1].distanceM;
        const ratio = total > 0 ? Math.max(0, Math.min(1, alongTrackMeters / total)) : 0;
        if (Math.abs(ratio - lastPaintedProgressRatio) < 0.0002) return;
        lastPaintedProgressRatio = ratio;

        if (ratio <= 0.0005) {
            map.setPaintProperty(LAYER_WALKED, "line-gradient", ["interpolate", ["linear"], ["line-progress"], 0, "rgba(148,163,184,0)", 1, "rgba(148,163,184,0)"]);
            map.setPaintProperty(LAYER_UPCOMING_CASING, "line-gradient", ["interpolate", ["linear"], ["line-progress"], 0, "#ffffff", 1, "#ffffff"]);
            map.setPaintProperty(LAYER_UPCOMING, "line-gradient", ["interpolate", ["linear"], ["line-progress"], 0, "#2563eb", 1, "#2563eb"]);
            return;
        }
        if (ratio >= 0.9995) {
            map.setPaintProperty(LAYER_WALKED, "line-gradient", ["interpolate", ["linear"], ["line-progress"], 0, "#94a3b8", 1, "#94a3b8"]);
            map.setPaintProperty(LAYER_UPCOMING_CASING, "line-gradient", ["interpolate", ["linear"], ["line-progress"], 0, "rgba(255,255,255,0)", 1, "rgba(255,255,255,0)"]);
            map.setPaintProperty(LAYER_UPCOMING, "line-gradient", ["interpolate", ["linear"], ["line-progress"], 0, "rgba(37,99,235,0)", 1, "rgba(37,99,235,0)"]);
            return;
        }
        map.setPaintProperty(LAYER_WALKED, "line-gradient", ["step", ["line-progress"], "#94a3b8", ratio, "rgba(148,163,184,0)"]);
        map.setPaintProperty(LAYER_UPCOMING_CASING, "line-gradient", ["step", ["line-progress"], "rgba(255,255,255,0)", ratio, "#ffffff"]);
        map.setPaintProperty(LAYER_UPCOMING, "line-gradient", ["step", ["line-progress"], "rgba(37,99,235,0)", ratio, "#2563eb"]);
    }

    function ensureBaseNavSourcesAndLayers() {
        if (!map || !isStyleReady()) return;
        try {
            if (!map.getSource(SRC_ROUTE)) {
                map.addSource(SRC_ROUTE, {
                    type: "geojson",
                    data: buildFullRouteGeoJson(),
                    lineMetrics: true,
                });
                routeSourceDirty = false;
                lastPaintedProgressRatio = -1;
            }
            for (const srcId of [
                SRC_BREADCRUMB,
                SRC_OFFTRAIL,
                SRC_REJOIN,
                SRC_RESCUE,
                SRC_ACCESS,
            ]) {
                if (!map.getSource(srcId)) {
                    map.addSource(srcId, { type: "geojson", data: EMPTY_FC });
                }
            }

            if (!map.getLayer(LAYER_WALKED)) {
                map.addLayer({
                    id: LAYER_WALKED,
                    type: "line",
                    source: SRC_ROUTE,
                    layout: { "line-cap": "round", "line-join": "round" },
                    paint: { "line-color": "#94a3b8", "line-width": 5 },
                });
            }

            if (!map.getLayer(LAYER_UPCOMING_CASING)) {
                map.addLayer({
                    id: LAYER_UPCOMING_CASING,
                    type: "line",
                    source: SRC_ROUTE,
                    layout: { "line-cap": "round", "line-join": "round" },
                    paint: { "line-color": "#ffffff", "line-width": 9 },
                });
            }

            if (!map.getLayer(LAYER_UPCOMING)) {
                map.addLayer({
                    id: LAYER_UPCOMING,
                    type: "line",
                    source: SRC_ROUTE,
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
        if (activeReroute === lastSyncedRerouteRef) return;
        lastSyncedRerouteRef = activeReroute;
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
                        paint: { "line-color": "#ffffff", "line-width": 6.5 },
                    });
                }
                if (!map.getLayer(LAYER_OFFTRAIL_LINE)) {
                    map.addLayer({
                        id: LAYER_OFFTRAIL_LINE,
                        type: "line",
                        source: SRC_OFFTRAIL,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: {
                            "line-color": "#b45309",
                            "line-width": 3.5,
                            "line-dasharray": [2, 1.4],
                        },
                    });
                }
                if (!map.getLayer(LAYER_REJOIN_POINT)) {
                    map.addLayer({
                        id: LAYER_REJOIN_POINT,
                        type: "circle",
                        source: SRC_REJOIN,
                        paint: {
                            "circle-radius": 6.5,
                            "circle-color": "#b45309",
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

    function syncAccessRouteLayers(pts: OffTrailPoint[] | null) {
        if (!map || !isStyleReady()) return;
        if (pts === lastSyncedAccessRef && accessRouteActive === lastSyncedAccessActive) return;
        lastSyncedAccessRef = pts;
        lastSyncedAccessActive = accessRouteActive;
        try {
            const accessSrc = map.getSource(SRC_ACCESS) as M.GeoJSONSource | undefined;
            if (accessRouteActive && pts && pts.length >= 2) {
                accessSrc?.setData({
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: {},
                            geometry: {
                                type: "LineString",
                                coordinates: pts.map((p) => [p.lon, p.lat]),
                            },
                        },
                    ],
                });
                if (!map.getLayer(LAYER_ACCESS_CASING)) {
                    map.addLayer({
                        id: LAYER_ACCESS_CASING,
                        type: "line",
                        source: SRC_ACCESS,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: { "line-color": "#ffffff", "line-width": 6.5 },
                    });
                }
                if (!map.getLayer(LAYER_ACCESS_LINE)) {
                    map.addLayer({
                        id: LAYER_ACCESS_LINE,
                        type: "line",
                        source: SRC_ACCESS,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: {
                            "line-color": "#242734",
                            "line-width": 3.5,
                            "line-dasharray": [2, 1.4],
                        },
                    });
                }
            } else {
                for (const id of [LAYER_ACCESS_LINE, LAYER_ACCESS_CASING]) {
                    if (map.getLayer(id)) {
                        map.removeLayer(id);
                    }
                }
                accessSrc?.setData(EMPTY_FC);
            }
        } catch {
            // Ignore during style swap
        }
    }

    function syncRescueLayers(rescue: DirectRescueRouteResult | null) {
        if (!map || !isStyleReady()) return;
        if (rescue === lastSyncedRescueRef) return;
        lastSyncedRescueRef = rescue;
        try {
            const rescueSrc = map.getSource(SRC_RESCUE) as M.GeoJSONSource | undefined;
            if (rescue && rescue.points.length >= 2) {
                rescueSrc?.setData({
                    type: "FeatureCollection",
                    features: [
                        {
                            type: "Feature",
                            properties: { mode: rescue.mode },
                            geometry: {
                                type: "LineString",
                                coordinates: rescue.points.map((p) => [p.lon, p.lat]),
                            },
                        },
                    ],
                });

                if (!map.getLayer(LAYER_RESCUE_CASING)) {
                    map.addLayer({
                        id: LAYER_RESCUE_CASING,
                        type: "line",
                        source: SRC_RESCUE,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: { "line-color": "#ffffff", "line-width": 9.5 },
                    });
                }
                if (!map.getLayer(LAYER_RESCUE_LINE)) {
                    map.addLayer({
                        id: LAYER_RESCUE_LINE,
                        type: "line",
                        source: SRC_RESCUE,
                        layout: { "line-cap": "round", "line-join": "round" },
                        paint: {
                            "line-color": "#e11d48",
                            "line-width": 5.5,
                            "line-dasharray": [2.2, 1.3],
                        },
                    });
                }
            } else {
                for (const id of [LAYER_RESCUE_LINE, LAYER_RESCUE_CASING]) {
                    if (map.getLayer(id)) {
                        map.removeLayer(id);
                    }
                }
                rescueSrc?.setData(EMPTY_FC);
            }
        } catch {
            // Ignore during style teardown
        }
    }

    function syncNavGeoJson() {
        if (!map || !isStyleReady()) return;
        ensureBaseNavSourcesAndLayers();
        try {
            if (routeSourceDirty) {
                (map.getSource(SRC_ROUTE) as M.GeoJSONSource | undefined)?.setData(
                    buildFullRouteGeoJson(),
                );
                routeSourceDirty = false;
                lastPaintedProgressRatio = -1;
            }
            applyRouteProgressGradient();

            if (breadcrumbCoords.length !== lastSyncedBreadcrumbLen) {
                lastSyncedBreadcrumbLen = breadcrumbCoords.length;
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
            }

            syncOffTrailLayers(reroute);
            syncAccessRouteLayers(accessRoutePoints);
            syncRescueLayers(activeRescueRoute);
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

    function gatherCorridorObstacles(userLat: number, userLon: number, matched: NavMatchResult) {
        const padDeg = 0.008;
        const bbox: [number, number, number, number] = [
            Math.min(userLon, matched.matchedLon) - padDeg,
            Math.min(userLat, matched.matchedLat) - padDeg,
            Math.max(userLon, matched.matchedLon) + padDeg,
            Math.max(userLat, matched.matchedLat) + padDeg,
        ];
        const extracted = extractMapLibreObstacles(
            map as unknown as Parameters<typeof extractMapLibreObstacles>[0],
            bbox,
        );
        const obstacles = customObstacles
            ? [...customObstacles, ...extracted.obstacles]
            : extracted.obstacles;
        return { obstacles, preferredPaths: extracted.preferredPaths };
    }

    function recomputeRerouteForFix(
        fix: { lat: number; lon: number; altitude: number | null },
        matched: NavMatchResult,
        force = false,
    ): void {
        if (
            !matched.isOffTrail ||
            matched.crossTrackMeters > FAR_PREVIEW_THRESHOLD_METERS ||
            activePoints.length === 0 ||
            !terrainClient
        ) {
            lastReroutePos = null;
            lastHybridReroutePos = null;
            hybridReqSeq++;
            localRerouteSeq++;
            reroute = null;
            return;
        }

        const evalUserEle =
            fix.altitude !== null && Number.isFinite(fix.altitude)
                ? fix.altitude
                : activeSampler(fix.lat, fix.lon) ?? matched.matchedEle;

        const { obstacles, preferredPaths } = gatherCorridorObstacles(fix.lat, fix.lon, matched);

        const shouldRunLocal =
            force ||
            !reroute ||
            !lastReroutePos ||
            haversineMeters(lastReroutePos.lat, lastReroutePos.lon, fix.lat, fix.lon) >= 15;
        if (!shouldRunLocal) return;

        lastReroutePos = { lat: fix.lat, lon: fix.lon };
        const lSeq = ++localRerouteSeq;
        void terrainClient
            .computeReroute({
                userLat: fix.lat,
                userLon: fix.lon,
                userEle: evalUserEle,
                lastAlongTrackM: matched.alongTrackMeters,
                mode: offTrailMode,
                locale: activeLocaleCode(),
                obstacles,
                preferredPaths,
            })
            .then((localRes) => {
                if (lSeq !== localRerouteSeq || !matchResult?.isOffTrail || isFarPreview) return;
                reroute = localRes;
                if (etaCalc) {
                    const extra = localRes
                        ? {
                              distanceM: localRes.distanceM,
                              durationSec: localRes.estimatedSeconds,
                              ascentM: localRes.ascentM,
                              rejoinAlongTrackM: localRes.rejoinAlongTrackM,
                          }
                        : null;
                    etaSnapshot = etaCalc.compute(
                        alongTrackMeters,
                        lastRealFixMs ?? Date.now(),
                        extra,
                    );
                }
                syncNavGeoJson();

                const now = Date.now();
                const movedHybrid =
                    !lastHybridReroutePos ||
                    haversineMeters(
                        lastHybridReroutePos.lat,
                        lastHybridReroutePos.lon,
                        fix.lat,
                        fix.lon,
                    ) >= 20;
                if (localRes && (force || movedHybrid || now - lastHybridRerouteAt >= 10_000)) {
                    const hSeq = ++hybridReqSeq;
                    lastHybridRerouteAt = now;
                    lastHybridReroutePos = { lat: fix.lat, lon: fix.lon };
                    void computeHybridOffTrailReroute({
                        userLat: fix.lat,
                        userLon: fix.lon,
                        userEle: evalUserEle,
                        trailPoints: activePoints,
                        lastAlongTrackM: matched.alongTrackMeters,
                        sampler: activeSampler,
                        mode: offTrailMode,
                        locale: activeLocaleCode(),
                        isCycling,
                        obstacles,
                        preferredPaths,
                        precomputedLocal: localRes,
                        connectorSolver: (c) =>
                            terrainClient!.computeConnector({
                                ...c,
                                userEle: evalUserEle,
                                mode: offTrailMode,
                                obstacles,
                                preferredPaths,
                            }),
                    }).then((hybridRes) => {
                        if (hSeq !== hybridReqSeq) return;
                        if (
                            !matchResult?.isOffTrail ||
                            isFarPreview ||
                            signalState === "degraded" ||
                            signalState === "coasting"
                        ) {
                            return;
                        }
                        if (hybridRes) {
                            reroute = hybridRes;
                            if (etaCalc) {
                                etaSnapshot = etaCalc.compute(
                                    alongTrackMeters,
                                    lastRealFixMs ?? Date.now(),
                                    {
                                        distanceM: hybridRes.distanceM,
                                        durationSec: hybridRes.estimatedSeconds,
                                        ascentM: hybridRes.ascentM,
                                        rejoinAlongTrackM: hybridRes.rejoinAlongTrackM,
                                    },
                                );
                            }
                            syncNavGeoJson();
                        }
                    });
                }
            });
    }

    function handleFocusGroupMember(member: GroupMemberDto) {
        if (!map || !Number.isFinite(member.lat) || !Number.isFinite(member.lon)) return;
        isFollowing = false;
        runProgrammaticCamera(() => {
            map!.easeTo({
                center: [member.lon, member.lat],
                zoom: Math.max(15.8, map!.getZoom()),
                duration: 380,
            });
        });
    }

    function syncLiveMapOverlays() {
        if (!map) return;
        reportMarkers = syncReportMapMarkers(map, reportMarkers, liveReports, {
            onVote: (id, v) => void handleVoteReport(id, v),
        });
        sosMarkers = syncSosMapMarkers(map, sosMarkers, liveSosAlerts, {
            onRespond: (sos) => void handleRespondSos(sos),
        });
        groupMarkers = syncGroupMapMarkers(map, groupMarkers, groupMembers, {
            selfAlongTrackM: alongTrackMeters,
            selfLat: liveUserPos?.lat ?? null,
            selfLon: liveUserPos?.lon ?? null,
            locale: activeLocaleCode(),
            onSelectMember: handleFocusGroupMember,
        });
    }

    $effect(() => {
        liveReports;
        liveSosAlerts;
        groupSession;
        untrack(() => {
            syncLiveMapOverlays();
        });
    });

    function getEffectiveResponderOrigin(): {
        lat: number;
        lon: number;
        ele: number;
    } | null {
        if (latestFix) {
            return {
                lat: latestFix.lat,
                lon: latestFix.lon,
                ele:
                    userEle ??
                    latestFix.altitude ??
                    activeSampler(latestFix.lat, latestFix.lon) ??
                    0,
            };
        }
        if (activePoints.length > 0) {
            const p = activePoints[0];
            return { lat: p.lat, lon: p.lon, ele: p.ele };
        }
        if (trail.lat !== undefined && trail.lon !== undefined) {
            return { lat: trail.lat, lon: trail.lon, ele: 0 };
        }
        return null;
    }

    async function computeRescueRouteToSos(
        sos: SosAlertDto,
    ): Promise<DirectRescueRouteResult | null> {
        const origin = getEffectiveResponderOrigin();
        if (!origin || !terrainClient) return null;
        lastRescueCalcPos = { lat: origin.lat, lon: origin.lon };
        return terrainClient.computeRescueRoute({
            fromLat: origin.lat,
            fromLon: origin.lon,
            fromEle: origin.ele,
            targetLat: sos.lat,
            targetLon: sos.lon,
            targetEle: sos.ele,
            mode: offTrailMode,
            locale: activeLocaleCode(),
        });
    }

    function ingestSosListWithTone(incomingList: SosAlertDto[]) {
        for (const s of incomingList) {
            if (!s.isMine && s.status === "active" && !alertedSosIds.has(s.id)) {
                alertedSosIds.add(s.id);
                playSosTone();
            }
        }
        liveSosAlerts = incomingList;
    }

    async function triggerHeartbeatNow(force = false) {
        if (!latestFix) return;
        const now = Date.now();
        const isStationary = powerGovernor?.snapshot().isStationary ?? false;
        const minInterval = isStationary ? 110_000 : 18_000;
        if (!force && now - lastHeartbeatSentAt < minInterval) return;
        lastHeartbeatSentAt = now;
        const hbPayload = {
            trailId: trail.id,
            lat: latestFix.lat,
            lon: latestFix.lon,
            ele: userEle ?? latestFix.altitude,
            inNavigation: true,
            stationary: isStationary,
        };
        const res = await sendHeartbeat(hbPayload);
        if (res) {
            activeHikersCount = res.activeHikers30m;
            liveReports = res.reports;
            ingestSosListWithTone(res.sosAlerts);
        }
    }

    async function handleSubmitReport(payload: {
        category: TrailReportCategory;
        note: string;
    }) {
        const origin = getEffectiveResponderOrigin();
        if (!origin) return;
        liveBusy = true;
        try {
            const totalDist =
                activePoints.length > 0 ? activePoints[activePoints.length - 1].distanceM : 0;
            const forwardAlongM = reversed
                ? Math.max(0, totalDist - alongTrackMeters)
                : alongTrackMeters;
            const created = await createReport({
                trailId: trail.id,
                category: payload.category,
                note: payload.note,
                lat: origin.lat,
                lon: origin.lon,
                ele: origin.ele,
                alongTrackM: forwardAlongM,
            });
            if (created) {
                votedReportMap = { ...votedReportMap, [created.id]: "confirm" };
                liveReports = mergeReportIntoList(liveReports, created);
            }
        } finally {
            liveBusy = false;
        }
    }

    async function handleVoteReport(reportId: string, vote: ReportVoteType) {
        votedReportMap = { ...votedReportMap, [reportId]: vote };
        const updated = await voteReport(reportId, vote);
        if (updated) {
            liveReports = mergeReportIntoList(liveReports, updated);
        } else if (vote === "dismiss" || vote === "spam") {
            snoozedReportIds = { ...snoozedReportIds, [reportId]: true };
        }
    }

    function handleSnoozeReport(reportId: string) {
        snoozedReportIds = { ...snoozedReportIds, [reportId]: true };
    }

    async function handleTriggerSos(payload: {
        reason: SosReason;
        message: string;
        requesterName: string;
    }) {
        const origin = getEffectiveResponderOrigin();
        if (!origin) return;
        powerGovernor?.resetToMoving(Date.now());
        if (!currentWatchHighAccuracy) {
            rebindGeolocationWatch(true);
        }
        liveBusy = true;
        try {
            const created = await triggerSos({
                trailId: trail.id,
                reason: payload.reason,
                message: payload.message,
                requesterName: payload.requesterName,
                lat: origin.lat,
                lon: origin.lon,
                ele: origin.ele,
            });
            if (created) {
                lastMySosPatchAt = Date.now();
                lastMySosPos = { lat: origin.lat, lon: origin.lon };
                liveSosAlerts = mergeSosIntoList(liveSosAlerts, created);
            }
        } finally {
            liveBusy = false;
        }
    }

    async function handleResolveMySos() {
        const mine = myActiveSos;
        if (!mine) return;
        liveBusy = true;
        try {
            await updateSos(mine.id, { status: "resolved" });
            liveSosAlerts = liveSosAlerts.filter((s) => s.id !== mine.id);
        } finally {
            liveBusy = false;
        }
    }

    async function handleRespondSos(sos: SosAlertDto) {
        const origin = getEffectiveResponderOrigin();
        if (!origin) return;
        powerGovernor?.resetToMoving(Date.now());
        if (!currentWatchHighAccuracy) {
            rebindGeolocationWatch(true);
        }
        liveBusy = true;
        try {
            activeRescueSosId = sos.id;
            const initialRoute = await computeRescueRouteToSos(sos);
            activeRescueRoute = initialRoute;
            syncNavGeoJson();

            // Prefetch DEM tiles covering responder -> SOS corridor to refine elevation profile
            void terrainClient
                ?.prefetchCorridor(
                    [
                        { lat: origin.lat, lon: origin.lon },
                        { lat: sos.lat, lon: sos.lon },
                    ],
                    350,
                )
                .then(async () => {
                    if (activeRescueSosId === sos.id) {
                        activeRescueRoute = await computeRescueRouteToSos(sos);
                        syncNavGeoJson();
                    }
                });

            lastResponderUpdateAt = Date.now();
            lastResponderPos = { lat: origin.lat, lon: origin.lon };
            const updated = await respondToSos(sos.id, {
                status: "coming",
                lat: origin.lat,
                lon: origin.lon,
                ele: origin.ele,
                distanceM: initialRoute?.distanceM ?? haversineMeters(origin.lat, origin.lon, sos.lat, sos.lon),
                etaSec: initialRoute?.estimatedSeconds ?? 0,
            });
            if (updated) {
                liveSosAlerts = mergeSosIntoList(liveSosAlerts, updated);
            } else {
                liveSosAlerts = liveSosAlerts.map((item) =>
                    item.id === sos.id ? { ...item, amResponding: true } : item,
                );
            }
        } finally {
            liveBusy = false;
        }
    }

    async function handleCancelRespondSos(sos: SosAlertDto) {
        const origin = getEffectiveResponderOrigin();
        activeRescueSosId = null;
        activeRescueRoute = null;
        lastRescueCalcPos = null;
        syncNavGeoJson();
        if (!origin) return;
        const updated = await respondToSos(sos.id, {
            status: "cancelled",
            lat: origin.lat,
            lon: origin.lon,
            ele: origin.ele,
            distanceM: 0,
            etaSec: 0,
        });
        if (updated) {
            liveSosAlerts = mergeSosIntoList(liveSosAlerts, updated);
        } else {
            liveSosAlerts = liveSosAlerts.map((item) =>
                item.id === sos.id ? { ...item, amResponding: false } : item,
            );
        }
    }

    function forwardAlongTrackMeters(): number {
        const totalDist =
            activePoints.length > 0 ? activePoints[activePoints.length - 1].distanceM : 0;
        return reversed ? Math.max(0, totalDist - alongTrackMeters) : alongTrackMeters;
    }

    function buildPeerObservations(nowMs: number): PeerGpsObservation[] {
        if (!groupSession) return [];
        const out: PeerGpsObservation[] = [];
        for (const m of groupSession.members) {
            if (m.isSelf) continue;
            if (!Number.isFinite(m.lat) || !Number.isFinite(m.lon) || (m.lat === 0 && m.lon === 0)) {
                continue;
            }
            const parsedTs = m.updatedAt ? Date.parse(m.updatedAt) : NaN;
            const updatedAtMs =
                Number.isFinite(parsedTs) && parsedTs <= nowMs + 60_000 ? parsedTs : nowMs;
            out.push({
                memberId: m.memberId,
                lat: m.lat,
                lon: m.lon,
                accuracy: m.accuracy > 0 ? m.accuracy : 10,
                ele: m.ele,
                updatedAtMs,
            });
        }
        return out;
    }

    async function triggerGroupPingIfDue(force = false) {
        if (!groupSession || !latestFix) return;
        const now = Date.now();
        const movedM = lastGroupPingPos
            ? haversineMeters(
                  lastGroupPingPos.lat,
                  lastGroupPingPos.lon,
                  latestFix.lat,
                  latestFix.lon,
              )
            : Infinity;
        const isStationary = powerGovernor?.snapshot().isStationary ?? false;
        const minIntervalMs = isStationary ? 45_000 : movedM >= 4 ? 5_500 : 18_000;
        if (!force && now - lastGroupPingAt < minIntervalMs) return;

        lastGroupPingAt = now;
        lastGroupPingPos = { lat: latestFix.lat, lon: latestFix.lon };
        const code = groupSession.code;
        const pingPayload = {
            lat: latestFix.lat,
            lon: latestFix.lon,
            ele: userEle ?? latestFix.altitude,
            accuracy: effectiveAccuracyM ?? latestFix.accuracy,
            heading: resolveHeadingDeg(),
            speed: latestFix.speed,
            alongTrackM: forwardAlongTrackMeters(),
            inNavigation: true,
            stationary: isStationary,
        };
        const updated = await pingLiveGroup(code, pingPayload);
        if (updated && groupSession?.code === code) {
            groupSession = {
                ...groupSession,
                ...updated,
                trailId: updated.trailId || groupSession.trailId,
                expiresAt: updated.expiresAt || groupSession.expiresAt,
            };
        }
    }

    async function handleCreateGroup(displayName: string) {
        groupBusy = true;
        try {
            const origin = getEffectiveResponderOrigin();
            const created = await createLiveGroup({
                displayName,
                trailId: trail.id,
                lat: latestFix ? latestFix.lat : origin?.lat ?? null,
                lon: latestFix ? latestFix.lon : origin?.lon ?? null,
                ele: userEle ?? origin?.ele ?? null,
                accuracy: effectiveAccuracyM ?? latestFix?.accuracy ?? null,
                alongTrackM: forwardAlongTrackMeters(),
                inNavigation: true,
            });
            if (created) {
                savedGroupName = displayName;
                groupSession = created;
                streamHandle?.updateGroupCode(created.code);
            }
        } finally {
            groupBusy = false;
        }
    }

    async function handleJoinGroup(code: string, displayName: string) {
        groupBusy = true;
        try {
            const origin = getEffectiveResponderOrigin();
            const joined = await joinLiveGroup(code, {
                displayName,
                trailId: trail.id,
                lat: latestFix ? latestFix.lat : origin?.lat ?? null,
                lon: latestFix ? latestFix.lon : origin?.lon ?? null,
                ele: userEle ?? origin?.ele ?? null,
                accuracy: effectiveAccuracyM ?? latestFix?.accuracy ?? null,
                alongTrackM: forwardAlongTrackMeters(),
                inNavigation: true,
            });
            if (joined) {
                savedGroupName = displayName;
                groupSession = joined;
                streamHandle?.updateGroupCode(joined.code);
            }
        } finally {
            groupBusy = false;
        }
    }

    async function handleLeaveGroup() {
        if (!groupSession) return;
        const code = groupSession.code;
        groupBusy = true;
        try {
            await leaveLiveGroup(code);
            groupSession = null;
            coLocatedPeerIds = new Set();
            streamHandle?.updateGroupCode(null);
        } finally {
            groupBusy = false;
        }
    }

    async function handleRequestAccessRoute() {
        if (accessRouteActive) {
            accessRouteActive = false;
            accessRoutePoints = null;
            syncNavGeoJson();
            return;
        }
        if (!latestFix || activePoints.length === 0) return;
        const startPt = activePoints[0];
        const pts = await computeValhallaAccessRoute(
            latestFix.lat,
            latestFix.lon,
            startPt.lat,
            startPt.lon,
            isCycling,
            undefined,
            activeSampler,
        );
        if (pts && pts.length >= 2) {
            accessRoutePoints = pts;
            accessRouteActive = true;
            syncNavGeoJson();
        }
    }

    function runCoastingTick(nowMs = Date.now()) {
        if (!hasFix || lastRealFixMs === null || nowMs - lastRealFixMs < 6_000) {
            return;
        }

        // 1. Check Group Tether first when own GNSS dropped out > 6s
        const peerObs = buildPeerObservations(nowMs);
        const tethered = fuseCooperativeGps(null, peerObs, coLocatedPeerIds, nowMs);
        if (tethered && matcher && etaCalc && activePoints.length > 0) {
            signalState = "cooperative";
            effectiveAccuracyM = tethered.accuracy;
            liveUserPos = { lat: tethered.lat, lon: tethered.lon };
            locationPuck?.setPosition(tethered.lon, tethered.lat);
            accuracyLayer?.update(tethered.lon, tethered.lat, tethered.accuracy);

            const matched = matcher.update({
                lat: tethered.lat,
                lon: tethered.lon,
                accuracy: tethered.accuracy,
            });
            matchResult = matched;
            alongTrackMeters = matched.alongTrackMeters;
            userEle = activeSampler(tethered.lat, tethered.lon) ?? matched.matchedEle;
            etaSnapshot = etaCalc.compute(alongTrackMeters, nowMs, null);
            syncNavGeoJson();
            return;
        }

        // 2. Otherwise advance smoothly along trail via 1Hz Tobler Pace Coaster
        const coastSnap = coaster?.tickCoasting(
            nowMs,
            etaCalc?.getPaceFactor() ?? 1,
            paused,
        );
        if (coastSnap) {
            signalState = "coasting";
            alongTrackMeters = coastSnap.effectiveAlongM;
            userEle = coastSnap.ele;
            reroute = null;
            locationPuck?.setPosition(coastSnap.lon, coastSnap.lat);
            if (etaCalc) {
                etaSnapshot = etaCalc.compute(coastSnap.effectiveAlongM, nowMs, null);
            }
            syncNavGeoJson();
        }
    }

    async function handleEnableWebPush() {
        const origin = getEffectiveResponderOrigin();
        const status = await subscribeWebPushIfSupported(
            origin?.lat ?? null,
            origin?.lon ?? null,
            trail.id,
            { requestPermission: true },
        );
        if (status === "subscribed") {
            pushSubscribed = true;
        }
    }

    function handleGpsFix(raw: NavFixInput) {
        if (!Number.isFinite(raw.lat) || !Number.isFinite(raw.lon)) return;
        const wasFirstFix = !hasFix;
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
                rebuildRouteEngines(cachedBasePoints, !reversed);
                persistSession();
            }
        }

        hasFix = true;
        lastRealFixMs = nowMs;

        const peerObs = buildPeerObservations(nowMs);
        coLocatedPeerIds = findCoLocatedPeerIds(
            { lat: raw.lat, lon: raw.lon, accuracy },
            peerObs,
            nowMs,
        );
        const fused = fuseCooperativeGps(
            {
                lat: raw.lat,
                lon: raw.lon,
                accuracy,
                ele: altitude,
                heading,
                speed,
                timestampMs: nowMs,
            },
            peerObs,
            coLocatedPeerIds,
            nowMs,
        ) ?? {
            lat: raw.lat,
            lon: raw.lon,
            accuracy,
            source: "self" as const,
            fusedPeerCount: 0,
        };

        const effLat = fused.lat;
        const effLon = fused.lon;
        const effAcc = fused.accuracy;
        effectiveAccuracyM = effAcc;

        latestFix = { lat: effLat, lon: effLon, accuracy: effAcc, altitude, heading, speed };
        liveUserPos = { lat: effLat, lon: effLon };

        if (powerGovernor) {
            const pSnap = powerGovernor.ingestFix({
                lat: effLat,
                lon: effLon,
                speed,
                nowMs,
                hasActiveSos: Boolean(myActiveSos || activeRescueSosId),
            });
            if (pSnap.highAccuracyGps !== currentWatchHighAccuracy) {
                rebindGeolocationWatch(pSnap.highAccuracyGps);
            }
        }

        locationPuck?.setPosition(effLon, effLat);
        accuracyLayer?.update(effLon, effLat, effAcc);
        const effHeading = resolveHeadingDeg();
        locationPuck?.setHeading(effHeading, compassAccuracy ?? (effHeading !== null ? 20 : null));

        if (!paused) {
            const lastBc = breadcrumbCoords[breadcrumbCoords.length - 1];
            if (
                !lastBc ||
                haversineMeters(lastBc[1], lastBc[0], effLat, effLon) >= 5
            ) {
                breadcrumbCoords.push([effLon, effLat]);
            }
        }

        if (matcher && etaCalc && coaster && activePoints.length > 0) {
            const wasOffTrail = (matchResult?.isOffTrail ?? false) && !isFarPreview;
            const matched = matcher.update({
                lat: effLat,
                lon: effLon,
                accuracy: effAcc,
                heading,
                speed,
            });
            matchResult = matched;

            const coasterRes = coaster.ingestFix({
                lat: effLat,
                lon: effLon,
                accuracy: effAcc,
                matchedAlongM: matched.alongTrackMeters,
                crossTrackM: matched.crossTrackMeters,
                isPaused: paused,
                paceFactor: etaCalc.getPaceFactor(),
                fusedSource: fused.source,
                nowMs,
            });

            signalState = coasterRes.signalState;
            alongTrackMeters = coasterRes.effectiveAlongM;

            if (coasterRes.suppressOffTrail) {
                locationPuck?.setPosition(coasterRes.lon, coasterRes.lat);
            }

            const sampledEle =
                altitude !== null
                    ? altitude
                    : activeSampler(effLat, effLon) ?? coasterRes.ele ?? matched.matchedEle;
            userEle = sampledEle;

            if (!paused && (!matched.isOffTrail || coasterRes.suppressOffTrail)) {
                etaCalc.recordProgress(alongTrackMeters, nowMs);
            }

            if (matched.crossTrackMeters > FAR_PREVIEW_THRESHOLD_METERS) {
                isFarPreview = true;
                farFromTrailDistanceM = matched.crossTrackMeters;
                reroute = null;
                lastReroutePos = null;
                lastHybridReroutePos = null;
                hybridReqSeq++;
                localRerouteSeq++;
                justRejoined = false;
            } else if (coasterRes.suppressOffTrail) {
                isFarPreview = false;
                farFromTrailDistanceM = null;
                accessRouteActive = false;
                accessRoutePoints = null;
                reroute = null;
                lastReroutePos = null;
                lastHybridReroutePos = null;
                hybridReqSeq++;
                localRerouteSeq++;
            } else if (matched.isOffTrail) {
                isFarPreview = false;
                farFromTrailDistanceM = null;
                accessRouteActive = false;
                accessRoutePoints = null;
                recomputeRerouteForFix(
                    { lat: effLat, lon: effLon, altitude },
                    matched,
                );
                justRejoined = false;
            } else {
                isFarPreview = false;
                farFromTrailDistanceM = null;
                accessRouteActive = false;
                accessRoutePoints = null;
                if (wasOffTrail || reroute !== null) {
                    reroute = null;
                    lastReroutePos = null;
                    lastHybridReroutePos = null;
                    hybridReqSeq++;
                    localRerouteSeq++;
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
            etaSnapshot = etaCalc.compute(alongTrackMeters, nowMs, offTrailExtra);
        }

        // Update live SSE geo subscription, fire immediate heartbeat on first GPS fix & sync group ping
        streamHandle?.updateCoords(effLat, effLon);
        if (wasFirstFix) {
            void triggerHeartbeatNow(true);
            void triggerGroupPingIfDue(true);
        } else {
            void triggerGroupPingIfDue(false);
        }

        // Keep requester's active SOS coordinates live as GPS moves
        const mine = myActiveSos;
        if (mine) {
            const movedMine =
                !lastMySosPos ||
                haversineMeters(lastMySosPos.lat, lastMySosPos.lon, raw.lat, raw.lon) >= 25;
            if (movedMine && Date.now() - lastMySosPatchAt >= 15_000) {
                lastMySosPatchAt = Date.now();
                lastMySosPos = { lat: raw.lat, lon: raw.lon };
                void updateSos(mine.id, {
                    lat: raw.lat,
                    lon: raw.lon,
                    ele: userEle ?? altitude,
                }).then((updated) => {
                    if (updated) liveSosAlerts = mergeSosIntoList(liveSosAlerts, updated);
                });
            }
        }

        // Recompute DEM rescue route & responder ETA as responder moves toward SOS victim
        if (activeRescueSosId) {
            const targetSos = liveSosAlerts.find(
                (s) => s.id === activeRescueSosId && s.status === "active",
            );
            if (targetSos) {
                const movedForRoute =
                    !lastRescueCalcPos ||
                    haversineMeters(
                        lastRescueCalcPos.lat,
                        lastRescueCalcPos.lon,
                        raw.lat,
                        raw.lon,
                    ) >= 15;
                if (movedForRoute) {
                    void computeRescueRouteToSos(targetSos).then((r) => {
                        activeRescueRoute = r;
                        syncNavGeoJson();
                    });
                }
                const movedForApi =
                    !lastResponderPos ||
                    haversineMeters(
                        lastResponderPos.lat,
                        lastResponderPos.lon,
                        raw.lat,
                        raw.lon,
                    ) >= 30;
                if (
                    activeRescueRoute &&
                    movedForApi &&
                    Date.now() - lastResponderUpdateAt >= 18_000
                ) {
                    lastResponderUpdateAt = Date.now();
                    lastResponderPos = { lat: raw.lat, lon: raw.lon };
                    void respondToSos(targetSos.id, {
                        status: "coming",
                        lat: raw.lat,
                        lon: raw.lon,
                        ele: userEle ?? altitude,
                        distanceM: activeRescueRoute.distanceM,
                        etaSec: activeRescueRoute.estimatedSeconds,
                    }).then((updated) => {
                        if (updated) liveSosAlerts = mergeSosIntoList(liveSosAlerts, updated);
                    });
                }
            }
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
                map!.jumpTo({ bearing: deviceHeading! });
            });
        }
    }

    function handleOffTrailModeChange(mode: OffTrailMode) {
        if (offTrailMode === mode) return;
        offTrailMode = mode;
        persistSession();
        if (latestFix && matchResult?.isOffTrail && !isFarPreview) {
            recomputeRerouteForFix(latestFix, matchResult, true);
        }
        if (activeRescueSosId) {
            const targetSos = liveSosAlerts.find((s) => s.id === activeRescueSosId);
            if (targetSos) {
                void computeRescueRouteToSos(targetSos).then((r) => {
                    activeRescueRoute = r;
                    syncNavGeoJson();
                });
            }
        }
        syncNavGeoJson();
    }

    function handleReverseDirection() {
        userManuallyToggledReverse = true;
        rebuildRouteEngines(cachedBasePoints, !reversed);
        persistSession();
        if (latestFix) {
            // Re-match current position onto the reversed track without altering breadcrumb
            if (matcher && etaCalc && coaster) {
                const matched = matcher.update({
                    lat: latestFix.lat,
                    lon: latestFix.lon,
                    accuracy: latestFix.accuracy,
                    heading: latestFix.heading,
                    speed: latestFix.speed,
                });
                matchResult = matched;
                const coasterRes = coaster.ingestFix({
                    lat: latestFix.lat,
                    lon: latestFix.lon,
                    accuracy: latestFix.accuracy,
                    matchedAlongM: matched.alongTrackMeters,
                    crossTrackM: matched.crossTrackMeters,
                    isPaused: paused,
                    paceFactor: etaCalc.getPaceFactor(),
                    nowMs: lastRealFixMs ?? Date.now(),
                });
                signalState = coasterRes.signalState;
                alongTrackMeters = coasterRes.effectiveAlongM;
                if (matched.crossTrackMeters > FAR_PREVIEW_THRESHOLD_METERS) {
                    isFarPreview = true;
                    farFromTrailDistanceM = matched.crossTrackMeters;
                    reroute = null;
                } else if (!coasterRes.suppressOffTrail && matched.isOffTrail) {
                    recomputeRerouteForFix(latestFix, matched, true);
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

    function rebindGeolocationWatch(highAccuracy: boolean) {
        if (typeof navigator === "undefined" || !navigator.geolocation) return;
        currentWatchHighAccuracy = highAccuracy;
        if (watchId !== null) {
            navigator.geolocation.clearWatch(watchId);
            watchId = null;
        }
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
                highAccuracy
                    ? { enableHighAccuracy: true, maximumAge: 2000, timeout: 15000 }
                    : { enableHighAccuracy: false, maximumAge: 30000, timeout: 30000 },
            );
        } catch {
            // Ignore geolocation availability errors
        }
    }

    onMount(() => {
        terrainClient = new NavTerrainClient({
            workerUrl: (workerUrls as { navTerrainWorkerUrl?: string }).navTerrainWorkerUrl,
        });
        powerGovernor = new PwaPowerGovernor();
        const base = buildBasePoints(trail);
        cachedBasePoints = base;
        const restored = loadPersistedSession();
        if (restored) {
            paused = restored.paused;
            offTrailMode = restored.offTrailMode ?? "min-climb";
        }
        rebuildRouteEngines(base, restored?.reversed ?? false);
        persistSession();

        if (base.length > 0) {
            void terrainClient.setTrack(activePoints, true);
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
            for (const tileset of page.data.settings?.tilesets ?? []) {
                baseMapStyles[tileset.name] = tileset.url;
            }

            let initialStyle: string | M.StyleSpecification = "/styles/ofm.json";
            try {
                const rawState = localStorage.getItem("wanderer-ro-map-state-v3");
                if (rawState) {
                    const parsedState = JSON.parse(rawState) as { base?: string };
                    if (parsedState?.base && parsedState.base in baseMapStyles) {
                        initialStyle = baseMapStyles[parsedState.base];
                    }
                }
            } catch {
                // Keep default OpenFreeMap style when storage is restricted
            }

            map = new M.Map({
                container: mapContainer,
                style: initialStyle,
                center: initialCoord,
                zoom: 16.2,
                pitch: is3D ? 50 : 0,
                bearing: initialBearing,
                attributionControl: false,
            });

            const navLayerManager = new LayerManager(map);
            const switcherControl = new StyleSwitcherControl({
                styles: baseMapStyles,
                onchange: (nextState) => {
                    const prevBase = navLayerManager.state.base;
                    if (nextState.base !== prevBase) {
                        styleReady = false;
                    }
                    navLayerManager.update(JSON.parse(JSON.stringify(nextState)));
                },
                state: JSON.parse(JSON.stringify(navLayerManager.state)),
            });
            map.addControl(switcherControl, "top-right");

            locationPuck = new LocationPuckMarker();
            locationPuck.attach(map);

            accuracyLayer = new AccuracyLayer();
            accuracyLayer.attach(map);

            const onStyleReady = () => {
                styleReady = true;
                for (const [ovName, active] of Object.entries(navLayerManager.state.overlays)) {
                    if (active && !navLayerManager.layers[ovName]) {
                        navLayerManager.addLayer(ovName, new OverlayLayer(ovName));
                    }
                }
                routeSourceDirty = true;
                lastPaintedProgressRatio = -1;
                lastSyncedBreadcrumbLen = -1;
                lastSyncedRerouteRef = undefined;
                lastSyncedAccessRef = undefined;
                lastSyncedRescueRef = undefined;
                ensureBaseNavSourcesAndLayers();
                syncNavGeoJson();
                syncStartEndMarkers();
                syncLiveMapOverlays();
            };

            map.on("style.load", onStyleReady);
            map.on("styledata", () => {
                if (map && map.isStyleLoaded()) {
                    onStyleReady();
                }
            });
            map.on("load", () => {
                map?.resize();
                onStyleReady();
                updateFollowCamera({ forceZoom: true, duration: 0 });
            });

            map.on("dragstart", (e) => {
                if (!isProgrammaticMove && e.originalEvent) {
                    isFollowing = false;
                }
            });
        }

        let mapResizeObserver: ResizeObserver | null = null;
        if (mapContainer && typeof ResizeObserver !== "undefined") {
            mapResizeObserver = new ResizeObserver(() => {
                map?.resize();
            });
            mapResizeObserver.observe(mapContainer);
        }

        compassSensor = new CompassSensor();
        compassSensor.start((reading) => handleCompassReading(reading.heading, reading.accuracy));

        // On iOS Safari / standalone PWA, DeviceOrientationEvent.requestPermission()
        // requires a user gesture if not already unlocked from the Start button.
        let removeIosCompassGesture: (() => void) | null = null;
        if (
            typeof window !== "undefined" &&
            typeof DeviceOrientationEvent !== "undefined" &&
            typeof (
                DeviceOrientationEvent as unknown as {
                    requestPermission?: () => Promise<string>;
                }
            ).requestPermission === "function"
        ) {
            const onFirstGesture = () => {
                void compassSensor?.requestPermissionFromGesture().then((granted) => {
                    if (granted) {
                        compassSensor?.start((reading) =>
                            handleCompassReading(reading.heading, reading.accuracy),
                        );
                    }
                });
            };
            window.addEventListener("click", onFirstGesture, { capture: true, once: true });
            removeIosCompassGesture = () =>
                window.removeEventListener("click", onFirstGesture, { capture: true });
        }

        rebindGeolocationWatch(true);

        const handleDeviceMotion = (ev: DeviceMotionEvent) => {
            if (!powerGovernor || powerGovernor.currentState !== "stationary_cabana_sleep") return;
            const acc = ev.acceleration;
            if (!acc) return;
            if (powerGovernor.ingestLinearAcceleration(acc.x, acc.y, acc.z, Date.now())) {
                rebindGeolocationWatch(true);
            }
        };
        if (typeof window !== "undefined") {
            window.addEventListener("devicemotion", handleDeviceMotion, { passive: true });
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

        const savedGroup = getSavedGroupSession(trail.id);
        if (savedGroup?.displayName) {
            savedGroupName = savedGroup.displayName;
        }
        const urlGroupCode = normalizeGroupCode(page.url.searchParams.get("group"));
        const initialGroupCode = urlGroupCode ?? savedGroup?.code ?? null;

        const openNavLiveStream = () => {
            streamHandle?.close();
            const liveCallbacks = {
                onReportUpdate: (rep: TrailReportDto) => {
                    liveReports = mergeReportIntoList(liveReports, rep);
                },
                onSosUpdate: (sos: SosAlertDto) => {
                    if (!sos.isMine && sos.status === "active" && !alertedSosIds.has(sos.id)) {
                        alertedSosIds.add(sos.id);
                        playSosTone();
                    }
                    liveSosAlerts = mergeSosIntoList(liveSosAlerts, sos);
                    if (activeRescueSosId === sos.id) {
                        if (sos.status === "active") {
                            void computeRescueRouteToSos(sos).then((r) => {
                                activeRescueRoute = r;
                                syncNavGeoJson();
                            });
                        } else {
                            activeRescueSosId = null;
                            activeRescueRoute = null;
                            syncNavGeoJson();
                        }
                    }
                },
                onGroupMemberUpdate: (member: GroupMemberDto) => {
                    if (!groupSession) return;
                    groupSession = {
                        ...groupSession,
                        members: mergeGroupMemberIntoList(groupSession.members, member),
                    };
                },
                onGroupMemberLeft: ({
                    groupCode,
                    memberId,
                }: {
                    groupCode: string;
                    memberId: string;
                }) => {
                    if (!groupSession || (groupCode && groupCode !== groupSession.code)) return;
                    groupSession = {
                        ...groupSession,
                        members: removeGroupMemberFromList(groupSession.members, memberId),
                    };
                },
                onResyncRequired: () => {
                    void triggerHeartbeatNow(true);
                    if (groupSession) {
                        void fetchLiveGroup(groupSession.code).then((g) => {
                            if (g) groupSession = g;
                        });
                    }
                },
            };
            streamHandle = connectLiveStream({
                trailId: trail.id,
                lat: trail.lat ?? null,
                lon: trail.lon ?? null,
                groupCode: groupSession?.code ?? initialGroupCode,
                callbacks: liveCallbacks,
            });
        };

        const handleVisibilityChange = () => {
            if (typeof document !== "undefined") {
                if (document.visibilityState === "visible") {
                    void acquireWakeLock();
                    compassSensor?.start((reading) =>
                        handleCompassReading(reading.heading, reading.accuracy),
                    );
                    if (!streamHandle) {
                        openNavLiveStream();
                    }
                    void triggerHeartbeatNow(true);
                } else if (document.visibilityState === "hidden") {
                    compassSensor?.stop();
                    streamHandle?.close();
                    streamHandle = null;
                    if (latestFix) {
                        void clearHeartbeat();
                    }
                }
            }
        };
        const handlePageHide = () => {
            if (latestFix) {
                void clearHeartbeat();
            }
        };
        if (typeof document !== "undefined") {
            document.addEventListener("visibilitychange", handleVisibilityChange);
        }
        if (typeof window !== "undefined") {
            window.addEventListener("pagehide", handlePageHide);
        }

        // Initialize Live Community state (votes, initial trail summary, 60s heartbeat, SSE & Web Push)
        votedReportMap = getVotedReportsMap();
        if (
            typeof window !== "undefined" &&
            typeof navigator !== "undefined" &&
            "serviceWorker" in navigator &&
            "PushManager" in window &&
            "Notification" in window
        ) {
            pushSupported = true;
            if (Notification.permission === "granted") {
                void subscribeWebPushIfSupported(
                    trail.lat ?? null,
                    trail.lon ?? null,
                    trail.id,
                    { requestPermission: false },
                ).then((res) => {
                    if (res === "subscribed") pushSubscribed = true;
                });
            }
        }

        if (trail.id) {
            void fetchTrailLiveSummary(trail.id, {
                lat: trail.lat ?? null,
                lon: trail.lon ?? null,
            }).then((sum) => {
                if (!sum) return;
                if (activeHikersCount === null) {
                    activeHikersCount = sum.activeHikers30m;
                }
                if (liveReports.length === 0) {
                    liveReports = sum.reports;
                }
                if (liveSosAlerts.length === 0) {
                    ingestSosListWithTone(sum.sosAlerts);
                }
            });
        }

        heartbeatTimer = setInterval(() => {
            if (typeof document === "undefined" || document.visibilityState === "visible") {
                void triggerHeartbeatNow(false);
            }
        }, 45_000);

        coastingTimer = setInterval(() => {
            if (typeof document === "undefined" || document.visibilityState === "visible") {
                runCoastingTick(Date.now());
            }
        }, 1_000);

        groupPingTimer = setInterval(() => {
            if (typeof document === "undefined" || document.visibilityState === "visible") {
                void triggerGroupPingIfDue(false);
            }
        }, 6_000);

        openNavLiveStream();

        if (urlGroupCode) {
            void joinLiveGroup(urlGroupCode, {
                displayName: savedGroup?.displayName || "Drumeț",
                trailId: trail.id,
                inNavigation: true,
            }).then((joined) => {
                if (joined) {
                    groupSession = joined;
                    streamHandle?.updateGroupCode(joined.code);
                }
            });
        } else if (savedGroup?.code) {
            void fetchLiveGroup(savedGroup.code).then((fetched) => {
                if (fetched) {
                    groupSession = fetched;
                    streamHandle?.updateGroupCode(fetched.code);
                }
            });
        }

        // Expose deterministic E2E test hook
        if (typeof window !== "undefined") {
            (window as unknown as Record<string, unknown>).__wandererNavTest = {
                getMap: () => map,
                pushFix: (fix: NavFixInput) => handleGpsFix(fix),
                tickCoasting: (nowMs?: number) => runCoastingTick(nowMs ?? Date.now()),
                setCompass: (headingDeg: number, accuracyDeg: number | null = 10) =>
                    handleCompassReading(headingDeg, accuracyDeg),
                setCustomObstacles: (obstacles: ObstaclePolygon[] | null) => {
                    customObstacles = obstacles;
                    if (latestFix && matchResult?.isOffTrail && !isFarPreview) {
                        recomputeRerouteForFix(latestFix, matchResult, true);
                    }
                },
                injectGroupSession: (session: GroupSessionDto | null) => {
                    groupSession = session;
                    streamHandle?.updateGroupCode(session?.code ?? null);
                    syncLiveMapOverlays();
                },
                setCustomDemSampler: (
                    sampler: ((lat: number, lon: number) => number | null) | null,
                ) => {
                    customDemSampler = sampler;
                    terrainClient?.setCustomDemSampler(sampler);
                    if (latestFix && matchResult?.isOffTrail && !isFarPreview) {
                        recomputeRerouteForFix(latestFix, matchResult, true);
                    }
                    if (activeRescueSosId) {
                        const targetSos = liveSosAlerts.find((s) => s.id === activeRescueSosId);
                        if (targetSos) {
                            void computeRescueRouteToSos(targetSos).then((r) => {
                                activeRescueRoute = r;
                                syncNavGeoJson();
                            });
                        }
                    }
                    syncNavGeoJson();
                },
                injectLiveState: (payload: {
                    activeHikers30m?: number;
                    reports?: TrailReportDto[];
                    sosAlerts?: SosAlertDto[];
                }) => {
                    if (payload.activeHikers30m !== undefined) {
                        activeHikersCount = payload.activeHikers30m;
                    }
                    if (payload.reports) {
                        liveReports = payload.reports;
                    }
                    if (payload.sosAlerts) {
                        ingestSosListWithTone(payload.sosAlerts);
                    }
                },
            };
        }

        return () => {
            mapResizeObserver?.disconnect();
            removeIosCompassGesture?.();
            if (typeof document !== "undefined") {
                document.removeEventListener("visibilitychange", handleVisibilityChange);
            }
            if (typeof window !== "undefined") {
                window.removeEventListener("pagehide", handlePageHide);
                window.removeEventListener("devicemotion", handleDeviceMotion);
            }
        };
    });

    onDestroy(() => {
        terrainClient?.destroy();
        terrainClient = null;
        powerGovernor = null;
        if (latestFix) {
            void clearHeartbeat();
        }
        if (watchId !== null && typeof navigator !== "undefined" && navigator.geolocation) {
            navigator.geolocation.clearWatch(watchId);
            watchId = null;
        }
        if (heartbeatTimer) {
            clearInterval(heartbeatTimer);
            heartbeatTimer = null;
        }
        if (coastingTimer) {
            clearInterval(coastingTimer);
            coastingTimer = null;
        }
        if (groupPingTimer) {
            clearInterval(groupPingTimer);
            groupPingTimer = null;
        }
        streamHandle?.close();
        streamHandle = null;
        compassSensor?.stop();
        locationPuck?.remove();
        accuracyLayer?.detach();
        startMarker?.remove();
        endMarker?.remove();
        for (const m of waypointMarkers) m.remove();
        waypointMarkers = [];
        for (const m of reportMarkers) m.remove();
        reportMarkers = [];
        for (const m of sosMarkers) m.remove();
        sosMarkers = [];
        for (const m of groupMarkers) m.remove();
        groupMarkers = [];
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

<main id="nav-map-wrap" class="fixed inset-0 w-screen h-dvh overflow-hidden bg-background">
    <div bind:this={mapContainer} data-testid="nav-map" class="w-full h-full"></div>

    <!-- Top Navigation Banner + SOS Rescue Banner + Nearby Waze Prompt -->
    <div
        style="top: calc(0.75rem + env(safe-area-inset-top, 0px));"
        class={`fixed inset-x-3 ${sosModalOpen ? "z-50" : "z-35"} max-w-xl mx-auto pointer-events-none space-y-2`}
    >
        {#if activePoints.length === 0}
            <div
                class="bg-menu-background/94 backdrop-blur-md text-content rounded-2xl shadow-xl p-4 pointer-events-auto border border-input-border/60 flex items-center justify-between gap-3"
            >
                <span class="text-sm font-semibold">
                    {$_("nav-no-gpx", { default: "This trail has no GPX route for navigation." })}
                </span>
                <button
                    type="button"
                    onclick={handleExitNavigation}
                    class="px-3 py-1.5 rounded-full bg-[#242734] text-white text-xs font-semibold cursor-pointer shrink-0"
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

        <SosModalAndBanner
            bind:modalOpen={sosModalOpen}
            {myActiveSos}
            {nearbySos}
            userLat={liveUserPos?.lat ?? null}
            userLon={liveUserPos?.lon ?? null}
            {userEle}
            {activeRescueRoute}
            {activeRescueSosId}
            submitting={liveBusy}
            onTriggerSos={handleTriggerSos}
            onResolveMySos={handleResolveMySos}
            onRespondSos={handleRespondSos}
            onCancelRespondSos={handleCancelRespondSos}
        />

        {#if nearbyPromptCandidate}
            <WazeNearbyPrompt
                report={nearbyPromptCandidate.report}
                distanceM={nearbyPromptCandidate.distanceM}
                voting={liveBusy}
                onVote={handleVoteReport}
                onSnooze={handleSnoozeReport}
            />
        {/if}
    </div>

    <!-- Floating Left Controls: SOS Emergency Button & Push Bell (Unified 40px Slate/Frosted) -->
    <div
        class="fixed left-3 z-40 flex flex-col items-start gap-2 pointer-events-none transition-all duration-200"
        style="bottom: calc({floatingBottomPx}px + env(safe-area-inset-bottom, 0px));"
    >
        {#if pushSupported && !pushSubscribed}
            <button
                type="button"
                data-testid="nav-push-bell-btn"
                onclick={handleEnableWebPush}
                title="Activează notificările SOS pe o rază de 5 km"
                aria-label="Activează notificările SOS"
                class="pointer-events-auto h-10 w-10 rounded-full bg-menu-background/94 backdrop-blur-md text-content/80 border border-input-border/60 shadow-md text-sm flex items-center justify-center hover:bg-secondary-hover cursor-pointer transition-colors"
            >
                <i class="fa-solid fa-bell text-sm" aria-hidden="true"></i>
            </button>
        {/if}

        <button
            type="button"
            data-testid="nav-sos-btn"
            aria-label="SOS Urgență"
            title="SOS Urgență"
            onclick={() => {
                void handleEnableWebPush();
                sosModalOpen = true;
            }}
            class={`pointer-events-auto h-10 w-10 rounded-full shadow-md flex items-center justify-center cursor-pointer transition-colors border ${
                myActiveSos
                    ? "bg-red-600 text-white border-white/60 animate-pulse"
                    : "bg-menu-background/94 backdrop-blur-md hover:bg-secondary-hover text-content/80 border-input-border/60"
            }`}
        >
            <i class="fa-solid fa-life-ring text-sm" aria-hidden="true"></i>
        </button>
    </div>

    <!-- Floating Right Controls: Live Group, Calm Report Pin, 3D/2D Pitch Toggle & Recenter Pill -->
    <div
        class="fixed right-3 z-40 flex flex-col items-end gap-2 pointer-events-none transition-all duration-200"
        style="bottom: calc({floatingBottomPx}px + env(safe-area-inset-bottom, 0px));"
    >
        <button
            type="button"
            data-testid="nav-group-btn"
            onclick={() => (groupSheetOpen = true)}
            aria-label="Grup Live"
            title="Grup Live"
            class="pointer-events-auto relative h-10 w-10 rounded-full bg-menu-background/94 backdrop-blur-md hover:bg-secondary-hover text-content/85 border border-input-border/60 shadow-md flex items-center justify-center cursor-pointer transition-colors"
        >
            <i class="fa-solid fa-user-group text-sm" aria-hidden="true"></i>
            {#if groupMembers.length > 1}
                <span
                    data-testid="nav-group-count-badge"
                    class="absolute -top-1 -right-1 min-w-[18px] h-[18px] px-1 rounded-full bg-[#242734] text-white text-[10px] font-extrabold flex items-center justify-center border border-white"
                >
                    {groupMembers.length}
                </span>
            {/if}
        </button>

        <button
            type="button"
            data-testid="nav-waze-report-btn"
            onclick={() => (reportSheetOpen = true)}
            aria-label="Raportează pe potecă"
            title="Raportează pe potecă"
            class="pointer-events-auto relative h-10 w-10 rounded-full bg-menu-background/94 backdrop-blur-md hover:bg-secondary-hover text-content/85 border border-input-border/60 shadow-md flex items-center justify-center cursor-pointer transition-colors"
        >
            <i class="fa-solid fa-location-dot text-sm" aria-hidden="true"></i>
            <span class="absolute top-1.5 right-1.5 text-[9px] font-black leading-none" aria-hidden="true">+</span>
        </button>

        <button
            type="button"
            data-testid="nav-pitch-toggle"
            aria-pressed={is3D}
            aria-label={is3D
                ? $_("nav-switch-2d", { default: "2D" })
                : $_("nav-switch-3d", { default: "3D" })}
            onclick={handleTogglePitch}
            class="pointer-events-auto h-10 px-3 rounded-full bg-menu-background/94 backdrop-blur-md text-content border border-input-border/60 shadow-md text-xs font-bold flex items-center gap-1.5 hover:bg-secondary-hover cursor-pointer transition-colors"
        >
            <i class="fa-solid fa-cube text-[11px]" aria-hidden="true"></i>
            <span>{is3D ? $_("nav-switch-3d", { default: "3D" }) : $_("nav-switch-2d", { default: "2D" })}</span>
        </button>

        {#if !isFollowing}
            <button
                type="button"
                data-testid="nav-recenter-btn"
                onclick={handleRecenter}
                class="pointer-events-auto h-10 px-3.5 rounded-full bg-menu-background/94 backdrop-blur-md hover:bg-secondary-hover text-content border border-input-border/60 shadow-md text-xs font-bold flex items-center gap-1.5 cursor-pointer transition-colors"
            >
                <i class="fa-solid fa-crosshairs" aria-hidden="true"></i>
                <span>{$_("nav-recenter", { default: "Recenter" })}</span>
            </button>
        {/if}
    </div>

    <GroupSheet
        bind:open={groupSheetOpen}
        {groupSession}
        busy={groupBusy}
        initialDisplayName={savedGroupName}
        selfLat={liveUserPos?.lat ?? null}
        selfLon={liveUserPos?.lon ?? null}
        selfAlongTrackM={forwardAlongTrackMeters()}
        onCreateGroup={handleCreateGroup}
        onJoinGroup={handleJoinGroup}
        onLeaveGroup={handleLeaveGroup}
        onFocusMember={handleFocusGroupMember}
    />

    <WazeReportSheet
        bind:open={reportSheetOpen}
        submitting={liveBusy}
        onSubmit={handleSubmitReport}
    />

    <!-- Bottom Trip Bar & Live Elevation Sheet -->
    <div
        bind:this={bottomSheetWrapEl}
        class="fixed bottom-0 inset-x-0 z-30 max-w-2xl mx-auto pointer-events-none"
    >
        <LiveElevationSheet
            points={activePoints}
            {alongTrackMeters}
            eta={etaSnapshot}
            {reroute}
            rescueRoute={activeRescueRoute}
            reports={liveReports}
            {activeHikersCount}
            {userEle}
            {paused}
            {reversed}
            bind:expanded={sheetExpanded}
            onTogglePause={handleTogglePause}
            onReverse={handleReverseDirection}
            onExit={handleExitNavigation}
            {offTrailMode}
            onOffTrailModeChange={handleOffTrailModeChange}
            {signalState}
            {effectiveAccuracyM}
            {isFarPreview}
            {farFromTrailDistanceM}
            {accessRouteActive}
            onRequestAccessRoute={handleRequestAccessRoute}
            {groupMembers}
        />
    </div>
</main>

<style>
    #nav-map-wrap :global(.maplibregl-ctrl-top-right) {
        top: calc(5.25rem + env(safe-area-inset-top, 0px));
        right: 12px;
        z-index: 38;
    }
    #nav-map-wrap :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group) {
        border-radius: 9999px;
        box-shadow: 0 3px 12px rgb(0 0 0 / 0.18);
        border: 1.5px solid rgba(36, 39, 52, 0.18);
        margin: 0;
        background: rgba(var(--menu-background));
    }
    #nav-map-wrap :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group.wanderer-style-switcher) {
        overflow: visible;
    }
    #nav-map-wrap :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group > button) {
        width: 40px;
        height: 40px;
        border-radius: 9999px;
    }
</style>
