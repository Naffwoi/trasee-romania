import { interpolateTrackAtDistance, lowerBound } from "./geo_math";
import type {
	EtaCalculatorOptions,
	EtaSnapshot,
	NavTrackPoint,
	OffTrailExtra,
} from "./types";

interface PeakEntry {
	distanceM: number;
	ele: number;
	cumAscentM: number;
}

/**
 * Tobler's hiking (or cycling) speed function in km/h given slope ratio `rise / run`.
 */
export function toblerHikingSpeedKmh(slopeRatio: number, isCycling = false): number {
	const s = Number.isFinite(slopeRatio) ? slopeRatio : 0;
	if (isCycling) {
		const raw = 18 * Math.exp(-2.8 * Math.abs(s + 0.03));
		return Math.min(32.0, Math.max(2.0, raw));
	}
	const raw = 6 * Math.exp(-3.5 * Math.abs(s + 0.05));
	return Math.min(7.5, Math.max(0.7, raw));
}

function formatClockHHmm(timestampMs: number): string {
	const d = new Date(timestampMs);
	const hh = String(d.getHours()).padStart(2, "0");
	const mm = String(d.getMinutes()).padStart(2, "0");
	return `${hh}:${mm}`;
}

function detectProminentPeaks(
	points: readonly NavTrackPoint[],
	cumAscentM: readonly number[],
	minProminenceM = 20,
): PeakEntry[] {
	const n = points.length;
	if (n < 2) return [];

	const peaks: PeakEntry[] = [];

	let i = 1;
	while (i < n) {
		// Group flat plateau runs as a single local maximum candidate.
		let j = i;
		while (j + 1 < n && points[j + 1].ele === points[i].ele) {
			j++;
		}
		const higherThanLeft = points[i].ele > points[i - 1].ele;
		const higherThanRight = j === n - 1 ? true : points[j].ele > points[j + 1].ele;

		if (higherThanLeft && higherThanRight) {
			const peakIdx = Math.floor((i + j) / 2);
			const peakEle = points[peakIdx].ele;

			let minLeft = peakEle;
			let hitHigherLeft = false;
			for (let k = i - 1; k >= 0; k--) {
				if (points[k].ele > peakEle) {
					hitHigherLeft = true;
					break;
				}
				if (points[k].ele < minLeft) minLeft = points[k].ele;
			}

			let minRight = peakEle;
			let hitHigherRight = false;
			for (let k = j + 1; k < n; k++) {
				if (points[k].ele > peakEle) {
					hitHigherRight = true;
					break;
				}
				if (points[k].ele < minRight) minRight = points[k].ele;
			}

			let prominence: number;
			if (hitHigherLeft && hitHigherRight) {
				prominence = peakEle - Math.max(minLeft, minRight);
			} else if (hitHigherLeft) {
				prominence = peakEle - minLeft;
			} else if (hitHigherRight) {
				prominence = peakEle - minRight;
			} else {
				prominence = peakEle - Math.min(minLeft, minRight);
			}

			if (prominence >= minProminenceM) {
				peaks.push({
					distanceM: points[peakIdx].distanceM,
					ele: peakEle,
					cumAscentM: cumAscentM[peakIdx],
				});
			}
		}

		i = j + 1;
	}

	return peaks;
}

/**
 * Dynamic hiking/cycling ETA and elevation-remaining calculator using Tobler's speed model
 * and an EMA pace factor updated from observed progress.
 */
export class EtaCalculator {
	private readonly points: NavTrackPoint[];
	private readonly distances: number[];
	private readonly cumBaseSeconds: number[];
	private readonly cumAscentM: number[];
	private readonly cumDescentM: number[];
	private readonly peaks: PeakEntry[];
	private readonly totalDistanceM: number;

	private paceFactor = 1.0;
	private lastAnchorAlongM: number | null = null;
	private lastAnchorTsMs: number | null = null;

	constructor(points: NavTrackPoint[], options?: EtaCalculatorOptions) {
		this.points = points;
		const isCycling = options?.isCycling ?? false;
		const n = points.length;

		this.distances = new Array<number>(n);
		this.cumBaseSeconds = new Array<number>(n);
		this.cumAscentM = new Array<number>(n);
		this.cumDescentM = new Array<number>(n);

		if (n > 0) {
			this.distances[0] = points[0].distanceM;
			this.cumBaseSeconds[0] = 0;
			this.cumAscentM[0] = 0;
			this.cumDescentM[0] = 0;
		}

		for (let i = 1; i < n; i++) {
			const ds = Math.max(0, points[i].distanceM - points[i - 1].distanceM);
			const dEle = points[i].ele - points[i - 1].ele;
			const slope = ds > 0.1 ? dEle / ds : 0;
			const speedMs = (toblerHikingSpeedKmh(slope, isCycling) * 1000) / 3600;

			this.distances[i] = points[i].distanceM;
			this.cumBaseSeconds[i] = this.cumBaseSeconds[i - 1] + (ds > 0 ? ds / speedMs : 0);
			this.cumAscentM[i] = this.cumAscentM[i - 1] + (dEle > 0 ? dEle : 0);
			this.cumDescentM[i] = this.cumDescentM[i - 1] + (dEle < 0 ? -dEle : 0);
		}

		this.totalDistanceM = n > 0 ? this.distances[n - 1] : 0;
		this.peaks = detectProminentPeaks(points, this.cumAscentM, 20);
	}

	recordProgress(alongTrackM: number, timestampMs: number): void {
		if (!Number.isFinite(alongTrackM) || !Number.isFinite(timestampMs) || this.points.length < 2) {
			return;
		}

		const clampedAlong = Math.min(this.totalDistanceM, Math.max(0, alongTrackM));
		if (this.lastAnchorAlongM === null || this.lastAnchorTsMs === null) {
			this.lastAnchorAlongM = clampedAlong;
			this.lastAnchorTsMs = timestampMs;
			return;
		}

		const deltaM = clampedAlong - this.lastAnchorAlongM;
		const deltaSec = (timestampMs - this.lastAnchorTsMs) / 1000;

		if (deltaSec <= 0) {
			return;
		}

		if (deltaM < -30) {
			// Significant backward jump (e.g. trail reversed or manual reposition): re-anchor cleanly.
			this.lastAnchorAlongM = clampedAlong;
			this.lastAnchorTsMs = timestampMs;
			return;
		}

		if (deltaM < 15) {
			return;
		}

		const expectedSec =
			this.interpolateCumulative(this.cumBaseSeconds, clampedAlong) -
			this.interpolateCumulative(this.cumBaseSeconds, this.lastAnchorAlongM);

		if (expectedSec > 0.5) {
			const observedFactor = Math.min(1.85, Math.max(0.55, deltaSec / expectedSec));
			this.paceFactor = Math.min(1.85, Math.max(0.55, 0.2 * observedFactor + 0.8 * this.paceFactor));
		}

		this.lastAnchorAlongM = clampedAlong;
		this.lastAnchorTsMs = timestampMs;
	}

	compute(
		alongTrackM: number,
		nowMs?: number,
		offTrailExtra?: OffTrailExtra | null,
	): EtaSnapshot {
		const refNow = nowMs !== undefined && Number.isFinite(nowMs) ? nowMs : Date.now();

		if (this.points.length === 0) {
			return {
				remainingDistanceM: offTrailExtra ? Math.max(0, offTrailExtra.distanceM) : 0,
				remainingSeconds: offTrailExtra ? Math.max(0, offTrailExtra.durationSec) : 0,
				arrivalTimeFormatted: formatClockHHmm(
					refNow + Math.round(offTrailExtra ? Math.max(0, offTrailExtra.durationSec) : 0) * 1000,
				),
				remainingAscentM: offTrailExtra ? Math.max(0, offTrailExtra.ascentM) : 0,
				remainingDescentM: 0,
				currentEleM: 0,
				currentGradePct: 0,
				progressRatio: 1,
				nextPeak: null,
			};
		}

		const posAlong = Math.min(this.totalDistanceM, Math.max(0, alongTrackM));
		const currentInterp = interpolateTrackAtDistance(this.points, posAlong);

		const trailAnchor = offTrailExtra
			? Math.min(this.totalDistanceM, Math.max(0, offTrailExtra.rejoinAlongTrackM))
			: posAlong;

		const totalBaseSec = this.cumBaseSeconds[this.cumBaseSeconds.length - 1];
		const totalAscent = this.cumAscentM[this.cumAscentM.length - 1];
		const totalDescent = this.cumDescentM[this.cumDescentM.length - 1];

		const baseSecAtAnchor = this.interpolateCumulative(this.cumBaseSeconds, trailAnchor);
		const ascentAtAnchor = this.interpolateCumulative(this.cumAscentM, trailAnchor);
		const descentAtAnchor = this.interpolateCumulative(this.cumDescentM, trailAnchor);

		const trailRemDist = Math.max(0, this.totalDistanceM - trailAnchor);
		const trailRemSec = Math.max(0, totalBaseSec - baseSecAtAnchor) * this.paceFactor;
		const trailRemAscent = Math.max(0, totalAscent - ascentAtAnchor);
		const trailRemDescent = Math.max(0, totalDescent - descentAtAnchor);

		const remainingDistanceM =
			trailRemDist + (offTrailExtra ? Math.max(0, offTrailExtra.distanceM) : 0);
		const remainingSeconds =
			trailRemSec + (offTrailExtra ? Math.max(0, offTrailExtra.durationSec) : 0);
		const remainingAscentM =
			trailRemAscent + (offTrailExtra ? Math.max(0, offTrailExtra.ascentM) : 0);
		const remainingDescentM = trailRemDescent;

		const progressRatio =
			this.totalDistanceM > 0 ? Math.min(1, Math.max(0, posAlong / this.totalDistanceM)) : 1;

		let nextPeak: EtaSnapshot["nextPeak"] = null;
		const ascentAtPos = this.interpolateCumulative(this.cumAscentM, posAlong);
		for (const peak of this.peaks) {
			if (peak.distanceM > posAlong + 5) {
				nextPeak = {
					ele: peak.ele,
					distanceAheadM: peak.distanceM - posAlong,
					gainAheadM: Math.max(0, peak.cumAscentM - ascentAtPos),
				};
				break;
			}
		}

		const arrivalTimeFormatted = formatClockHHmm(refNow + Math.round(remainingSeconds) * 1000);

		return {
			remainingDistanceM,
			remainingSeconds,
			arrivalTimeFormatted,
			remainingAscentM,
			remainingDescentM,
			currentEleM: currentInterp.ele,
			currentGradePct: currentInterp.gradePct,
			progressRatio,
			nextPeak,
		};
	}

	private interpolateCumulative(values: readonly number[], alongM: number): number {
		const n = this.distances.length;
		if (n === 0) return 0;
		if (n === 1 || alongM <= this.distances[0]) return values[0];
		if (alongM >= this.distances[n - 1]) return values[n - 1];

		let idx = lowerBound(this.distances, alongM);
		if (idx <= 0) return values[0];
		if (idx >= n) return values[n - 1];

		const d0 = this.distances[idx - 1];
		const d1 = this.distances[idx];
		const span = d1 - d0;
		const t = span > 1e-6 ? Math.min(1, Math.max(0, (alongM - d0) / span)) : 0;
		return values[idx - 1] + t * (values[idx] - values[idx - 1]);
	}
}
