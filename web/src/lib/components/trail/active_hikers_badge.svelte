<script lang="ts">
    interface Props {
        count: number | null | undefined;
        compact?: boolean;
        loading?: boolean;
    }

    let { count = 0, compact = false, loading: _loading = false }: Props = $props();

    const safeCount = $derived(
        typeof count === "number" && Number.isFinite(count) && count > 0
            ? Math.round(count)
            : 0,
    );

    const labelText = $derived.by(() => {
        if (safeCount <= 0) return "";
        if (compact) {
            return `${safeCount} ${safeCount === 1 ? "persoană" : "persoane"} în zonă`;
        }
        return `${safeCount} ${safeCount === 1 ? "persoană" : "persoane"} în zonă`;
    });
</script>

{#if safeCount > 0}
    <span
        data-testid="active-hikers-badge"
        data-active-count={safeCount}
        title={`🟢 ${labelText}`}
        class={`inline-flex items-center gap-1.5 rounded-full border font-semibold tabular-nums transition-colors bg-emerald-500/14 border-emerald-500/35 text-emerald-700 dark:text-emerald-300 ${
            compact ? "px-2.5 py-0.5 text-[11px]" : "px-3 py-1 text-xs"
        }`}
    >
        <span class="relative flex h-2 w-2 shrink-0" aria-hidden="true">
            <span
                class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"
            ></span>
            <span class="relative inline-flex rounded-full h-2 w-2 bg-emerald-500"></span>
        </span>
        <span class="truncate">{labelText}</span>
    </span>
{/if}
