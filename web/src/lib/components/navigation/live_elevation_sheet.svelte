<script lang="ts">
    import type {
        EtaSnapshot,
        NavTrackPoint,
        OffTrailRerouteResult,
    } from "#lib/navigation/index.ts";
    import { theme } from "#lib/stores/theme_store.ts";
    import { formatDistance, formatElevation } from "#lib/util/format_util.ts";
    import { _ } from "svelte-i18n";

    interface Props {
        points: NavTrackPoint[];
        alongTrackMeters: number;
        eta: EtaSnapshot | null;
        reroute: OffTrailRerouteResult | null;
        userEle?: number | null;
        paused: boolean;
        reversed: boolean;
        expanded?: boolean;
        onTogglePause?: () => void;
        onReverse?: () => void;
        onExit?: () => void;
    }

    let {
        points,
        alongTrackMeters,
        eta,
        reroute,
        userEle = null,
        paused,
        reversed,
        expanded = $bindable(true),
        onTogglePause,
        onReverse,
        onExit,
    }: Props = $props();

    let chartZoom = $state<"2km" | "full">("2km");
    let confirmingExit = $state(false);
    let canvasEl = $state<HTMLCanvasElement | null>(null);
    let chartWrapEl = $state<HTMLDivElement | null>(null);
    let canvasSize = $state({ width: 340, height: 120 });
    let markerOverlay = $state<{ x: number; y: number; visible: boolean }>({
        x: 0,
        y: 0,
        visible: false,
    });

    export function formatDuration(seconds?: number | null): string {
        if (seconds == null || !Number.isFinite(seconds) || seconds < 0) {
            return "-";
        }
        const totalMinutes = Math.round(seconds / 60);
        if (totalMinutes < 1) {
            return "< 1 min";
        }
        if (totalMinutes < 60) {
            return `${totalMinutes} min`;
        }
        const h = Math.floor(totalMinutes / 60);
        const m = totalMinutes % 60;
        return m === 0 ? `${h} h` : `${h} h ${m.toString().padStart(2, "0")} min`;
    }

    function colorForGrade(gradePct: number): string {
        if (gradePct <= -5) return "#3b82f6";
        if (gradePct <= 5) return "#22c55e";
        if (gradePct <= 10) return "#eab308";
        if (gradePct <= 18) return "#f97316";
        return "#ef4444";
    }

    function interpolateElevationAt(pts: NavTrackPoint[], distM: number): number {
        if (pts.length === 0) return 0;
        if (distM <= pts[0].distanceM) return pts[0].ele;
        const last = pts[pts.length - 1];
        if (distM >= last.distanceM) return last.ele;
        for (let i = 1; i < pts.length; i++) {
            const a = pts[i - 1];
            const b = pts[i];
            if (b.distanceM >= distM) {
                const span = b.distanceM - a.distanceM;
                const t = span > 1e-6 ? (distM - a.distanceM) / span : 0;
                return a.ele + (b.ele - a.ele) * t;
            }
        }
        return last.ele;
    }

    function sliceWindow(
        pts: NavTrackPoint[],
        startM: number,
        endM: number,
    ): Array<{ distM: number; ele: number; gradePct: number }> {
        if (pts.length === 0 || endM <= startM) return [];
        const out: Array<{ distM: number; ele: number; gradePct: number }> = [];
        for (let i = 1; i < pts.length; i++) {
            const a = pts[i - 1];
            const b = pts[i];
            if (b.distanceM < startM || a.distanceM > endM) continue;
            const segLen = b.distanceM - a.distanceM;
            const cStart = Math.max(startM, a.distanceM);
            const cEnd = Math.min(endM, b.distanceM);
            if (cEnd <= cStart && segLen > 1e-6) continue;
            const t0 = segLen > 1e-6 ? (cStart - a.distanceM) / segLen : 0;
            const t1 = segLen > 1e-6 ? (cEnd - a.distanceM) / segLen : 1;
            const e0 = a.ele + (b.ele - a.ele) * t0;
            const e1 = a.ele + (b.ele - a.ele) * t1;
            if (out.length === 0) {
                out.push({ distM: cStart, ele: e0, gradePct: b.gradePct });
            }
            out.push({ distM: cEnd, ele: e1, gradePct: b.gradePct });
        }
        return out;
    }

    const totalDistanceM = $derived(
        points.length > 0 ? points[points.length - 1].distanceM : 0,
    );

    const remainingDistanceM = $derived(
        eta?.remainingDistanceM ?? Math.max(0, totalDistanceM - alongTrackMeters),
    );
    const remainingSeconds = $derived(eta?.remainingSeconds ?? null);
    const arrivalTime = $derived(eta?.arrivalTimeFormatted ?? "--:--");
    const remainingAscentM = $derived(eta?.remainingAscentM ?? 0);
    const currentEleM = $derived(
        userEle !== null && Number.isFinite(userEle)
            ? userEle
            : (eta?.currentEleM ?? interpolateElevationAt(points, alongTrackMeters)),
    );
    const currentGradePct = $derived(eta?.currentGradePct ?? 0);
    const gradeSign = $derived(currentGradePct >= 0.5 ? "+" : "");

    $effect(() => {
        if (!chartWrapEl) return;
        const el = chartWrapEl;
        const update = () => {
            const rect = el.getBoundingClientRect();
            const width = Math.max(200, Math.round(rect.width));
            const height = Math.max(96, Math.round(rect.height));
            if (width !== canvasSize.width || height !== canvasSize.height) {
                canvasSize = { width, height };
            }
        };
        update();
        if (typeof ResizeObserver !== "undefined") {
            const observer = new ResizeObserver(update);
            observer.observe(el);
            return () => observer.disconnect();
        }
    });

    $effect(() => {
        // Track reactive inputs explicitly
        const canvas = canvasEl;
        const pts = points;
        const alongM = alongTrackMeters;
        const activeReroute = reroute;
        const zoom = chartZoom;
        const { width, height } = canvasSize;
        const isDark = $theme === "dark";
        const curEle = currentEleM;

        if (!canvas || !expanded) {
            markerOverlay = { x: 0, y: 0, visible: false };
            return;
        }

        const dpr = typeof window !== "undefined" ? Math.min(window.devicePixelRatio || 1, 3) : 1;
        canvas.width = Math.round(width * dpr);
        canvas.height = Math.round(height * dpr);
        const ctx = canvas.getContext("2d");
        if (!ctx) return;

        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, width, height);

        if (pts.length < 2 || totalDistanceM <= 0) {
            markerOverlay = { x: 0, y: 0, visible: false };
            return;
        }

        let minDistM = 0;
        let maxDistM = totalDistanceM;
        if (zoom === "2km" && totalDistanceM > 2000) {
            const anchor = Math.max(0, Math.min(alongM, totalDistanceM));
            minDistM = Math.max(0, Math.min(anchor - 250, totalDistanceM - 2000));
            maxDistM = Math.min(totalDistanceM, minDistM + 2000);
            if (activeReroute && activeReroute.rejoinAlongTrackM > maxDistM - 100) {
                maxDistM = Math.min(totalDistanceM, activeReroute.rejoinAlongTrackM + 250);
            }
        }
        const distSpan = Math.max(1, maxDistM - minDistM);

        // Determine Y range over visible window + reroute points
        let minEle = Infinity;
        let maxEle = -Infinity;
        for (const p of pts) {
            if (p.distanceM >= minDistM - 50 && p.distanceM <= maxDistM + 50) {
                if (p.ele < minEle) minEle = p.ele;
                if (p.ele > maxEle) maxEle = p.ele;
            }
        }
        if (Number.isFinite(curEle)) {
            minEle = Math.min(minEle, curEle);
            maxEle = Math.max(maxEle, curEle);
        }
        if (activeReroute) {
            minEle = Math.min(minEle, activeReroute.rejoinEleM);
            maxEle = Math.max(maxEle, activeReroute.rejoinEleM);
            for (const rp of activeReroute.points) {
                minEle = Math.min(minEle, rp.ele);
                maxEle = Math.max(maxEle, rp.ele);
            }
        }
        if (!Number.isFinite(minEle) || !Number.isFinite(maxEle)) {
            minEle = 0;
            maxEle = 100;
        }
        const rawSpan = Math.max(20, maxEle - minEle);
        const yMin = minEle - rawSpan * 0.1;
        const yMax = maxEle + rawSpan * 0.14;
        const ySpan = Math.max(1, yMax - yMin);

        const padLeft = 40;
        const padRight = 10;
        const padTop = 10;
        const padBottom = 18;
        const plotW = Math.max(10, width - padLeft - padRight);
        const plotH = Math.max(10, height - padTop - padBottom);

        const toX = (d: number) => padLeft + ((d - minDistM) / distSpan) * plotW;
        const toY = (e: number) => padTop + (1 - (e - yMin) / ySpan) * plotH;

        // Horizontal gridlines & axis labels
        const gridColor = isDark ? "rgba(255,255,255,0.10)" : "rgba(15,23,42,0.08)";
        const labelColor = isDark ? "rgba(226,232,240,0.72)" : "rgba(71,85,105,0.85)";
        ctx.font = "600 10px IBMPlexSans, system-ui, sans-serif";
        ctx.lineWidth = 1;
        for (const frac of [0, 0.5, 1]) {
            const eleVal = minEle + (maxEle - minEle) * frac;
            const y = toY(eleVal);
            ctx.strokeStyle = gridColor;
            ctx.beginPath();
            ctx.moveTo(padLeft, y);
            ctx.lineTo(width - padRight, y);
            ctx.stroke();

            ctx.fillStyle = labelColor;
            ctx.textAlign = "right";
            ctx.textBaseline = "middle";
            ctx.fillText(`${Math.round(eleVal)}m`, padLeft - 5, y);
        }

        // X axis distance ticks
        ctx.textAlign = "center";
        ctx.textBaseline = "top";
        for (const frac of [0, 0.5, 1]) {
            const dVal = minDistM + distSpan * frac;
            const x = toX(dVal);
            const label =
                dVal >= 1000
                    ? `${(dVal / 1000).toFixed(1)} km`
                    : `${Math.round(dVal)} m`;
            ctx.fillStyle = labelColor;
            ctx.textAlign = frac === 0 ? "left" : frac === 1 ? "right" : "center";
            ctx.fillText(label, x, height - padBottom + 4);
        }

        // 1. Walked segment [0 .. alongTrackMeters] in muted slate (#94a3b8)
        const walkedEndM = Math.min(maxDistM, Math.max(minDistM, alongM));
        const walkedSeg = sliceWindow(pts, minDistM, walkedEndM);
        if (walkedSeg.length >= 2) {
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(toX(walkedSeg[0].distM), padTop + plotH);
            for (const p of walkedSeg) {
                ctx.lineTo(toX(p.distM), toY(p.ele));
            }
            ctx.lineTo(toX(walkedSeg[walkedSeg.length - 1].distM), padTop + plotH);
            ctx.closePath();
            ctx.fillStyle = "rgba(148, 163, 184, 0.18)";
            ctx.fill();

            ctx.beginPath();
            ctx.moveTo(toX(walkedSeg[0].distM), toY(walkedSeg[0].ele));
            for (let i = 1; i < walkedSeg.length; i++) {
                ctx.lineTo(toX(walkedSeg[i].distM), toY(walkedSeg[i].ele));
            }
            ctx.strokeStyle = "#94a3b8";
            ctx.lineWidth = 2.5;
            ctx.lineJoin = "round";
            ctx.lineCap = "round";
            ctx.stroke();
            ctx.restore();
        }

        // 2. Upcoming trail segment colored by grade
        const upcomingStartM = activeReroute
            ? Math.max(minDistM, Math.min(maxDistM, activeReroute.rejoinAlongTrackM))
            : Math.max(minDistM, Math.min(maxDistM, alongM));
        const upcomingSeg = sliceWindow(pts, upcomingStartM, maxDistM);
        if (upcomingSeg.length >= 2) {
            // Soft area fill beneath upcoming profile
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(toX(upcomingSeg[0].distM), padTop + plotH);
            for (const p of upcomingSeg) {
                ctx.lineTo(toX(p.distM), toY(p.ele));
            }
            ctx.lineTo(toX(upcomingSeg[upcomingSeg.length - 1].distM), padTop + plotH);
            ctx.closePath();
            ctx.fillStyle = isDark ? "rgba(59, 130, 246, 0.14)" : "rgba(37, 99, 235, 0.10)";
            ctx.fill();

            // Stroke each grade-colored segment
            ctx.lineWidth = 3;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            for (let i = 1; i < upcomingSeg.length; i++) {
                const a = upcomingSeg[i - 1];
                const b = upcomingSeg[i];
                ctx.strokeStyle = colorForGrade(b.gradePct);
                ctx.beginPath();
                ctx.moveTo(toX(a.distM), toY(a.ele));
                ctx.lineTo(toX(b.distM), toY(b.ele));
                ctx.stroke();
            }
            ctx.restore();
        }

        // 3. Off-trail dashed orange (#f97316) lead-in from user's elevation to rejoinEleM
        if (activeReroute) {
            const clampedAlong = Math.max(minDistM, Math.min(maxDistM, alongM));
            const clampedRejoin = Math.max(minDistM, Math.min(maxDistM, activeReroute.rejoinAlongTrackM));
            const startX = toX(clampedAlong);
            const startY = toY(curEle);
            const endX = toX(clampedRejoin);
            const endY = toY(activeReroute.rejoinEleM);

            ctx.save();
            ctx.setLineDash([6, 4]);
            ctx.strokeStyle = "#f97316";
            ctx.lineWidth = 3;
            ctx.lineCap = "round";
            ctx.lineJoin = "round";
            ctx.beginPath();
            if (
                activeReroute.points.length >= 2 &&
                Math.abs(clampedRejoin - clampedAlong) >= 5 &&
                activeReroute.distanceM > 0
            ) {
                ctx.moveTo(startX, startY);
                for (let i = 1; i < activeReroute.points.length - 1; i++) {
                    const rp = activeReroute.points[i];
                    const f = rp.distanceM / activeReroute.distanceM;
                    const d = clampedAlong + f * (clampedRejoin - clampedAlong);
                    ctx.lineTo(toX(d), toY(rp.ele));
                }
                ctx.lineTo(endX, endY);
            } else {
                ctx.moveTo(startX, startY);
                ctx.lineTo(endX, endY);
            }
            ctx.stroke();
            ctx.setLineDash([]);

            // Rejoin ring
            ctx.beginPath();
            ctx.arc(endX, endY, 4.5, 0, Math.PI * 2);
            ctx.fillStyle = "#f97316";
            ctx.fill();
            ctx.strokeStyle = "#ffffff";
            ctx.lineWidth = 1.8;
            ctx.stroke();
            ctx.restore();
        }

        // 4. "You are here" marker dot on canvas + pulsing overlay coords
        const clampedMarkerDist = Math.max(minDistM, Math.min(maxDistM, alongM));
        const mx = toX(clampedMarkerDist);
        const markerEle = activeReroute
            ? curEle
            : interpolateElevationAt(pts, clampedMarkerDist);
        const my = toY(markerEle);

        ctx.save();
        ctx.beginPath();
        ctx.arc(mx, my, 8, 0, Math.PI * 2);
        ctx.fillStyle = "rgba(37, 99, 235, 0.25)";
        ctx.fill();

        ctx.beginPath();
        ctx.arc(mx, my, 5, 0, Math.PI * 2);
        ctx.fillStyle = "#2563eb";
        ctx.fill();
        ctx.strokeStyle = "#ffffff";
        ctx.lineWidth = 2;
        ctx.stroke();
        ctx.restore();

        markerOverlay = {
            x: mx,
            y: my,
            visible: alongM >= minDistM - 5 && alongM <= maxDistM + 5,
        };
    });
</script>

<section
    data-testid="live-elevation-sheet"
    aria-label={$_("elevation-profile", { default: "Elevation profile" })}
    style="padding-bottom: env(safe-area-inset-bottom, 0px);"
    class="bg-menu-background/96 backdrop-blur-md text-content rounded-t-2xl shadow-[0_-8px_28px_rgba(0,0,0,0.22)] border-t border-input-border/60 pointer-events-auto"
>
    {#if confirmingExit}
        <div
            data-testid="nav-exit-confirm-bar"
            class="px-4 py-3 bg-red-600/10 border-b border-red-500/25 flex items-center justify-between gap-3"
        >
            <span class="text-sm font-semibold text-content">
                {$_("nav-exit-confirm", { default: "End trail navigation?" })}
            </span>
            <div class="flex items-center gap-2 shrink-0">
                <button
                    type="button"
                    onclick={() => (confirmingExit = false)}
                    class="px-3 py-1.5 rounded-full text-xs font-semibold bg-content/10 hover:bg-content/15 text-content cursor-pointer"
                >
                    {$_("cancel", { default: "Cancel" })}
                </button>
                <button
                    type="button"
                    data-testid="nav-confirm-exit-btn"
                    onclick={() => {
                        confirmingExit = false;
                        onExit?.();
                    }}
                    class="px-3.5 py-1.5 rounded-full text-xs font-semibold bg-red-600 hover:bg-red-700 text-white cursor-pointer"
                >
                    {$_("nav-exit", { default: "Exit" })}
                </button>
            </div>
        </div>
    {/if}

    <!-- Google Maps Bottom Trip Bar -->
    <div class="px-3.5 pt-2.5 pb-2.5 flex items-center justify-between gap-2">
        <div class="min-w-0 flex-1">
            <div class="flex items-baseline gap-2 flex-wrap">
                <span
                    data-testid="nav-remaining-duration"
                    class="text-xl sm:text-2xl font-extrabold tracking-tight tabular-nums text-emerald-600 dark:text-emerald-400"
                >
                    {formatDuration(remainingSeconds)}
                </span>
                <span class="text-xs font-medium text-content/65 tabular-nums">
                    {$_("nav-arrival", { default: "Arrival" })}
                    <strong data-testid="nav-arrival-time" class="text-content font-semibold">
                        {arrivalTime}
                    </strong>
                </span>
                {#if paused}
                    <span class="px-2 py-0.5 rounded-full bg-amber-500/15 text-amber-600 dark:text-amber-400 text-[11px] font-bold">
                        {$_("nav-paused", { default: "Paused" })}
                    </span>
                {/if}
            </div>
            <div
                data-testid="nav-remaining-summary"
                class="text-xs font-medium text-content/75 flex items-center gap-1.5 mt-0.5 tabular-nums"
            >
                <span data-testid="nav-remaining-distance">
                    {formatDistance(Math.max(0, Math.round(remainingDistanceM)), { compact: true })}
                </span>
                <span aria-hidden="true">·</span>
                <span data-testid="nav-remaining-climb">
                    +{formatElevation(Math.max(0, Math.round(remainingAscentM)))}
                </span>
            </div>
        </div>

        <div class="flex items-center gap-1.5 shrink-0">
            <button
                type="button"
                data-testid="nav-pause-btn"
                onclick={() => onTogglePause?.()}
                aria-label={paused
                    ? $_("nav-resume", { default: "Resume" })
                    : $_("nav-pause", { default: "Pause" })}
                title={paused
                    ? $_("nav-resume", { default: "Resume" })
                    : $_("nav-pause", { default: "Pause" })}
                class={`w-9 h-9 rounded-full flex items-center justify-center text-sm cursor-pointer transition-colors ${
                    paused
                        ? "bg-emerald-600 text-white hover:bg-emerald-700"
                        : "bg-content/[0.08] text-content hover:bg-secondary-hover"
                }`}
            >
                <i class={`fa-solid ${paused ? "fa-play" : "fa-pause"}`} aria-hidden="true"></i>
            </button>

            <button
                type="button"
                data-testid="nav-reverse-btn"
                onclick={() => onReverse?.()}
                aria-pressed={reversed}
                aria-label={$_("nav-reverse-direction", { default: "Reverse direction" })}
                title={$_("nav-reverse-direction", { default: "Reverse direction" })}
                class={`w-9 h-9 rounded-full flex items-center justify-center text-sm cursor-pointer transition-colors ${
                    reversed
                        ? "bg-blue-600 text-white hover:bg-blue-700"
                        : "bg-content/[0.08] text-content hover:bg-secondary-hover"
                }`}
            >
                <i class="fa-solid fa-right-left" aria-hidden="true"></i>
            </button>

            <button
                type="button"
                data-testid="nav-expand-chart-btn"
                aria-expanded={expanded}
                aria-label={expanded
                    ? $_("nav-collapse-chart", { default: "Hide elevation profile" })
                    : $_("nav-expand-chart", { default: "Show elevation profile" })}
                title={expanded
                    ? $_("nav-collapse-chart", { default: "Hide elevation profile" })
                    : $_("nav-expand-chart", { default: "Show elevation profile" })}
                onclick={() => (expanded = !expanded)}
                class="w-9 h-9 rounded-full bg-content/[0.08] text-content hover:bg-secondary-hover flex items-center justify-center text-sm cursor-pointer transition-colors"
            >
                <i
                    class={`fa-solid ${expanded ? "fa-chevron-down" : "fa-chevron-up"}`}
                    aria-hidden="true"
                ></i>
            </button>

            <button
                type="button"
                data-testid="nav-exit-btn"
                aria-label={$_("nav-exit", { default: "Exit" })}
                title={$_("nav-exit", { default: "Exit" })}
                onclick={() => (confirmingExit = true)}
                class="w-9 h-9 rounded-full bg-red-600 hover:bg-red-700 text-white flex items-center justify-center text-sm font-bold cursor-pointer shadow-sm transition-colors"
            >
                <i class="fa-solid fa-xmark" aria-hidden="true"></i>
            </button>
        </div>
    </div>

    {#if expanded}
        <div class="px-3.5 pb-3 pt-1.5 border-t border-input-border/40">
            <!-- Live Altitude, Grade, Next Peak & Chart Zoom Controls -->
            <div class="flex flex-wrap items-center justify-between gap-1.5 mb-2">
                <div class="flex flex-wrap items-center gap-1.5 min-w-0">
                    <span
                        data-testid="nav-live-ele-grade"
                        class="inline-flex items-center gap-1.5 rounded-full bg-blue-600/12 text-blue-700 dark:text-blue-300 px-2.5 py-0.5 text-xs font-bold tabular-nums"
                    >
                        <i class="fa-solid fa-mountain text-[10px]" aria-hidden="true"></i>
                        <span>
                            {formatElevation(Math.round(currentEleM))} · {gradeSign}{currentGradePct.toFixed(0)}%
                        </span>
                    </span>

                    {#if eta?.nextPeak}
                        <span
                            data-testid="nav-next-peak-badge"
                            class="inline-flex items-center gap-1 rounded-full bg-content/[0.07] text-content/85 px-2.5 py-0.5 text-[11px] font-semibold tabular-nums"
                        >
                            <i class="fa-solid fa-mountain-sun text-[10px]" aria-hidden="true"></i>
                            <span>
                                {$_("nav-next-peak", { default: "Next peak" })}:
                                {formatElevation(Math.round(eta.nextPeak.ele))}
                                ({formatDistance(Math.round(eta.nextPeak.distanceAheadM), { compact: true })})
                            </span>
                        </span>
                    {/if}
                </div>

                <div class="inline-flex rounded-full bg-content/[0.07] p-0.5 shrink-0">
                    <button
                        type="button"
                        data-testid="chart-zoom-2km"
                        aria-pressed={chartZoom === "2km"}
                        onclick={() => (chartZoom = "2km")}
                        class={`px-2.5 py-0.5 rounded-full text-[11px] font-semibold cursor-pointer transition-colors ${
                            chartZoom === "2km"
                                ? "bg-menu-background text-content shadow-sm"
                                : "text-content/65 hover:text-content"
                        }`}
                    >
                        {$_("nav-next-2km", { default: "Next 2 km" })}
                    </button>
                    <button
                        type="button"
                        data-testid="chart-zoom-full"
                        aria-pressed={chartZoom === "full"}
                        onclick={() => (chartZoom = "full")}
                        class={`px-2.5 py-0.5 rounded-full text-[11px] font-semibold cursor-pointer transition-colors ${
                            chartZoom === "full"
                                ? "bg-menu-background text-content shadow-sm"
                                : "text-content/65 hover:text-content"
                        }`}
                    >
                        {$_("nav-full-trail", { default: "Full trail" })}
                    </button>
                </div>
            </div>

            <!-- High-DPI Split Elevation Canvas + Pulsing Marker -->
            <div
                bind:this={chartWrapEl}
                class="relative w-full h-[120px] select-none overflow-hidden rounded-xl bg-content/[0.03]"
            >
                <canvas
                    bind:this={canvasEl}
                    data-testid="live-elevation-canvas"
                    class="block w-full h-full"
                ></canvas>

                {#if markerOverlay.visible}
                    <div
                        data-testid="elevation-you-are-here"
                        aria-label={$_("nav-you-are-here", { default: "You are here" })}
                        title={$_("nav-you-are-here", { default: "You are here" })}
                        class="pointer-events-none absolute -translate-x-1/2 -translate-y-1/2"
                        style="left: {markerOverlay.x}px; top: {markerOverlay.y}px;"
                    >
                        <span
                            class="block w-4 h-4 rounded-full bg-blue-500/40 animate-ping"
                        ></span>
                    </div>
                {/if}
            </div>
        </div>
    {/if}
</section>
