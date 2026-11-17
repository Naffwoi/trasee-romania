<script lang="ts">
    import type { Snippet } from "svelte";
    import type { Trail } from "#lib/models/trail.ts";
    import { _ } from "svelte-i18n";
    import SkeletonCard from "../base/skeleton_card.svelte";
    import EmptyStateSearch from "../empty_states/empty_state_search.svelte";
    import TrailCard from "../trail/trail_card.svelte";
    import TrailResultLink from "../trail/trail_result_link.svelte";

    export type SheetSnap = "peek" | "half" | "full";

    interface Props {
        snap?: SheetSnap;
        trails: Trail[];
        loading: boolean;
        onSelectTrail?: (trail: Trail) => void;
        onHoverTrail?: (trail?: Trail) => void;
        moreResults?: Snippet;
    }

    let {
        snap = $bindable<SheetSnap>("peek"),
        trails,
        loading,
        onSelectTrail,
        onHoverTrail,
        moreResults,
    }: Props = $props();

    const heightClass = $derived(
        snap === "full"
            ? "h-[calc(100dvh-64px)] rounded-t-none"
            : snap === "half"
              ? "h-[48dvh] rounded-t-2xl"
              : "h-[52px] rounded-t-2xl",
    );

    function toggleSnap() {
        if (snap === "peek") snap = "half";
        else if (snap === "half") snap = "full";
        else snap = "peek";
    }

    function hrefFor(trail: Trail) {
        const author = trail.author || trail.expand?.author?.preferred_username || "romania";
        return `/map/trail/@${author}${trail.domain ? `@${trail.domain}` : ""}/${trail.id}`;
    }
</script>

<section
    class={`mobile-trails-sheet fixed bottom-16 inset-x-0 mx-auto max-w-[680px] z-30 bg-background border-t border-input-border/60 shadow-[0_-6px_24px_rgba(0,0,0,0.16)] flex flex-col transition-[height] duration-200 ease-out overflow-hidden ${heightClass}`}
    aria-label={$_("trail", { values: { n: 2 } })}
>
    <div class="shrink-0 px-4 pt-2 pb-2 flex items-center justify-between select-none">
        <button
            type="button"
            class="flex-1 flex flex-col items-center justify-center gap-1.5 cursor-pointer py-0.5"
            onclick={toggleSnap}
            aria-expanded={snap !== "peek"}
        >
            <span class="w-8 h-1 rounded-full bg-content/25 block"></span>
            <span class="text-xs font-semibold text-content/85">
                {loading
                    ? $_("trail", { values: { n: 2 } })
                    : `${trails.length} ${$_("trail", { values: { n: trails.length } })}`}
            </span>
        </button>
        {#if snap !== "peek"}
            <button
                type="button"
                class="w-7 h-7 rounded-full bg-content/[0.06] hover:bg-secondary-hover flex items-center justify-center text-xs text-content/75 cursor-pointer"
                aria-label={$_("trail-map-show-map")}
                onclick={() => (snap = "peek")}
            >
                <i class="fa fa-chevron-down" aria-hidden="true"></i>
            </button>
        {/if}
    </div>

    {#if snap !== "peek"}
        <div class="trail-results flex-1 min-h-0 overflow-y-auto px-4 pb-8 space-y-4">
            {#if loading}
                {#each { length: 4 } as _}
                    <SkeletonCard />
                {/each}
            {:else if !trails.length}
                <EmptyStateSearch />
            {:else}
                {#each trails as trail (trail.id)}
                    <TrailResultLink
                        {trail}
                        selected={false}
                        href={hrefFor(trail)}
                        onclick={(e) => {
                            if (onSelectTrail) {
                                e.preventDefault();
                                snap = "peek";
                                onSelectTrail(trail);
                            }
                        }}
                        onselect={() => {}}
                        onhover={(hovered) => onHoverTrail?.(hovered ? trail : undefined)}
                    >
                        {#snippet children(hovered)}
                            <TrailCard {trail} fullWidth={true} {hovered} selected={false} />
                        {/snippet}
                    </TrailResultLink>
                {/each}
                {#if moreResults}
                    {@render moreResults()}
                {/if}
            {/if}
        </div>
    {/if}

    {#if snap === "full"}
        <div class="pointer-events-none fixed bottom-24 inset-x-0 flex justify-center z-35">
            <button
                type="button"
                class="pointer-events-auto inline-flex items-center gap-2 rounded-full bg-primary text-white px-5 py-2.5 text-sm font-semibold shadow-lg cursor-pointer hover:opacity-95"
                onclick={() => (snap = "peek")}
            >
                <i class="fa fa-map" aria-hidden="true"></i>
                <span>{$_("map")}</span>
            </button>
        </div>
    {/if}
</section>
