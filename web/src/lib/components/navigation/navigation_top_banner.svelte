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
        offTrailMode?: OffTrailMode;
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
        class="max-w-md mx-auto bg-menu-background/94 backdrop-blur-md text-content rounded-2xl shadow-[0_4px_20px_rgba(0,0,0,0.12)] border border-input-border/60 pointer-events-auto overflow-hidden"
        role="region"
        aria-label={$_("nav-off-trail-title", { default: "Off trail" })}
    >
        <div class="px-3.5 py-2.5 flex items-center gap-3">
            <div
                class="w-9 h-9 rounded-xl bg-amber-500/15 text-amber-700 dark:text-amber-300 flex items-center justify-center shrink-0"
                aria-hidden="true"
            >
                <i
                    class="fa-solid fa-arrow-up text-base transition-transform duration-150"
                    style="transform: rotate({relativeTurnDeg}deg)"
                ></i>
            </div>

            <div class="flex-1 min-w-0">
                <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                    <span class="text-base font-extrabold leading-tight tracking-tight text-content tabular-nums">
                        {formattedRejoinDistance} → {$_("nav-to-trail", { default: "potecă" })}
                    </span>
                    {#if reroute.ascentM >= 1}
                        <span class="text-xs font-semibold text-amber-700 dark:text-amber-300 tabular-nums">
                            +{Math.round(reroute.ascentM)} m
                        </span>
                    {/if}
                </div>

                <p class="text-xs font-medium text-content/80 leading-snug truncate mt-0.5">
                    {reroute.instruction}
                </p>
            </div>
        </div>
    </div>
{:else}
    <div
        data-testid="nav-banner"
        data-nav-state="on-trail"
        class="max-w-md mx-auto bg-menu-background/94 backdrop-blur-md text-content rounded-2xl shadow-[0_4px_20px_rgba(0,0,0,0.12)] border border-input-border/60 pointer-events-auto overflow-hidden"
        role="region"
        aria-label={currentManeuver?.instruction || trailName || "Navigation"}
    >
        <div class="px-3.5 py-2.5 flex items-center gap-3">
            <div
                class="w-9 h-9 rounded-xl bg-[#242734] text-white flex items-center justify-center shrink-0"
                aria-hidden="true"
            >
                <i
                    class={`fa-solid ${primaryVisual.icon} text-base transition-transform duration-150`}
                    style={primaryVisual.rotateDeg
                        ? `transform: rotate(${primaryVisual.rotateDeg}deg)`
                        : undefined}
                ></i>
            </div>

            <div class="flex-1 min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                    {#if formattedManeuverDistance !== null}
                        <span class="text-base font-extrabold leading-tight tracking-tight text-content tabular-nums">
                            {$_("nav-in-distance", {
                                values: { distance: formattedManeuverDistance },
                                default: `in ${formattedManeuverDistance}`,
                            })}
                        </span>
                    {/if}
                    {#if justRejoined}
                        <span
                            data-testid="nav-rejoined-badge"
                            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-emerald-500/15 text-emerald-700 dark:text-emerald-300 text-[11px] font-bold"
                        >
                            <i class="fa-solid fa-circle-check text-[10px]" aria-hidden="true"></i>
                            <span>{$_("nav-off-trail-rejoined", { default: "Back on trail" })}</span>
                        </span>
                    {:else if waitingForGps}
                        <span
                            data-testid="nav-waiting-gps-badge"
                            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-content/[0.08] text-content/70 text-[11px] font-medium animate-pulse"
                        >
                            {$_("nav-waiting-gps", { default: "Waiting for GPS…" })}
                        </span>
                    {/if}
                </div>
                <p class="text-xs font-semibold text-content/85 leading-snug line-clamp-1 mt-0.5">
                    {currentManeuver?.instruction || trailName}
                </p>
            </div>
        </div>

        {#if nextManeuver}
            <div
                class="bg-content/[0.04] px-3.5 py-1.5 flex items-center gap-2 text-xs text-content/75 border-t border-input-border/40"
            >
                <span class="opacity-75 shrink-0">{$_("nav-then", { default: "Then" })}</span>
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
