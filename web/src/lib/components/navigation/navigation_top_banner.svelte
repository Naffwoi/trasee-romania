<script lang="ts">
    import {
        normalizeBearingDelta,
        type NavManeuver,
        type OffTrailMode,
        type OffTrailRerouteResult,
    } from "#lib/navigation/index.ts";
    import { formatDistance } from "#lib/util/format_util.ts";
    import { _ } from "svelte-i18n";

    interface Props {
        reroute: OffTrailRerouteResult | null;
        offTrailMode: OffTrailMode;
        onModeChange?: (mode: OffTrailMode) => void;
        currentManeuver: NavManeuver | null;
        nextManeuver: NavManeuver | null;
        distanceToManeuverM: number | null;
        deviceHeading: number | null;
        waitingForGps?: boolean;
        justRejoined?: boolean;
        trailName?: string;
    }

    let {
        reroute,
        offTrailMode,
        onModeChange,
        currentManeuver,
        nextManeuver,
        distanceToManeuverM,
        deviceHeading,
        waitingForGps = false,
        justRejoined = false,
        trailName = "",
    }: Props = $props();

    function maneuverVisual(m: NavManeuver | null): { icon: string; rotateDeg: number } {
        if (!m) return { icon: "fa-arrow-up", rotateDeg: 0 };
        switch (m.type) {
            case 4:
                return { icon: "fa-flag-checkered", rotateDeg: 0 };
            case 9:
                return { icon: "fa-arrow-up", rotateDeg: 45 };
            case 10:
                return { icon: "fa-arrow-right", rotateDeg: 0 };
            case 11:
                return { icon: "fa-arrow-up", rotateDeg: 135 };
            case 14:
                return { icon: "fa-arrow-up", rotateDeg: -135 };
            case 15:
                return { icon: "fa-arrow-left", rotateDeg: 0 };
            case 16:
                return { icon: "fa-arrow-up", rotateDeg: -45 };
            case 8: {
                const lower = m.instruction.toLowerCase();
                if (
                    lower.includes("vârf") ||
                    lower.includes("varf") ||
                    lower.includes("peak") ||
                    lower.includes("summit") ||
                    lower.includes("climb") ||
                    lower.includes("urc") ||
                    lower.includes("cobor") ||
                    lower.includes("descent") ||
                    lower.includes("pant") ||
                    lower.includes("grade")
                ) {
                    return { icon: "fa-mountain", rotateDeg: 0 };
                }
                return { icon: "fa-arrow-up", rotateDeg: 0 };
            }
            case 1:
            default:
                return { icon: "fa-arrow-up", rotateDeg: 0 };
        }
    }

    const relativeTurnDeg = $derived(
        reroute
            ? normalizeBearingDelta(deviceHeading ?? 0, reroute.initialBearingDeg)
            : 0,
    );

    const primaryVisual = $derived(maneuverVisual(currentManeuver));
    const secondaryVisual = $derived(maneuverVisual(nextManeuver));

    const formattedManeuverDistance = $derived(
        distanceToManeuverM !== null && Number.isFinite(distanceToManeuverM)
            ? formatDistance(Math.max(0, Math.round(distanceToManeuverM)), { compact: true })
            : null,
    );

    const formattedRejoinDistance = $derived(
        reroute
            ? formatDistance(Math.max(0, Math.round(reroute.distanceM)), { compact: true })
            : null,
    );
</script>

{#if reroute !== null}
    <div
        data-testid="nav-banner"
        data-nav-state="off-trail"
        class="bg-orange-600 text-white rounded-2xl shadow-xl p-3.5 sm:p-4 pointer-events-auto border border-orange-400/40"
        role="region"
        aria-label={$_("nav-off-trail-title", { default: "Off trail" })}
    >
        <div class="flex items-start gap-3">
            <div
                class="w-12 h-12 rounded-xl bg-white/15 flex items-center justify-center shrink-0 mt-0.5"
                aria-hidden="true"
            >
                <i
                    class="fa-solid fa-arrow-up text-2xl transition-transform duration-150"
                    style="transform: rotate({relativeTurnDeg}deg)"
                ></i>
            </div>

            <div class="flex-1 min-w-0">
                <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                    <span
                        class="inline-flex items-center gap-1 text-[11px] font-bold uppercase tracking-wider bg-black/20 px-2 py-0.5 rounded-full"
                    >
                        <i class="fa-solid fa-triangle-exclamation text-[10px]" aria-hidden="true"></i>
                        <span>{$_("nav-off-trail-title", { default: "Off trail" })}</span>
                    </span>
                    <span class="text-lg font-extrabold tracking-tight tabular-nums">
                        {formattedRejoinDistance} → {$_("nav-to-trail", { default: "potecă" })}
                    </span>
                    {#if reroute.ascentM >= 1}
                        <span class="text-xs font-semibold text-orange-100 tabular-nums">
                            +{Math.round(reroute.ascentM)} m
                        </span>
                    {/if}
                </div>

                <p class="text-sm font-semibold leading-snug mt-1">
                    {reroute.instruction}
                </p>
                {#if reroute.slopeAdvice}
                    <p class="text-xs text-orange-50/95 leading-snug mt-0.5">
                        {reroute.slopeAdvice}
                    </p>
                {/if}
            </div>
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-2">
            <button
                type="button"
                data-testid="offtrail-mode-min-climb"
                aria-pressed={offTrailMode === "min-climb"}
                onclick={() => onModeChange?.("min-climb")}
                class={`px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer ${
                    offTrailMode === "min-climb"
                        ? "bg-white text-orange-700 shadow-sm"
                        : "bg-orange-700/75 text-white hover:bg-orange-700 border border-white/25"
                }`}
            >
                {$_("nav-min-climb", { default: "Min climb" })}
            </button>
            <button
                type="button"
                data-testid="offtrail-mode-shortest-safe"
                aria-pressed={offTrailMode === "shortest-safe"}
                onclick={() => onModeChange?.("shortest-safe")}
                class={`px-3 py-1 rounded-full text-xs font-semibold transition-colors cursor-pointer ${
                    offTrailMode === "shortest-safe"
                        ? "bg-white text-orange-700 shadow-sm"
                        : "bg-orange-700/75 text-white hover:bg-orange-700 border border-white/25"
                }`}
            >
                {$_("nav-shortest-path", { default: "Shortest path" })}
            </button>
        </div>
    </div>
{:else}
    <div
        data-testid="nav-banner"
        data-nav-state="on-trail"
        class="bg-emerald-700 text-white rounded-2xl shadow-xl overflow-hidden pointer-events-auto border border-emerald-500/30"
        role="region"
        aria-label={currentManeuver?.instruction || trailName || "Navigation"}
    >
        <div class="px-4 py-3 flex items-center gap-3.5">
            <div
                class="w-11 h-11 rounded-xl bg-white/15 flex items-center justify-center shrink-0"
                aria-hidden="true"
            >
                <i
                    class={`fa-solid ${primaryVisual.icon} text-2xl transition-transform duration-150`}
                    style={primaryVisual.rotateDeg
                        ? `transform: rotate(${primaryVisual.rotateDeg}deg)`
                        : undefined}
                ></i>
            </div>

            <div class="flex-1 min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                    {#if formattedManeuverDistance !== null}
                        <span class="text-xl font-extrabold leading-tight tracking-tight tabular-nums">
                            {$_("nav-in-distance", {
                                values: { distance: formattedManeuverDistance },
                                default: `in ${formattedManeuverDistance}`,
                            })}
                        </span>
                    {/if}
                    {#if justRejoined}
                        <span
                            data-testid="nav-rejoined-badge"
                            class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-white text-emerald-800 text-[11px] font-bold"
                        >
                            <i class="fa-solid fa-circle-check text-[10px]" aria-hidden="true"></i>
                            <span>{$_("nav-off-trail-rejoined", { default: "Back on trail" })}</span>
                        </span>
                    {:else if waitingForGps}
                        <span
                            data-testid="nav-waiting-gps-badge"
                            class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-white/15 text-emerald-50 text-[11px] font-medium animate-pulse"
                        >
                            {$_("nav-waiting-gps", { default: "Waiting for GPS…" })}
                        </span>
                    {/if}
                </div>
                <p class="text-sm font-semibold text-white/95 leading-snug line-clamp-2 mt-0.5">
                    {currentManeuver?.instruction || trailName}
                </p>
            </div>
        </div>

        {#if nextManeuver}
            <div
                class="bg-emerald-800/95 px-4 py-2 flex items-center gap-2 text-xs text-emerald-50 border-t border-white/10"
            >
                <span class="opacity-80 shrink-0">{$_("nav-then", { default: "Then" })}</span>
                <i
                    class={`fa-solid ${secondaryVisual.icon} text-[11px] shrink-0`}
                    style={secondaryVisual.rotateDeg
                        ? `transform: rotate(${secondaryVisual.rotateDeg}deg)`
                        : undefined}
                    aria-hidden="true"
                ></i>
                <span class="font-medium truncate">{nextManeuver.instruction}</span>
            </div>
        {/if}
    </div>
{/if}
