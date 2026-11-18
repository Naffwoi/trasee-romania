<script lang="ts">
    import {
        buildEmergencySmsHref,
        formatRescueCoordinates,
    } from "#lib/emergency/rescue_coordinates.ts";
    import {
        EmergencySpatialIndex,
        findBestGsm112SignalSpot,
        type GsmSignalRecommendation,
    } from "#lib/emergency/gsm_viewshed.ts";
    import type { DemTileGrid } from "#lib/navigation/dem_tile_grid.ts";
    import { onMount } from "svelte";

    interface Props {
        lat: number | null;
        lon: number | null;
        ele?: number | null;
        accuracy?: number | null;
        reasonRo?: string;
        demGrid?: Pick<DemTileGrid, "sampleElevation"> | null;
        trailPoints?: ReadonlyArray<{ lat: number; lon: number; distanceM?: number }>;
        alongTrackM?: number;
        onShowSignalTarget?: (rec: GsmSignalRecommendation) => void;
    }

    let {
        lat,
        lon,
        ele = null,
        accuracy = null,
        reasonRo = "Urgență",
        demGrid = null,
        trailPoints = [],
        alongTrackM = 0,
        onShowSignalTarget,
    }: Props = $props();

    let spatialIndex = $state<EmergencySpatialIndex | null>(null);
    let copied = $state(false);
    let signalOpen = $state(false);
    let signalResult = $state<GsmSignalRecommendation | null>(null);

    onMount(() => {
        void EmergencySpatialIndex.loadCached().then((idx) => {
            spatialIndex = idx;
        });
    });

    const hasValidCoords = $derived(
        lat !== null && lon !== null && Number.isFinite(lat) && Number.isFinite(lon),
    );

    const rescueBundle = $derived.by(() => {
        if (!hasValidCoords || lat === null || lon === null) return null;
        const lm = spatialIndex?.findNearestLandmark(lat, lon) ?? null;
        return formatRescueCoordinates({
            lat,
            lon,
            elevationM: ele,
            accuracyM: accuracy,
            reasonRo,
            landmark: lm ? { name: lm.name, lat: lm.lat, lon: lm.lon, eleM: lm.eleM } : null,
        });
    });

    const smsSalvamontHref = $derived(
        rescueBundle
            ? buildEmergencySmsHref("+40725826668", rescueBundle.sms113AsciiBody)
            : "sms:+40725826668",
    );
    const sms113Href = $derived(
        rescueBundle ? buildEmergencySmsHref("113", rescueBundle.sms113AsciiBody) : "sms:113",
    );

    async function handleCopyCard() {
        if (!rescueBundle || typeof navigator === "undefined") return;
        try {
            await navigator.clipboard.writeText(rescueBundle.clipboardFullCardRo);
            copied = true;
            setTimeout(() => (copied = false), 2200);
        } catch {
            // Clipboard permission restricted
        }
    }

    function handleRunSignalScan() {
        signalOpen = !signalOpen;
        if (!signalOpen || !hasValidCoords || lat === null || lon === null || !spatialIndex) return;
        const fallbackDem = demGrid ?? { sampleElevation: () => ele ?? 1200 };
        const rec = findBestGsm112SignalSpot({
            lat,
            lon,
            dem: fallbackDem,
            index: spatialIndex,
            trailPoints,
            alongTrackM,
        });
        signalResult = rec;
        if (rec.status === "climb_recommended") {
            onShowSignalTarget?.(rec);
        }
    }
</script>

{#if rescueBundle}
    <div
        data-testid="rescue-coordinates-card"
        class="rounded-2xl bg-content/[0.04] border border-input-border/60 p-2.5 mb-3 text-content"
    >
        <div class="flex items-center justify-between gap-2 mb-1.5">
            <span class="text-[11px] font-extrabold uppercase tracking-wide text-content/75">
                Fișă Coordonate 112 / Salvamont
            </span>
            <button
                type="button"
                data-testid="rescue-copy-coords-btn"
                onclick={handleCopyCard}
                class="px-2 py-0.5 rounded-full bg-[#242734] text-white text-[10.5px] font-bold cursor-pointer"
            >
                {copied ? "✓ Copiat" : "Copiază tot"}
            </button>
        </div>

        <div class="space-y-0.5 font-mono text-[11px] leading-snug tabular-nums">
            <div><span class="text-content/55 font-sans">WGS84:</span> {rescueBundle.wgs84Decimal}</div>
            <div><span class="text-content/55 font-sans">DMS:</span> {rescueBundle.wgs84Dms}</div>
            <div><span class="text-content/55 font-sans">UTM:</span> {rescueBundle.utm.formatted}</div>
            <div><span class="text-content/55 font-sans">Plus:</span> {rescueBundle.plusCode}</div>
            {#if rescueBundle.elevationM !== null}
                <div class="font-sans text-[11px] text-content/85">
                    ⛰️ {rescueBundle.elevationM} m
                    {#if rescueBundle.accuracyM !== null}
                        · ±{rescueBundle.accuracyM} m
                    {/if}
                    {#if rescueBundle.nearestLandmark}
                        · {rescueBundle.nearestLandmark.summaryRo}
                    {/if}
                </div>
            {/if}
        </div>

        <div class="grid grid-cols-2 gap-1.5 mt-2">
            <a
                href={smsSalvamontHref}
                data-testid="sos-sms-coords-btn"
                class="py-1.5 px-2 rounded-xl bg-content/[0.08] hover:bg-content/[0.14] text-content font-bold text-[11px] flex items-center justify-center gap-1 text-center"
            >
                <i class="fa-solid fa-comment-sms text-[11px]" aria-hidden="true"></i>
                <span>SMS Coordonate</span>
            </a>
            <a
                href={sms113Href}
                data-testid="sos-sms-113-btn"
                title="Serviciul SMS 113 necesită număr înregistrat prealabil la STS"
                class="py-1.5 px-2 rounded-xl border border-input-border/70 hover:bg-content/[0.06] text-content/85 font-bold text-[11px] flex items-center justify-center gap-1 text-center"
            >
                <span>SMS 113 (STS)</span>
            </a>
        </div>
        <p class="mt-1 text-[10px] text-content/55 leading-tight">
            112 folosește automat orice rețea din zonă. SMS 113 necesită înregistrare STS prealabilă.
        </p>

        <button
            type="button"
            data-testid="sos-gsm-viewshed-btn"
            onclick={handleRunSignalScan}
            class="mt-2 w-full py-1.5 px-2.5 rounded-xl bg-[#242734]/10 dark:bg-white/10 hover:bg-[#242734]/15 text-content font-bold text-[11px] flex items-center justify-between cursor-pointer"
        >
            <span>📡 Unde prind semnal 112? (Analiză relief)</span>
            <i
                class={`fa-solid ${signalOpen ? "fa-chevron-up" : "fa-chevron-down"} text-[10px]`}
                aria-hidden="true"
            ></i>
        </button>

        {#if signalOpen && signalResult}
            <div
                data-testid="sos-gsm-viewshed-result"
                class="mt-1.5 rounded-xl bg-menu-background/95 border border-input-border/60 p-2 text-[11px] leading-snug"
            >
                <p class="font-semibold text-content">{signalResult.instructionRo}</p>
                <p class="mt-0.5 text-[10px] text-content/55">
                    Estimare geometrică DEM (4/3 R_Earth); pădurea deasă sau vremea pot atenua semnalul.
                </p>
            </div>
        {/if}
    </div>
{/if}
