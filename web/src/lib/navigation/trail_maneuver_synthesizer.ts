import {
	bearingDegrees,
	cardinalDirection,
	haversineMeters,
	normalizeBearingDelta,
} from "./geo_math";
import type { NavManeuver } from "./types";

interface CandidateEvent {
	index: number;
	type: number;
	bearing: number;
	instruction: string;
	priority: number;
}

function findChordIndexBackward(cumDist: readonly number[], i: number, minChordM: number): number {
	let idx = i - 1;
	while (idx > 0 && cumDist[i] - cumDist[idx] < minChordM) {
		idx--;
	}
	return Math.max(0, idx);
}

function findChordIndexForward(cumDist: readonly number[], i: number, minChordM: number): number {
	const last = cumDist.length - 1;
	let idx = i + 1;
	while (idx < last && cumDist[idx] - cumDist[i] < minChordM) {
		idx++;
	}
	return Math.min(last, idx);
}

function smoothElevations(raw: readonly number[]): number[] {
	const n = raw.length;
	const out = new Array<number>(n);
	for (let i = 0; i < n; i++) {
		const r = Math.min(2, i, n - 1 - i);
		let sum = 0;
		for (let j = i - r; j <= i + r; j++) {
			sum += raw[j];
		}
		out[i] = sum / (2 * r + 1);
	}
	return out;
}

function computeLocalGrades(cumDist: readonly number[], eles: readonly number[]): number[] {
	const n = cumDist.length;
	const grades = new Array<number>(n).fill(0);
	for (let i = 0; i < n; i++) {
		let lo = i;
		while (lo > 0 && cumDist[i] - cumDist[lo] < 20) lo--;
		let hi = i;
		while (hi < n - 1 && cumDist[hi] - cumDist[i] < 20) hi++;
		const run = cumDist[hi] - cumDist[lo];
		if (run > 1) {
			grades[i] = ((eles[hi] - eles[lo]) / run) * 100;
		}
	}
	return grades;
}

function detectSteepRuns(
	cumDist: readonly number[],
	eles: readonly number[],
	grades: readonly number[],
	isClimb: boolean,
): { index: number; avgGradePct: number; runDistM: number }[] {
	const n = cumDist.length;
	const results: { index: number; avgGradePct: number; runDistM: number }[] = [];
	let i = 0;
	let lastAcceptedDist = -Infinity;

	while (i < n - 1) {
		const meets = isClimb ? grades[i] >= 14 : grades[i] <= -14;
		if (!meets) {
			i++;
			continue;
		}

		const startIdx = i;
		let endIdx = i;
		let j = i + 1;
		while (j < n) {
			const jMeets = isClimb ? grades[j] >= 14 : grades[j] <= -14;
			if (jMeets) {
				endIdx = j;
				j++;
			} else {
				// Allow tiny <20m flat steps inside a sustained steep ramp.
				let lookahead = j;
				while (lookahead < n && cumDist[lookahead] - cumDist[endIdx] < 20) {
					const aheadMeets = isClimb ? grades[lookahead] >= 14 : grades[lookahead] <= -14;
					if (aheadMeets) break;
					lookahead++;
				}
				if (
					lookahead < n &&
					cumDist[lookahead] - cumDist[endIdx] < 20 &&
					(isClimb ? grades[lookahead] >= 14 : grades[lookahead] <= -14)
				) {
					endIdx = lookahead;
					j = lookahead + 1;
				} else {
					break;
				}
			}
		}

		const runDist = cumDist[endIdx] - cumDist[startIdx];
		if (runDist >= 150 && cumDist[startIdx] - lastAcceptedDist >= 150) {
			const avgGrade = ((eles[endIdx] - eles[startIdx]) / runDist) * 100;
			if ((isClimb && avgGrade >= 14) || (!isClimb && avgGrade <= -14)) {
				results.push({
					index: startIdx,
					avgGradePct: avgGrade,
					runDistM: runDist,
				});
				lastAcceptedDist = cumDist[endIdx];
			}
		}

		i = Math.max(j, endIdx + 1);
	}

	return results;
}

/**
 * Synthesizes Valhalla-compatible trail navigation maneuvers offline from GPX geometry,
 * elevation profile, and trail waypoints.
 */
export function synthesizeTrailManeuvers(
	points: { lat: number; lon: number; ele?: number }[],
	options?: {
		locale?: string;
		waypoints?: { lat: number; lon: number; name?: string }[];
	},
): { maneuvers: NavManeuver[]; shape: [number, number][] } {
	const n = points.length;
	if (n === 0) {
		return { maneuvers: [], shape: [] };
	}

	const isRo = (options?.locale ?? "en").trim().toLowerCase().startsWith("ro");
	const shape: [number, number][] = points.map((p) => [p.lat, p.lon]);

	if (n === 1) {
		return {
			maneuvers: [
				{
					instruction: isRo ? "Pornește pe traseu" : "Start on the trail",
					length: 0,
					begin_shape_index: 0,
					bearing: 0,
					type: 1,
				},
			],
			shape,
		};
	}

	const cumDist = new Array<number>(n);
	cumDist[0] = 0;
	for (let i = 1; i < n; i++) {
		cumDist[i] =
			cumDist[i - 1] +
			haversineMeters(points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon);
	}
	const totalDist = cumDist[n - 1];

	const startTargetIdx = findChordIndexForward(cumDist, 0, 25);
	const startBearing = bearingDegrees(
		points[0].lat,
		points[0].lon,
		points[startTargetIdx].lat,
		points[startTargetIdx].lon,
	);
	const startDir = cardinalDirection(startBearing, isRo ? "ro" : "en");

	const events: CandidateEvent[] = [
		{
			index: 0,
			type: 1,
			bearing: startBearing,
			instruction: isRo ? `Pornește spre ${startDir} pe traseu` : `Head ${startDir} on the trail`,
			priority: 100,
		},
	];

	// 1. Detect real turns via ~25m incoming vs ~25m outgoing chord bearings with apex selection.
	const turnDeltas = new Array<number>(n).fill(0);
	const outBearings = new Array<number>(n).fill(0);

	for (let i = 1; i < n - 1; i++) {
		const inIdx = findChordIndexBackward(cumDist, i, 25);
		const outIdx = findChordIndexForward(cumDist, i, 25);
		const inDist = cumDist[i] - cumDist[inIdx];
		const outDist = cumDist[outIdx] - cumDist[i];
		if (inDist < 8 || outDist < 8) continue;

		const inBearing = bearingDegrees(points[inIdx].lat, points[inIdx].lon, points[i].lat, points[i].lon);
		const outBearing = bearingDegrees(points[i].lat, points[i].lon, points[outIdx].lat, points[outIdx].lon);
		turnDeltas[i] = normalizeBearingDelta(inBearing, outBearing);
		outBearings[i] = outBearing;
	}

	let lastTurnDist = -Infinity;
	for (let i = 1; i < n - 1; i++) {
		const absDelta = Math.abs(turnDeltas[i]);
		if (absDelta < 32) continue;
		if (cumDist[i] < 20 || totalDist - cumDist[i] < 20) continue;

		// Ensure this point is the local turning apex within +-25m.
		let isApex = true;
		for (let j = i - 1; j >= 1 && cumDist[i] - cumDist[j] <= 25; j--) {
			if (Math.abs(turnDeltas[j]) > absDelta) {
				isApex = false;
				break;
			}
		}
		if (!isApex) continue;
		for (let j = i + 1; j < n - 1 && cumDist[j] - cumDist[i] <= 25; j++) {
			if (Math.abs(turnDeltas[j]) >= absDelta) {
				isApex = false;
				break;
			}
		}
		if (!isApex) continue;

		if (cumDist[i] - lastTurnDist < 60) continue;

		const right = turnDeltas[i] > 0;
		let type: number;
		let instruction: string;
		if (absDelta >= 105) {
			type = right ? 11 : 14;
			instruction = isRo
				? right
					? "Virează brusc la dreapta"
					: "Virează brusc la stânga"
				: right
					? "Sharp right"
					: "Sharp left";
		} else if (absDelta >= 60) {
			type = right ? 10 : 15;
			instruction = isRo
				? right
					? "Virează la dreapta"
					: "Virează la stânga"
				: right
					? "Turn right"
					: "Turn left";
		} else {
			type = right ? 9 : 16;
			instruction = isRo
				? right
					? "Ține ușor dreapta"
					: "Ține ușor stânga"
				: right
					? "Bear right"
					: "Bear left";
		}

		events.push({
			index: i,
			type,
			bearing: outBearings[i],
			instruction,
			priority: 70,
		});
		lastTurnDist = cumDist[i];
	}

	// 2. Elevation-derived events: sustained steep climbs/descents and highest peak.
	const finiteEles = points.filter((p) => p.ele !== undefined && Number.isFinite(p.ele));
	if (finiteEles.length >= 2) {
		const rawEles = points.map((p, idx) =>
			p.ele !== undefined && Number.isFinite(p.ele) ? p.ele : (points[Math.max(0, idx - 1)].ele ?? 0),
		);
		const smoothedEles = smoothElevations(rawEles);
		const grades = computeLocalGrades(cumDist, smoothedEles);

		for (const climb of detectSteepRuns(cumDist, smoothedEles, grades, true)) {
			const outIdx = findChordIndexForward(cumDist, climb.index, 25);
			const bearing = bearingDegrees(
				points[climb.index].lat,
				points[climb.index].lon,
				points[outIdx].lat,
				points[outIdx].lon,
			);
			const pct = Math.round(climb.avgGradePct);
			const dist = Math.round(climb.runDistM);
			events.push({
				index: climb.index,
				type: 8,
				bearing,
				instruction: isRo
					? `Urcare abruptă (${pct}%, ${dist} m)`
					: `Steep climb (${pct}%, ${dist} m)`,
				priority: 40,
			});
		}

		for (const descent of detectSteepRuns(cumDist, smoothedEles, grades, false)) {
			const outIdx = findChordIndexForward(cumDist, descent.index, 25);
			const bearing = bearingDegrees(
				points[descent.index].lat,
				points[descent.index].lon,
				points[outIdx].lat,
				points[outIdx].lon,
			);
			const pct = Math.round(Math.abs(descent.avgGradePct));
			const dist = Math.round(descent.runDistM);
			events.push({
				index: descent.index,
				type: 8,
				bearing,
				instruction: isRo
					? `Coborâre abruptă (-${pct}%, ${dist} m)`
					: `Steep descent (-${pct}%, ${dist} m)`,
				priority: 40,
			});
		}

		// Highest peak if interior and >= 20m above minimum elevation.
		let maxEle = -Infinity;
		let minEle = Infinity;
		let peakIdx = -1;
		for (let i = 0; i < n; i++) {
			if (smoothedEles[i] > maxEle) {
				maxEle = smoothedEles[i];
				peakIdx = i;
			}
			if (smoothedEles[i] < minEle) {
				minEle = smoothedEles[i];
			}
		}
		if (
			peakIdx > 0 &&
			peakIdx < n - 1 &&
			cumDist[peakIdx] > 40 &&
			totalDist - cumDist[peakIdx] > 40 &&
			maxEle - minEle >= 20
		) {
			const outIdx = findChordIndexForward(cumDist, peakIdx, 25);
			const bearing = bearingDegrees(
				points[peakIdx].lat,
				points[peakIdx].lon,
				points[outIdx].lat,
				points[outIdx].lon,
			);
			const peakRounded = Math.round(maxEle);
			events.push({
				index: peakIdx,
				type: 8,
				bearing,
				instruction: isRo
					? `Vârf / punct maxim (${peakRounded} m)`
					: `Summit / high point (${peakRounded} m)`,
				priority: 55,
			});
		}
	}

	// 3. Nearby trail waypoints within 40 m.
	for (const wp of options?.waypoints ?? []) {
		if (!Number.isFinite(wp.lat) || !Number.isFinite(wp.lon)) continue;
		let bestIdx = -1;
		let bestDist = Infinity;
		for (let i = 0; i < n; i++) {
			const d = haversineMeters(wp.lat, wp.lon, points[i].lat, points[i].lon);
			if (d < bestDist) {
				bestDist = d;
				bestIdx = i;
			}
		}
		if (bestIdx > 0 && bestIdx < n - 1 && bestDist <= 40) {
			const outIdx = findChordIndexForward(cumDist, bestIdx, 25);
			const bearing = bearingDegrees(
				points[bestIdx].lat,
				points[bestIdx].lon,
				points[outIdx].lat,
				points[outIdx].lon,
			);
			const label = wp.name?.trim() || (isRo ? "punct de reper" : "waypoint");
			events.push({
				index: bestIdx,
				type: 8,
				bearing,
				instruction: isRo ? `Treci pe lângă ${label}` : `Pass ${label}`,
				priority: 80,
			});
		}
	}

	// 4. Destination event.
	const endInIdx = findChordIndexBackward(cumDist, n - 1, 25);
	const endBearing = bearingDegrees(
		points[endInIdx].lat,
		points[endInIdx].lon,
		points[n - 1].lat,
		points[n - 1].lon,
	);
	events.push({
		index: n - 1,
		type: 4,
		bearing: endBearing,
		instruction: isRo ? "Ai ajuns la destinație" : "You have arrived at your destination",
		priority: 100,
	});

	// Deduplicate same shape index; nudge lower-priority non-terminal events (+1)
	// so e.g. a trailhead steep climb at index 0 is not swallowed by the start maneuver.
	events.sort((a, b) => a.index - b.index || b.priority - a.priority);
	const byIndex = new Map<number, CandidateEvent>();
	for (const ev of events) {
		let targetIdx = ev.index;
		if (byIndex.has(targetIdx)) {
			const existing = byIndex.get(targetIdx)!;
			if (ev.priority > existing.priority && targetIdx < n - 2) {
				// Demote existing to targetIdx + 1 if free.
				if (!byIndex.has(targetIdx + 1)) {
					byIndex.set(targetIdx + 1, { ...existing, index: targetIdx + 1 });
				}
				byIndex.set(targetIdx, ev);
			} else if (ev.type === 8 && targetIdx + 1 < n - 1 && !byIndex.has(targetIdx + 1)) {
				targetIdx += 1;
				byIndex.set(targetIdx, { ...ev, index: targetIdx });
			}
			continue;
		}
		byIndex.set(targetIdx, ev);
	}

	const sorted = [...byIndex.values()].sort((a, b) => a.index - b.index);
	const maneuvers: NavManeuver[] = sorted.map((ev, idx) => {
		const nextIdx = idx < sorted.length - 1 ? sorted[idx + 1].index : ev.index;
		const distKm = Math.max(0, (cumDist[nextIdx] - cumDist[ev.index]) / 1000);
		return {
			instruction: ev.instruction,
			length: idx === sorted.length - 1 ? 0 : Number(distKm.toFixed(4)),
			begin_shape_index: ev.index,
			bearing: Math.round(ev.bearing),
			type: ev.type,
		};
	});

	return { maneuvers, shape };
}
