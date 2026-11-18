import { DemTileGrid } from "./dem_tile_grid";
import type { WorkerRequestMessage, WorkerResponseMessage } from "./nav_terrain.worker";
import {
	packTrackPoints,
	parseGpxXmlFastToPackedTrack,
	unpackOffTrailPoints,
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

interface PendingCall {
	resolve: (msg: WorkerResponseMessage) => void;
	reject: (err: Error) => void;
}

/**
 * Zero-copy `Transferable` Web Worker RPC client for DEM tile decoding, 16-dir Tobler A*
 * off-trail rerouting, SOS rescue routing, and streaming GPX parsing.
 * Automatically falls back to in-process execution in Vitest/IIFE harnesses or when
 * an E2E test injects a non-cloneable JS closure via `setCustomDemSampler`.
 */
export class NavTerrainClient {
	private worker: Worker | null = null;
	private nextReqId = 1;
	private readonly pending = new Map<number, PendingCall>();
	private readonly fallbackDemGrid = new DemTileGrid();
	private customDemSampler: ((lat: number, lon: number) => number | null) | null = null;
	private cachedTrack: NavTrackPoint[] = [];

	constructor(options?: { workerUrl?: string }) {
		if (
			options?.workerUrl &&
			typeof Worker !== "undefined" &&
			typeof options.workerUrl === "string"
		) {
			try {
				this.worker = new Worker(options.workerUrl, { type: "module" });
				this.worker.onmessage = (ev: MessageEvent<WorkerResponseMessage>) => {
					const msg = ev.data;
					if (!msg) return;
					const entry = this.pending.get(msg.reqId);
					if (!entry) return;
					this.pending.delete(msg.reqId);
					if (msg.type === "ERROR") {
						entry.reject(new Error(msg.message));
					} else {
						entry.resolve(msg);
					}
				};
				this.worker.onerror = () => {
					this.teardownWorker();
				};
			} catch {
				this.worker = null;
			}
		}
	}

	setCustomDemSampler(sampler: ((lat: number, lon: number) => number | null) | null): void {
		this.customDemSampler = sampler;
	}

	sampleElevationSync(lat: number, lon: number): number | null {
		if (this.customDemSampler) {
			return this.customDemSampler(lat, lon);
		}
		return this.fallbackDemGrid.sampleElevation(lat, lon);
	}

	private get canUseWorker(): boolean {
		return this.worker !== null && this.customDemSampler === null;
	}

	private sendToWorker(
		msg: WorkerRequestMessage,
		transfer: Transferable[] = [],
	): Promise<WorkerResponseMessage> {
		return new Promise((resolve, reject) => {
			if (!this.worker) {
				reject(new Error("worker_unavailable"));
				return;
			}
			this.pending.set(msg.reqId, { resolve, reject });
			this.worker.postMessage(msg, transfer);
		});
	}

	async setTrack(points: NavTrackPoint[], prefetchDem = true): Promise<void> {
		this.cachedTrack = points;
		if (this.canUseWorker) {
			const reqId = this.nextReqId++;
			const packedTrack = packTrackPoints(points);
			await this.sendToWorker(
				{ type: "SET_TRACK", reqId, packedTrack, prefetchDem },
				[packedTrack.buffer],
			);
			return;
		}
		if (prefetchDem && points.length > 0 && !this.customDemSampler) {
			await this.fallbackDemGrid.prefetchCorridor(points);
		}
	}

	async prefetchCorridor(
		points: Array<{ lat: number; lon: number }>,
		bufferM = 1500,
	): Promise<void> {
		if (points.length === 0 || this.customDemSampler) return;
		if (this.canUseWorker) {
			const reqId = this.nextReqId++;
			await this.sendToWorker({ type: "PREFETCH_CORRIDOR", reqId, points, bufferM });
			return;
		}
		await this.fallbackDemGrid.prefetchCorridor(points, bufferM);
	}

	async computeReroute(params: {
		userLat: number;
		userLon: number;
		userEle?: number | null;
		lastAlongTrackM: number;
		mode: OffTrailMode;
		locale: string;
		obstacles?: ObstaclePolygon[];
		preferredPaths?: PreferredCorridor[];
	}): Promise<OffTrailRerouteResult | null> {
		if (this.cachedTrack.length === 0) return null;
		if (this.canUseWorker) {
			const reqId = this.nextReqId++;
			const res = await this.sendToWorker({
				type: "COMPUTE_REROUTE",
				reqId,
				userLat: params.userLat,
				userLon: params.userLon,
				userEle: params.userEle,
				lastAlongTrackM: params.lastAlongTrackM,
				mode: params.mode,
				locale: params.locale,
				obstacles: params.obstacles ?? [],
				preferredPaths: params.preferredPaths ?? [],
			});
			if (res.type === "REROUTE_DONE") {
				if (!res.meta || !res.packedPoints) return null;
				return {
					...res.meta,
					points: unpackOffTrailPoints(res.packedPoints),
				};
			}
		}

		return computeOffTrailReroute({
			userLat: params.userLat,
			userLon: params.userLon,
			userEle: params.userEle,
			trailPoints: this.cachedTrack,
			lastAlongTrackM: params.lastAlongTrackM,
			sampler: (lat, lon) => this.sampleElevationSync(lat, lon),
			mode: params.mode,
			locale: params.locale,
			obstacles: params.obstacles,
			preferredPaths: params.preferredPaths,
		});
	}

	async computeConnector(params: {
		fromLat: number;
		fromLon: number;
		toLat: number;
		toLon: number;
		userEle?: number | null;
		mode: OffTrailMode;
		obstacles?: ObstaclePolygon[];
		preferredPaths?: PreferredCorridor[];
	}): Promise<Array<{ lat: number; lon: number }>> {
		if (this.canUseWorker) {
			const reqId = this.nextReqId++;
			const res = await this.sendToWorker({
				type: "COMPUTE_CONNECTOR",
				reqId,
				fromLat: params.fromLat,
				fromLon: params.fromLon,
				toLat: params.toLat,
				toLon: params.toLon,
				userEle: params.userEle,
				mode: params.mode,
				obstacles: params.obstacles ?? [],
				preferredPaths: params.preferredPaths ?? [],
			});
			if (res.type === "CONNECTOR_DONE") {
				const out: Array<{ lat: number; lon: number }> = [];
				for (let i = 0; i + 1 < res.coords.length; i += 2) {
					out.push({ lat: res.coords[i], lon: res.coords[i + 1] });
				}
				return out;
			}
		}

		const evalEle = createElevationSampler(
			(lat, lon) => this.sampleElevationSync(lat, lon),
			this.cachedTrack,
			params.fromLat,
			params.fromLon,
			params.userEle,
		);
		return computeLocalCurvedConnector({
			fromLat: params.fromLat,
			fromLon: params.fromLon,
			toLat: params.toLat,
			toLon: params.toLon,
			evalEle,
			mode: params.mode,
			obstacles: params.obstacles,
			preferredPaths: params.preferredPaths,
		});
	}

	async computeRescueRoute(params: {
		fromLat: number;
		fromLon: number;
		fromEle?: number | null;
		targetLat: number;
		targetLon: number;
		targetEle?: number | null;
		mode: OffTrailMode;
		locale: string;
	}): Promise<DirectRescueRouteResult> {
		if (this.canUseWorker) {
			const reqId = this.nextReqId++;
			const res = await this.sendToWorker({
				type: "COMPUTE_RESCUE",
				reqId,
				fromLat: params.fromLat,
				fromLon: params.fromLon,
				fromEle: params.fromEle,
				targetLat: params.targetLat,
				targetLon: params.targetLon,
				targetEle: params.targetEle,
				mode: params.mode,
				locale: params.locale,
			});
			if (res.type === "RESCUE_DONE") {
				return {
					...res.meta,
					points: unpackOffTrailPoints(res.packedPoints),
				};
			}
		}

		return computeDirectRescueRoute({
			fromLat: params.fromLat,
			fromLon: params.fromLon,
			fromEle: params.fromEle,
			targetLat: params.targetLat,
			targetLon: params.targetLon,
			targetEle: params.targetEle,
			trailPoints: this.cachedTrack,
			sampler: (lat, lon) => this.sampleElevationSync(lat, lon),
			mode: params.mode,
			locale: params.locale,
		});
	}

	async parseGpxText(xml: string): Promise<NavTrackPoint[]> {
		if (this.canUseWorker) {
			const reqId = this.nextReqId++;
			const encoded = new TextEncoder().encode(xml);
			const xmlBuffer = encoded.buffer.slice(
				encoded.byteOffset,
				encoded.byteOffset + encoded.byteLength,
			);
			const res = await this.sendToWorker(
				{ type: "PARSE_GPX_TEXT", reqId, xmlBuffer },
				[xmlBuffer],
			);
			if (res.type === "GPX_PARSED") {
				return unpackTrackPoints(res.packedTrack);
			}
		}
		return unpackTrackPoints(parseGpxXmlFastToPackedTrack(xml));
	}

	private teardownWorker(): void {
		for (const [, entry] of this.pending) {
			entry.reject(new Error("worker_terminated"));
		}
		this.pending.clear();
		this.worker?.terminate();
		this.worker = null;
	}

	destroy(): void {
		this.teardownWorker();
		this.cachedTrack = [];
		this.customDemSampler = null;
	}
}
