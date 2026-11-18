<script lang="ts">
	import { onMount } from "svelte";

	interface Props {
		lat?: number;
		lon?: number;
	}
	let { lat, lon }: Props = $props();

	interface StreetPhoto {
		id: string;
		provider: string;
		thumbUrl: string;
		fullUrl: string;
		heading: number;
		capturedAt: string;
		distanceM: number;
		attribution: string;
	}

	let photos = $state<StreetPhoto[]>([]);
	let activePhoto = $state<StreetPhoto | null>(null);

	onMount(() => {
		if (lat === undefined || lon === undefined || !Number.isFinite(lat) || !Number.isFinite(lon)) {
			return;
		}
		void fetch(`/api/v1/live/street-preview?lat=${lat.toFixed(6)}&lon=${lon.toFixed(6)}`)
			.then((r) => (r.ok ? r.json() : null))
			.then((d) => {
				if (Array.isArray(d?.photos)) photos = d.photos;
			})
			.catch(() => {});
	});
</script>

{#if photos.length > 0}
	<section data-testid="trailhead-street-preview" class="my-4 space-y-2">
		<div class="flex items-center justify-between">
			<span class="text-xs font-semibold uppercase tracking-wide text-content/70">
				Acces & parcare la intrarea în traseu
			</span>
			<span class="text-[11px] text-content/55">{photos[0].attribution}</span>
		</div>
		<div class="flex gap-2 overflow-x-auto pb-1">
			{#each photos as p (p.id)}
				<button
					type="button"
					onclick={() => (activePhoto = p)}
					class="group relative h-24 w-36 shrink-0 overflow-hidden rounded-xl border border-input-border/60 bg-content/5 text-left cursor-pointer"
				>
					<img
						src={p.thumbUrl}
						alt="Trailhead preview"
						loading="lazy"
						class="h-full w-full object-cover transition group-hover:scale-105"
					/>
					<span
						class="absolute bottom-1 left-1 rounded-md bg-[#242734]/85 px-1.5 py-0.5 text-[10px] text-white"
					>
						{Math.round(p.distanceM)} m · {p.capturedAt || p.provider}
					</span>
				</button>
			{/each}
		</div>
	</section>
{/if}

{#if activePhoto}
	<div
		role="dialog"
		aria-modal="true"
		aria-label="Previzualizare stradală"
		class="fixed inset-0 z-50 flex items-center justify-center bg-black/75 p-4"
	>
		<button
			type="button"
			aria-label="Închide"
			class="fixed inset-0 w-full h-full cursor-default"
			onclick={() => (activePhoto = null)}
		></button>
		<div
			class="relative z-10 max-w-3xl overflow-hidden rounded-2xl bg-menu-background border border-input-border/60 shadow-2xl"
		>
			<img
				src={activePhoto.fullUrl}
				alt="Street level trailhead"
				class="max-h-[75vh] w-auto object-contain"
			/>
			<div class="flex items-center justify-between px-4 py-2.5 text-xs text-content">
				<span>
					La {Math.round(activePhoto.distanceM)} m de start · Azimut {Math.round(
						activePhoto.heading,
					)}° · {activePhoto.attribution}
				</span>
				<button
					type="button"
					class="rounded-lg bg-content/10 px-3 py-1 font-medium cursor-pointer"
					onclick={() => (activePhoto = null)}
				>
					Închide
				</button>
			</div>
		</div>
	</div>
{/if}
