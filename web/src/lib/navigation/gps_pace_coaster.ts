import { toblerHikingSpeedKmh } from "./eta_calculator";
import { interpolateTrackAtDistance } from "./geo_math";
import type {
	CoastingSnapshot,
	GpsSignalState,
	NavTrackPoint,
	PaceCoasterFixInput,
	PaceCoasterIngestResult,
} from "./types";

const MIN_COAST_GAP_MS = 6_000;
const MAX_COAST_GAP_MS = 180_000;

/**
 * Classifies GNSS quality (`good | cooperative | degraded | coasting`), suppresses false
 * off-trail triggers under forest canopy (`accuracy > 25m`), and coasts along the trail
 * geometry at `1 Hz` using Tobler's speed model during temporary signal dropouts (`6s..180s`).
 */
export class GpsPaceCoaster {
	private points: NavTrackPoint[];
	private isCycling: boolean;
	private totalDistanceM: number;

	private lastFixMs: number | null = null;
	private lastStepMs: number | null = null;
	private effectiveAlongM = 0;
	private hasInitialFix = false;
	private wasCoasting = false;
	private reconcileFixesRemaining = 0;
	private genuinelyOffTrail = false;

	constructor(points: NavTrackPoint[], options?: { isCycling?: boolean }) {
		this.points = points;
		this.isCycling = options?.isCycling ?? false;
		this.totalDistanceM = points.length > 0 ? points[points.length - 1].distanceM : 0;
	}

	setTrack(points: NavTrackPoint[], options?: { isCycling?: boolean }): void {
		this.points = points;
		if (options?.isCycling !== undefined) {
			this.isCycling = options.isCycling;
		}
		this.totalDistanceM = points.length > 0 ? points[points.length - 1].distanceM : 0;
		this.reset();
	}

	reset(): void {
		this.lastFixMs = null;
		this.lastStepMs = null;
		this.effectiveAlongM = 0;
		this.hasInitialFix = false;
		this.wasCoasting = false;
		this.reconcileFixesRemaining = 0;
		this.genuinelyOffTrail = false;
	}

	ingestFix(input: PaceCoasterFixInput): PaceCoasterIngestResult {
		const nowMs =
			input.nowMs !== undefined && Number.isFinite(input.nowMs) ? input.nowMs : Date.now();
		const accuracy =
			Number.isFinite(input.accuracy) && input.accuracy > 0 ? input.accuracy : 15;
		const matchedAlongM = this.clampAlong(input.matchedAlongM);
		const crossTrackM = Number.isFinite(input.crossTrackM) ? Math.max(0, input.crossTrackM) : 0;
		const isPaused = input.isPaused ?? false;
		const paceFactor = this.sanitizePaceFactor(input.paceFactor);
		const fusedSource = input.fusedSource ?? "self";

		const inCanopyCorridor =
			accuracy > 25 && crossTrackM <= Math.max(95, 2.2 * accuracy);

		let signalState: GpsSignalState;
		let suppressOffTrail = false;

		if (fusedSource !== "self") {
			signalState = "cooperative";
			suppressOffTrail = inCanopyCorridor;
		} else if (accuracy > 25) {
			signalState = "degraded";
			suppressOffTrail = inCanopyCorridor;
		} else {
			signalState = "good";
			suppressOffTrail = false;
		}

		const prevAlongM = this.effectiveAlongM;
		let nextAlongM = matchedAlongM;

		if (!this.hasInitialFix || this.points.length < 2) {
			nextAlongM = matchedAlongM;
			this.hasInitialFix = true;
		} else if (suppressOffTrail) {
			const dtSec =
				this.lastStepMs !== null && !isPaused
					? Math.min(180, Math.max(0, (nowMs - this.lastStepMs) / 1000))
					: 0;
			const expectedAlongM =
				dtSec > 0 ? this.advanceAlongByTime(prevAlongM, dtSec, paceFactor) : prevAlongM;
			nextAlongM = this.clampAlong(
				Math.max(prevAlongM, 0.35 * matchedAlongM + 0.65 * expectedAlongM),
			);
		} else if (this.wasCoasting || this.reconcileFixesRemaining > 0) {
			if (this.wasCoasting) {
				this.reconcileFixesRemaining = 2;
				this.wasCoasting = false;
			}
			const backwardDiff = prevAlongM - matchedAlongM;
			if (backwardDiff >= 0 && backwardDiff <= Math.max(15, accuracy)) {
				nextAlongM = prevAlongM;
			} else if (matchedAlongM > prevAlongM && this.reconcileFixesRemaining > 0) {
				nextAlongM = this.clampAlong(0.5 * prevAlongM + 0.5 * matchedAlongM);
			} else {
				nextAlongM = matchedAlongM;
			}
			this.reconcileFixesRemaining = Math.max(0, this.reconcileFixesRemaining - 1);
		}

		this.effectiveAlongM = nextAlongM;
		this.lastFixMs = nowMs;
		this.lastStepMs = nowMs;
		this.genuinelyOffTrail =
			!suppressOffTrail && crossTrackM > Math.max(35, Math.min(140, 1.5 * accuracy));

		const interp = interpolateTrackAtDistance(this.points, nextAlongM);
		return {
			lat: suppressOffTrail && this.points.length > 0 ? interp.lat : input.lat,
			lon: suppressOffTrail && this.points.length > 0 ? interp.lon : input.lon,
			ele: interp.ele,
			gradePct: interp.gradePct,
			effectiveAlongM: nextAlongM,
			signalState,
			suppressOffTrail,
		};
	}

	tickCoasting(
		nowMs: number = Date.now(),
		paceFactor = 1.0,
		isPaused = false,
	): CoastingSnapshot | null {
		if (!this.hasInitialFix || this.lastFixMs === null || this.points.length < 2) {
			return null;
		}
		if (isPaused) {
			this.lastStepMs = nowMs;
			return null;
		}
		if (this.genuinelyOffTrail) {
			return null;
		}

		const sinceLastFixMs = nowMs - this.lastFixMs;
		if (sinceLastFixMs < MIN_COAST_GAP_MS || sinceLastFixMs > MAX_COAST_GAP_MS) {
			return null;
		}

		const stepOriginMs = this.lastStepMs ?? this.lastFixMs;
		const dtSec = Math.min(180, Math.max(0, (nowMs - stepOriginMs) / 1000));
		const effPace = this.sanitizePaceFactor(paceFactor);

		if (dtSec > 0) {
			this.effectiveAlongM = this.advanceAlongByTime(this.effectiveAlongM, dtSec, effPace);
			this.lastStepMs = nowMs;
		}
		this.wasCoasting = true;

		const interp = interpolateTrackAtDistance(this.points, this.effectiveAlongM);
		return {
			lat: interp.lat,
			lon: interp.lon,
			ele: interp.ele,
			gradePct: interp.gradePct,
			effectiveAlongM: this.effectiveAlongM,
			signalState: "coasting",
			suppressOffTrail: true,
		};
	}

	private advanceAlongByTime(startAlongM: number, dtSec: number, paceFactor: number): number {
		if (this.points.length < 2 || dtSec <= 0) {
			return this.clampAlong(startAlongM);
		}
		const interp = interpolateTrackAtDistance(this.points, startAlongM);
		const slopeRatio = interp.gradePct / 100;
		const speedKmh = toblerHikingSpeedKmh(slopeRatio, this.isCycling);
		const speedMps = (speedKmh * 1000) / 3600 / paceFactor;
		return this.clampAlong(startAlongM + dtSec * speedMps);
	}

	private clampAlong(alongM: number): number {
		if (!Number.isFinite(alongM)) return 0;
		return Math.min(this.totalDistanceM, Math.max(0, alongM));
	}

	private sanitizePaceFactor(paceFactor?: number): number {
		if (paceFactor === undefined || !Number.isFinite(paceFactor) || paceFactor <= 0) {
			return 1.0;
		}
		return Math.min(2.5, Math.max(0.4, paceFactor));
	}
}
