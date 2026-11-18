<script lang="ts">
    import type { StyleSwitcherControlOptions } from "#lib/vendor/maplibre-style-switcher/style-switcher-control.ts";
    import { _ } from "svelte-i18n";
    import RadioGroup, { type RadioItem } from "../base/radio_group.svelte";
    import { defaultMapState, type OverlayName } from "#lib/vendor/maplibre-layer-manager/layers.ts";
    import { onDestroy, onMount, untrack } from "svelte";

    interface Props {
        settings: StyleSwitcherControlOptions;
    }

    let { settings }: Props = $props();

    let mapState = $state(untrack(() => settings.state));

    const recentSatelliteDates: string[] = Array.from({ length: 7 }, (_, idx) => {
        const d = new Date(Date.now() - (idx + 1) * 86_400_000);
        return d.toISOString().slice(0, 10);
    });

    let container: HTMLDivElement;

    let styleItems: RadioItem[] = $derived(
        Object.entries(settings.styles).map<RadioItem>(([name, style]) => ({
            text: name,
            value: style,
        })),
    );

    let selectedStyle: number = $derived(
        Math.max(
            0,
            styleItems.findIndex((i) => i.text === mapState.base),
        ),
    );

    let showSwitcher: boolean = $state(false);

    function toggleSwitcher(e: MouseEvent) {
        e.stopPropagation();
        showSwitcher = !showSwitcher;
    }

    function hideSwitcher() {
        showSwitcher = false;
    }

    function handlePointerDownOutside(e: PointerEvent) {
        if (!showSwitcher || !container) return;
        const target = e.target as Node | null;
        if (target && !container.contains(target)) {
            showSwitcher = false;
        }
    }

    function handleKeydown(e: KeyboardEvent) {
        if (showSwitcher && e.key === "Escape") {
            showSwitcher = false;
        }
    }

    onMount(() => {
        if (typeof window !== "undefined") {
            window.addEventListener("pointerdown", handlePointerDownOutside, true);
            window.addEventListener("keydown", handleKeydown);
        }
    });

    onDestroy(() => {
        if (typeof window !== "undefined") {
            window.removeEventListener("pointerdown", handlePointerDownOutside, true);
            window.removeEventListener("keydown", handleKeydown);
        }
    });

    export function getElement() {
        return container;
    }
</script>

<div
    bind:this={container}
    style="overflow: visible !important;"
    class="maplibregl-ctrl maplibregl-ctrl-group wanderer-style-switcher relative z-30"
>
    <button
        type="button"
        data-testid="style-switcher-btn"
        aria-expanded={showSwitcher}
        onclick={toggleSwitcher}
        aria-label={$_("toggle-style-switcher")}
        title={$_("toggle-style-switcher")}
    >
        <i class="fa fa-layer-group text-content" aria-hidden="true"></i>
    </button>

    <div
        data-testid="style-switcher-menu"
        class="absolute right-0 top-full bg-menu-background/94 backdrop-blur-md text-content rounded-2xl px-4 py-3 mt-2 shadow-[0_4px_20px_rgba(0,0,0,0.10)] border border-input-border/60 space-y-3 max-h-96 overflow-y-auto min-w-56 z-50"
        class:hidden={!showSwitcher}
    >
        <div class="flex items-center justify-between gap-2">
            <span class="font-semibold whitespace-nowrap text-sm"
                >{$_("map-style")}</span
            >
            <button
                type="button"
                class="fa fa-close !w-7 !h-7 !rounded-full flex items-center justify-center hover:bg-secondary-hover text-content/75 cursor-pointer"
                onclick={hideSwitcher}
                aria-label={$_("close-style-switcher")}
            ></button>
        </div>
        <RadioGroup
            name="completed"
            items={styleItems}
            selected={selectedStyle}
            onchange={(style) => {
                mapState.base = style.text;
                settings.onchange(mapState);
            }}
        ></RadioGroup>
        <hr class="border-input-border" />
        <span class="font-semibold whitespace-nowrap text-sm block"
            >{$_("layer", { values: { n: 2 } })}</span
        >
        {#each Object.keys(defaultMapState.overlays) as overlay}
            {@const ovKey = overlay as OverlayName}
            <div class="flex items-center mt-1.5 mb-2.5">
                <input
                    id="{overlay}-layer-checkbox"
                    type="checkbox"
                    bind:checked={mapState.overlays[ovKey]}
                    class="w-4 h-4 bg-input-background accent-primary border-input-border focus:ring-input-ring focus:ring-2"
                    onchange={() => {
                        settings.onchange(mapState);
                    }}
                />

                <label for="{overlay}-layer-checkbox" class="ms-2 text-sm cursor-pointer"
                    >{$_(overlay)}</label
                >
            </div>
        {/each}
        {#if mapState.overlays.snowCover || mapState.overlays.dailySatellite}
            <div class="pt-1 pb-2 space-y-1">
                <label for="satellite-pass-date" class="block text-xs font-medium text-content/75">
                    {$_("satellite-pass-date")}
                </label>
                <select
                    id="satellite-pass-date"
                    data-testid="satellite-pass-date-select"
                    class="w-full rounded-lg border border-input-border bg-input-background px-2 py-1 text-xs text-content"
                    value={mapState.satelliteDate ?? "default"}
                    onchange={(e) => {
                        mapState.satelliteDate = (e.currentTarget as HTMLSelectElement).value;
                        settings.onchange(mapState);
                    }}
                >
                    <option value="default">{$_("satellite-latest-pass")}</option>
                    {#each recentSatelliteDates as iso (iso)}
                        <option value={iso}>{iso}</option>
                    {/each}
                </select>
            </div>
        {/if}
        <hr class="border-input-border" />
        <p class="font-semibold whitespace-nowrap text-sm">{$_("pois")}</p>
        {#each Object.entries(defaultMapState.pois) as [category, pois]}
            <p class="text-xs font-semibold text-content/75 whitespace-nowrap">{$_(category)}</p>
            {#each Object.keys(pois) as poi}
                <div class="flex items-center mt-1.5 mb-2.5 ml-2">
                    <input
                        id="{poi}-poi-checkbox"
                        type="checkbox"
                        bind:checked={mapState.pois[category][poi]}
                        class="w-4 h-4 bg-input-background accent-primary border-input-border focus:ring-input-ring focus:ring-2"
                        onchange={() => {
                            settings.onchange(mapState);
                        }}
                    />

                    <label for="{poi}-poi-checkbox" class="ms-2 text-sm cursor-pointer"
                        >{$_(poi)}</label
                    >
                </div>
            {/each}
        {/each}
    </div>
</div>
