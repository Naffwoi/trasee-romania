import * as privateEnv from "$app/env/private";
import * as publicEnv from "$app/env/public";
import { proxyJsonResponse } from "#lib/server/http.ts";
import type { RequestEvent } from "@sveltejs/kit";
import { createHmac } from "node:crypto";

export const FALLBACK_HMAC_SECRET = "wanderer-live-fallback";
export const DEVICE_TOKEN_MIN_LENGTH = 24;
export const DEVICE_TOKEN_MAX_LENGTH = 128;
export const GROUP_CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/;

const ASCII_PRINTABLE_TOKEN_RE = /^[\x21-\x7E]+$/;
const MAX_TRACKED_DEVICES = 10_000;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 15_000;

export function isValidGroupCode(rawCode: unknown): rawCode is string {
	return typeof rawCode === "string" && GROUP_CODE_RE.test(rawCode);
}

export class InvalidDeviceTokenError extends Error {
	readonly status = 400;
	readonly code = "invalid_device_token";

	constructor(message = "invalid_device_token") {
		super(message);
		this.name = "InvalidDeviceTokenError";
	}
}

export function isValidDeviceToken(rawToken: unknown): rawToken is string {
	return (
		typeof rawToken === "string" &&
		rawToken.length >= DEVICE_TOKEN_MIN_LENGTH &&
		rawToken.length <= DEVICE_TOKEN_MAX_LENGTH &&
		ASCII_PRINTABLE_TOKEN_RE.test(rawToken)
	);
}

export function computeDeviceHash(rawToken: string, secretOverride?: string): string {
	const trimmed = typeof rawToken === "string" ? rawToken.trim() : "";
	if (!isValidDeviceToken(trimmed)) {
		throw new InvalidDeviceTokenError();
	}
	const configuredSecret =
		secretOverride ?? (privateEnv as Record<string, string | undefined>).POCKETBASE_PROXY_SECRET;
	const hmacKey = configuredSecret || FALLBACK_HMAC_SECRET;
	return createHmac("sha256", hmacKey).update(trimmed).digest("hex");
}

export function extractRawDeviceToken(
	request: Request,
	url?: URL,
	allowQueryToken = false,
): string | null {
	const headerToken = request.headers.get("x-device-token")?.trim() ?? "";
	if (headerToken.length > 0) {
		return headerToken;
	}
	if (allowQueryToken && url) {
		const queryToken = url.searchParams.get("deviceToken")?.trim() ?? "";
		if (queryToken.length > 0) {
			return queryToken;
		}
	}
	return null;
}

export interface ResolveDeviceIdentityOptions {
	optional?: boolean;
	allowQueryToken?: boolean;
	secret?: string;
}

export type DeviceIdentityResult =
	| { ok: true; deviceHash: string }
	| { ok: false; response: Response };

export function resolveDeviceIdentity(
	input: { request: Request; url?: URL } | Request,
	options: ResolveDeviceIdentityOptions = {},
): DeviceIdentityResult {
	const request = input instanceof Request ? input : input.request;
	const url = input instanceof Request ? undefined : input.url;
	const rawToken = extractRawDeviceToken(request, url, Boolean(options.allowQueryToken));

	if (rawToken === null) {
		if (options.optional) {
			return { ok: true, deviceHash: "" };
		}
		return {
			ok: false,
			response: Response.json({ message: "invalid_device_token" }, { status: 400 }),
		};
	}

	try {
		const deviceHash = computeDeviceHash(rawToken, options.secret);
		return { ok: true, deviceHash };
	} catch {
		return {
			ok: false,
			response: Response.json({ message: "invalid_device_token" }, { status: 400 }),
		};
	}
}

export function resolveActorId(event: Pick<RequestEvent, "locals">): string {
	const actor = event.locals?.user?.actor;
	return typeof actor === "string" ? actor : "";
}

export interface RateLimitDecision {
	allowed: boolean;
	remaining: number;
	retryAfterSec: number;
}

export interface SlidingWindowRateLimiter {
	readonly maxRequests: number;
	readonly windowMs: number;
	check(deviceHash: string, now?: number): RateLimitDecision;
	enforce(deviceHash: string, now?: number): Response | null;
	reset(): void;
	size(): number;
}

export function createSlidingWindowRateLimiter(
	maxRequests: number,
	windowMs: number,
): SlidingWindowRateLimiter {
	const buckets = new Map<string, number[]>();

	function pruneKey(key: string, cutoff: number): number[] {
		const existing = buckets.get(key);
		if (!existing || existing.length === 0) {
			return [];
		}
		let firstValidIdx = 0;
		while (firstValidIdx < existing.length && existing[firstValidIdx] <= cutoff) {
			firstValidIdx++;
		}
		if (firstValidIdx === existing.length) {
			buckets.delete(key);
			return [];
		}
		if (firstValidIdx > 0) {
			const sliced = existing.slice(firstValidIdx);
			buckets.set(key, sliced);
			return sliced;
		}
		return existing;
	}

	function evictExpiredBucketsIfFull(cutoff: number): void {
		if (buckets.size < MAX_TRACKED_DEVICES) {
			return;
		}
		for (const [key, timestamps] of buckets) {
			if (timestamps.length === 0 || timestamps[timestamps.length - 1] <= cutoff) {
				buckets.delete(key);
			}
		}
		if (buckets.size >= MAX_TRACKED_DEVICES) {
			buckets.clear();
		}
	}

	function check(deviceHash: string, now = Date.now()): RateLimitDecision {
		const key = deviceHash || "anonymous";
		const cutoff = now - windowMs;
		const active = pruneKey(key, cutoff);

		if (active.length >= maxRequests) {
			const oldest = active[0];
			const retryAfterSec = Math.max(1, Math.ceil((oldest + windowMs - now) / 1000));
			return {
				allowed: false,
				remaining: 0,
				retryAfterSec,
			};
		}

		if (active.length === 0) {
			evictExpiredBucketsIfFull(cutoff);
			const fresh = [now];
			buckets.set(key, fresh);
			return {
				allowed: true,
				remaining: Math.max(0, maxRequests - fresh.length),
				retryAfterSec: 0,
			};
		}

		active.push(now);
		return {
			allowed: true,
			remaining: Math.max(0, maxRequests - active.length),
			retryAfterSec: 0,
		};
	}

	function enforce(deviceHash: string, now = Date.now()): Response | null {
		const decision = check(deviceHash, now);
		if (decision.allowed) {
			return null;
		}
		return Response.json(
			{
				message: "rate_limit_exceeded",
				retryAfterSec: decision.retryAfterSec,
			},
			{
				status: 429,
				headers: {
					"Retry-After": String(decision.retryAfterSec),
				},
			},
		);
	}

	return {
		maxRequests,
		windowMs,
		check,
		enforce,
		reset: () => buckets.clear(),
		size: () => buckets.size,
	};
}

export const liveRateLimiters = {
	heartbeat: createSlidingWindowRateLimiter(6, 60_000),
	reports: createSlidingWindowRateLimiter(6, 10 * 60_000),
	votes: createSlidingWindowRateLimiter(20, 5 * 60_000),
	sos: createSlidingWindowRateLimiter(3, 15 * 60_000),
	sosUpdate: createSlidingWindowRateLimiter(30, 60_000),
	sosRespond: createSlidingWindowRateLimiter(30, 60_000),
	pushSubscribe: createSlidingWindowRateLimiter(12, 5 * 60_000),
	groupCreate: createSlidingWindowRateLimiter(10, 10 * 60_000),
	groupJoin: createSlidingWindowRateLimiter(15, 5 * 60_000),
	groupPing: createSlidingWindowRateLimiter(30, 60_000),
};

export function forwardLiveToDb(
	path: string,
	init: RequestInit,
	deviceHash: string,
	actorId?: string,
	fetchImpl: typeof fetch = fetch,
): Promise<Response> {
	const rawBaseUrl =
		(publicEnv as Record<string, string | undefined>).PUBLIC_POCKETBASE_URL ||
		"http://127.0.0.1:8090";
	const pbBaseUrl = rawBaseUrl.replace(/\/+$/, "");
	const normalizedPath = path.startsWith("/") ? path : `/${path}`;
	const targetUrl = `${pbBaseUrl}/live${normalizedPath}`;

	const headers = new Headers(init.headers);
	if (init.body !== undefined && !headers.has("Content-Type")) {
		headers.set("Content-Type", "application/json");
	}
	headers.set(
		"X-Internal-Secret",
		(privateEnv as Record<string, string | undefined>).POCKETBASE_PROXY_SECRET ?? "",
	);
	headers.set("X-Device-Hash", deviceHash);
	headers.set("X-Actor-Id", actorId ?? "");

	const signal = init.signal ?? AbortSignal.timeout(DEFAULT_UPSTREAM_TIMEOUT_MS);

	return fetchImpl(targetUrl, {
		...init,
		headers,
		signal,
	});
}

export async function forwardAndProxyLiveJson(
	path: string,
	init: RequestInit,
	deviceHash: string,
	actorId?: string,
	fetchImpl: typeof fetch = fetch,
): Promise<Response> {
	try {
		const upstream = await forwardLiveToDb(path, init, deviceHash, actorId, fetchImpl);
		return await proxyJsonResponse(upstream);
	} catch {
		return Response.json({ message: "backend_unavailable" }, { status: 503 });
	}
}
