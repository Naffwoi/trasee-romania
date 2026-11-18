import { haversineMeters } from "./geo_math";

export type PwaPowerState = "moving" | "scramble_grace" | "stationary_cabana_sleep";

export interface PwaPowerSnapshot {
	state: PwaPowerState;
	highAccuracyGps: boolean;
	isStationary: boolean;
	recommendedHeartbeatMs: number;
	recommendedGroupPingMs: number;
}

const STATIONARY_RADIUS_M = 8;
const STATIONARY_SPEED_MPS = 0.25;
const WAKE_DRIFT_M = 15;
const DEFAULT_SLEEP_AFTER_MS = 90_000;
const EXPEDITION_SLEEP_AFTER_MS = 45_000;
const STEP_ACCEL_THRESHOLD_MPS2 = 1.2;
const STEP_MIN_GAP_MS = 280;
const STEP_WINDOW_MS = 2_500;

export class PwaPowerGovernor {
	private expeditionMode: boolean;
	private state: PwaPowerState = "moving";
	private anchorLat = NaN;
	private anchorLon = NaN;
	private stillSinceMs: number | null = null;
	private stepTimestampsMs: number[] = [];

	constructor(options?: { expeditionMode?: boolean }) {
		this.expeditionMode = options?.expeditionMode ?? false;
	}

	get currentState(): PwaPowerState {
		return this.state;
	}

	get isHighAccuracy(): boolean {
		return this.state !== "stationary_cabana_sleep";
	}

	setExpeditionMode(enabled: boolean): void {
		this.expeditionMode = enabled;
	}

	resetToMoving(nowMs = Date.now()): PwaPowerSnapshot {
		this.state = "moving";
		this.stillSinceMs = nowMs;
		this.stepTimestampsMs = [];
		return this.snapshot();
	}

	ingestFix(input: {
		lat: number;
		lon: number;
		speed?: number | null;
		nowMs?: number;
		hasActiveSos?: boolean;
	}): PwaPowerSnapshot {
		const nowMs = input.nowMs ?? Date.now();
		if (input.hasActiveSos) {
			this.anchorLat = input.lat;
			this.anchorLon = input.lon;
			return this.resetToMoving(nowMs);
		}

		const speedMps =
			input.speed !== undefined && input.speed !== null && Number.isFinite(input.speed)
				? Math.max(0, input.speed)
				: 0;

		if (!Number.isFinite(this.anchorLat) || !Number.isFinite(this.anchorLon)) {
			this.anchorLat = input.lat;
			this.anchorLon = input.lon;
			this.stillSinceMs = speedMps >= STATIONARY_SPEED_MPS ? null : nowMs;
			this.state = speedMps >= STATIONARY_SPEED_MPS ? "moving" : "scramble_grace";
			return this.snapshot();
		}

		const distFromAnchorM = haversineMeters(
			this.anchorLat,
			this.anchorLon,
			input.lat,
			input.lon,
		);
		const wakeThresholdM =
			this.state === "stationary_cabana_sleep" ? WAKE_DRIFT_M : STATIONARY_RADIUS_M;

		if (speedMps >= STATIONARY_SPEED_MPS || distFromAnchorM > wakeThresholdM) {
			this.anchorLat = input.lat;
			this.anchorLon = input.lon;
			this.stillSinceMs = null;
			this.state = "moving";
			this.stepTimestampsMs = [];
			return this.snapshot();
		}

		if (this.stillSinceMs === null) {
			this.anchorLat = input.lat;
			this.anchorLon = input.lon;
			this.stillSinceMs = nowMs;
		}

		const stillDurationMs = Math.max(0, nowMs - this.stillSinceMs);
		const sleepThresholdMs = this.expeditionMode
			? EXPEDITION_SLEEP_AFTER_MS
			: DEFAULT_SLEEP_AFTER_MS;

		this.state =
			stillDurationMs >= sleepThresholdMs ? "stationary_cabana_sleep" : "scramble_grace";
		return this.snapshot();
	}

	/**
	 * Processes linear acceleration (`DeviceMotionEvent.acceleration`, gravity-free) in m/s^2.
	 * Requires 2 distinct walking step peaks (`>= 1.2 m/s^2`, `>= 280 ms` apart within `2.5 s`)
	 * so setting the phone on a cabin table does not false-wake GPS.
	 */
	ingestLinearAcceleration(
		ax: number | null | undefined,
		ay: number | null | undefined,
		az: number | null | undefined,
		nowMs = Date.now(),
	): boolean {
		if (this.state !== "stationary_cabana_sleep") return false;
		const x = Number.isFinite(ax) ? Number(ax) : 0;
		const y = Number.isFinite(ay) ? Number(ay) : 0;
		const z = Number.isFinite(az) ? Number(az) : 0;
		const mag = Math.hypot(x, y, z);
		if (mag < STEP_ACCEL_THRESHOLD_MPS2) return false;

		this.stepTimestampsMs = this.stepTimestampsMs.filter((t) => nowMs - t <= STEP_WINDOW_MS);
		const lastStep = this.stepTimestampsMs[this.stepTimestampsMs.length - 1];
		if (lastStep !== undefined && nowMs - lastStep < STEP_MIN_GAP_MS) {
			return false;
		}
		this.stepTimestampsMs.push(nowMs);
		if (this.stepTimestampsMs.length >= 2) {
			this.state = "moving";
			this.stillSinceMs = null;
			this.stepTimestampsMs = [];
			return true;
		}
		return false;
	}

	snapshot(): PwaPowerSnapshot {
		const isStationary = this.state === "stationary_cabana_sleep";
		return {
			state: this.state,
			highAccuracyGps: !isStationary,
			isStationary,
			recommendedHeartbeatMs: isStationary ? 120_000 : 45_000,
			recommendedGroupPingMs: isStationary ? 45_000 : 6_000,
		};
	}
}
