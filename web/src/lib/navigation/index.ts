export type {
	NavTrackPoint,
	NavMatchResult,
	NavManeuver,
	EtaSnapshot,
	OffTrailMode,
	OffTrailPoint,
	OffTrailRerouteResult,
	NavGpsFix,
	NavGpsFixWithMeta,
	GpsSignalState,
	PeerGpsObservation,
	FusedGpsResult,
	ObstaclePolygon,
	PreferredCorridor,
	PaceCoasterFixInput,
	PaceCoasterIngestResult,
	CoastingSnapshot,
} from "./types";

export { FAR_PREVIEW_THRESHOLD_METERS } from "./types";

export {
	haversineMeters,
	bearingDegrees,
	normalizeBearingDelta,
	cardinalDirection,
	extractRawTrackPoints,
	reverseTrackPoints,
	interpolateTrackAtDistance,
} from "./geo_math";

export { RouteMapMatcher } from "./route_map_matcher";
export { EtaCalculator, toblerHikingSpeedKmh } from "./eta_calculator";
export { synthesizeTrailManeuvers } from "./trail_maneuver_synthesizer";
export { DemTileGrid } from "./dem_tile_grid";
export {
	computeOffTrailReroute,
	computeLocalCurvedConnector,
	computeDirectRescueRoute,
	type DirectRescueRouteResult,
} from "./off_trail_router";
export { fuseCooperativeGps, findCoLocatedPeerIds } from "./cooperative_gps_fusion";
export { GpsPaceCoaster } from "./gps_pace_coaster";
export {
	extractMapLibreObstacles,
	computeHybridOffTrailReroute,
	computeValhallaAccessRoute,
	type MapLibreFeatureQueryable,
	type HybridOffTrailRerouteParams,
} from "./hybrid_rejoin_router";
