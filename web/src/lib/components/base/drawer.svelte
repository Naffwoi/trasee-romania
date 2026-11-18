<script lang="ts">
    import { browser } from "$app/env";
    import { beforeNavigate } from "$app/navigation";
    import type { Snippet } from "svelte";
    import { backIn, backOut } from "svelte/easing";
    import { slide } from "svelte/transition";

    interface Props {
        open?: boolean;
        children?: Snippet;
    }

    let { open = $bindable(false), children }: Props = $props();
    let dialogEl = $state<HTMLDialogElement | undefined>();

    $effect(() => {
        if (!browser) return;
        if (open && dialogEl && !dialogEl.open) {
            dialogEl.showModal?.();
        } else if (!open && dialogEl?.open) {
            dialogEl.close?.();
        }
    });

    beforeNavigate(({ shallow }) => {
        if (shallow) return;
        open = false;
    });
</script>

{#if open}
    <dialog
        bind:this={dialogEl}
        onclose={() => (open = false)}
        onclick={(e) => {
            if (e.target === dialogEl) open = false;
        }}
        class="wanderer-drawer fixed inset-0 m-0 ml-auto h-dvh max-h-none w-72 max-w-[85vw] bg-background text-content p-0 border-0 shadow-2xl overflow-y-auto overscroll-contain"
        in:slide={{ axis: "x", easing: backOut }}
        out:slide={{ axis: "x", easing: backIn }}
    >
        <div class="flex flex-col min-h-full">
            {@render children?.()}
        </div>
    </dialog>
{/if}

<style>
    .wanderer-drawer::backdrop {
        background: rgba(18, 20, 28, 0.45);
        backdrop-filter: blur(4px);
    }
</style>
