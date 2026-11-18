<script lang="ts">
    import { onMount, type Component } from "svelte";

    interface Props {
        value?: string;
        label?: string;
        error?: string | string[] | null;
        placeholder?: string;
        extraClasses?: string;
        searchListPosition?: string;
    }

    let {
        value = $bindable(""),
        label = "",
        error = "",
        placeholder = "",
        extraClasses = "",
        searchListPosition = "absolute",
    }: Props = $props();

    let LoadedEditor: Component<Props> | null = $state(null);

    onMount(async () => {
        const mod = await import("./editor.svelte");
        LoadedEditor = mod.default;
    });
</script>

{#if LoadedEditor}
    <LoadedEditor
        bind:value
        {label}
        {error}
        {placeholder}
        {extraClasses}
        {searchListPosition}
    />
{:else}
    <div
        class="min-h-28 w-full rounded-lg border border-input-border bg-input-background/60 animate-pulse"
        aria-busy="true"
    ></div>
{/if}
