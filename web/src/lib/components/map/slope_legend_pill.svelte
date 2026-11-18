<script lang="ts">
    let showInfo = $state(false);
</script>

<div
    data-testid="slope-legend-pill"
    class="bg-menu-background/94 backdrop-blur-md text-content border border-input-border/60 rounded-2xl px-3 py-2 shadow-[0_4px_20px_rgba(0,0,0,0.10)] pointer-events-auto max-w-xs"
>
    <div class="flex items-center justify-between gap-2 text-[11px] font-bold">
        <span>Înclinare pantă (avalanșă)</span>
        <button
            type="button"
            onclick={() => (showInfo = !showInfo)}
            aria-label="Informații rezoluție DEM"
            class="w-5 h-5 rounded-full bg-content/[0.08] text-content/80 flex items-center justify-center text-[10px] cursor-pointer"
        >
            i
        </button>
    </div>
    <div class="flex items-center gap-1.5 mt-1.5 text-[10px] font-semibold tabular-nums">
        <span class="px-1.5 py-0.5 rounded bg-[#EAB308]/80 text-slate-950">27–29°</span>
        <span class="px-1.5 py-0.5 rounded bg-[#F97316]/85 text-white">30–34°</span>
        <span class="px-1.5 py-0.5 rounded bg-[#DC2626]/90 text-white">35–44°</span>
        <span class="px-1.5 py-0.5 rounded bg-[#9333EA]/90 text-white">45–49°</span>
        <span class="px-1.5 py-0.5 rounded bg-[#1D4ED8]/90 text-white">50°+</span>
    </div>
    {#if showInfo}
        <p class="mt-1.5 text-[10.5px] leading-snug text-content/75">
            Calculat din DEM ~30 m (Mapterhorn / Copernicus GLO-30). Vâlcelele înguste și rupturile sub 30 m pot fi mai abrupte în teren.
        </p>
    {/if}
</div>
