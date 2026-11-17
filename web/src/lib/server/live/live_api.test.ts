import { createECDH, randomBytes } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as webpush from "web-push";

const { privateEnvMock, publicEnvMock } = vi.hoisted(() => ({
	privateEnvMock: {
		POCKETBASE_PROXY_SECRET: "test-proxy-secret-key",
		UPLOAD_FOLDER: undefined,
	} as Record<string, string | undefined>,
	publicEnvMock: {
		PUBLIC_POCKETBASE_URL: "http://pocketbase.internal:8090",
		PUBLIC_PRIVATE_INSTANCE: "true",
	} as Record<string, string | undefined>,
}));

vi.mock("$app/env/private", () => privateEnvMock);
vi.mock("$app/env/public", () => publicEnvMock);
vi.mock("$app/env", () => ({ browser: false, dev: false }));

import { isRouteProtected } from "#lib/util/authorization_util.ts";
import {
	computeDeviceHash,
	createSlidingWindowRateLimiter,
	forwardLiveToDb,
	InvalidDeviceTokenError,
	isValidDeviceToken,
	liveRateLimiters,
	resolveDeviceIdentity,
} from "./device_identity.ts";
import {
	buildSosPushPayload,
	dispatchSosPushNotifications,
	ensureVapidKeys,
	getVapidPublicKey,
	resetVapidKeysCache,
	VAPID_SUBJECT,
} from "./vapid_push.ts";
import { POST as postHeartbeat } from "../../../routes/api/v1/live/heartbeat/+server.ts";
import { POST as postPushSubscribe } from "../../../routes/api/v1/live/push/subscribe/+server.ts";
import { GET as getVapidKey } from "../../../routes/api/v1/live/push/vapid-public-key/+server.ts";
import { POST as postReports } from "../../../routes/api/v1/live/reports/+server.ts";
import { POST as postReportVote } from "../../../routes/api/v1/live/reports/[id]/vote/+server.ts";
import { POST as postSos } from "../../../routes/api/v1/live/sos/+server.ts";
import { PATCH as patchSos } from "../../../routes/api/v1/live/sos/[id]/+server.ts";
import { POST as postSosRespond } from "../../../routes/api/v1/live/sos/[id]/respond/+server.ts";
import { GET as getStream } from "../../../routes/api/v1/live/stream/+server.ts";
import { GET as getTrailSummary } from "../../../routes/api/v1/live/trail/[id]/summary/+server.ts";

const VALID_TOKEN_A = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
const VALID_TOKEN_B = "f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f";

describe("Live API public route authorization", () => {
	it("allows /api/v1/live/* routes without user login even on private instances", () => {
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live"))).toBe(false);
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live/heartbeat"))).toBe(false);
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live/sos"))).toBe(false);
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live/stream"))).toBe(false);
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/settings"))).toBe(true);
	});
});

describe("device_identity", () => {
	beforeEach(() => {
		privateEnvMock.POCKETBASE_PROXY_SECRET = "test-proxy-secret-key";
		publicEnvMock.PUBLIC_POCKETBASE_URL = "http://pocketbase.internal:8090";
		liveRateLimiters.heartbeat.reset();
		liveRateLimiters.reports.reset();
		liveRateLimiters.votes.reset();
		liveRateLimiters.sos.reset();
		liveRateLimiters.pushSubscribe.reset();
	});

	it("computes deterministic 64-char hex HMAC-SHA256 digests and falls back cleanly", () => {
		const hash1 = computeDeviceHash(VALID_TOKEN_A);
		const hash2 = computeDeviceHash(`  ${VALID_TOKEN_A}  `);
		const hashB = computeDeviceHash(VALID_TOKEN_B);

		expect(hash1).toMatch(/^[0-9a-f]{64}$/);
		expect(hash1).toBe(hash2);
		expect(hash1).not.toBe(hashB);

		privateEnvMock.POCKETBASE_PROXY_SECRET = "";
		const fallbackHash1 = computeDeviceHash(VALID_TOKEN_A);
		const fallbackHash2 = computeDeviceHash(VALID_TOKEN_A);
		expect(fallbackHash1).toMatch(/^[0-9a-f]{64}$/);
		expect(fallbackHash1).toBe(fallbackHash2);
		expect(fallbackHash1).not.toBe(hash1);
	});

	it("rejects invalid device tokens (too short, too long, spaces, non-ASCII)", () => {
		expect(isValidDeviceToken("")).toBe(false);
		expect(isValidDeviceToken("short-token-123")).toBe(false);
		expect(isValidDeviceToken("x".repeat(129))).toBe(false);
		expect(isValidDeviceToken("token with spaces 12345678901234")).toBe(false);
		expect(isValidDeviceToken("token-cu-diacritice-ăîâșț-12345678")).toBe(false);
		expect(isValidDeviceToken("x".repeat(24))).toBe(true);
		expect(isValidDeviceToken("y".repeat(128))).toBe(true);

		expect(() => computeDeviceHash("too-short")).toThrow(InvalidDeviceTokenError);

		const badReq = new Request("https://trasee.skillfy.ro/api/v1/live/heartbeat", {
			method: "POST",
			headers: { "X-Device-Token": "short" },
		});
		const identity = resolveDeviceIdentity(badReq);
		expect(identity.ok).toBe(false);
		if (!identity.ok) {
			expect(identity.response.status).toBe(400);
		}
	});

	it("supports query ?deviceToken=... for SSE EventSource and optional tokens", () => {
		const sseUrl = new URL(
			`https://trasee.skillfy.ro/api/v1/live/stream?lat=45.4&lon=25.5&deviceToken=${VALID_TOKEN_A}`,
		);
		const sseReq = new Request(sseUrl);

		const sseIdentity = resolveDeviceIdentity(
			{ request: sseReq, url: sseUrl },
			{ allowQueryToken: true },
		);
		expect(sseIdentity.ok).toBe(true);
		if (sseIdentity.ok) {
			expect(sseIdentity.deviceHash).toBe(computeDeviceHash(VALID_TOKEN_A));
		}

		const summaryUrl = new URL("https://trasee.skillfy.ro/api/v1/live/trail/tr123/summary");
		const anonIdentity = resolveDeviceIdentity(
			{ request: new Request(summaryUrl), url: summaryUrl },
			{ optional: true },
		);
		expect(anonIdentity).toEqual({ ok: true, deviceHash: "" });
	});

	it("enforces sliding-window rate limits per deviceHash and recovers as window slides", async () => {
		const limiter = createSlidingWindowRateLimiter(3, 60_000);
		const t0 = 1_700_000_000_000;

		expect(limiter.check("device-1", t0)).toEqual({
			allowed: true,
			remaining: 2,
			retryAfterSec: 0,
		});
		expect(limiter.check("device-1", t0 + 10_000).allowed).toBe(true);
		expect(limiter.check("device-1", t0 + 20_000).allowed).toBe(true);

		// 4th call inside 60s window is rejected
		const blocked = limiter.check("device-1", t0 + 25_000);
		expect(blocked.allowed).toBe(false);
		expect(blocked.retryAfterSec).toBe(35);

		const res429 = limiter.enforce("device-1", t0 + 25_000);
		expect(res429).not.toBeNull();
		expect(res429?.status).toBe(429);
		expect(res429?.headers.get("Retry-After")).toBe("35");

		// Independent deviceHash is unaffected
		expect(limiter.check("device-2", t0 + 25_000).allowed).toBe(true);

		// Once t0 ages past 60s, one slot opens up while t0+10s and t0+20s remain in window
		const afterSlide = limiter.check("device-1", t0 + 60_001);
		expect(afterSlide.allowed).toBe(true);
		expect(afterSlide.remaining).toBe(0);
	});

	it("forwards internal headers cleanly in forwardLiveToDb", async () => {
		const mockFetch = vi.fn().mockResolvedValue(Response.json({ ok: true }));
		await forwardLiveToDb(
			"/heartbeat",
			{ method: "POST", body: JSON.stringify({ lat: 45.5, lon: 25.5 }) },
			"hashed-device-abc",
			"actor-xyz",
			mockFetch as unknown as typeof fetch,
		);

		expect(mockFetch).toHaveBeenCalledTimes(1);
		const [calledUrl, calledInit] = mockFetch.mock.calls[0] as [string, RequestInit];
		expect(calledUrl).toBe("http://pocketbase.internal:8090/live/heartbeat");
		const headers = new Headers(calledInit.headers);
		expect(headers.get("X-Internal-Secret")).toBe("test-proxy-secret-key");
		expect(headers.get("X-Device-Hash")).toBe("hashed-device-abc");
		expect(headers.get("X-Actor-Id")).toBe("actor-xyz");
		expect(headers.get("Content-Type")).toBe("application/json");
	});
});

describe("vapid_push", () => {
	let tempDir: string;

	beforeEach(() => {
		resetVapidKeysCache();
		tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "wanderer-vapid-test-"));
	});

	afterEach(() => {
		resetVapidKeysCache();
		fs.rmSync(tempDir, { recursive: true, force: true });
		vi.restoreAllMocks();
	});

	it("auto-generates VAPID keys, persists .vapid_keys.json atomically, and reloads them", () => {
		const setVapidSpy = vi.fn();
		const genSpy = vi.fn().mockReturnValue({
			publicKey: "PUB_KEY_TEST_123",
			privateKey: "PRIV_KEY_TEST_456",
		});

		const first = ensureVapidKeys({
			uploadFolder: tempDir,
			webpushClient: {
				generateVAPIDKeys: genSpy,
				setVapidDetails: setVapidSpy,
			},
		});

		expect(first).toEqual({
			publicKey: "PUB_KEY_TEST_123",
			privateKey: "PRIV_KEY_TEST_456",
		});
		expect(genSpy).toHaveBeenCalledTimes(1);
		expect(setVapidSpy).toHaveBeenCalledWith(
			VAPID_SUBJECT,
			"PUB_KEY_TEST_123",
			"PRIV_KEY_TEST_456",
		);

		const persistedFile = path.join(tempDir, ".vapid_keys.json");
		expect(fs.existsSync(persistedFile)).toBe(true);

		// Reset in-memory cache and verify keys are loaded from disk without regenerating
		resetVapidKeysCache();
		const pubKeyReloaded = getVapidPublicKey({
			uploadFolder: tempDir,
			webpushClient: {
				generateVAPIDKeys: genSpy,
				setVapidDetails: setVapidSpy,
			},
		});
		expect(pubKeyReloaded).toBe("PUB_KEY_TEST_123");
		expect(genSpy).toHaveBeenCalledTimes(1);
	});

	it("falls back to in-memory VAPID keys when filesystem is unwritable", () => {
		// Create a regular file where uploadFolder expects a directory so mkdirSync fails
		const blockingFile = path.join(tempDir, "not-a-directory");
		fs.writeFileSync(blockingFile, "readonly");

		const keys = ensureVapidKeys({
			uploadFolder: path.join(blockingFile, "nested"),
		});
		expect(keys.publicKey.length).toBeGreaterThan(20);
		expect(keys.privateKey.length).toBeGreaterThan(20);
	});

	it("builds SOS push payload and removes stale 410/404 endpoints via removeStaleEndpoint", async () => {
		const sos = {
			id: "sos999",
			trailId: "bucegi-1",
			reason: "injury",
			requesterName: "Andrei",
			message: "Gleznă luxată sub vârf",
		};

		const payload = buildSosPushPayload(sos, 640);
		expect(payload).toEqual({
			type: "sos_alert",
			sosId: "sos999",
			trailId: "bucegi-1",
			title: "🆘 Ajutor solicitat în apropiere!",
			body: "Accidentare · (Andrei) · la 640 m — Gleznă luxată sub vârf",
			url: "/map/trail/@romania/bucegi-1/navigate?sos=sos999",
		});

		const fallbackPayload = buildSosPushPayload({ id: "sos000", reason: "lost" }, 1500);
		expect(fallbackPayload.url).toBe("/map?sos=sos000");
		expect(fallbackPayload.body).toContain("1.5 km");

		const sentPayloads: Array<{ endpoint: string; body: string }> = [];
		const staleRemoved: string[] = [];

		const mockSendNotification = vi.fn(async (sub: { endpoint: string }, rawPayload?: string | Buffer | null) => {
			if (sub.endpoint.includes("stale-410")) {
				throw Object.assign(new Error("Gone"), { statusCode: 410 });
			}
			if (sub.endpoint.includes("stale-404")) {
				throw Object.assign(new Error("Not Found"), { statusCode: 404 });
			}
			sentPayloads.push({ endpoint: sub.endpoint, body: String(rawPayload) });
			return { statusCode: 201, body: "", headers: {} };
		});

		const summary = await dispatchSosPushNotifications(
			sos,
			[
				{
					endpoint: "https://push.example/ok-1",
					p256dh: "key-p256dh-1",
					auth: "key-auth-1",
					distanceM: 420,
				},
				{
					endpoint: "https://push.example/stale-410",
					p256dh: "key-p256dh-2",
					auth: "key-auth-2",
					distanceM: 1200,
				},
				{
					endpoint: "https://push.example/stale-404",
					p256dh: "key-p256dh-3",
					auth: "key-auth-3",
					distanceM: 2100,
				},
			],
			async (endpoint) => {
				staleRemoved.push(endpoint);
			},
			{
				uploadFolder: tempDir,
				sendNotification: mockSendNotification as never,
			},
		);

		expect(summary).toEqual({ sent: 1, staleRemoved: 2, failed: 0 });
		expect(sentPayloads).toHaveLength(1);
		expect(JSON.parse(sentPayloads[0].body)).toMatchObject({
			type: "sos_alert",
			sosId: "sos999",
			title: "🆘 Ajutor solicitat în apropiere!",
		});
		expect(staleRemoved.sort()).toEqual([
			"https://push.example/stale-404",
			"https://push.example/stale-410",
		]);
	});
});

describe("SvelteKit /api/v1/live route handlers", () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		liveRateLimiters.sos.reset();
		liveRateLimiters.pushSubscribe.reset();
	});

	it("POST /api/v1/live/sos strips pushTargets from client response", async () => {
		const fetchSpy = vi.fn().mockResolvedValue(
			Response.json({
				sos: { id: "sos-abc", trailId: "trail-1", status: "active", reason: "lost" },
				pushTargets: [],
			}),
		);
		vi.stubGlobal("fetch", fetchSpy);

		const req = new Request("https://trasee.skillfy.ro/api/v1/live/sos", {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"X-Device-Token": VALID_TOKEN_A,
			},
			body: JSON.stringify({
				trailId: "trail-1",
				reason: "lost",
				message: "Ceață densă",
				lat: 45.41,
				lon: 25.45,
			}),
		});

		const res = await postSos({
			request: req,
			url: new URL(req.url),
			locals: { user: { actor: "actor-1" } },
		} as never);

		expect(res.status).toBe(200);
		const data = await res.json();
		expect(data).toEqual({
			sos: { id: "sos-abc", trailId: "trail-1", status: "active", reason: "lost" },
		});
		expect(data.pushTargets).toBeUndefined();
	});

	it("POST /api/v1/live/push/subscribe flattens PushSubscription keys for Go backend", async () => {
		const fetchSpy = vi.fn().mockResolvedValue(Response.json({ ok: true }));
		vi.stubGlobal("fetch", fetchSpy);

		const req = new Request("https://trasee.skillfy.ro/api/v1/live/push/subscribe", {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"X-Device-Token": VALID_TOKEN_A,
			},
			body: JSON.stringify({
				endpoint: "https://fcm.googleapis.com/fcm/send/sub123",
				keys: { p256dh: "p256dh_val", auth: "auth_val" },
				lat: 45.5,
				lon: 25.6,
				trailId: "trail-9",
			}),
		});

		const res = await postPushSubscribe({
			request: req,
			url: new URL(req.url),
			locals: {},
		} as never);

		expect(res.status).toBe(200);
		const [, upstreamInit] = fetchSpy.mock.calls[0] as [string, RequestInit];
		expect(JSON.parse(String(upstreamInit.body))).toEqual({
			endpoint: "https://fcm.googleapis.com/fcm/send/sub123",
			p256dh: "p256dh_val",
			auth: "auth_val",
			lat: 45.5,
			lon: 25.6,
			trailId: "trail-9",
		});
	});

	it("GET /api/v1/live/stream proxies SSE headers, hides deviceToken from upstream URL, and aborts cleanly", async () => {
		let upstreamAborted = false;
		const encoder = new TextEncoder();

		const fetchSpy = vi.fn().mockImplementation((_url: string, init: RequestInit) => {
			init.signal?.addEventListener("abort", () => {
				upstreamAborted = true;
			});
			const upstreamBody = new ReadableStream<Uint8Array>({
				start(controller) {
					controller.enqueue(encoder.encode("event: sos_update\ndata: {\"id\":\"1\"}\n\n"));
				},
			});
			return Promise.resolve(
				new Response(upstreamBody, {
					status: 200,
					headers: { "Content-Type": "text/event-stream" },
				}),
			);
		});
		vi.stubGlobal("fetch", fetchSpy);

		const url = new URL(
			`https://trasee.skillfy.ro/api/v1/live/stream?lat=45.4&lon=25.5&trailId=t1&deviceToken=${VALID_TOKEN_A}`,
		);
		const req = new Request(url);
		const res = await getStream({
			request: req,
			url,
			locals: {},
		} as never);

		expect(res.status).toBe(200);
		expect(res.headers.get("Content-Type")).toBe("text/event-stream");
		expect(res.headers.get("Cache-Control")).toBe("no-cache");
		expect(res.headers.get("X-Accel-Buffering")).toBe("no");

		const [calledUrl, calledInit] = fetchSpy.mock.calls[0] as [string, RequestInit];
		expect(calledUrl).toBe("http://pocketbase.internal:8090/live/stream?lat=45.4&lon=25.5&trailId=t1");
		expect(calledUrl).not.toContain("deviceToken");
		expect(new Headers(calledInit.headers).get("X-Device-Hash")).toBe(
			computeDeviceHash(VALID_TOKEN_A),
		);

		const reader = res.body!.getReader();
		const firstChunk = await reader.read();
		expect(new TextDecoder().decode(firstChunk.value)).toContain("event: sos_update");

		await reader.cancel();
		expect(upstreamAborted).toBe(true);
	});

	it("encrypts RFC 8291 Web Push request details with real VAPID + P-256 keys", () => {
		const tmpVapidDir = fs.mkdtempSync(path.join(os.tmpdir(), "wanderer-vapid-real-"));
		try {
			resetVapidKeysCache();
			const keys = ensureVapidKeys({ uploadFolder: tmpVapidDir });
			expect(keys.publicKey.length).toBeGreaterThan(40);

			const ecdh = createECDH("prime256v1");
			ecdh.generateKeys();
			const p256dh = ecdh.getPublicKey("base64url");
			const auth = randomBytes(16).toString("base64url");

			const payload = buildSosPushPayload(
				{ id: "sos-real", trailId: "piatra-craiului", reason: "exhaustion" },
				380,
			);
			const details = webpush.generateRequestDetails(
				{
					endpoint: "https://fcm.googleapis.com/fcm/send/real-test",
					keys: { p256dh, auth },
				},
				JSON.stringify(payload),
			);
			expect(details.method).toBe("POST");
			expect(details.body).toBeInstanceOf(Buffer);
			expect(details.body!.byteLength).toBeGreaterThan(32);
		} finally {
			resetVapidKeysCache();
			fs.rmSync(tmpVapidDir, { recursive: true, force: true });
		}
	});

	it("proxies heartbeat, trail summary, reports, votes, SOS patch/respond, and VAPID public key", async () => {
		const fetchSpy = vi.fn(() =>
			Promise.resolve(Response.json({ ok: true, activeHikers30m: 4 })),
		);
		vi.stubGlobal("fetch", fetchSpy);

		// 1. Heartbeat
		const hbReq = new Request("https://trasee.skillfy.ro/api/v1/live/heartbeat", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ trailId: "t1", lat: 45.4, lon: 25.5, inNavigation: true }),
		});
		const hbRes = await postHeartbeat({
			request: hbReq,
			url: new URL(hbReq.url),
			locals: {},
		} as never);
		expect(hbRes.status).toBe(200);

		// 2. Trail summary without X-Device-Token (optional)
		const sumReq = new Request("https://trasee.skillfy.ro/api/v1/live/trail/t1/summary");
		const sumRes = await getTrailSummary({
			request: sumReq,
			url: new URL(sumReq.url),
			params: { id: "t1" },
			locals: {},
		} as never);
		expect(sumRes.status).toBe(200);

		// 3. Create report + vote
		const repReq = new Request("https://trasee.skillfy.ro/api/v1/live/reports", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ trailId: "t1", category: "spring", lat: 45.4, lon: 25.5 }),
		});
		expect(
			(
				await postReports({
					request: repReq,
					url: new URL(repReq.url),
					locals: {},
				} as never)
			).status,
		).toBe(200);

		const voteReq = new Request("https://trasee.skillfy.ro/api/v1/live/reports/r1/vote", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ vote: "confirm" }),
		});
		expect(
			(
				await postReportVote({
					request: voteReq,
					url: new URL(voteReq.url),
					params: { id: "r1" },
					locals: {},
				} as never)
			).status,
		).toBe(200);

		// 4. SOS patch & respond
		const patchReq = new Request("https://trasee.skillfy.ro/api/v1/live/sos/s1", {
			method: "PATCH",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ status: "resolved" }),
		});
		expect(
			(
				await patchSos({
					request: patchReq,
					url: new URL(patchReq.url),
					params: { id: "s1" },
					locals: {},
				} as never)
			).status,
		).toBe(200);

		const respReq = new Request("https://trasee.skillfy.ro/api/v1/live/sos/s1/respond", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_B },
			body: JSON.stringify({ status: "coming", lat: 45.41, lon: 25.51, distanceM: 900, etaSec: 720 }),
		});
		expect(
			(
				await postSosRespond({
					request: respReq,
					url: new URL(respReq.url),
					params: { id: "s1" },
					locals: {},
				} as never)
			).status,
		).toBe(200);

		// 5. VAPID public key endpoint
		const tmpVapidDir = fs.mkdtempSync(path.join(os.tmpdir(), "wanderer-vapid-ep-"));
		privateEnvMock.UPLOAD_FOLDER = tmpVapidDir;
		resetVapidKeysCache();
		try {
			const vapidRes = await getVapidKey();
			expect(vapidRes.status).toBe(200);
			const vapidBody = await vapidRes.json();
			expect(typeof vapidBody.publicKey).toBe("string");
			expect(vapidBody.publicKey.length).toBeGreaterThan(40);
		} finally {
			privateEnvMock.UPLOAD_FOLDER = undefined;
			resetVapidKeysCache();
			fs.rmSync(tmpVapidDir, { recursive: true, force: true });
		}
	});
});
