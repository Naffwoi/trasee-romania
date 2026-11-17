export interface NavTrackPoint {
	lat: number;
	lon: number;
	ele: number;
	distanceM: number;
	gradePct: number;
}

export interface NavMatchResult {
	isOffTrail: boolean;
	alongTrackMeters: number;
	crossTrackMeters: number;
	matchedLat: number;
	matchedLon: number;
	matchedEle: number;
	currentGradePct: number;
	segmentIndex: number;
	consecutiveOffTrailFixes: number;
}

export interface NavManeuver {
	instruction: string;
	length: number; // km to next maneuver
	begin_shape_index: number;
	bearing: number;
	type: number; // 1=start, 4=dest, 8=continue/grade, 9=slightRight, 10=right, 11=sharpRight, 14=sharpLeft, 15=left, 16=slightLeft
}

export interface EtaSnapshot {
	remainingDistanceM: number;
	remainingSeconds: number;
	arrivalTimeFormatted: string; // "HH:mm"
	remainingAscentM: number;
	remainingDescentM: number;
	currentEleM: number;
	currentGradePct: number;
	progressRatio: number; // 0..1
	nextPeak: { ele: number; distanceAheadM: number; gainAheadM: number } | null;
}

export type OffTrailMode = "min-climb" | "shortest-safe";

export interface OffTrailPoint {
	lat: number;
	lon: number;
	ele: number;
	distanceM: number;
	gradePct: number;
}

export interface OffTrailRerouteResult {
	mode: OffTrailMode;
	points: OffTrailPoint[];
	rejoinLat: number;
	rejoinLon: number;
	rejoinAlongTrackM: number;
	rejoinEleM: number;
	distanceM: number;
	estimatedSeconds: number;
	ascentM: number;
	descentM: number;
	maxSlopeDeg: number;
	avoidedSteepHazard: boolean;
	initialBearingDeg: number;
	instruction: string;
	slopeAdvice: string;
}

export interface NavGpsFix {
	lat: number;
	lon: number;
	accuracy?: number | null;
	heading?: number | null;
	speed?: number | null;
}

export interface RouteMapMatcherOptions {
	offTrailThresholdMeters?: number;
	offTrailConfirmFixes?: number;
	rejoinThresholdMeters?: number;
}

export interface EtaCalculatorOptions {
	isCycling?: boolean;
}

export interface OffTrailExtra {
	distanceM: number;
	durationSec: number;
	ascentM: number;
	rejoinAlongTrackM: number;
}

export interface SegmentProjection {
	t: number;
	crossTrackMeters: number;
	projectedLat: number;
	projectedLon: number;
	segmentLengthMeters: number;
	bearingDegrees: number;
}
