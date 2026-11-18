import { DemTileGrid } from "./dem_tile_grid";
import {
	packOffTrailPoints,
	parseGpxXmlFastToPackedTrack,
	unpackTrackPoints,
} from "./nav_terrain_codec";
import {
	computeDirectRescueRoute,
	computeLocalCurvedConnector,
	computeOffTrailReroute,
	createElevationSampler,
	type DirectRescueRouteResult,
} from "./off_trail_router";
import type {
	NavTrackPoint,
	ObstaclePolygon,
	OffTrailMode,
	OffTrailRerouteResult,
	PreferredCorridor,
} from "./types";

export type WorkerRequestMessage =
	| {
			type: "SET_TRACK";
			reqId: number;
			packedTrack: Float64Array;
			prefetchDem?: boolean;
	  }
	| {
			type: "PREFETCH_CORRIDOR";
			reqId: number;
			points: Array<{ lat: number; lon: number }>;
			bufferM?: number;
	  }
	| {
			type: "COMPUTE_REROUTE";
			reqId: number;
			userLat: number;
			userLon: number;
			userEle?: number | null;
			lastAlongTrackM: number;
			mode: OffTrailMode;
			locale: string;
			obstacles: ObstaclePolygon[];
			preferredPaths: PreferredCorridor[];
	  }
	| {
			type: "COMPUTE_CONNECTOR";
			reqId: number;
			fromLat: number;
			fromLon: number;
			toLat: number;
			toLon: number;
			userEle?: number | null;
			mode: OffTrailMode;
			obstacles: ObstaclePolygon[];
			preferredPaths: PreferredCorridor[];
	  }
	| {
			type: "COMPUTE_RESCUE";
			reqId: number;
			fromLat: number;
			fromLon: number;
			fromEle?: number | null;
			targetLat: number;
			targetLon: number;
			targetEle?: number | null;
			mode: OffTrailMode;
			locale: string;
	  }
	| {
			type: "PARSE_GPX_TEXT";
			reqId: number;
			xmlBuffer: ArrayBuffer;
	  };

export type RerouteMeta = Omit<OffTrailRerouteResult, "points">;
export type RescueMeta = Omit<DirectRescueRouteResult, "points">;

export type WorkerResponseMessage =
	| { type: "ACK"; reqId: number; sampledStartEle: number | null }
	| {
			type: "REROUTE_DONE";
			reqId: number;
			meta: RerouteMeta | null;
			packedPoints: Float32Array | null;
	  }
	| {
			type: "CONNECTOR_DONE";
			reqId: number;
			coords: Float64Array;
	  }
	| {
			type: "RESCUE_DONE";
			reqId: number;
			meta: RescueMeta;
			packedPoints: Float32Array;
	  }
	| {
			type: "GPX_PARSED";
			reqId: number;
			packedTrack: Float64Array;
	  }
	| {
			type: "ERROR";
			reqId: number;
			message: string;
	  };

const demGrid = new DemTileGrid();
let activeTrack: NavTrackPoint[] = [];

const workerScope = self as unknown as {
	onmessage: ((ev: MessageEvent<WorkerRequestMessage>) => void) | null;
	postMessage: (msg: WorkerResponseMessage, transfer?: Transferable[]) => void;
};

workerScope.onmessage = async (ev: MessageEvent<WorkerRequestMessage>) => {
	const msg = ev.data;
	if (!msg || typeof msg.reqId !== "number") return;

	try {
		switch (msg.type) {
			case "SET_TRACK": {
				activeTrack = unpackTrackPoints(msg.packedTrack);
				if (msg.prefetchDem !== false && activeTrack.length > 0) {
					await demGrid.prefetchCorridor(activeTrack);
				}
				const sampledStartEle =
					activeTrack.length > 0
						? demGrid.sampleElevation(activeTrack[0].lat, activeTrack[0].lon)
						: null;
				workerScope.postMessage({ type: "ACK", reqId: msg.reqId, sampledStartEle });
				return;
			}
			case "PREFETCH_CORRIDOR": {
				await demGrid.prefetchCorridor(msg.points, msg.bufferM ?? 1500);
				const sampledStartEle =
					msg.points.length > 0
						? demGrid.sampleElevation(msg.points[0].lat, msg.points[0].lon)
						: null;
				workerScope.postMessage({ type: "ACK", reqId: msg.reqId, sampledStartEle });
				return;
			}
			case "COMPUTE_REROUTE": {
				const res = computeOffTrailReroute({
					userLat: msg.userLat,
					userLon: msg.userLon,
					userEle: msg.userEle,
					trailPoints: activeTrack,
					lastAlongTrackM: msg.lastAlongTrackM,
					sampler: (lat, lon) => demGrid.sampleElevation(lat, lon),
					mode: msg.mode,
					locale: msg.locale,
					obstacles: msg.obstacles,
					preferredPaths: msg.preferredPaths,
				});
				if (!res) {
					workerScope.postMessage({
						type: "REROUTE_DONE",
						reqId: msg.reqId,
						meta: null,
						packedPoints: null,
					});
					return;
				}
				const packedPoints = packOffTrailPoints(res.points);
				const { points: _pts, ...meta } = res;
				workerScope.postMessage(
					{ type: "REROUTE_DONE", reqId: msg.reqId, meta, packedPoints },
					[packedPoints.buffer],
				);
				return;
			}
			case "COMPUTE_CONNECTOR": {
				const evalEle = createElevationSampler(
					(lat, lon) => demGrid.sampleElevation(lat, lon),
					activeTrack,
					msg.fromLat,
					msg.fromLon,
					msg.userEle,
				);
				const pts = computeLocalCurvedConnector({
					fromLat: msg.fromLat,
					fromLon: msg.fromLon,
					toLat: msg.toLat,
					toLon: msg.toLon,
					evalEle,
					mode: msg.mode,
					obstacles: msg.obstacles,
					preferredPaths: msg.preferredPaths,
				});
				const coords = new Float64Array(pts.length * 2);
				for (let i = 0; i < pts.length; i++) {
					coords[i * 2] = pts[i].lat;
					coords[i * 2 + 1] = pts[i].lon;
				}
				workerScope.postMessage(
					{ type: "CONNECTOR_DONE", reqId: msg.reqId, coords },
					[coords.buffer],
				);
				return;
			}
			case "COMPUTE_RESCUE": {
				const res = computeDirectRescueRoute({
					fromLat: msg.fromLat,
					fromLon: msg.fromLon,
					fromEle: msg.fromEle,
					targetLat: msg.targetLat,
					targetLon: msg.targetLon,
					targetEle: msg.targetEle,
					trailPoints: activeTrack,
					sampler: (lat, lon) => demGrid.sampleElevation(lat, lon),
					mode: msg.mode,
					locale: msg.locale,
				});
				const packedPoints = packOffTrailPoints(res.points);
				const { points: _pts, ...meta } = res;
				workerScope.postMessage(
					{ type: "RESCUE_DONE", reqId: msg.reqId, meta, packedPoints },
					[packedPoints.buffer],
				);
				return;
			}
			case "PARSE_GPX_TEXT": {
				const xml = new TextDecoder().decode(msg.xmlBuffer);
				const packedTrack = parseGpxXmlFastToPackedTrack(xml);
				workerScope.postMessage(
					{ type: "GPX_PARSED", reqId: msg.reqId, packedTrack },
					[packedTrack.buffer],
				);
				return;
			}
		}
	} catch (err) {
		workerScope.postMessage({
			type: "ERROR",
			reqId: msg.reqId,
			message: err instanceof Error ? err.message : String(err),
		});
	}
};
