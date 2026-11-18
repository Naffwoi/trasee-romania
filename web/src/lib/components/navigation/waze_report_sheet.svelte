<script lang="ts">
    import {
        REPORT_CATEGORIES,
        type TrailReportCategory,
    } from "#lib/live/live_client.ts";
    import { verifyAndStripReportPhoto } from "#lib/live/exif_photo_verifier.ts";

    interface Props {
        open?: boolean;
        submitting?: boolean;
        userLat?: number | null;
        userLon?: number | null;
        onSubmit?: (payload: {
            category: TrailReportCategory;
            note: string;
            photoBlob?: Blob | null;
            photoFilename?: string;
            photoVerified?: boolean;
        }) => Promise<void> | void;
    }

    let {
        open = $bindable(false),
        submitting = false,
        userLat = null,
        userLon = null,
        onSubmit,
    }: Props = $props();

    let note = $state("");
    let photoBlob = $state<Blob | null>(null);
    let photoFilename = $state("report.jpg");
    let photoVerified = $state(false);
    let photoProcessing = $state(false);
    let photoInputEl: HTMLInputElement | undefined = $state();

    async function handlePhotoSelected(ev: Event) {
        const input = ev.currentTarget as HTMLInputElement;
        const file = input.files?.[0];
        if (!file) return;
        photoProcessing = true;
        try {
            const res = await verifyAndStripReportPhoto(file, {
                lat: userLat ?? 0,
                lon: userLon ?? 0,
            });
            photoBlob = res.strippedBlob;
            photoFilename = res.filename;
            photoVerified = res.photoVerified;
        } catch {
            photoBlob = null;
            photoVerified = false;
        } finally {
            photoProcessing = false;
            input.value = "";
        }
    }

    const SHORT_LABELS_RO: Record<TrailReportCategory, string> = {
        bear: "Urs",
        shepherd_dogs: "Câini",
        fallen_tree_terrain: "Obstacol",
        ice_mud: "Gheață / Noroi",
        deer: "Faună",
        spring: "Izvor",
        viewpoint: "Belvedere",
        shelter: "Adăpost",
    };

    async function handleQuickSelect(category: TrailReportCategory) {
        if (submitting || photoProcessing) return;
        const cleanNote = note.trim().slice(0, 160);
        const outBlob = photoBlob;
        const outName = photoFilename;
        const outVerified = photoVerified;
        note = "";
        photoBlob = null;
        photoVerified = false;
        open = false;
        await onSubmit?.({
            category,
            note: cleanNote,
            photoBlob: outBlob,
            photoFilename: outName,
            photoVerified: outVerified,
        });
    }
</script>

{#if open}
    <div
        class="fixed inset-0 z-50 flex items-end justify-center bg-black/45 backdrop-blur-[2px] p-0 sm:p-4 pointer-events-auto"
        role="dialog"
        aria-modal="true"
        aria-label="Raportează"
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
            class="relative z-10 w-full max-w-md bg-menu-background text-content rounded-t-3xl sm:rounded-3xl shadow-2xl border border-input-border/60 px-4 pt-3"
        >
            <div class="w-10 h-1 rounded-full bg-content/20 mx-auto mb-2.5"></div>

            <div class="flex items-center justify-between gap-2 mb-3">
                <h2 class="text-sm font-extrabold tracking-tight">
                    Ce ai observat?
                </h2>
                <button
                    type="button"
                    aria-label="Închide"
                    onclick={() => (open = false)}
                    class="w-7 h-7 rounded-full bg-content/[0.08] hover:bg-secondary-hover flex items-center justify-center text-xs cursor-pointer shrink-0"
                >
                    <i class="fa-solid fa-xmark" aria-hidden="true"></i>
                </button>
            </div>

            <div class="grid grid-cols-4 gap-2 mb-3">
                {#each REPORT_CATEGORIES as item (item.category)}
                    {@const isDeer = item.category === "deer"}
                    <button
                        type="button"
                        disabled={submitting}
                        data-testid={`waze-cat-${item.category}`}
                        onclick={() => handleQuickSelect(item.category)}
                        class={`rounded-2xl py-3 px-1.5 border transition-transform active:scale-95 cursor-pointer flex flex-col items-center justify-center text-center gap-1.5 disabled:opacity-50 ${
                            isDeer
                                ? "border-emerald-500/35 bg-emerald-500/[0.07] hover:bg-emerald-500/15"
                                : "border-input-border/60 bg-content/[0.04] hover:bg-content/[0.09]"
                        }`}
                    >
                        <span class="text-2xl leading-none" aria-hidden="true">
                            {item.emoji}
                        </span>
                        <span class="text-[11px] font-bold text-content leading-tight">
                            {SHORT_LABELS_RO[item.category] ?? item.labelRo}
                        </span>
                    </button>
                {/each}
            </div>

            <input
                id="waze-report-note"
                data-testid="waze-report-note"
                type="text"
                maxlength="160"
                bind:value={note}
                placeholder="Notă scurtă opțională (înainte să apeși iconul)..."
                class="w-full rounded-xl bg-content/[0.05] border border-input-border/60 px-3 py-2 text-xs text-content placeholder:text-content/45 focus:outline-none focus:ring-2 focus:ring-orange-500/40"
            />

            <div class="mt-2 flex items-center justify-between gap-2">
                <input
                    bind:this={photoInputEl}
                    type="file"
                    accept="image/*"
                    class="hidden"
                    onchange={handlePhotoSelected}
                />
                <button
                    type="button"
                    data-testid="waze-attach-photo-btn"
                    disabled={photoProcessing || submitting}
                    onclick={() => photoInputEl?.click()}
                    class="px-3 py-1.5 rounded-xl bg-content/[0.06] hover:bg-content/[0.11] border border-input-border/60 text-xs font-semibold text-content cursor-pointer flex items-center gap-1.5"
                >
                    <i class="fa-solid fa-camera text-xs" aria-hidden="true"></i>
                    <span>{photoProcessing ? "Se curăță EXIF..." : photoBlob ? "Schimbă foto" : "Adaugă foto (fără date personale)"}</span>
                </button>
                {#if photoBlob}
                    <span
                        data-testid="waze-photo-ready-chip"
                        class={`px-2 py-1 rounded-full text-[11px] font-bold ${
                            photoVerified
                                ? "bg-emerald-500/12 text-emerald-700 dark:text-emerald-300"
                                : "bg-content/[0.08] text-content/75"
                        }`}
                    >
                        {photoVerified ? "✓ Foto verificată la fața locului" : "✓ EXIF eliminat"}
                    </span>
                {/if}
            </div>
        </div>
    </div>
{/if}
