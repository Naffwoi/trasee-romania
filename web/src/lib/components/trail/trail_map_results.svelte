<script module lang="ts">
    export interface MapCamera { center: [number, number]; zoom: number; bearing: number; pitch: number }
</script>

<script lang="ts">
    import type { Snippet } from "svelte";
    import { onMount, tick, untrack } from "svelte";
    import type { FeatureCollection } from "geojson";
    import * as M from "maplibre-gl";
    import type { Settings } from "#lib/models/settings.ts";
    import type { Trail, TrailBoundingBox, TrailFilter } from "#lib/models/trail.ts";
    import type { TrailSearchBounds } from "#lib/util/trail_search_util.ts";
    import type { SelectItem } from "../base/select.svelte";
    import MobileSelectedTrailCard from "../mobile_shell/mobile_selected_trail_card.svelte";
    import MobileTrailsSheet, { type SheetSnap } from "../mobile_shell/mobile_trails_sheet.svelte";
    import MapWithElevationMaplibre from "./map_with_elevation_maplibre.svelte";
    import MergeDialog from "./trail_merge_dialog.svelte";

    interface Props {
        expanded?: boolean;
        onenlarge?: () => void;
        trails: Trail[];
        mapTrails: Trail[];
        clusters?: FeatureCollection;
        loading: boolean;
        showMap?: boolean;
        display?: "cards" | "list" | "table";
        tableHeader?: SelectItem[];
        filter?: TrailFilter;
        onsort?: (sort: string) => void;
        onupdate?: (updatedTrails?: Trail[]) => void;
        active?: boolean;
        mapLoading?: boolean;
        initialBounds?: TrailSearchBounds;
        initialCenter?: { lat: number; lon: number };
        initialCamera?: MapCamera;
        boundingBox: TrailBoundingBox;
        settings?: Settings;
        near: TrailFilter["near"];
        onviewport: (bounds: TrailSearchBounds, zoom: number) => void;
        ongroup?: (trail: Trail) => void;
        moreResults: Snippet;
    }
    let {
        expanded = false,
        onenlarge: _onenlarge,
        trails,
        mapTrails,
        clusters,
        loading,
        showMap = $bindable(true),
        display: _display = "cards",
        tableHeader: _tableHeader = [],
        filter: _filter,
        onsort: _onsort,
        onupdate: _onupdate,
        active = true,
        mapLoading = false,
        initialBounds,
        initialCenter,
        boundingBox,
        settings,
        near,
        onviewport,
        ongroup,
        moreResults,
        initialCamera,
    }: Props = $props();

    let root: HTMLDivElement;
    let mapElement: HTMLDivElement;
    let map: M.Map | undefined = $state();
    let mapWithElevation: MapWithElevationMaplibre | undefined = $state();
    let ready = false;
    let initialized = false;
    let selectedTrail = $state<Trail | null>(null);
    let sheetSnap = $state<SheetSnap>("peek");

    function hoverTrail(trail?: Trail) {
        if (trail) mapWithElevation?.highlightCluster(trail);
        else mapWithElevation?.unHighlightCluster();
    }

    function selectTrail(trail: Trail) {
        const enrichedFromMap = mapTrails.find((item) => item.id === trail.id);
        const enrichedFromList = trails.find((item) => item.id === trail.id);
        const merged = enrichedFromMap
            ? {
                  ...(enrichedFromList ?? {}),
                  ...enrichedFromMap,
                  name: enrichedFromMap.name || enrichedFromList?.name || trail.name,
              }
            : { ...trail, ...(enrichedFromList ?? {}) };
        selectedTrail = merged;
        sheetSnap = "peek";
    }

    let lastViewport: TrailSearchBounds | undefined;
    let hiddenArea: TrailSearchBounds | undefined;
    let cameraPositioned = false;
    let initializingViewport = false;
    let defaultCamera: MapCamera | undefined;
    let resumeRevision = 0;
    let locationRequest = 0;
    let pendingLocation: { lat: number; lon: number } | undefined;

    function mapVisible() {
        return true;
    }

    function renderedBounds(): TrailSearchBounds | undefined {
        if (!map) return;
        const bounds = map.getBounds();
        const normalize = (longitude: number) => ((((longitude + 180) % 360) + 360) % 360) - 180;
        const global = bounds.getEast() - bounds.getWest() >= 360;
        return {
            northEast: { lat: bounds.getNorth(), lng: global ? 180 : normalize(bounds.getEast()) },
            southWest: { lat: bounds.getSouth(), lng: global ? -180 : normalize(bounds.getWest()) },
        };
    }

    function insets() {
        return { left: 0, top: 0 };
    }

    function fitPadding(margin: number) {
        return { left: margin, top: margin + 104, right: margin, bottom: margin + 72 };
    }

    function visibleBounds(): TrailSearchBounds | undefined {
        return renderedBounds();
    }

    function handleMoveEnd() {
        if (!ready || initializingViewport || !mapVisible()) return;
        if (hiddenArea) { focusBounds(hiddenArea); return; }
        cameraPositioned = true;
        notifyViewport();
    }

    $effect(() => {
        const visible = active;
        const revision = ++resumeRevision;
        if (!visible || !ready) return;
        void tick().then(() => {
            if (!active || !ready || revision !== resumeRevision) return;
            if (!initialized) initializeViewport();
            else if (initialBounds && JSON.stringify(initialBounds) !== JSON.stringify(lastViewport)) focusBounds(initialBounds);
            else notifyViewport();
        });
    });

    onMount(() => {
        return () => {
            ready = false;
            ++resumeRevision;
            ++locationRequest;
        };
    });

    function notifyViewport() {
        if (!active || !ready || !map) return;
        lastViewport = visibleBounds();
        if (lastViewport) onviewport(lastViewport, map.getZoom());
    }

    export function focusBounds(bounds: TrailSearchBounds) {
        if (!ready || !map) return false;
        const east = bounds.northEast.lng < bounds.southWest.lng ? bounds.northEast.lng + 360 : bounds.northEast.lng;
        hiddenArea = undefined;
        cameraPositioned = true;
        map.fitBounds([[bounds.southWest.lng, bounds.southWest.lat], [east, bounds.northEast.lat]], {
            animate: false,
            ...(expanded ? { padding: fitPadding(0) } : {}),
            bearing: map.getBearing(),
            pitch: map.getPitch(),
        });
        return true;
    }

    export function focusPlace(place: TrailFilter["near"], _reveal = true) {
        if (!ready || !map || !Number.isFinite(place.lat) || !Number.isFinite(place.lon)) return;
        showMap = true;
        map.fitBounds(M.LngLatBounds.fromLngLat(new M.LngLat(place.lon!, place.lat!), place.radius), {
            padding: fitPadding(32),
            maxZoom: 14,
            animate: false,
        });
    }

    export async function focusLocation(location: { lat: number; lon: number }) {
        if (!Number.isFinite(location.lat) || !Number.isFinite(location.lon)) return;
        ++locationRequest;
        showMap = true;
        if (!ready || !map) { pendingLocation = location; return; }
        await tick();
        centerOn(location, 14);
    }

    function handleMapInit() {
        ready = true;
        if (map) {
            defaultCamera = {
                center: map.getCenter().toArray(),
                zoom: map.getZoom(),
                bearing: map.getBearing(),
                pitch: map.getPitch(),
            };
        }
        if (active) initializeViewport();
    }

    function initializeViewport() {
        initialized = true;
        initializingViewport = true;
        if (pendingLocation) {
            centerOn(pendingLocation, 14);
            pendingLocation = undefined;
        }
        else if (initialCamera) map?.jumpTo(initialCamera);
        else if (initialBounds) focusBounds(initialBounds);
        else if (initialCenter) centerOn(initialCenter, 14);
        else if (Number.isFinite(near.lat) && Number.isFinite(near.lon)) focusPlace(near, false);
        else focusDefaultViewport();
        if (!hiddenArea) cameraPositioned = true;
        initializingViewport = false;
        notifyViewport();
    }

    export function captureView(): MapCamera | undefined {
        if (!ready || !cameraPositioned || !map) return;
        return { center: map.getCenter().toArray(), zoom: map.getZoom(), bearing: map.getBearing(), pitch: map.getPitch() };
    }

    export function focusCamera(camera: MapCamera) {
        if (!ready || !map) return false;
        hiddenArea = undefined;
        cameraPositioned = true;
        map.jumpTo(camera);
        return true;
    }

    function centerOn(location: { lat: number; lon: number }, zoom: number) {
        const center: [number, number] = [location.lon, location.lat];
        const { left, top } = insets();
        map?.easeTo({ center, zoom, offset: [left / 2, top / 2], duration: 0 });
    }

    function focusDefaultViewport() {
        map?.jumpTo({ bearing: 0, pitch: 0 });
        const request = ++locationRequest;
        const hasTrails = boundingBox.has_trails ?? (boundingBox.min_lon !== 0 || boundingBox.max_lon !== 0 || boundingBox.min_lat !== 0 || boundingBox.max_lat !== 0);
        if (settings?.mapFocus === "trails" && hasTrails) {
            if (boundingBox.min_lon === boundingBox.max_lon && boundingBox.min_lat === boundingBox.max_lat) {
                centerOn({ lon: boundingBox.min_lon, lat: boundingBox.min_lat }, 12);
            } else {
                map?.fitBounds([[boundingBox.min_lon, boundingBox.min_lat], [boundingBox.max_lon, boundingBox.max_lat]], { animate: false, padding: fitPadding(32) });
            }
        } else if (settings?.mapFocus === "location" && settings.location) {
            centerOn(settings.location, 12);
        } else {
            if (defaultCamera) map?.jumpTo(defaultCamera);
            const camera = () => map && JSON.stringify([map.getCenter().toArray(), map.getZoom(), map.getBearing(), map.getPitch()]);
            const requestedCamera = camera();
            navigator.geolocation?.getCurrentPosition(position => {
                if (!ready || !map || request !== locationRequest || map.isMoving() || camera() !== requestedCamera) return;
                centerOn({ lon: position.coords.longitude, lat: position.coords.latitude }, 12);
                lastViewport = visibleBounds();
                notifyViewport();
            }, () => { /* Keep the default camera when location is unavailable. */ });
        }
    }
</script>

<div bind:this={root} class="map-results">
    <div class="map-pane">
        <div id="trail-map" bind:this={mapElement} aria-busy={mapLoading}>
            <MapWithElevationMaplibre
                onmoveend={handleMoveEnd}
                oninit={handleMapInit}
                scalePosition="top-left"
                trails={mapTrails}
                serverClusters={clusters}
                showElevation={false}
                showTerrain={true}
                showInfoPopup={false}
                showClusterPopups={false}
                mobileChrome={true}
                selectedPreviewTrail={selectedTrail}
                onTrailPinSelect={(t) => selectTrail(t)}
                onMapBackgroundClick={() => {
                    selectedTrail = null;
                }}
                activeTrail={-1}
                fitBounds="off"
                clusterTrails={true}
                bind:map
                bind:this={mapWithElevation}
            />
        </div>
    </div>

    {#if selectedTrail}
        <div class="selected-card-overlay">
            <MobileSelectedTrailCard
                trail={selectedTrail}
                ondismiss={() => (selectedTrail = null)}
                {ongroup}
            />
        </div>
    {:else}
        <MobileTrailsSheet
            bind:snap={sheetSnap}
            {trails}
            {loading}
            onSelectTrail={(t) => selectTrail(t)}
            onHoverTrail={hoverTrail}
            {moreResults}
        />
    {/if}
</div>

<MergeDialog />

<style>
    .map-results {
        position: relative;
        width: 100%;
        height: 100%;
        overflow: hidden;
    }
    .map-pane,
    #trail-map {
        width: 100%;
        height: 100%;
        border: 0;
        border-radius: 0;
        overflow: hidden;
    }
    .selected-card-overlay {
        position: fixed;
        left: 1rem;
        right: 1rem;
        bottom: 5.25rem;
        max-width: 500px;
        margin-inline: auto;
        z-index: 35;
    }
    #trail-map :global(.maplibregl-ctrl-top-left) {
        top: calc(124px + env(safe-area-inset-top, 0px));
        left: 16px;
    }
    #trail-map :global(.maplibregl-ctrl-scale) {
        background: rgba(255, 255, 255, 0.78);
        border: none;
        border-bottom: 2px solid #242734;
        border-radius: 3px;
        color: #242734;
        font-size: 11px;
        font-weight: 700;
        padding: 1px 6px;
        box-shadow: none;
    }
    #trail-map :global(.maplibregl-ctrl-top-right) {
        top: 68px;
        right: 14px;
        display: flex;
        flex-direction: column;
        align-items: flex-end;
        gap: 8px;
        z-index: 20;
    }
    #trail-map :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group) {
        border-radius: 9999px;
        box-shadow: 0 3px 12px rgb(0 0 0 / 0.18);
        border: 1.5px solid rgba(36, 39, 52, 0.18);
        overflow: hidden;
        margin: 0;
        background: rgba(var(--menu-background));
    }
    #trail-map :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group.wanderer-style-switcher) {
        overflow: visible;
    }
    #trail-map :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group.wanderer-style-switcher > button) {
        border-radius: 9999px;
    }
    #trail-map :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group button) {
        width: 40px;
        height: 40px;
    }
    #trail-map :global(.maplibregl-ctrl-bottom-right) {
        bottom: 120px;
        right: 8px;
    }
    #trail-map :global(.maplibregl-ctrl-bottom-left) {
        bottom: 120px;
        left: 8px;
    }
</style>
