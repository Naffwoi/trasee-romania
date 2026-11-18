import { describe, expect, it } from "vitest";
import { PwaPowerGovernor } from "./pwa_power_governor";

describe("PwaPowerGovernor (>90s Stationary Cabana Sleep + SOS override)", () => {
	it("transitions MOVING -> SCRAMBLE_GRACE -> STATIONARY_CABANA_SLEEP after >90s within 8m and wakes on 2 IMU steps", () => {
		const gov = new PwaPowerGovernor();
		const t0 = 1_700_000_000_000;

		// Initial moving fix
		const s0 = gov.ingestFix({ lat: 45.44, lon: 25.55, speed: 1.2, nowMs: t0, hasActiveSos: false });
		expect(s0.state).toBe("moving");
		expect(s0.highAccuracyGps).toBe(true);
		expect(s0.isStationary).toBe(false);

		// Stop at mountain hut at t0 + 30s -> scramble_grace (still high accuracy!)
		const s1 = gov.ingestFix({ lat: 45.44001, lon: 25.55001, speed: 0.05, nowMs: t0 + 30_000, hasActiveSos: false });
		expect(s1.state).toBe("scramble_grace");
		expect(s1.highAccuracyGps).toBe(true);

		// 92s stationary elapsed since stopping (t0 + 122s) within <8m radius and speed <0.25 m/s -> enters stationary_cabana_sleep!
		const s2 = gov.ingestFix({ lat: 45.44002, lon: 25.55001, speed: 0.0, nowMs: t0 + 122_000, hasActiveSos: false });
		expect(s2.state).toBe("stationary_cabana_sleep");
		expect(s2.highAccuracyGps).toBe(false);
		expect(s2.isStationary).toBe(true);
		expect(s2.recommendedGroupPingMs).toBe(45_000);
		expect(s2.recommendedHeartbeatMs).toBe(120_000);

		// Single bump on table (1 step) does NOT false-wake
		expect(gov.ingestLinearAcceleration(1.5, 0, 0, t0 + 125_000)).toBe(false);
		// Second walking step within 2.5s window wakes immediately back to moving!
		expect(gov.ingestLinearAcceleration(0, 1.6, 0, t0 + 125_650)).toBe(true);
		expect(gov.currentState).toBe("moving");
		expect(gov.isHighAccuracy).toBe(true);
	});

	it("supports 45s Expedition Mode and enforces mandatory SOS max-precision override", () => {
		const gov = new PwaPowerGovernor({ expeditionMode: true });
		const t0 = 1_700_000_000_000;

		gov.ingestFix({ lat: 45.44, lon: 25.55, speed: 0, nowMs: t0, hasActiveSos: false });
		const sleepSnap = gov.ingestFix({
			lat: 45.44001,
			lon: 25.55,
			speed: 0,
			nowMs: t0 + 46_000,
			hasActiveSos: false,
		});
		expect(sleepSnap.state).toBe("stationary_cabana_sleep");
		expect(sleepSnap.highAccuracyGps).toBe(false);

		// Triggering SOS or responding to SOS immediately overrides sleep -> highAccuracyGps: true!
		const sosSnap = gov.ingestFix({
			lat: 45.44001,
			lon: 25.55,
			speed: 0,
			nowMs: t0 + 50_000,
			hasActiveSos: true,
		});
		expect(sosSnap.state).toBe("moving");
		expect(sosSnap.highAccuracyGps).toBe(true);
		expect(sosSnap.isStationary).toBe(false);
	});
});
