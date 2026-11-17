import {
	bearingDegrees,
	haversineMeters,
	interpolateTrackAtDistance,
	lowerBound,
	normalizeBearingDelta,
	projectOntoSegment,
} from "./geo_math";
import type {
	NavGpsFix,
	NavMatchResult,
	NavTrackPoint,
	RouteMapMatcherOptions,
} from "./types";

interface Hypothesis {
	segmentIndex: number;
	alongTrackMeters: number;
	score: number;
}

interface Candidate {
	segmentIndex: number;
	alongTrackMeters: number;
	crossTrackMeters: number;
	bearingDegrees: number;
}

interface GlobalNearestMatch {
	segmentIndex: number;
	alongTrackMeters: number;
	crossTrackMeters: number;
	matchedLat: number;
	matchedLon: number;
	matchedEle: number;
	currentGradePct: number;
}

function logGaussian(x: number, sigma: number): number {
	const s = sigma <= 0 ? 1e-6 : sigma;
	return -0.5 * (x * x) / (s * s);
}

/**
 * Online Viterbi HMM map matcher with loop/hairpin protection and off-trail hysteresis.
 */
export class RouteMapMatcher {
	private readonly points: NavTrackPoint[];
	private readonly cumulative: number[];
	private readonly totalLength: number;

	private readonly offTrailThresholdMeters: number;
	private readonly offTrailConfirmFixes: number;
	private readonly rejoinThresholdMeters: number;

	private readonly accuracyFloor = 8;
	private readonly transitionSigma = 12;
	private readonly headingSigma = 35;
	private readonly topK = 3;
	private readonly coldStartLookAhead = 1000;
	private readonly warmWindowFactor = 6;
	private readonly warmWindowFloor = 25;
	private readonly warmWindowCap = 180;
	private readonly warmWindowCapSpeedCoeff = 20;
	private readonly backMargin = 15;
	private readonly movingSpeedThreshold = 0.3;
	private readonly recoveryLookAhead = 600;
	private readonly recoveryTransitionSigmaMultiplier = 20;
	private readonly commitConfirmFixes = 3;

	private hypotheses: Hypothesis[] = [];
	private lastPos: { lat: number; lon: number } | null = null;
	private committedAtd = 0;
	private committedSegmentIndex = 0;
	private pendingJumpAtd: number | null = null;
	private pendingJumpFixes = 0;
	private isOffTrailState = false;
	private consecutiveOffTrailFixesCount = 0;

	constructor(points: NavTrackPoint[], options?: RouteMapMatcherOptions) {
		this.points = points;
		this.cumulative = points.map((p) => p.distanceM);
		this.totalLength = this.cumulative.length > 0 ? this.cumulative[this.cumulative.length - 1] : 0;
		this.offTrailThresholdMeters = options?.offTrailThresholdMeters ?? 35;
		this.offTrailConfirmFixes = Math.max(1, options?.offTrailConfirmFixes ?? 3);
		this.rejoinThresholdMeters = options?.rejoinThresholdMeters ?? 22;
	}

	update(fix: NavGpsFix): NavMatchResult {
		if (this.points.length === 0) {
			return {
				isOffTrail: false,
				alongTrackMeters: 0,
				crossTrackMeters: 0,
				matchedLat: fix.lat,
				matchedLon: fix.lon,
				matchedEle: 0,
				currentGradePct: 0,
				segmentIndex: 0,
				consecutiveOffTrailFixes: 0,
			};
		}

		if (this.points.length === 1) {
			const p = this.points[0];
			const dist = haversineMeters(fix.lat, fix.lon, p.lat, p.lon);
			const threshold = this.computeThreshold(fix.accuracy);
			this.updateSinglePointOffTrail(dist, threshold);
			return {
				isOffTrail: this.isOffTrailState,
				alongTrackMeters: 0,
				crossTrackMeters: dist,
				matchedLat: p.lat,
				matchedLon: p.lon,
				matchedEle: p.ele,
				currentGradePct: p.gradePct,
				segmentIndex: 0,
				consecutiveOffTrailFixes: this.consecutiveOffTrailFixesCount,
			};
		}

		const isFirstFix = this.lastPos === null;
		const groundDistance = isFirstFix
			? 0
			: haversineMeters(this.lastPos!.lat, this.lastPos!.lon, fix.lat, fix.lon);
		this.lastPos = { lat: fix.lat, lon: fix.lon };

		const threshold = this.computeThreshold(fix.accuracy);
		const globalNearest = this.findGlobalNearest(fix.lat, fix.lon);

		if (this.isOffTrailState) {
			if (globalNearest.crossTrackMeters <= this.rejoinThresholdMeters) {
				this.snapToGlobalNearest(globalNearest);
				this.isOffTrailState = false;
				this.consecutiveOffTrailFixesCount = 0;
				return {
					isOffTrail: false,
					alongTrackMeters: globalNearest.alongTrackMeters,
					crossTrackMeters: globalNearest.crossTrackMeters,
					matchedLat: globalNearest.matchedLat,
					matchedLon: globalNearest.matchedLon,
					matchedEle: globalNearest.matchedEle,
					currentGradePct: globalNearest.currentGradePct,
					segmentIndex: globalNearest.segmentIndex,
					consecutiveOffTrailFixes: 0,
				};
			}

			this.consecutiveOffTrailFixesCount += 1;
			const held = interpolateTrackAtDistance(this.points, this.committedAtd);
			return {
				isOffTrail: true,
				alongTrackMeters: this.committedAtd,
				crossTrackMeters: globalNearest.crossTrackMeters,
				matchedLat: held.lat,
				matchedLon: held.lon,
				matchedEle: held.ele,
				currentGradePct: held.gradePct,
				segmentIndex: this.committedSegmentIndex,
				consecutiveOffTrailFixes: this.consecutiveOffTrailFixesCount,
			};
		}

		const sources: Hypothesis[] =
			this.hypotheses.length > 0
				? this.hypotheses
				: [{ segmentIndex: 0, alongTrackMeters: 0, score: 0 }];

		let baseAtd = Infinity;
		let maxSourceAtd = -Infinity;
		for (const h of sources) {
			if (h.alongTrackMeters < baseAtd) baseAtd = h.alongTrackMeters;
			if (h.alongTrackMeters > maxSourceAtd) maxSourceAtd = h.alongTrackMeters;
		}

		const effSpeed = Math.max(0, fix.speed ?? 0);
		const effectiveWarmWindowCap =
			this.warmWindowCap + this.warmWindowCapSpeedCoeff * effSpeed;
		const plausibleStep = Math.max(
			this.warmWindowFloor,
			groundDistance * this.warmWindowFactor,
		);

		let candidates: Candidate[];
		let effectiveTransitionSigma = this.transitionSigma;

		if (isFirstFix) {
			const coldMax = Math.min(this.totalLength, baseAtd + this.coldStartLookAhead);
			const coldCandidates = this.candidatesInWindow(fix.lat, fix.lon, 0, coldMax);
			const bestColdCross = this.minCrossTrack(coldCandidates);
			if (bestColdCross <= threshold) {
				candidates = coldCandidates;
			} else {
				// Allow mid-trail starts while still preferring trailhead when near start.
				candidates = this.candidatesInWindow(fix.lat, fix.lon, 0, this.totalLength);
			}
		} else {
			const normalWindow = Math.min(
				effectiveWarmWindowCap,
				Math.max(this.warmWindowFloor, groundDistance * this.warmWindowFactor),
			);
			const normalMin = Math.max(0, baseAtd - this.backMargin);
			const normalMax = Math.min(this.totalLength, maxSourceAtd + normalWindow);
			const normalCandidates = this.candidatesInWindow(fix.lat, fix.lon, normalMin, normalMax);
			const bestNormalCross = this.minCrossTrack(normalCandidates);

			if (bestNormalCross > threshold) {
				if (bestNormalCross > 90 && globalNearest.crossTrackMeters <= this.rejoinThresholdMeters) {
					// Large single-fix jump along the trail (e.g. simulated teleport on-trail).
					this.snapToGlobalNearest(globalNearest);
					this.consecutiveOffTrailFixesCount = 0;
					this.isOffTrailState = false;
					return {
						isOffTrail: false,
						alongTrackMeters: globalNearest.alongTrackMeters,
						crossTrackMeters: globalNearest.crossTrackMeters,
						matchedLat: globalNearest.matchedLat,
						matchedLon: globalNearest.matchedLon,
						matchedEle: globalNearest.matchedEle,
						currentGradePct: globalNearest.currentGradePct,
						segmentIndex: globalNearest.segmentIndex,
						consecutiveOffTrailFixes: 0,
					};
				}

				const nextConsecutive = this.consecutiveOffTrailFixesCount + 1;
				const entersOffTrail =
					globalNearest.crossTrackMeters > 90 ||
					(globalNearest.crossTrackMeters > threshold &&
						nextConsecutive >= this.offTrailConfirmFixes);

				if (entersOffTrail) {
					this.consecutiveOffTrailFixesCount = nextConsecutive;
					this.isOffTrailState = true;
					const held = interpolateTrackAtDistance(this.points, this.committedAtd);
					return {
						isOffTrail: true,
						alongTrackMeters: this.committedAtd,
						crossTrackMeters: globalNearest.crossTrackMeters,
						matchedLat: held.lat,
						matchedLon: held.lon,
						matchedEle: held.ele,
						currentGradePct: held.gradePct,
						segmentIndex: this.committedSegmentIndex,
						consecutiveOffTrailFixes: this.consecutiveOffTrailFixesCount,
					};
				}

				this.consecutiveOffTrailFixesCount = nextConsecutive;

				if (nextConsecutive >= this.offTrailConfirmFixes) {
					const recMax = Math.min(this.totalLength, maxSourceAtd + this.recoveryLookAhead);
					candidates = this.candidatesInWindow(fix.lat, fix.lon, normalMin, recMax);
					effectiveTransitionSigma =
						this.transitionSigma * this.recoveryTransitionSigmaMultiplier;
				} else {
					candidates = normalCandidates;
				}
			} else {
				this.consecutiveOffTrailFixesCount = 0;
				candidates = normalCandidates;
			}
		}

		// Handle very first fix starting far off-trail.
		if (isFirstFix) {
			const bestCross = this.minCrossTrack(candidates);
			if (bestCross > 90 || (bestCross > threshold && this.offTrailConfirmFixes <= 1)) {
				this.snapToGlobalNearest(globalNearest);
				this.consecutiveOffTrailFixesCount = 1;
				this.isOffTrailState = true;
				return {
					isOffTrail: true,
					alongTrackMeters: globalNearest.alongTrackMeters,
					crossTrackMeters: globalNearest.crossTrackMeters,
					matchedLat: globalNearest.matchedLat,
					matchedLon: globalNearest.matchedLon,
					matchedEle: globalNearest.matchedEle,
					currentGradePct: globalNearest.currentGradePct,
					segmentIndex: globalNearest.segmentIndex,
					consecutiveOffTrailFixes: 1,
				};
			} else if (bestCross > threshold) {
				this.consecutiveOffTrailFixesCount = 1;
			}
		}

		const sigmaZ = Math.max(this.accuracyFloor, fix.accuracy ?? this.accuracyFloor);
		const useHeading =
			fix.heading !== null &&
			fix.heading !== undefined &&
			Number.isFinite(fix.heading) &&
			(fix.speed === null || fix.speed === undefined || fix.speed >= this.movingSpeedThreshold);

		const scored: Hypothesis[] = [];
		for (const c of candidates) {
			const headingDelta = useHeading
				? Math.abs(normalizeBearingDelta(c.bearingDegrees, fix.heading!))
				: 0;
			const emission =
				logGaussian(c.crossTrackMeters, sigmaZ) +
				(useHeading ? logGaussian(headingDelta, this.headingSigma) : 0);

			let best = -Infinity;
			if (isFirstFix) {
				best = -1e-6 * Math.abs(c.alongTrackMeters - baseAtd);
			} else {
				for (const source of sources) {
					const delta = c.alongTrackMeters - source.alongTrackMeters;
					if (delta < -this.backMargin) continue;
					const mismatch = Math.abs(delta - groundDistance);
					const transition = logGaussian(mismatch, effectiveTransitionSigma);
					const score = source.score + transition;
					if (score > best) best = score;
				}
			}
			if (best === -Infinity) continue;

			scored.push({
				segmentIndex: c.segmentIndex,
				alongTrackMeters: c.alongTrackMeters,
				score: best + emission,
			});
		}

		if (scored.length === 0) {
			const held = interpolateTrackAtDistance(this.points, this.committedAtd);
			return {
				isOffTrail: this.isOffTrailState,
				alongTrackMeters: this.committedAtd,
				crossTrackMeters: globalNearest.crossTrackMeters,
				matchedLat: held.lat,
				matchedLon: held.lon,
				matchedEle: held.ele,
				currentGradePct: held.gradePct,
				segmentIndex: this.committedSegmentIndex,
				consecutiveOffTrailFixes: this.consecutiveOffTrailFixesCount,
			};
		}

		scored.sort((a, b) => b.score - a.score);
		const globalBest = scored[0];

		const continuation = isFirstFix
			? null
			: this.findContinuation(scored, this.committedAtd, groundDistance, plausibleStep);

		let kept = scored.slice(0, this.topK);
		if (
			continuation !== null &&
			!kept.some(
				(h) =>
					h.segmentIndex === continuation.segmentIndex &&
					h.alongTrackMeters === continuation.alongTrackMeters,
			)
		) {
			kept = [...kept.slice(0, Math.max(0, this.topK - 1)), continuation];
		}

		const maxScore = Math.max(...kept.map((h) => h.score));
		this.hypotheses = kept.map((h) => ({
			segmentIndex: h.segmentIndex,
			alongTrackMeters: h.alongTrackMeters,
			score: h.score - maxScore,
		}));

		if (isFirstFix) {
			this.committedAtd = globalBest.alongTrackMeters;
			this.committedSegmentIndex = globalBest.segmentIndex;
			this.pendingJumpAtd = null;
			this.pendingJumpFixes = 0;
		} else {
			this.gateCommit(globalBest, plausibleStep, groundDistance);
		}

		const matched = interpolateTrackAtDistance(this.points, this.committedAtd);
		const crossTrack = haversineMeters(fix.lat, fix.lon, matched.lat, matched.lon);

		return {
			isOffTrail: this.isOffTrailState,
			alongTrackMeters: this.committedAtd,
			crossTrackMeters: crossTrack,
			matchedLat: matched.lat,
			matchedLon: matched.lon,
			matchedEle: matched.ele,
			currentGradePct: matched.gradePct,
			segmentIndex: this.committedSegmentIndex,
			consecutiveOffTrailFixes: this.consecutiveOffTrailFixesCount,
		};
	}

	private computeThreshold(accuracy?: number | null): number {
		const acc = accuracy !== null && accuracy !== undefined && Number.isFinite(accuracy)
			? Math.max(0, accuracy)
			: 15;
		return Math.max(this.offTrailThresholdMeters, Math.min(75, 1.5 * acc));
	}

	private updateSinglePointOffTrail(dist: number, threshold: number): void {
		if (this.isOffTrailState) {
			if (dist <= this.rejoinThresholdMeters) {
				this.isOffTrailState = false;
				this.consecutiveOffTrailFixesCount = 0;
			} else {
				this.consecutiveOffTrailFixesCount += 1;
			}
			return;
		}
		if (dist > 90) {
			this.consecutiveOffTrailFixesCount += 1;
			this.isOffTrailState = true;
		} else if (dist > threshold) {
			this.consecutiveOffTrailFixesCount += 1;
			if (this.consecutiveOffTrailFixesCount >= this.offTrailConfirmFixes) {
				this.isOffTrailState = true;
			}
		} else {
			this.consecutiveOffTrailFixesCount = 0;
		}
	}

	private snapToGlobalNearest(nearest: GlobalNearestMatch): void {
		this.committedAtd = nearest.alongTrackMeters;
		this.committedSegmentIndex = nearest.segmentIndex;
		this.hypotheses = [
			{
				segmentIndex: nearest.segmentIndex,
				alongTrackMeters: nearest.alongTrackMeters,
				score: 0,
			},
		];
		this.pendingJumpAtd = null;
		this.pendingJumpFixes = 0;
	}

	private minCrossTrack(candidates: Candidate[]): number {
		let best = Infinity;
		for (const c of candidates) {
			if (c.crossTrackMeters < best) best = c.crossTrackMeters;
		}
		return best;
	}

	private findGlobalNearest(lat: number, lon: number): GlobalNearestMatch {
		let bestCross = Infinity;
		let bestSeg = 0;
		let bestAtd = 0;
		let bestLat = this.points[0].lat;
		let bestLon = this.points[0].lon;
		let bestEle = this.points[0].ele;
		let bestGrade = this.points[0].gradePct;

		for (let i = 0; i < this.points.length - 1; i++) {
			const a = this.points[i];
			const b = this.points[i + 1];
			const proj = projectOntoSegment(lat, lon, a.lat, a.lon, b.lat, b.lon);
			const segLen = this.cumulative[i + 1] - this.cumulative[i];
			const atd = this.cumulative[i] + proj.t * segLen;

			const isStrictlyBetter = proj.crossTrackMeters < bestCross - 1e-3;
			const isTieCloserToCommitted =
				Math.abs(proj.crossTrackMeters - bestCross) <= 1e-3 &&
				Math.abs(atd - this.committedAtd) < Math.abs(bestAtd - this.committedAtd);

			if (isStrictlyBetter || isTieCloserToCommitted) {
				bestCross = proj.crossTrackMeters;
				bestSeg = i;
				bestAtd = atd;
				bestLat = proj.projectedLat;
				bestLon = proj.projectedLon;
				bestEle = a.ele + proj.t * (b.ele - a.ele);
				bestGrade = a.gradePct + proj.t * (b.gradePct - a.gradePct);
			}
		}

		return {
			segmentIndex: bestSeg,
			alongTrackMeters: bestAtd,
			crossTrackMeters: bestCross,
			matchedLat: bestLat,
			matchedLon: bestLon,
			matchedEle: bestEle,
			currentGradePct: bestGrade,
		};
	}

	private gateCommit(
		globalBest: Hypothesis,
		plausibleStep: number,
		groundDistance: number,
	): void {
		const advance = globalBest.alongTrackMeters - this.committedAtd;
		if (advance <= plausibleStep) {
			this.committedAtd = globalBest.alongTrackMeters;
			this.committedSegmentIndex = globalBest.segmentIndex;
			this.pendingJumpAtd = null;
			this.pendingJumpFixes = 0;
			return;
		}

		const sameJump =
			this.pendingJumpAtd !== null &&
			Math.abs(globalBest.alongTrackMeters - this.pendingJumpAtd) <= plausibleStep;
		this.pendingJumpAtd = globalBest.alongTrackMeters;
		this.pendingJumpFixes = sameJump ? this.pendingJumpFixes + 1 : 1;

		if (this.pendingJumpFixes >= this.commitConfirmFixes) {
			this.committedAtd = globalBest.alongTrackMeters;
			this.committedSegmentIndex = globalBest.segmentIndex;
			this.pendingJumpAtd = null;
			this.pendingJumpFixes = 0;
		} else {
			this.committedAtd = Math.min(
				globalBest.alongTrackMeters,
				this.committedAtd + groundDistance,
			);
			this.committedSegmentIndex = this.shapeIndexForAlongTrack(this.committedAtd);
		}
	}

	private findContinuation(
		scored: Hypothesis[],
		committedAtd: number,
		groundDistance: number,
		plausibleStep: number,
	): Hypothesis | null {
		const target = committedAtd + groundDistance;
		let bestMatch: Hypothesis | null = null;
		let bestDistance = Infinity;
		for (const h of scored) {
			if (h.alongTrackMeters - committedAtd > plausibleStep) continue;
			const d = Math.abs(h.alongTrackMeters - target);
			if (d < bestDistance) {
				bestDistance = d;
				bestMatch = h;
			}
		}
		return bestMatch;
	}

	private shapeIndexForAlongTrack(atd: number): number {
		let idx = lowerBound(this.cumulative, atd);
		if (idx > 0) idx -= 1;
		return Math.min(this.points.length - 2, Math.max(0, idx));
	}

	private candidatesInWindow(
		lat: number,
		lon: number,
		minAtd: number,
		maxAtd: number,
	): Candidate[] {
		let start = lowerBound(this.cumulative, minAtd);
		if (start > 0) start -= 1;
		start = Math.min(this.points.length - 2, Math.max(0, start));

		const candidates: Candidate[] = [];
		for (let i = start; i < this.points.length - 1; i++) {
			if (this.cumulative[i] > maxAtd) break;
			if (this.cumulative[i + 1] < minAtd) continue;

			const a = this.points[i];
			const b = this.points[i + 1];
			const proj = projectOntoSegment(lat, lon, a.lat, a.lon, b.lat, b.lon);
			const segLen = this.cumulative[i + 1] - this.cumulative[i];
			const atd = this.cumulative[i] + proj.t * segLen;

			candidates.push({
				segmentIndex: i,
				alongTrackMeters: atd,
				crossTrackMeters: proj.crossTrackMeters,
				bearingDegrees:
					proj.segmentLengthMeters > 1e-3
						? proj.bearingDegrees
						: bearingDegrees(a.lat, a.lon, b.lat, b.lon),
			});
		}

		return candidates;
	}
}
