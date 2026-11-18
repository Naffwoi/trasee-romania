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
export { NavTerrainClient } from "./nav_terrain_client";
export {
	packTrackPoints,
	unpackTrackPoints,
	reversePackedTrackPoints,
	parseGpxXmlFastToPackedTrack,
} from "./nav_terrain_codec";
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
export {
	getSunPosition,
	getSunTimes,
	astroRefractionRad,
	type SunPosition,
	type SunTimes,
} from "./sun_calc";
export {
	avalancheSlopeColorRgba,
	sampleSlopeAndAspect,
	renderAvalancheSlopeTileRgba,
	renderCastShadowTileRgba,
	type SlopeAspectSample,
} from "./slope_aspect";
export {
	CURVATURE_REFRACTION_COEFF,
	computeHorizonAngleDeg,
	computeLocalRidgeSunset,
	computeTrailSolarForecast,
	type LightSafetyStatus,
	type RidgeSunsetResult,
	type TrailSolarForecast,
} from "./ridge_sunset_calculator";
export {
	OfflinePeakFinder,
	type PeakEntryDto,
	type VisiblePeakResult,
	type HorizonPanorama,
} from "./peak_finder_engine";
