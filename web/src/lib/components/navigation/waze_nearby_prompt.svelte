<script lang="ts">
    import {
        formatConfirmedAgo,
        getReportCategoryMeta,
        type ReportVoteType,
        type TrailReportDto,
    } from "#lib/live/live_client.ts";

    interface Props {
        report: TrailReportDto;
        distanceM: number;
        voting?: boolean;
        onVote?: (reportId: string, vote: ReportVoteType) => Promise<void> | void;
        onSnooze?: (reportId: string) => void;
    }

    let {
        report,
        distanceM,
        voting = false,
        onVote,
        onSnooze,
    }: Props = $props();

    const meta = $derived(getReportCategoryMeta(report.category));
    const confirmedAgo = $derived(
        formatConfirmedAgo(report.lastConfirmedAt || report.createdAt, "ro"),
    );
</script>

<div
    data-testid="waze-nearby-prompt"
    data-report-id={report.id}
    class="bg-menu-background/96 backdrop-blur-md text-content rounded-2xl shadow-xl border border-input-border/70 p-3 pointer-events-auto"
    role="region"
    aria-label={`Raport în apropiere: ${meta.labelRo}`}
>
    <div class="flex items-start justify-between gap-2.5">
        <div class="flex items-start gap-2.5 min-w-0">
            <div
                class="w-10 h-10 rounded-xl flex items-center justify-center text-xl shrink-0 border border-input-border/40"
                style={`background: ${meta.badgeBg};`}
                aria-hidden="true"
            >
                {meta.emoji}
            </div>
            <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-1.5">
                    <span class="text-sm font-extrabold text-content">
                        {meta.labelRo}
                    </span>
                    <span class="px-2 py-0.5 rounded-full bg-content/[0.08] text-[11px] font-bold tabular-nums text-content/80">
                        la {Math.max(1, Math.round(distanceM))} m
                    </span>
                </div>
                <p class="text-[11px] text-content/65 mt-0.5">
                    {confirmedAgo}
                    {#if report.conditionStatus === "dry_or_closed"}
                        · <strong class="text-amber-600 dark:text-amber-400">Secat / Indisponibil momentan</strong>
                    {/if}
                </p>
                {#if report.note}
                    <p class="text-xs text-content/85 mt-1 line-clamp-2">
                        „{report.note}”
                    </p>
                {/if}
            </div>
        </div>

        <button
            type="button"
            aria-label="Ascunde"
            onclick={() => onSnooze?.(report.id)}
            class="w-7 h-7 rounded-full bg-content/[0.06] hover:bg-secondary-hover flex items-center justify-center text-xs text-content/65 cursor-pointer shrink-0"
        >
            <i class="fa-solid fa-xmark" aria-hidden="true"></i>
        </button>
    </div>

    {#if !report.isPermanent}
        <div class="mt-2.5 pt-2 border-t border-input-border/40 flex flex-wrap items-center justify-between gap-2">
            <span class="text-xs font-bold text-content/90">
                Mai este acolo?
            </span>
            <div class="flex items-center gap-2">
                <button
                    type="button"
                    data-testid="waze-vote-confirm"
                    disabled={voting}
                    onclick={() => onVote?.(report.id, "confirm")}
                    class="px-3 py-1.5 rounded-full bg-emerald-600 hover:bg-emerald-700 disabled:opacity-60 text-white text-xs font-bold cursor-pointer transition-colors shadow-sm"
                >
                    👍 OK, mai este
                </button>
                <button
                    type="button"
                    data-testid="waze-vote-dismiss"
                    disabled={voting}
                    onclick={() => onVote?.(report.id, "dismiss")}
                    class="px-3 py-1.5 rounded-full bg-content/10 hover:bg-red-600/15 text-content hover:text-red-600 dark:hover:text-red-400 disabled:opacity-60 text-xs font-bold cursor-pointer transition-colors"
                >
                    👎 Nu mai e
                </button>
            </div>
        </div>
    {:else}
        <div class="mt-2.5 pt-2 border-t border-input-border/40 flex flex-wrap items-center justify-between gap-1.5">
            <div class="flex flex-wrap items-center gap-1.5">
                <button
                    type="button"
                    data-testid="waze-vote-seasonal-ok"
                    disabled={voting}
                    onclick={() => onVote?.(report.id, "seasonal_ok")}
                    class="px-3 py-1.5 rounded-full bg-sky-600 hover:bg-sky-700 disabled:opacity-60 text-white text-xs font-bold cursor-pointer transition-colors shadow-sm"
                >
                    {#if report.category === "spring"}
                        💧 Curge apă
                    {:else if report.category === "shelter"}
                        🛖 Refugiu deschis
                    {:else}
                        📸 Vizibil / OK
                    {/if}
                </button>
                <button
                    type="button"
                    data-testid="waze-vote-seasonal-dry"
                    disabled={voting}
                    onclick={() => onVote?.(report.id, "seasonal_dry")}
                    class="px-3 py-1.5 rounded-full bg-amber-500/15 hover:bg-amber-500/25 text-amber-700 dark:text-amber-300 disabled:opacity-60 text-xs font-bold cursor-pointer transition-colors"
                >
                    {#if report.category === "spring"}
                        ⚠️ Secat momentan
                    {:else if report.category === "shelter"}
                        ⚠️ Închis / Deteriorat
                    {:else}
                        ⚠️ Blocat momentan
                    {/if}
                </button>
            </div>

            <button
                type="button"
                data-testid="waze-vote-spam"
                disabled={voting}
                onclick={() => onVote?.(report.id, "spam")}
                class="px-2 py-1 rounded-full text-[11px] font-medium text-content/50 hover:text-red-500 cursor-pointer"
            >
                Spam
            </button>
        </div>
    {/if}
</div>
