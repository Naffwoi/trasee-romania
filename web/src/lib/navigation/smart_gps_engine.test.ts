import { describe, expect, it } from "vitest";
import { findCoLocatedPeerIds, fuseCooperativeGps } from "./cooperative_gps_fusion";
import { GpsPaceCoaster } from "./gps_pace_coaster";
import { FAR_PREVIEW_THRESHOLD_METERS, type NavTrackPoint } from "./types";

const sampleTrack: NavTrackPoint[] = Array.from({ length: 21 }, (_, i) => ({
	lat: 45.44 + i * 0.00045, // ~50m per step
	lon: 25.55,
	ele: 1000 + i * 2,
	distanceM: i * 50,
	gradePct: 4,
}));

describe("fuseCooperativeGps (Inverse-Variance Weighting + Proximity Gate)", () => {
	it("exports FAR_PREVIEW_THRESHOLD_METERS = 3000", () => {
		expect(FAR_PREVIEW_THRESHOLD_METERS).toBe(3_000);
	});

	it("sharpens noisy canopy GPS (60m) using a nearby group peer (6m) within overlap radius", () => {
		const now = 1_700_000_000_000;
		const res = fuseCooperativeGps(
			{ lat: 45.44, lon: 25.5504, accuracy: 60, timestampMs: now },
			[
				{
					memberId: "peer-1",
					lat: 45.44,
					lon: 25.55,
					accuracy: 6,
					updatedAtMs: now - 2_000,
				},
			],
			new Set(),
			now,
		);
		expect(res).not.toBeNull();
		expect(res!.source).toBe("cooperative");
		expect(res!.fusedPeerCount).toBe(1);
		expect(res!.accuracy).toBeLessThan(12);
		expect(Math.abs(res!.lon - 25.55)).toBeLessThan(0.0001);
	});

	it("ignores a group peer standing 300m behind so user position is never pulled backward", () => {
		const now = 1_700_000_000_000;
		const res = fuseCooperativeGps(
			{ lat: 45.445, lon: 25.55, accuracy: 45, timestampMs: now },
			[
				{
					memberId: "peer-lagging",
					lat: 45.442, // ~333m behind
					lon: 25.55,
					accuracy: 5,
					updatedAtMs: now - 1_000,
				},
			],
			new Set(),
			now,
		);
		expect(res).not.toBeNull();
		expect(res!.source).toBe("self");
		expect(res!.fusedPeerCount).toBe(0);
		expect(res!.lat).toBeCloseTo(45.445, 6);
	});

	it("enforces freshness (<=12s), peer accuracy (0 < acc <= 60), and self accuracy (>12m) gates", () => {
		const now = 1_700_000_000_000;
		// Sharp own fix (8m <= 12m) stays "self" even with nearby peer
		const sharpSelf = fuseCooperativeGps(
			{ lat: 45.44, lon: 25.55, accuracy: 8, timestampMs: now },
			[
				{
					memberId: "peer-1",
					lat: 45.44,
					lon: 25.5501,
					accuracy: 5,
					updatedAtMs: now - 1_000,
				},
			],
			new Set(),
			now,
		);
		expect(sharpSelf!.source).toBe("self");
		expect(sharpSelf!.fusedPeerCount).toBe(0);

		// Stale peer (>12s) and noisy peer (>60m) are rejected
		const rejectedPeers = fuseCooperativeGps(
			{ lat: 45.44, lon: 25.55, accuracy: 35, timestampMs: now },
			[
				{
					memberId: "peer-stale",
					lat: 45.44,
					lon: 25.5501,
					accuracy: 5,
					updatedAtMs: now - 13_000,
				},
				{
					memberId: "peer-noisy",
					lat: 45.44,
					lon: 25.5501,
					accuracy: 65,
					updatedAtMs: now - 1_000,
				},
			],
			new Set(),
			now,
		);
		expect(rejectedPeers!.source).toBe("self");
		expect(rejectedPeers!.fusedPeerCount).toBe(0);
	});

	it("uses group-tether when own GPS has dropped out (>6s) and co-located peer is fresh", () => {
		const now = 1_700_000_010_000;
		const coLocated = findCoLocatedPeerIds(
			{ lat: 45.441, lon: 25.55, accuracy: 12 },
			[
				{
					memberId: "peer-1",
					lat: 45.4411,
					lon: 25.55,
					accuracy: 7,
					updatedAtMs: now - 11_000,
				},
				{
					memberId: "peer-far",
					lat: 45.45,
					lon: 25.55,
					accuracy: 5,
					updatedAtMs: now - 11_000,
				},
			],
			now - 10_000,
		);
		expect(coLocated.has("peer-1")).toBe(true);
		expect(coLocated.has("peer-far")).toBe(false);

		const res = fuseCooperativeGps(
			null,
			[
				{
					memberId: "peer-1",
					lat: 45.441,
					lon: 25.55,
					accuracy: 7,
					updatedAtMs: now - 3_000,
				},
			],
			coLocated,
			now,
		);
		expect(res).not.toBeNull();
		expect(res!.source).toBe("group-tether");
		expect(res!.fusedPeerCount).toBe(1);
		expect(res!.lat).toBeCloseTo(45.441, 6);
		expect(res!.accuracy).toBeCloseTo(Math.hypot(7, 15), 5);

		// Non-co-located or stale peer returns null when selfFix === null
		expect(
			fuseCooperativeGps(
				null,
				[
					{
						memberId: "peer-stranger",
						lat: 45.441,
						lon: 25.55,
						accuracy: 7,
						updatedAtMs: now - 2_000,
					},
				],
				new Set(["peer-1"]),
				now,
			),
		).toBeNull();
	});
});

describe("GpsPaceCoaster", () => {
	it("suppresses off-trail under degraded canopy GPS, classifies cooperative fixes, and coasts forward smoothly up to 180s", () => {
		const coaster = new GpsPaceCoaster(sampleTrack, { isCycling: false });
		const t0 = 1_700_000_000_000;

		const s1 = coaster.ingestFix({
			lat: sampleTrack[2].lat,
			lon: sampleTrack[2].lon,
			accuracy: 8,
			matchedAlongM: 100,
			crossTrackM: 4,
			isPaused: false,
			paceFactor: 1.0,
			nowMs: t0,
		});
		expect(s1.signalState).toBe("good");
		expect(s1.suppressOffTrail).toBe(false);
		expect(s1.effectiveAlongM).toBeCloseTo(100, 1);

		// Cooperative fix classification
		const sCoop = coaster.ingestFix({
			lat: sampleTrack[2].lat,
			lon: sampleTrack[2].lon,
			accuracy: 10,
			matchedAlongM: 105,
			crossTrackM: 3,
			fusedSource: "cooperative",
			isPaused: false,
			paceFactor: 1.0,
			nowMs: t0 + 4_000,
		});
		expect(sCoop.signalState).toBe("cooperative");
		expect(sCoop.suppressOffTrail).toBe(false);

		// Degraded 65m accuracy 55m off trail -> canopy mode suppresses off-trail!
		const s2 = coaster.ingestFix({
			lat: sampleTrack[3].lat,
			lon: 25.5507,
			accuracy: 65,
			matchedAlongM: 150,
			crossTrackM: 55,
			isPaused: false,
			paceFactor: 1.0,
			nowMs: t0 + 35_000,
		});
		expect(s2.signalState).toBe("degraded");
		expect(s2.suppressOffTrail).toBe(true);
		expect(s2.effectiveAlongM).toBeGreaterThanOrEqual(140);

		// <6s since last fix -> does not coast yet
		expect(coaster.tickCoasting(t0 + 39_000, 1.0, false)).toBeNull();

		// Paused -> does not coast
		expect(coaster.tickCoasting(t0 + 42_000, 1.0, true)).toBeNull();

		// Unpaused 15s later (t0 + 57_000 is 22s since s2 at t0 + 35_000, 15s unpaused) -> 1Hz coasting advances along the trail
		const coast = coaster.tickCoasting(t0 + 57_000, 1.0, false);
		expect(coast).not.toBeNull();
		expect(coast!.signalState).toBe("coasting");
		expect(coast!.effectiveAlongM).toBeGreaterThan(s2.effectiveAlongM + 10);

		// >180s without any fix -> stops coasting autonomously
		expect(coaster.tickCoasting(t0 + 35_000 + 185_000, 1.0, false)).toBeNull();

		// Good fix returning slightly behind coasted position (within accuracy) does not jump backward
		const sReconcile = coaster.ingestFix({
			lat: sampleTrack[3].lat,
			lon: sampleTrack[3].lon,
			accuracy: 15,
			matchedAlongM: coast!.effectiveAlongM - 8,
			crossTrackM: 3,
			isPaused: false,
			paceFactor: 1.0,
			nowMs: t0 + 60_000,
		});
		expect(sReconcile.signalState).toBe("good");
		expect(sReconcile.effectiveAlongM).toBeGreaterThanOrEqual(coast!.effectiveAlongM);
	});
});
