<script lang="ts">
    import { cardinalDirection, normalizeBearingDelta } from "#lib/navigation/geo_math.ts";
    import type {
        HorizonPanorama,
        PeakEntryDto,
        VisiblePeakResult,
    } from "#lib/navigation/peak_finder_engine.ts";
    import { OfflinePeakFinder } from "#lib/navigation/peak_finder_engine.ts";
    import { getSunPosition } from "#lib/navigation/sun_calc.ts";
    import { formatDistance, formatElevation } from "#lib/util/format_util.ts";

    interface Props {
        open: boolean;
        panorama: HorizonPanorama | null;
        compassHeadingDeg: number | null;
        finder: OfflinePeakFinder;
        nowMs?: number;
        onClose: () => void;
        onSelectPeakOnMap?: (peak: PeakEntryDto) => void;
    }

    let {
        open = $bindable(false),
        panorama,
        compassHeadingDeg,
        finder,
        nowMs = Date.now(),
        onClose,
        onSelectPeakOnMap,
    }: Props = $props();

    let manualOffsetDeg = $state(0);
    let dragStartX = $state<number | null>(null);
    let dragStartOffset = $state(0);
    let canvasEl = $state<HTMLCanvasElement | null>(null);

    const FOV_DEG = 90;
    const effectiveHeadingDeg = $derived(
        ((((compassHeadingDeg ?? 0) + manualOffsetDeg) % 360) + 360) % 360,
    );

    const viewportPeaks = $derived<VisiblePeakResult[]>(
        panorama ? finder.selectViewportPeaks(panorama, effectiveHeadingDeg, FOV_DEG, 8) : [],
    );

    $effect(() => {
        const canvas = canvasEl;
        const pano = panorama;
        const centerAz = effectiveHeadingDeg;
        if (!open || !canvas || !pano) return;

        const width = 360;
        const height = 165;
        const dpr = typeof window !== "undefined" ? Math.min(window.devicePixelRatio || 1, 3) : 1;
        canvas.width = width * dpr;
        canvas.height = height * dpr;
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, width, height);

        const minAng = -8;
        const maxAng = 26;
        const toY = (ang: number) => height - ((ang - minAng) / (maxAng - minAng)) * (height - 28);

        const drawBand = (arr: Float32Array, fill: string) => {
            ctx.beginPath();
            ctx.moveTo(0, height);
            for (let x = 0; x <= width; x += 2) {
                const az =
                    (((centerAz - FOV_DEG / 2 + (x / width) * FOV_DEG) % 360) + 360) % 360;
                const bin = Math.min(719, Math.max(0, Math.round(az * 2) % 720));
                ctx.lineTo(x, toY(arr[bin]));
            }
            ctx.lineTo(width, height);
            ctx.closePath();
            ctx.fillStyle = fill;
            ctx.fill();
        };

        drawBand(pano.farDeg, "rgba(100, 116, 139, 0.25)");
        drawBand(pano.midDeg, "rgba(71, 85, 105, 0.38)");
        drawBand(pano.nearDeg, "rgba(36, 39, 52, 0.62)");

        const sun = getSunPosition(nowMs, pano.observerLat, pano.observerLon);
        const sunRel = normalizeBearingDelta(centerAz, sun.azimuthDeg);
        if (
            Math.abs(sunRel) <= FOV_DEG / 2 &&
            sun.altitudeDeg >= minAng &&
            sun.altitudeDeg <= maxAng
        ) {
            const sx = ((sunRel + FOV_DEG / 2) / FOV_DEG) * width;
            const sy = toY(sun.altitudeDeg);
            ctx.beginPath();
            ctx.arc(sx, sy, 6, 0, Math.PI * 2);
            ctx.fillStyle = "rgba(245, 158, 11, 0.92)";
            ctx.fill();
        }

        for (const vp of viewportPeaks) {
            const rel = normalizeBearingDelta(centerAz, vp.bearingDeg);
            const px = ((rel + FOV_DEG / 2) / FOV_DEG) * width;
            const py = Math.min(height - 14, Math.max(42, toY(vp.elevationAngleDeg)));
            const topY = vp.tier === 1 ? 16 : 32;

            ctx.save();
            if (vp.visibility === "unverified") ctx.setLineDash([3, 3]);
            ctx.strokeStyle = "rgba(148, 163, 184, 0.75)";
            ctx.lineWidth = 1.2;
            ctx.beginPath();
            ctx.moveTo(px, py);
            ctx.lineTo(px, topY);
            ctx.stroke();
            ctx.restore();
        }
    });
</script>

{#if open}
    <section
        data-testid="peak-finder-sheet"
        aria-label="Ce vârf văd în față?"
        class="fixed inset-x-3 bottom-4 z-50 max-w-lg mx-auto bg-menu-background/96 backdrop-blur-md text-content rounded-2xl border border-input-border/60 shadow-[0_8px_32px_rgba(0,0,0,0.24)] p-3.5 pointer-events-auto"
    >
        <div class="flex items-center justify-between gap-2 mb-2">
            <div>
                <h2 class="text-sm font-extrabold tracking-tight flex items-center gap-2">
                    <i class="fa-solid fa-mountain-sun text-xs" aria-hidden="true"></i>
                    <span>Ce vârf văd în față?</span>
                    <span
                        data-testid="peak-finder-heading"
                        class="px-2 py-0.5 rounded-full bg-[#242734] text-white text-[11px] font-bold tabular-nums"
                    >
                        {Math.round(effectiveHeadingDeg)}° {cardinalDirection(effectiveHeadingDeg, "ro")}
                    </span>
                </h2>
                {#if panorama?.standingOnPeak}
                    <p class="text-[11px] text-content/75 mt-0.5">
                        Ești pe <strong>{panorama.standingOnPeak.name}</strong> ({formatElevation(panorama.standingOnPeak.ele)})
                    </p>
                {/if}
            </div>
            <div class="flex items-center gap-1.5">
                {#if manualOffsetDeg !== 0}
                    <button
                        type="button"
                        onclick={() => (manualOffsetDeg = 0)}
                        class="px-2.5 py-1 rounded-full bg-content/[0.08] text-[11px] font-semibold cursor-pointer"
                    >
                        Busolă live
                    </button>
                {/if}
                <button
                    type="button"
                    data-testid="peak-finder-close-btn"
                    onclick={onClose}
                    aria-label="Închide"
                    class="w-8 h-8 rounded-full bg-content/[0.08] text-content/75 flex items-center justify-center cursor-pointer"
                >
                    <i class="fa-solid fa-xmark text-sm" aria-hidden="true"></i>
                </button>
            </div>
        </div>

        <div
            role="presentation"
            class="relative w-full h-[165px] rounded-xl bg-content/[0.04] overflow-hidden select-none touch-pan-y"
            onpointerdown={(e) => {
                dragStartX = e.clientX;
                dragStartOffset = manualOffsetDeg;
            }}
            onpointermove={(e) => {
                if (dragStartX === null) return;
                const dx = e.clientX - dragStartX;
                manualOffsetDeg = dragStartOffset - dx * 0.3;
            }}
            onpointerup={() => (dragStartX = null)}
            onpointercancel={() => (dragStartX = null)}
        >
            <canvas bind:this={canvasEl} class="block w-full h-full"></canvas>
        </div>

        <div data-testid="peak-finder-list" class="mt-2.5 max-h-44 overflow-y-auto divide-y divide-input-border/40">
            {#if viewportPeaks.length === 0}
                <p class="py-3 text-xs text-center text-content/65">
                    Niciun vârf numit vizibil pe direcția actuală ({Math.round(effectiveHeadingDeg)}°). Rotește telefonul sau glisează orizontul.
                </p>
            {:else}
                {#each viewportPeaks as item (item.peak.id)}
                    <button
                        type="button"
                        data-testid="peak-finder-item"
                        onclick={() => onSelectPeakOnMap?.(item.peak)}
                        class="w-full py-2 px-1 flex items-center justify-between gap-2 text-left hover:bg-content/[0.04] rounded-lg cursor-pointer"
                    >
                        <div class="min-w-0">
                            <span class="text-xs font-bold text-content block truncate">
                                {item.peak.name}
                            </span>
                            <span class="text-[11px] text-content/70 tabular-nums">
                                {formatElevation(item.peak.ele)} · {formatDistance(Math.round(item.distanceM), { compact: true })} · {Math.round(item.bearingDeg)}° {item.cardinal}
                            </span>
                        </div>
                        <span class="px-2 py-0.5 rounded-full bg-content/[0.07] text-[10.5px] font-semibold shrink-0">
                            Pe hartă
                        </span>
                    </button>
                {/each}
            {/if}
        </div>
    </section>
{/if}
