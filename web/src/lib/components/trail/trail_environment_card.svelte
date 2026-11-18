<script lang="ts">
	import { onMount } from "svelte";

	interface Props {
		trailId: string;
		maxElevationM?: number | null;
	}
	let { trailId, maxElevationM = null }: Props = $props();

	interface EnvResponse {
		weather: {
			elevationM: number;
			temperatureC: number;
			apparentTempC: number;
			windGustsKmh: number;
			ridgeWindPeakKmh: number;
			ridgeWindSeverity: "none" | "warning" | "danger";
			freezingLevelM: number;
			freezingOnTrail: boolean;
			snowDepthCm: number;
			thunderstormRisk: boolean;
			attribution: string;
		} | null;
		gorgeFlood: {
			forecastPeakM3s: number;
			ratioToMedian: number;
			warning: boolean;
			severity: "none" | "warning" | "danger";
			attribution: string;
		} | null;
		hazards: Array<{
			id: string;
			hazardType: "wildfire" | "forest_disturbance";
			severity: "warning" | "danger";
			title: string;
			detectedAt: string;
		}>;
	}

	let envData = $state<EnvResponse | null>(null);

	onMount(() => {
		if (!trailId) return;
		const qs =
			maxElevationM && maxElevationM > 0 ? `?maxEle=${Math.round(maxElevationM)}` : "";
		void fetch(`/api/v1/live/trail/${encodeURIComponent(trailId)}/environment${qs}`)
			.then((r) => (r.ok ? r.json() : null))
			.then((d) => {
				if (d) envData = d as EnvResponse;
			})
			.catch(() => {});
	});
</script>

{#if envData && (envData.weather || envData.gorgeFlood?.warning || envData.hazards.length > 0)}
	<section
		data-testid="trail-environment-card"
		class="my-4 rounded-2xl border border-input-border/60 bg-menu-background/94 p-3.5 text-content shadow-sm space-y-2.5"
	>
		<div class="flex items-center justify-between">
			<span class="text-xs font-semibold uppercase tracking-wide text-content/70">
				Meteo la altitudine & alerte satelit
			</span>
			{#if envData.weather}
				<span class="text-xs text-content/60">{Math.round(envData.weather.elevationM)} m</span>
			{/if}
		</div>

		{#if envData.weather}
			<div class="grid grid-cols-3 gap-2 text-xs">
				<div class="rounded-xl bg-content/[0.05] px-2.5 py-2">
					<div class="text-content/60">Temperatură</div>
					<div class="font-semibold text-sm">{envData.weather.temperatureC.toFixed(1)}°C</div>
					<div class="text-[11px] text-content/60">
						Resimțită {envData.weather.apparentTempC.toFixed(0)}°C
					</div>
				</div>
				<div class="rounded-xl bg-content/[0.05] px-2.5 py-2">
					<div class="text-content/60">Vânt creastă</div>
					<div class="font-semibold text-sm">
						{Math.round(envData.weather.ridgeWindPeakKmh)} km/h
					</div>
					<div class="text-[11px] text-content/60">
						Plafon 0°C: {Math.round(envData.weather.freezingLevelM)} m
					</div>
				</div>
				<div class="rounded-xl bg-content/[0.05] px-2.5 py-2">
					<div class="text-content/60">Zăpadă</div>
					<div class="font-semibold text-sm">{envData.weather.snowDepthCm} cm</div>
					<div class="text-[11px] text-content/60">Model Open-Meteo</div>
				</div>
			</div>
		{/if}

		<div class="flex flex-wrap gap-1.5">
			{#if envData.weather?.ridgeWindSeverity !== "none" && envData.weather}
				<span
					class="inline-flex items-center gap-1.5 rounded-lg bg-amber-500/15 px-2.5 py-1 text-xs font-medium text-amber-800 dark:text-amber-300"
				>
					<i class="fa fa-wind" aria-hidden="true"></i> Vânt puternic pe creastă ({Math.round(
						envData.weather.ridgeWindPeakKmh,
					)} km/h)
				</span>
			{/if}
			{#if envData.weather?.thunderstormRisk}
				<span
					class="inline-flex items-center gap-1.5 rounded-lg bg-amber-500/15 px-2.5 py-1 text-xs font-medium text-amber-800 dark:text-amber-300"
				>
					<i class="fa fa-bolt" aria-hidden="true"></i> Risc de furtună electrică (CAPE ridicat)
				</span>
			{/if}
			{#if envData.gorgeFlood?.warning}
				<span
					class="inline-flex items-center gap-1.5 rounded-lg bg-amber-500/15 px-2.5 py-1 text-xs font-medium text-amber-800 dark:text-amber-300"
				>
					<i class="fa fa-water" aria-hidden="true"></i> Debit crescut în chei ({envData.gorgeFlood
						.ratioToMedian}x față de medie · GloFAS)
				</span>
			{/if}
			{#each envData.hazards as hz (hz.id)}
				<span
					class="inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 text-xs font-medium {hz.severity ===
					'danger'
						? 'bg-red-600/15 text-red-700 dark:text-red-300'
						: 'bg-amber-500/15 text-amber-800 dark:text-amber-300'}"
				>
					<i
						class="fa {hz.hazardType === 'wildfire' ? 'fa-fire' : 'fa-tree'}"
						aria-hidden="true"
					></i>
					{hz.title}
				</span>
			{/each}
		</div>
	</section>
{/if}
