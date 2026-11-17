<script lang="ts">
    import { goto } from "$app/navigation";
    import { page } from "$app/state";
    import MetaTags from "#lib/components/base/meta_tags.svelte";
    import StatChip from "#lib/components/mobile_shell/stat_chip.svelte";
    import ActiveHikersBadge from "#lib/components/trail/active_hikers_badge.svelte";
    import LikeButton from "#lib/components/trail/like_button.svelte";
    import MapWithElevationMaplibre from "#lib/components/trail/map_with_elevation_maplibre.svelte";
    import TrailDropdown from "#lib/components/trail/trail_dropdown.svelte";
    import TrailInfoPanel from "#lib/components/trail/trail_info_panel.svelte";
    import {
        connectLiveStream,
        fetchTrailLiveSummary,
        mergeReportIntoList,
        mergeSosIntoList,
        subscribeWebPushIfSupported,
        voteReport,
        type LiveStreamHandle,
        type ReportVoteType,
        type SosAlertDto,
        type TrailReportDto,
    } from "#lib/live/live_client.ts";
    import {
        syncReportMapMarkers,
        syncSosMapMarkers,
    } from "#lib/live/report_markers.ts";
    import { currentUser } from "#lib/stores/user_store.ts";
    import { getFileURL } from "#lib/util/file_util.ts";
    import {
        formatDistance,
        formatElevation,
        formatTimeHHMM,
        trailDisplayDuration,
    } from "#lib/util/format_util.ts";
    import * as M from "maplibre-gl";
    import "photoswipe/style.css";
    import { onDestroy, onMount, untrack } from "svelte";
    import { _ } from "svelte-i18n";

    let { data } = $props();

    const trail = $state(untrack(() => data.trail));

    let markers: M.Marker[] = $state([]);
    let detailMap: M.Map | null = $state(null);
    let mapRef: MapWithElevationMaplibre | undefined = $state();
    let showRoute = $state(true);
    let sheetOpen = $state(true);
    let activeSheetTab = $state<"elevation" | "details">("elevation");
    let activeHikers30m = $state<number>(0);
    let liveReports = $state<TrailReportDto[]>([]);
    let liveSosAlerts = $state<SosAlertDto[]>([]);
    let liveLoading = $state(true);

    let reportMarkers: M.Marker[] = [];
    let sosMarkers: M.Marker[] = [];
    let streamHandle: LiveStreamHandle | null = null;
    let summaryPollTimer: ReturnType<typeof setInterval> | null = null;
    let scrubPoint = $state<{
        distance: number;
        elevation: number;
        dPlus: number;
        gradePercent: number;
    } | null>(null);
    let eleSummary = $state<{
        minElevation: number | null;
        maxElevation: number | null;
        totalAscent: number;
    }>({
        minElevation: null,
        maxElevation: null,
        totalAscent: 0,
    });

    const canLikeTrail = $derived(
        Boolean(
            ($currentUser && $currentUser.actor == trail.author) ||
                trail.expand?.trail_share_via_trail?.length ||
                trail.public,
        ),
    );

    const navigateHref = $derived.by(() => {
        const share = page.url.searchParams.get("share");
        const base = `/map/trail/${page.params.handle}/${trail.id ?? page.params.id}/navigate`;
        return share ? `${base}?share=${encodeURIComponent(share)}` : base;
    });

    function requestIosCompassPermissionFromStartTap() {
        try {
            if (typeof DeviceOrientationEvent !== "undefined") {
                const req = (
                    DeviceOrientationEvent as unknown as {
                        requestPermission?: () => Promise<string>;
                    }
                ).requestPermission;
                if (typeof req === "function") {
                    void req.call(DeviceOrientationEvent).catch(() => {});
                }
            }
            if (
                typeof Notification !== "undefined" &&
                Notification.permission === "granted"
            ) {
                void subscribeWebPushIfSupported(
                    trail.lat ?? null,
                    trail.lon ?? null,
                    trail.id,
                    { requestPermission: false },
                );
            }
        } catch {
            // Non-blocking best-effort iOS compass unlock on user tap
        }
    }

    async function handleReportVoteOnDetail(reportId: string, vote: ReportVoteType) {
        const updated = await voteReport(reportId, vote);
        if (updated) {
            liveReports = mergeReportIntoList(liveReports, updated);
        }
    }

    async function loadLiveSummary() {
        if (!trail.id) return;
        const sum = await fetchTrailLiveSummary(trail.id);
        if (sum) {
            activeHikers30m = sum.activeHikers30m;
            liveReports = sum.reports;
            liveSosAlerts = sum.sosAlerts;
        }
        liveLoading = false;
    }

    $effect(() => {
        const m = detailMap;
        const reps = liveReports;
        untrack(() => {
            reportMarkers = syncReportMapMarkers(m, reportMarkers, reps, {
                onVote: (id, v) => void handleReportVoteOnDetail(id, v),
            });
        });
    });

    $effect(() => {
        const m = detailMap;
        const alerts = liveSosAlerts;
        untrack(() => {
            sosMarkers = syncSosMapMarkers(m, sosMarkers, alerts, {
                onRespond: (sos) => {
                    const targetUrl = `${navigateHref}${navigateHref.includes("?") ? "&" : "?"}sos=${encodeURIComponent(sos.id)}`;
                    void goto(targetUrl);
                },
            });
        });
    });

    onMount(() => {
        void loadLiveSummary();

        summaryPollTimer = setInterval(() => {
            if (typeof document === "undefined" || document.visibilityState === "visible") {
                void loadLiveSummary();
            }
        }, 60_000);

        if (trail.id) {
            streamHandle = connectLiveStream({
                trailId: trail.id,
                lat: trail.lat ?? null,
                lon: trail.lon ?? null,
                callbacks: {
                    onReportUpdate: (rep) => {
                        liveReports = mergeReportIntoList(liveReports, rep);
                    },
                    onSosUpdate: (sos) => {
                        liveSosAlerts = mergeSosIntoList(liveSosAlerts, sos);
                    },
                },
            });
        }
    });

    onDestroy(() => {
        if (summaryPollTimer) {
            clearInterval(summaryPollTimer);
            summaryPollTimer = null;
        }
        streamHandle?.close();
        streamHandle = null;
        for (const m of reportMarkers) m.remove();
        reportMarkers = [];
        for (const m of sosMarkers) m.remove();
        sosMarkers = [];
    });
</script>

<MetaTags
    title={`${data.trail.name} | ${$_("map")} | wanderer`}
    openGraph={{
        title: data.trail.name,
        description: data.trail.description,
        url: page.url.origin + page.url.pathname,
        type: "article",
        article: {
            publishedTime: data.trail.created,
            modifiedTime: data.trail.updated,
            authors: [
                `${page.url.origin}/profile/@${data.trail.expand?.author?.preferred_username ?? ""}`,
            ],
            tags: [...new Set(data.trail.expand?.tags?.map((t) => t.name) ?? [])],
        },
        images: data.trail.photos
            // Link previews can't show SVG, like the generated route image.
            .filter((p) => !p.endsWith(".svg"))
            .map((p) => ({
                url: page.url.origin + getFileURL(data.trail, p),
            })),
    }}
></MetaTags>

<main class="fixed inset-0 w-screen h-dvh overflow-hidden">
    <div id="trail-detail-map" class="w-full h-full">
        <MapWithElevationMaplibre
            bind:this={mapRef}
            bind:map={detailMap}
            trails={[trail]}
            waypoints={trail.expand?.waypoints_via_trail}
            activeTrail={0}
            bind:markers
            showTerrain={true}
            mobileChrome={true}
            showStyleSwitcher={true}
            hideTrailRoute={!showRoute}
            fitPaddingBottom={sheetOpen ? 300 : 84}
            elevationProfileContainer="mobile-epc-container"
            onElevationMove={(pt) => (scrubPoint = pt)}
            onElevationSummary={(sum) => (eleSummary = sum)}
        />
    </div>

    <!-- Top Floating Header -->
    <header
        style="top: calc(0.875rem + env(safe-area-inset-top, 0px));"
        class="fixed inset-x-3.5 z-35 flex items-center justify-between gap-2 pointer-events-none"
    >
        <div class="flex items-center gap-2 min-w-0">
            <button
                type="button"
                aria-label={$_("back")}
                class="pointer-events-auto rounded-full w-10 h-10 bg-menu-background/95 backdrop-blur shadow-md border border-input-border/50 flex items-center justify-center text-content hover:bg-secondary-hover shrink-0 cursor-pointer"
                onclick={() => (history.length > 1 ? history.back() : goto("/map"))}
            >
                <i class="fa fa-arrow-left" aria-hidden="true"></i>
            </button>
            <div
                class="pointer-events-auto bg-menu-background/95 backdrop-blur px-3.5 py-1.5 rounded-full shadow-md border border-input-border/50 text-sm font-semibold text-content truncate max-w-[min(46vw,420px)]"
                title={trail.name}
            >
                {trail.name}
            </div>
        </div>

        <div
            class="pointer-events-auto flex items-center gap-1.5 bg-menu-background/95 backdrop-blur px-2 py-1 rounded-full shadow-md border border-input-border/50 shrink-0"
        >
            <a
                href={navigateHref}
                onclick={requestIosCompassPermissionFromStartTap}
                class="inline-flex items-center gap-1.5 rounded-full bg-emerald-700 hover:bg-emerald-800 text-white px-3 py-1.5 text-xs font-semibold whitespace-nowrap shadow-sm transition-colors"
            >
                <i class="fa-solid fa-location-arrow text-[11px]" aria-hidden="true"></i>
                <span>{$_("start-trail", { default: "Start" })}</span>
            </a>
            {#if canLikeTrail}
                <LikeButton {trail} />
            {/if}
            <TrailDropdown
                trails={new Set([trail])}
                onDelete={() =>
                    history.length > 1 ? history.back() : goto("/map")}
                mode="map"
            />
        </div>
    </header>

    <!-- Floating Map Action Pill on Left-Top -->
    <div
        style="top: calc(4rem + env(safe-area-inset-top, 0px));"
        class="fixed left-3.5 z-35 rounded-3xl bg-menu-background/95 backdrop-blur shadow-md border border-input-border/50 p-1 flex flex-col gap-1"
    >
        <button
            type="button"
            class="w-9 h-9 rounded-full flex items-center justify-center text-content hover:bg-secondary-hover cursor-pointer"
            class:text-primary={showRoute}
            aria-label={$_("route", { values: { n: 1 } })}
            title={$_("route", { values: { n: 1 } })}
            onclick={() => (showRoute = !showRoute)}
        >
            <i class={`fa ${showRoute ? "fa-eye" : "fa-eye-slash"} text-sm`} aria-hidden="true"></i>
        </button>
        <button
            type="button"
            class="w-9 h-9 rounded-full flex items-center justify-center text-content hover:bg-secondary-hover cursor-pointer"
            aria-label={$_("trail-map-reset-view")}
            title={$_("trail-map-reset-view")}
            onclick={() => mapRef?.fitToBounds()}
        >
            <i class="fa fa-expand text-sm" aria-hidden="true"></i>
        </button>
        <button
            type="button"
            class="w-9 h-9 rounded-full flex items-center justify-center text-content hover:bg-secondary-hover cursor-pointer"
            class:text-primary={sheetOpen}
            aria-label={$_("elevation-profile")}
            title={$_("elevation-profile")}
            aria-expanded={sheetOpen}
            onclick={() => (sheetOpen = !sheetOpen)}
        >
            <i class="fa fa-chart-area text-sm" aria-hidden="true"></i>
        </button>
    </div>

    {#if !sheetOpen}
        <div class="fixed bottom-20 inset-x-0 z-34 flex justify-center items-center gap-2 pointer-events-none px-3">
            <button
                type="button"
                class="pointer-events-auto inline-flex items-center gap-2 rounded-full bg-menu-background border border-input-border/60 shadow-lg px-4 py-2 text-xs font-semibold text-content cursor-pointer hover:bg-secondary-hover"
                onclick={() => (sheetOpen = true)}
            >
                <i class="fa fa-chevron-up" aria-hidden="true"></i>
                <span>{$_("elevation-profile")} · {$_("details")}</span>
            </button>
            <div class="pointer-events-auto rounded-full bg-menu-background/95 shadow-lg">
                <ActiveHikersBadge count={activeHikers30m} loading={liveLoading} compact={true} />
            </div>
        </div>
    {/if}

    <!-- Bottom Rounded Sheet -->
    <section
        class="fixed bottom-16 inset-x-0 max-w-[760px] mx-auto z-34 bg-menu-background rounded-t-2xl shadow-[0_-6px_24px_rgba(0,0,0,0.18)] border-t border-input-border/60 transition-transform duration-200"
        class:translate-y-[calc(100%+5rem)]={!sheetOpen}
        aria-label={$_("details")}
    >
        <div class="px-4 pt-2 pb-1.5 flex flex-col gap-1.5">
            <div class="w-8 h-1 rounded-full bg-content/20 mx-auto"></div>
            <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="flex flex-wrap items-center gap-2 min-w-0">
                    <div
                        class="inline-flex rounded-full bg-content/[0.06] p-1 gap-1"
                        role="tablist"
                    >
                        <button
                            type="button"
                            role="tab"
                            aria-selected={activeSheetTab === "elevation"}
                            class={`px-3 py-1 rounded-full text-xs font-semibold inline-flex items-center gap-1.5 cursor-pointer transition-colors ${
                                activeSheetTab === "elevation"
                                    ? "bg-menu-background text-primary shadow-sm"
                                    : "text-content/70 hover:text-content"
                            }`}
                            onclick={() => (activeSheetTab = "elevation")}
                        >
                            <i class="fa fa-mountain" aria-hidden="true"></i>
                            <span>{$_("elevation-profile")}</span>
                        </button>
                        <button
                            type="button"
                            role="tab"
                            aria-selected={activeSheetTab === "details"}
                            class={`px-3 py-1 rounded-full text-xs font-semibold inline-flex items-center gap-1.5 cursor-pointer transition-colors ${
                                activeSheetTab === "details"
                                    ? "bg-menu-background text-primary shadow-sm"
                                    : "text-content/70 hover:text-content"
                            }`}
                            onclick={() => (activeSheetTab = "details")}
                        >
                            <i class="fa fa-circle-info" aria-hidden="true"></i>
                            <span>{$_("details")}</span>
                        </button>
                    </div>

                    <ActiveHikersBadge count={activeHikers30m} loading={liveLoading} />
                </div>

                <button
                    type="button"
                    aria-label={$_("close")}
                    class="w-7 h-7 rounded-full bg-content/[0.06] hover:bg-secondary-hover flex items-center justify-center text-xs text-content/75 cursor-pointer"
                    onclick={() => (sheetOpen = false)}
                >
                    <i class="fa fa-chevron-down" aria-hidden="true"></i>
                </button>
            </div>
        </div>

        <div class="px-4 pb-3 pt-1" class:hidden={activeSheetTab !== "elevation"}>
            <div class="flex flex-wrap items-center justify-between gap-1.5 mb-2">
                {#if scrubPoint}
                    <StatChip icon="fa-ruler" label={formatDistance(scrubPoint.distance)} />
                    <StatChip icon="fa-mountain" label={formatElevation(scrubPoint.elevation)} />
                    <StatChip icon="fa-arrow-trend-up" label={formatElevation(scrubPoint.dPlus)} />
                    <StatChip
                        icon="fa-percent"
                        label={`${scrubPoint.gradePercent >= 0 ? "+" : ""}${scrubPoint.gradePercent.toFixed(1)}%`}
                    />
                {:else}
                    <StatChip
                        icon="fa-clock"
                        label={formatTimeHHMM(trailDisplayDuration(trail))}
                    />
                    <StatChip icon="fa-ruler" label={formatDistance(trail.distance)} />
                    <StatChip
                        icon="fa-arrow-trend-up"
                        label={formatElevation(trail.elevation_gain)}
                    />
                    <StatChip
                        icon="fa-arrow-trend-down"
                        label={formatElevation(trail.elevation_loss)}
                    />
                    {#if eleSummary.maxElevation !== null}
                        <StatChip
                            icon="fa-mountain-sun"
                            label={`${$_("peak")}: ${formatElevation(eleSummary.maxElevation)}`}
                        />
                    {/if}
                {/if}
            </div>

            <div id="mobile-epc-container" class="relative w-full h-[175px]"></div>
        </div>

        <div
            class="max-h-[64dvh] overflow-y-auto border-t border-input-border/40"
            class:hidden={activeSheetTab !== "details"}
        >
            <TrailInfoPanel
                handle={page.params.handle!}
                initTrail={trail}
                {markers}
                mode="list"
            />
        </div>
    </section>
</main>

<style>
    #trail-detail-map :global(.maplibregl-ctrl-top-left) {
        top: 64px;
        left: 64px;
    }
    #trail-detail-map :global(.maplibregl-ctrl-scale) {
        background: rgba(255, 255, 255, 0.88);
        border: 1.5px solid #242734;
        border-top: none;
        border-radius: 0 0 4px 4px;
        color: #242734;
        font-size: 11px;
        font-weight: 600;
        padding: 1px 6px;
        box-shadow: 0 1px 4px rgb(0 0 0 / 0.12);
    }
    #trail-detail-map :global(.maplibregl-ctrl-top-right) {
        top: 64px;
        right: 14px;
        display: flex;
        flex-direction: column;
        align-items: flex-end;
        gap: 8px;
        z-index: 20;
    }
    #trail-detail-map :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group) {
        border-radius: 9999px;
        box-shadow: 0 3px 12px rgb(0 0 0 / 0.18);
        border: 1.5px solid rgba(36, 39, 52, 0.18);
        overflow: hidden;
        margin: 0;
        background: rgba(var(--menu-background));
    }
    #trail-detail-map :global(.maplibregl-ctrl-top-right .maplibregl-ctrl-group button) {
        width: 40px;
        height: 40px;
    }
    #trail-detail-map :global(.maplibregl-ctrl-bottom-right) {
        bottom: 335px;
        right: 8px;
    }
    #trail-detail-map :global(.maplibregl-ctrl-bottom-left) {
        bottom: 335px;
        left: 8px;
    }
</style>
