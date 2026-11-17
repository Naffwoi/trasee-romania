<script lang="ts">
    interface Props {
        icon: string;
        label: string;
    }

    let { icon, label }: Props = $props();
</script>

<span
    class="inline-flex items-center gap-1.5 rounded-full bg-content/[0.07] px-2.5 py-1 text-xs font-medium text-content whitespace-nowrap"
>
    <i class={`fa ${icon} text-[12px] text-slate-500 dark:text-slate-400`} aria-hidden="true"></i>
    <span>{label}</span>
</span>
