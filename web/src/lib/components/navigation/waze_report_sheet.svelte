<script lang="ts">
    import {
        REPORT_CATEGORIES,
        type TrailReportCategory,
    } from "#lib/live/live_client.ts";

    interface Props {
        open?: boolean;
        submitting?: boolean;
        onSubmit?: (payload: {
            category: TrailReportCategory;
            note: string;
        }) => Promise<void> | void;
    }

    let {
        open = $bindable(false),
        submitting = false,
        onSubmit,
    }: Props = $props();

    let selectedCategory = $state<TrailReportCategory>("bear");
    let note = $state("");

    const temporaryCategories = REPORT_CATEGORIES.filter((c) => !c.isPermanent);
    const permanentCategories = REPORT_CATEGORIES.filter((c) => c.isPermanent);

    async function handlePublish() {
        if (submitting || !selectedCategory) return;
        await onSubmit?.({
            category: selectedCategory,
            note: note.trim().slice(0, 160),
        });
        note = "";
        open = false;
    }
</script>

{#if open}
    <div
        class="fixed inset-0 z-50 flex items-end justify-center bg-black/50 backdrop-blur-[2px] p-0 sm:p-4 pointer-events-auto"
        role="dialog"
        aria-modal="true"
        aria-label="Raportează pe traseu"
        data-testid="waze-report-sheet"
    >
        <button
            type="button"
            aria-label="Închide"
            class="fixed inset-0 w-full h-full cursor-default"
            onclick={() => (open = false)}
        ></button>

        <div
            style="padding-bottom: calc(1rem + env(safe-area-inset-bottom, 0px));"
            class="relative z-10 w-full max-w-lg bg-menu-background text-content rounded-t-3xl sm:rounded-3xl shadow-2xl border border-input-border/60 px-4 pt-3 max-h-[88dvh] overflow-y-auto"
        >
            <div class="w-10 h-1 rounded-full bg-content/20 mx-auto mb-2.5"></div>

            <div class="flex items-center justify-between gap-2 mb-3">
                <div>
                    <h2 class="text-base font-extrabold tracking-tight">
                        Raportează pe potecă
                    </h2>
                    <p class="text-xs text-content/65">
                        Ajută drumeții din zonă cu alerte live sau repere permanente
                    </p>
                </div>
                <button
                    type="button"
                    aria-label="Închide"
                    onclick={() => (open = false)}
                    class="w-8 h-8 rounded-full bg-content/[0.08] hover:bg-secondary-hover flex items-center justify-center text-sm cursor-pointer shrink-0"
                >
                    <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                </button>
            </div>

            <!-- Temporary Waze Alerts -->
            <div class="mb-3.5">
                <div class="flex items-center justify-between mb-1.5">
                    <span class="text-[11px] font-bold uppercase tracking-wider text-orange-600 dark:text-orange-400">
                        Atenționări Temporare
                    </span>
                    <span class="text-[11px] text-content/55">
                        Expiră automat dacă nu sunt reconfirmate
                    </span>
                </div>

                <div class="grid grid-cols-2 gap-2">
                    {#each temporaryCategories as item (item.category)}
                        {@const isSelected = selectedCategory === item.category}
                        {@const isDeer = item.category === "deer"}
                        <button
                            type="button"
                            data-testid={`waze-cat-${item.category}`}
                            aria-pressed={isSelected}
                            onclick={() => (selectedCategory = item.category)}
                            class={`text-left rounded-2xl p-2.5 border transition-all cursor-pointer flex items-center gap-2.5 ${
                                isSelected
                                    ? isDeer
                                        ? "border-emerald-500 bg-emerald-500/15 ring-2 ring-emerald-500/40"
                                        : "border-orange-500 bg-orange-500/14 ring-2 ring-orange-500/40"
                                    : isDeer
                                      ? "border-emerald-500/35 bg-emerald-500/[0.06] hover:bg-emerald-500/12"
                                      : "border-input-border/60 bg-content/[0.03] hover:bg-content/[0.07]"
                            }`}
                        >
                            <span class="text-2xl leading-none shrink-0" aria-hidden="true">
                                {item.emoji}
                            </span>
                            <span class="min-w-0 flex-1">
                                <span
                                    class={`block text-xs font-bold leading-snug ${
                                        isDeer
                                            ? "text-emerald-700 dark:text-emerald-300"
                                            : "text-content"
                                    }`}
                                >
                                    {item.labelRo}
                                </span>
                                <span class="block text-[10.5px] text-content/60 mt-0.5">
                                    {item.ttlLabelRo}
                                </span>
                            </span>
                        </button>
                    {/each}
                </div>
            </div>

            <!-- Permanent Landmarks -->
            <div class="mb-3.5">
                <div class="flex items-center justify-between mb-1.5">
                    <span class="text-[11px] font-bold uppercase tracking-wider text-sky-600 dark:text-sky-400">
                        Repere Permanente
                    </span>
                    <span class="text-[11px] text-content/55">
                        Rămân pe hartă (cu status sezonier)
                    </span>
                </div>

                <div class="grid grid-cols-3 gap-2">
                    {#each permanentCategories as item (item.category)}
                        {@const isSelected = selectedCategory === item.category}
                        <button
                            type="button"
                            data-testid={`waze-cat-${item.category}`}
                            aria-pressed={isSelected}
                            onclick={() => (selectedCategory = item.category)}
                            class={`rounded-2xl p-2.5 border transition-all cursor-pointer flex flex-col items-center text-center gap-1 ${
                                isSelected
                                    ? "border-sky-500 bg-sky-500/15 ring-2 ring-sky-500/40"
                                    : "border-input-border/60 bg-content/[0.03] hover:bg-content/[0.07]"
                            }`}
                        >
                            <span class="text-2xl leading-none" aria-hidden="true">
                                {item.emoji}
                            </span>
                            <span class="text-xs font-bold text-content leading-tight">
                                {item.labelRo}
                            </span>
                            <span class="text-[10px] font-medium text-sky-600 dark:text-sky-400">
                                Permanent
                            </span>
                        </button>
                    {/each}
                </div>
            </div>

            <!-- Optional Note -->
            <div class="mb-4">
                <div class="flex items-center justify-between mb-1">
                    <label for="waze-report-note" class="text-xs font-semibold text-content/80">
                        Detalii scurte (opțional)
                    </label>
                    <span class="text-[11px] text-content/55 tabular-nums">
                        {note.length}/160
                    </span>
                </div>
                <input
                    id="waze-report-note"
                    data-testid="waze-report-note"
                    type="text"
                    maxlength="160"
                    bind:value={note}
                    placeholder="Ex: urs văzut lângă izvor, copac peste potecă..."
                    class="w-full rounded-xl bg-content/[0.05] border border-input-border/70 px-3 py-2 text-sm text-content placeholder:text-content/45 focus:outline-none focus:ring-2 focus:ring-orange-500/50"
                />
            </div>

            <button
                type="button"
                data-testid="waze-report-submit-btn"
                disabled={submitting}
                onclick={handlePublish}
                class="w-full py-3 rounded-2xl bg-orange-600 hover:bg-orange-700 disabled:opacity-60 text-white font-bold text-sm shadow-lg cursor-pointer transition-colors flex items-center justify-center gap-2"
            >
                <i class="fa-solid fa-paper-plane text-xs" aria-hidden="true"></i>
                <span>{submitting ? "Se trimite..." : "Publică pe hartă"}</span>
            </button>
        </div>
    </div>
{/if}
