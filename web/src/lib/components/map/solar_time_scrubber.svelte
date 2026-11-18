<script lang="ts">
    import { getSunPosition, getSunTimes } from "#lib/navigation/sun_calc.ts";

    interface Props {
        lat: number;
        lon: number;
        simulatedTimeMs: number;
        onChange: (nextTimeMs: number) => void;
    }

    let { lat, lon, simulatedTimeMs, onChange }: Props = $props();

    const dayStartMs = $derived.by(() => {
        const d = new Date(simulatedTimeMs);
        d.setHours(0, 0, 0, 0);
        return d.getTime();
    });

    const minutesOfDay = $derived(
        Math.max(300, Math.min(1320, Math.round((simulatedTimeMs - dayStartMs) / 60_000))),
    );

    const sunPos = $derived(getSunPosition(simulatedTimeMs, lat, lon));
    const sunTimes = $derived(getSunTimes(simulatedTimeMs, lat, lon));

    function fmtClock(ms: number): string {
        const d = new Date(ms);
        return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    }
</script>

<div
    data-testid="solar-time-scrubber"
    class="bg-menu-background/94 backdrop-blur-md text-content border border-input-border/60 rounded-2xl px-3.5 py-2.5 shadow-[0_4px_20px_rgba(0,0,0,0.10)] pointer-events-auto w-72"
>
    <div class="flex items-center justify-between text-xs font-bold tabular-nums">
        <span>Umbre solare · {fmtClock(simulatedTimeMs)}</span>
        <span class="text-[11px] font-semibold text-content/70">
            Alt {sunPos.altitudeDeg.toFixed(0)}° · Az {sunPos.azimuthDeg.toFixed(0)}°
        </span>
    </div>
    <input
        type="range"
        min="300"
        max="1320"
        step="10"
        value={minutesOfDay}
        aria-label="Oră simulare solară"
        oninput={(e) => {
            const mins = Number((e.currentTarget as HTMLInputElement).value);
            onChange(dayStartMs + mins * 60_000);
        }}
        class="w-full mt-2 accent-[#242734] cursor-pointer"
    />
    <div class="flex items-center justify-between text-[10.5px] text-content/65 mt-0.5 tabular-nums">
        <span>
            Răsărit {sunTimes.sunrise ? fmtClock(sunTimes.sunrise.getTime()) : "--:--"}
        </span>
        <button
            type="button"
            onclick={() => onChange(Date.now())}
            class="px-2 py-0.5 rounded-full bg-content/[0.08] text-content font-semibold cursor-pointer"
        >
            Acum
        </button>
        <span>
            Apus {sunTimes.sunset ? fmtClock(sunTimes.sunset.getTime()) : "--:--"}
        </span>
    </div>
</div>
