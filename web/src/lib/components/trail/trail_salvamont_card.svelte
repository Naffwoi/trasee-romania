<script lang="ts">
	import {
		formatRoPhoneDisplay,
		resolveTrailSalvamontSummary,
	} from "#lib/emergency/salvamont_resolver.ts";
	import GPX from "#lib/models/gpx/gpx.ts";
	import type { Trail } from "#lib/models/trail.ts";
	import { extractRawTrackPoints } from "#lib/navigation/geo_math.ts";
	import { formatDistance } from "#lib/util/format_util.ts";
	import { decodePolyline } from "#lib/util/polyline_util.ts";
	import { locale } from "svelte-i18n";

	interface Props {
		trail: Trail;
	}

	let { trail }: Props = $props();

	let showLocalDispatches = $state(false);
	const isRo = $derived(($locale ?? "ro").toLowerCase().startsWith("ro"));

	const trackPoints = $derived.by(() => {
		if (trail.expand?.gpx) {
			const pts = extractRawTrackPoints(trail.expand.gpx);
			if (pts.length > 0) return pts;
		}
		if (trail.expand?.gpx_data) {
			try {
				const parsed = GPX.parse(trail.expand.gpx_data);
				const pts = extractRawTrackPoints(parsed);
				if (pts.length > 0) return pts;
			} catch {
				// Fallback below
			}
		}
		if (trail.polyline) {
			return decodePolyline(trail.polyline, 5).map(([lon, lat]) => ({ lat, lon }));
		}
		if (trail.lat !== undefined && trail.lon !== undefined) {
			return [{ lat: trail.lat, lon: trail.lon }];
		}
		return [];
	});

	const summary = $derived(
		resolveTrailSalvamontSummary(trackPoints, isRo ? "ro" : "en"),
	);
</script>

{#if summary}
	<div
		data-testid="trail-salvamont-card"
		class="my-4 rounded-2xl bg-menu-background/94 backdrop-blur-md border border-input-border/60 p-3.5 text-content shadow-xs"
	>
		<div class="flex flex-wrap items-center justify-between gap-2">
			<div class="flex items-center gap-2">
				<span
					class="w-7 h-7 rounded-lg bg-[#242734] text-white flex items-center justify-center text-xs font-extrabold shrink-0"
					aria-hidden="true"
				>
					+
				</span>
				<div>
					<h5 class="text-xs font-extrabold tracking-tight text-content">
						{isRo ? "Acoperire Salvamont pe traseu" : "Mountain Rescue (Salvamont)"}
					</h5>
					<p class="text-[11px] text-content/70">
						{summary.nearestBase.point.name} · {formatDistance(
							Math.round(summary.nearestBase.distanceM),
							{ compact: true },
						)}
						{#if summary.nearestRefuge}
							· {summary.nearestRefuge.point.name} ({formatDistance(
								Math.round(summary.nearestRefuge.distanceM),
								{ compact: true },
							)})
						{/if}
					</p>
				</div>
			</div>

			{#if summary.isRidgeBorderTrail}
				<span
					class="px-2 py-0.5 rounded-full bg-content/[0.07] text-[10.5px] font-bold text-content/80"
				>
					{isRo ? "Traseu pe graniță montană" : "Multi-jurisdiction ridge"}
				</span>
			{/if}
		</div>

		<div class="mt-2.5 flex flex-wrap items-center gap-2">
			<a
				href="tel:112"
				class="inline-flex items-center gap-1.5 px-3 min-h-11 sm:min-h-9 rounded-full bg-red-600 hover:bg-red-700 text-white text-xs font-extrabold focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-red-600"
			>
				<i class="fa-solid fa-phone text-[11px]" aria-hidden="true"></i>
				<span>112</span>
			</a>
			<a
				href="tel:+40725826668"
				class="inline-flex items-center gap-1.5 px-3 min-h-11 sm:min-h-9 rounded-full bg-[#242734] hover:opacity-90 text-white text-xs font-extrabold focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
			>
				<i class="fa-solid fa-shield-halved text-[11px]" aria-hidden="true"></i>
				<span>0-SALVAMONT (0725 826 668)</span>
			</a>
			{#if summary.services.length > 0}
				<button
					type="button"
					aria-expanded={showLocalDispatches}
					onclick={() => (showLocalDispatches = !showLocalDispatches)}
					class="inline-flex items-center gap-1.5 px-3 min-h-11 sm:min-h-9 rounded-full bg-content/[0.06] hover:bg-content/[0.11] border border-input-border/60 text-content text-xs font-semibold cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
				>
					<span>
						{isRo
							? `Dispecerate locale (${summary.services.length})`
							: `Local dispatches (${summary.services.length})`}
					</span>
					<i
						class={`fa-solid ${showLocalDispatches ? "fa-chevron-up" : "fa-chevron-down"} text-[10px]`}
						aria-hidden="true"
					></i>
				</button>
			{/if}
		</div>
		{#if showLocalDispatches && summary.services.length > 0}
			<div class="mt-2 flex flex-wrap items-center gap-1.5">
				{#each summary.services as entry (entry.service.id)}
					<a
						href={`tel:${entry.service.primaryPhone}`}
						class="inline-flex items-center gap-1.5 px-3 min-h-11 sm:min-h-9 rounded-full bg-content/[0.05] hover:bg-content/[0.1] border border-input-border/60 text-content text-xs font-semibold focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#242734]"
					>
						<i class="fa-solid fa-phone text-[10px] opacity-70" aria-hidden="true"></i>
						<span>{entry.service.shortName}: {formatRoPhoneDisplay(entry.service.primaryPhone)}</span>
					</a>
				{/each}
			</div>
		{/if}
	</div>
{/if}
