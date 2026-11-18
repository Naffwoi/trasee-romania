<script lang="ts">
    import {
        SOS_REASON_META,
        type SosAlertDto,
        type SosReason,
    } from "#lib/live/live_client.ts";
    import { haversineMeters } from "#lib/navigation/index.ts";
    import type { DirectRescueRouteResult } from "#lib/navigation/off_trail_router.ts";
    import { formatDistance } from "#lib/util/format_util.ts";

    interface Props {
        modalOpen?: boolean;
        myActiveSos: SosAlertDto | null;
        nearbySos: SosAlertDto | null;
        userLat?: number | null;
        userLon?: number | null;
        userEle?: number | null;
        activeRescueRoute?: DirectRescueRouteResult | null;
        activeRescueSosId?: string | null;
        submitting?: boolean;
        onTriggerSos?: (payload: {
            reason: SosReason;
            message: string;
            requesterName: string;
        }) => Promise<void> | void;
        onResolveMySos?: () => Promise<void> | void;
        onRespondSos?: (sos: SosAlertDto) => Promise<void> | void;
        onCancelRespondSos?: (sos: SosAlertDto) => Promise<void> | void;
    }

    let {
        modalOpen = $bindable(false),
        myActiveSos,
        nearbySos,
        userLat = null,
        userLon = null,
        userEle = null,
        activeRescueRoute = null,
        activeRescueSosId = null,
        submitting = false,
        onTriggerSos,
        onResolveMySos,
        onRespondSos,
        onCancelRespondSos,
    }: Props = $props();

    let selectedReason = $state<SosReason>("lost");
    let message = $state("");

    const reasons: SosReason[] = ["lost", "injury", "exhaustion", "other"];
    const SHORT_REASON_RO: Record<SosReason, string> = {
        lost: "Rătăcit",
        injury: "Accidentare",
        exhaustion: "Epuizat",
        other: "Altul",
    };

    const mySosStatusText = $derived.by(() => {
        if (!myActiveSos) return "";
        const count = myActiveSos.responderCount;
        if (count <= 0) {
            return "SOS Activ · Alertă trimisă în zonă";
        }
        const peopleLabel =
            count === 1 ? "1 persoană vine spre tine" : `${count} persoane vin spre tine`;
        if (
            myActiveSos.nearestDistanceM !== null &&
            myActiveSos.nearestDistanceM > 0
        ) {
            const distLabel = formatDistance(Math.round(myActiveSos.nearestDistanceM), {
                compact: true,
            });
            const etaMin = Math.max(
                1,
                Math.round((myActiveSos.nearestEtaSec ?? 60) / 60),
            );
            return `SOS Activ · ${peopleLabel} · cel mai aproape la ${distLabel} (~${etaMin} min)`;
        }
        return `SOS Activ · ${peopleLabel}`;
    });

    const nearbyMetrics = $derived.by(() => {
        if (!nearbySos) {
            return { distM: null as number | null, climbM: 0, etaMin: null as number | null };
        }
        if (activeRescueRoute && activeRescueSosId === nearbySos.id) {
            return {
                distM: activeRescueRoute.distanceM,
                climbM: Math.max(0, Math.round(activeRescueRoute.ascentM)),
                etaMin: Math.max(1, Math.round(activeRescueRoute.estimatedSeconds / 60)),
            };
        }
        const distM =
            userLat !== null &&
            userLon !== null &&
            Number.isFinite(userLat) &&
            Number.isFinite(userLon)
                ? haversineMeters(userLat, userLon, nearbySos.lat, nearbySos.lon)
                : null;
        const climbM =
            userEle !== null && Number.isFinite(userEle) && Number.isFinite(nearbySos.ele)
                ? Math.max(0, Math.round(nearbySos.ele - userEle))
                : 0;
        return { distM, climbM, etaMin: null };
    });

    const isRespondingToNearby = $derived(
        Boolean(
            nearbySos &&
                (nearbySos.amResponding || activeRescueSosId === nearbySos.id),
        ),
    );

    async function handleSendSos() {
        if (submitting) return;
        await onTriggerSos?.({
            reason: selectedReason,
            message: message.trim().slice(0, 200),
            requesterName: "",
        });
        message = "";
        modalOpen = false;
    }
</script>

{#if myActiveSos}
    <div
        data-testid="my-active-sos-bar"
        class="bg-red-700 text-white rounded-2xl shadow-xl p-3 border border-red-400/50 pointer-events-auto"
        role="status"
    >
        <div class="flex items-center justify-between gap-2.5 flex-wrap">
            <div class="min-w-0 flex-1">
                <p class="text-xs font-extrabold leading-snug">
                    {mySosStatusText}
                </p>
                <div class="mt-0.5 flex items-center gap-2 text-[11px] text-red-100">
                    <a href="tel:112" class="underline font-bold text-white">112</a>
                    <span>·</span>
                    <a href="tel:0725826668" class="underline font-bold text-white">Salvamont</a>
                </div>
            </div>
            <button
                type="button"
                data-testid="sos-resolve-btn"
                disabled={submitting}
                onclick={() => onResolveMySos?.()}
                class="px-3 py-1.5 rounded-full bg-white text-red-700 hover:bg-red-50 font-extrabold text-xs cursor-pointer shadow-sm shrink-0"
            >
                Oprește SOS
            </button>
        </div>
    </div>
{/if}

{#if nearbySos && !nearbySos.isMine}
    {@const rMeta = SOS_REASON_META[nearbySos.reason] ?? SOS_REASON_META.other}
    <div
        data-testid="sos-rescue-banner"
        data-sos-id={nearbySos.id}
        class="bg-red-600 text-white rounded-2xl shadow-2xl p-3 border-2 border-white/40 pointer-events-auto"
        role="alert"
    >
        <div class="flex flex-wrap items-center gap-1.5">
            <span class="px-2 py-0.5 rounded-full bg-black/25 text-[11px] font-extrabold uppercase">
                🆘 SOS în apropiere
            </span>
            <span class="text-xs font-extrabold">
                {rMeta.emoji} {rMeta.labelRo}
            </span>
        </div>

        <div class="mt-1 flex flex-wrap items-center gap-2 text-xs font-bold tabular-nums text-white/95">
            {#if nearbyMetrics.distM !== null}
                <span>📍 {formatDistance(Math.round(nearbyMetrics.distM), { compact: true })}</span>
            {/if}
            <span>⛰️ +{nearbyMetrics.climbM}m</span>
            {#if nearbyMetrics.etaMin !== null}
                <span>⏱️ ~{nearbyMetrics.etaMin} min</span>
            {/if}
        </div>

        {#if nearbySos.message}
            <p class="mt-1 text-xs text-red-50 bg-black/15 rounded-lg px-2.5 py-1 line-clamp-2">
                „{nearbySos.message}”
            </p>
        {/if}

        <div class="mt-2 flex flex-wrap items-center gap-2">
            {#if !isRespondingToNearby}
                <button
                    type="button"
                    data-testid="sos-respond-btn"
                    disabled={submitting}
                    onclick={() => onRespondSos?.(nearbySos)}
                    class="flex-1 py-2 px-4 rounded-full bg-white text-red-700 hover:bg-red-50 font-extrabold text-xs shadow-md cursor-pointer text-center"
                >
                    Pot să vin să ajut
                </button>
            {:else}
                <span class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-emerald-500 text-white text-xs font-extrabold shadow-sm">
                    <i class="fa-solid fa-route" aria-hidden="true"></i>
                    <span>Rută DEM activă spre victimă</span>
                </span>
                <button
                    type="button"
                    data-testid="sos-cancel-respond-btn"
                    disabled={submitting}
                    onclick={() => onCancelRespondSos?.(nearbySos)}
                    class="px-3 py-1.5 rounded-full bg-black/25 hover:bg-black/35 text-white text-xs font-semibold cursor-pointer"
                >
                    Oprește
                </button>
            {/if}
        </div>
    </div>
{/if}

{#if modalOpen}
    <div
        data-testid="sos-modal"
        class="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/55 backdrop-blur-xs p-0 sm:p-4 pointer-events-auto"
        role="dialog"
        aria-modal="true"
        aria-label="SOS"
    >
        <button
            type="button"
            aria-label="Închide"
            class="fixed inset-0 w-full h-full cursor-default"
            onclick={() => (modalOpen = false)}
        ></button>

        <div
            style="padding-bottom: calc(1rem + env(safe-area-inset-bottom, 0px));"
            class="relative z-10 w-full max-w-sm bg-menu-background text-content rounded-t-3xl sm:rounded-3xl shadow-2xl border border-red-500/40 px-4 pt-3"
        >
            <div class="w-10 h-1 rounded-full bg-content/20 mx-auto mb-2.5"></div>

            <div class="flex items-center justify-between gap-2 mb-3">
                <h2 class="text-sm font-extrabold text-red-600 dark:text-red-400">
                    SOS Urgență
                </h2>
                <button
                    type="button"
                    aria-label="Închide"
                    onclick={() => (modalOpen = false)}
                    class="w-7 h-7 rounded-full bg-content/[0.08] hover:bg-secondary-hover flex items-center justify-center text-xs cursor-pointer"
                >
                    <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                </button>
            </div>

            <div class="grid grid-cols-2 gap-2 mb-3">
                <a
                    href="tel:112"
                    data-testid="sos-call-112"
                    class="py-2.5 px-3 rounded-xl bg-red-600 hover:bg-red-700 text-white font-extrabold text-xs flex items-center justify-center gap-1.5 shadow-sm"
                >
                    <i class="fa-solid fa-phone" aria-hidden="true"></i>
                    <span>112</span>
                </a>
                <a
                    href="tel:0725826668"
                    data-testid="sos-call-salvamont"
                    class="py-2.5 px-3 rounded-xl bg-slate-900 hover:bg-slate-800 text-white font-extrabold text-xs flex items-center justify-center gap-1.5 shadow-sm"
                >
                    <i class="fa-solid fa-mountain" aria-hidden="true"></i>
                    <span>Salvamont</span>
                </a>
            </div>

            <div class="grid grid-cols-4 gap-1.5 mb-2.5">
                {#each reasons as r (r)}
                    {@const meta = SOS_REASON_META[r]}
                    {@const active = selectedReason === r}
                    <button
                        type="button"
                        data-testid={`sos-reason-${r}`}
                        aria-pressed={active}
                        onclick={() => (selectedReason = r)}
                        class={`rounded-xl py-2 px-1 border flex flex-col items-center gap-1 cursor-pointer transition-all ${
                            active
                                ? "border-red-600 bg-red-600/15 ring-2 ring-red-500/40"
                                : "border-input-border/60 bg-content/[0.03] hover:bg-content/[0.07]"
                        }`}
                    >
                        <span class="text-lg leading-none" aria-hidden="true">
                            {meta.emoji}
                        </span>
                        <span class="text-[11px] font-bold text-content leading-tight">
                            {SHORT_REASON_RO[r]}
                        </span>
                    </button>
                {/each}
            </div>

            <input
                type="text"
                maxlength="200"
                data-testid="sos-message-input"
                bind:value={message}
                placeholder="Detalii scurte (opțional)..."
                class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2 text-xs text-content placeholder:text-content/45 focus:outline-none focus:ring-2 focus:ring-red-500/40 mb-3"
            />

            <button
                type="button"
                data-testid="sos-submit-btn"
                disabled={submitting}
                onclick={handleSendSos}
                class="w-full py-2.5 px-4 rounded-2xl bg-red-600 hover:bg-red-700 disabled:opacity-60 text-white font-extrabold text-xs shadow-lg cursor-pointer transition-colors"
            >
                {submitting ? "Se trimite..." : "Trimite SOS în zonă"}
            </button>
        </div>
    </div>
{/if}
