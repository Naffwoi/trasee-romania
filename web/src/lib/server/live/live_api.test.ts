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
vi.mock("#lib/server/live/vapid_push.ts", async (importOriginal) => {
	const actual = await importOriginal<typeof import("./vapid_push.ts")>();
	return {
		...actual,
		dispatchSosPushNotifications: vi.fn(actual.dispatchSosPushNotifications),
	};
});

import { isRouteProtected } from "#lib/util/authorization_util.ts";
import {
	computeDeviceHash,
	createSlidingWindowRateLimiter,
	forwardLiveToDb,
	GROUP_CODE_RE,
	InvalidDeviceTokenError,
	isValidDeviceToken,
	isValidGroupCode,
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
} from "#lib/server/live/vapid_push.ts";
import { POST as postCreateGroup } from "../../../routes/api/v1/live/groups/+server.ts";
import { GET as getGroupByCode } from "../../../routes/api/v1/live/groups/[code]/+server.ts";
import { POST as postJoinGroup } from "../../../routes/api/v1/live/groups/[code]/join/+server.ts";
import { POST as postLeaveGroup } from "../../../routes/api/v1/live/groups/[code]/leave/+server.ts";
import { POST as postPingGroup } from "../../../routes/api/v1/live/groups/[code]/ping/+server.ts";
import { DELETE as deleteHeartbeat, POST as postHeartbeat } from "../../../routes/api/v1/live/heartbeat/+server.ts";
import { POST as postPushSubscribe } from "../../../routes/api/v1/live/push/subscribe/+server.ts";
import { GET as getVapidKey } from "../../../routes/api/v1/live/push/vapid-public-key/+server.ts";
import { POST as postReports } from "../../../routes/api/v1/live/reports/+server.ts";
import { POST as postReportVote } from "../../../routes/api/v1/live/reports/[id]/vote/+server.ts";
import { POST as postSos } from "../../../routes/api/v1/live/sos/+server.ts";
import { PATCH as patchSos } from "../../../routes/api/v1/live/sos/[id]/+server.ts";
import { POST as postSosRespond } from "../../../routes/api/v1/live/sos/[id]/respond/+server.ts";
import { POST as postSosRelay } from "../../../routes/api/v1/live/sos/relay/+server.ts";
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

		const delHbReq = new Request("https://trasee.skillfy.ro/api/v1/live/heartbeat", {
			method: "DELETE",
			headers: { "X-Device-Token": VALID_TOKEN_A },
		});
		const delHbRes = await deleteHeartbeat({
			request: delHbReq,
			url: new URL(delHbReq.url),
			locals: {},
		} as never);
		expect(delHbRes.status).toBe(200);

		// 2. Trail summary without X-Device-Token (optional) + lat/lon forwarding
		const sumReq = new Request("https://trasee.skillfy.ro/api/v1/live/trail/t1/summary?lat=45.44&lon=25.55");
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

	it("validates 6-char unambiguous group codes (/^[A-HJ-NP-Z2-9]{6}$/) and proxies group create, get, join, ping (30/min limit), leave, and SSE groupCode", async () => {
		liveRateLimiters.groupCreate.reset();
		liveRateLimiters.groupJoin.reset();
		liveRateLimiters.groupPing.reset();

		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live/groups"))).toBe(false);
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2/ping"))).toBe(false);

		// Strict code validation (/^[A-HJ-NP-Z2-9]{6}$/)
		expect(GROUP_CODE_RE.source).toBe("^[A-HJ-NP-Z2-9]{6}$");
		expect(isValidGroupCode("K7M9P2")).toBe(true);
		expect(isValidGroupCode("ABCDEF")).toBe(true);
		expect(isValidGroupCode("234567")).toBe(true);
		expect(isValidGroupCode("AB0234")).toBe(false); // 0 is excluded
		expect(isValidGroupCode("AB1234")).toBe(false); // 1 is excluded
		expect(isValidGroupCode("ABI234")).toBe(false); // I is excluded
		expect(isValidGroupCode("ABO234")).toBe(false); // O is excluded
		expect(isValidGroupCode("k7m9p2")).toBe(false); // lowercase rejected
		expect(isValidGroupCode("K7M9P")).toBe(false); // too short
		expect(isValidGroupCode("K7M9P23")).toBe(false); // too long

		const sampleSession = {
			code: "K7M9P2",
			trailId: "bucegi-1",
			expiresAt: "2026-11-18T22:00:00Z",
			selfMemberId: "a1b2c3d4e5f6",
			members: [
				{
					memberId: "a1b2c3d4e5f6",
					displayName: "Diana",
					colorHex: "#242734",
					lat: 45.44,
					lon: 25.55,
					ele: 1200,
					accuracy: 6.5,
					inNavigation: true,
					isSelf: true,
					updatedAt: "2026-11-18T10:00:00Z",
				},
			],
		};

		const fetchSpy = vi.fn().mockImplementation((url: string, init?: RequestInit) => {
			if (url.includes("/live/stream")) {
				const encoder = new TextEncoder();
				const upstreamBody = new ReadableStream<Uint8Array>({
					start(controller) {
						controller.enqueue(
							encoder.encode(
								`event: group_member_update\ndata: ${JSON.stringify(sampleSession.members[0])}\n\n`,
							),
						);
						controller.close();
					},
				});
				return Promise.resolve(
					new Response(upstreamBody, {
						status: 200,
						headers: { "Content-Type": "text/event-stream" },
					}),
				);
			}
			if (url.endsWith("/leave")) {
				return Promise.resolve(Response.json({ ok: true }));
			}
			return Promise.resolve(Response.json(sampleSession));
		});
		vi.stubGlobal("fetch", fetchSpy);

		// 1. Create group validation (displayName 1..24 trimmed) + valid POST
		const emptyNameReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ displayName: "   ", trailId: "bucegi-1" }),
		});
		expect(
			(
				await postCreateGroup({
					request: emptyNameReq,
					url: new URL(emptyNameReq.url),
					locals: {},
				} as never)
			).status,
		).toBe(400);

		const longNameReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ displayName: "X".repeat(25), trailId: "bucegi-1" }),
		});
		expect(
			(
				await postCreateGroup({
					request: longNameReq,
					url: new URL(longNameReq.url),
					locals: {},
				} as never)
			).status,
		).toBe(400);

		const createReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({
				displayName: "  Diana  ",
				trailId: "bucegi-1",
				lat: 45.44,
				lon: 25.55,
				ele: 1200,
				accuracy: 6.5,
			}),
		});
		const createRes = await postCreateGroup({
			request: createReq,
			url: new URL(createReq.url),
			locals: { user: { actor: "actor-diana" } },
		} as never);
		expect(createRes.status).toBe(200);
		expect(await createRes.json()).toEqual(sampleSession);

		const [createUrl, createInit] = fetchSpy.mock.calls[0] as [string, RequestInit];
		expect(createUrl).toBe("http://pocketbase.internal:8090/live/groups");
		expect(JSON.parse(String(createInit.body))).toMatchObject({
			displayName: "Diana",
			trailId: "bucegi-1",
			lat: 45.44,
			lon: 25.55,
			ele: 1200,
			accuracy: 6.5,
		});

		// 2. Invalid group codes rejected on GET, join, ping, leave before upstream fetch
		const callsBeforeInvalid = fetchSpy.mock.calls.length;
		for (const badCode of ["AB01IO", "k7m9p2", "SHORT"]) {
			const badGetReq = new Request(`https://trasee.skillfy.ro/api/v1/live/groups/${badCode}`, {
				headers: { "X-Device-Token": VALID_TOKEN_A },
			});
			expect(
				(
					await getGroupByCode({
						request: badGetReq,
						url: new URL(badGetReq.url),
						params: { code: badCode },
						locals: {},
					} as never)
				).status,
			).toBe(400);
		}
		expect(fetchSpy.mock.calls.length).toBe(callsBeforeInvalid);

		// 3. Valid GET /groups/[code] & POST /groups/[code]/join
		const getReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2", {
			headers: { "X-Device-Token": VALID_TOKEN_A },
		});
		const getRes = await getGroupByCode({
			request: getReq,
			url: new URL(getReq.url),
			params: { code: "K7M9P2" },
			locals: {},
		} as never);
		expect(getRes.status).toBe(200);

		const joinReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2/join", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_B },
			body: JSON.stringify({ displayName: "Andrei", lat: 45.441, lon: 25.551, accuracy: 8 }),
		});
		const joinRes = await postJoinGroup({
			request: joinReq,
			url: new URL(joinReq.url),
			params: { code: "K7M9P2" },
			locals: {},
		} as never);
		expect(joinRes.status).toBe(200);

		// 4. Ping validates lat/lon & enforces 30 req/min rate limiter
		const badPingReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2/ping", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ lat: 120, lon: 25.55 }),
		});
		expect(
			(
				await postPingGroup({
					request: badPingReq,
					url: new URL(badPingReq.url),
					params: { code: "K7M9P2" },
					locals: {},
				} as never)
			).status,
		).toBe(400);

		liveRateLimiters.groupPing.reset();
		for (let i = 0; i < 30; i++) {
			const pingReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2/ping", {
				method: "POST",
				headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
				body: JSON.stringify({
					lat: 45.44,
					lon: 25.55,
					ele: 1210,
					accuracy: 5.5,
					alongTrackM: 340,
					inNavigation: true,
				}),
			});
			const pingRes = await postPingGroup({
				request: pingReq,
				url: new URL(pingReq.url),
				params: { code: "K7M9P2" },
				locals: {},
			} as never);
			expect(pingRes.status).toBe(200);
		}
		// 31st ping in same 60s window returns 429
		const ping31Req = new Request("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2/ping", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ lat: 45.44, lon: 25.55 }),
		});
		const ping31Res = await postPingGroup({
			request: ping31Req,
			url: new URL(ping31Req.url),
			params: { code: "K7M9P2" },
			locals: {},
		} as never);
		expect(ping31Res.status).toBe(429);

		// 5. Leave group
		const leaveReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups/K7M9P2/leave", {
			method: "POST",
			headers: { "X-Device-Token": VALID_TOKEN_B },
		});
		const leaveRes = await postLeaveGroup({
			request: leaveReq,
			url: new URL(leaveReq.url),
			params: { code: "K7M9P2" },
			locals: {},
		} as never);
		expect(leaveRes.status).toBe(200);
		expect(await leaveRes.json()).toEqual({ ok: true });

		// 6. Stream forwards valid groupCode alongside lat, lon, trailId
		const streamUrl = new URL(
			`https://trasee.skillfy.ro/api/v1/live/stream?lat=45.44&lon=25.55&trailId=bucegi-1&groupCode=K7M9P2&deviceToken=${VALID_TOKEN_A}`,
		);
		const streamRes = await getStream({
			request: new Request(streamUrl),
			url: streamUrl,
			locals: {},
		} as never);
		expect(streamRes.status).toBe(200);
		const lastStreamCallUrl = fetchSpy.mock.calls[fetchSpy.mock.calls.length - 1][0] as string;
		expect(lastStreamCallUrl).toBe(
			"http://pocketbase.internal:8090/live/stream?lat=45.44&lon=25.55&trailId=bucegi-1&groupCode=K7M9P2",
		);
		await streamRes.body?.cancel();
	});

	it("validates POST /api/v1/live/sos/relay hex claims, coordinates, 20/5m rate limit, and dispatches VAPID push ONLY when created === true", async () => {
		expect(isRouteProtected(new URL("https://trasee.skillfy.ro/api/v1/live/sos/relay"))).toBe(false);
		expect(liveRateLimiters.sosRelay.maxRequests).toBe(20);
		expect(liveRateLimiters.sosRelay.windowMs).toBe(5 * 60_000);
		liveRateLimiters.sosRelay.reset();

		const pushMock = vi.mocked(dispatchSosPushNotifications);
		pushMock.mockClear();
		pushMock.mockResolvedValue({ sent: 1, staleRemoved: 0, failed: 0 });

		const fetchSpy = vi.fn();
		vi.stubGlobal("fetch", fetchSpy);

		const makeRelayEvent = (bodyObj: unknown, token = VALID_TOKEN_A) => {
			const req = new Request("https://trasee.skillfy.ro/api/v1/live/sos/relay", {
				method: "POST",
				headers: {
					"Content-Type": "application/json",
					"X-Device-Token": token,
				},
				body: JSON.stringify(bodyObj),
			});
			return {
				request: req,
				url: new URL(req.url),
				locals: { user: { actor: "mule-actor" } },
			} as never;
		};

		// 1. Validation failures must return 400 without hitting upstream
		const badPayloads = [
			// Invalid clientSosId
			{ clientSosId: "short", sosClaimHash: "0123456789abcdef", lat: 45.4, lon: 25.5 },
			{ clientSosId: "zzzzzzzzzzzzzzzz", sosClaimHash: "0123456789abcdef", lat: 45.4, lon: 25.5 },
			// Missing / invalid sosClaimHash when status !== "resolved"
			{ clientSosId: "a1b2c3d4e5f60718", lat: 45.4, lon: 25.5 },
			{ clientSosId: "a1b2c3d4e5f60718", sosClaimHash: "bad-hash", lat: 45.4, lon: 25.5 },
			// Missing / invalid coordinates when status !== "resolved"
			{ clientSosId: "a1b2c3d4e5f60718", sosClaimHash: "0123456789abcdef" },
			{ clientSosId: "a1b2c3d4e5f60718", sosClaimHash: "0123456789abcdef", lat: null, lon: 25.5 },
			{ clientSosId: "a1b2c3d4e5f60718", sosClaimHash: "0123456789abcdef", lat: 95, lon: 25.5 },
			// Malformed sosClaimSecret when status === "resolved"
			{
				clientSosId: "a1b2c3d4e5f60718",
				status: "resolved",
				sosClaimSecret: "not-32-hex",
			},
		];

		for (const bad of badPayloads) {
			liveRateLimiters.sosRelay.reset();
			const res = await postSosRelay(makeRelayEvent(bad));
			expect(res.status).toBe(400);
		}
		expect(fetchSpy).not.toHaveBeenCalled();

		// 2. First relay (created: true, pushTargets non-empty) -> normalizes hex lowercase, triggers VAPID push, strips pushTargets & created
		liveRateLimiters.sosRelay.reset();
		fetchSpy.mockResolvedValueOnce(
			Response.json({
				sos: {
					id: "sos-relayed-1",
					clientSosId: "a1b2c3d4e5f60718",
					trailId: "bucegi-1",
					status: "active",
					reason: "injury",
					isMine: false,
				},
				pushTargets: [
					{
						endpoint: "https://push.example/target-1",
						p256dh: "p256dh-1",
						auth: "auth-1",
						distanceM: 520,
					},
				],
				created: true,
			}),
		);

		const firstRes = await postSosRelay(
			makeRelayEvent({
				clientSosId: "  A1B2C3D4E5F60718  ",
				sosClaimHash: "  FEDCBA9876543210 ",
				trailId: "bucegi-1",
				reason: "injury",
				message: "Picior luxat în vale",
				requesterName: "Mihai",
				lat: 45.412,
				lon: 25.456,
				ele: 1680,
				packetEpochSec: 1_795_000_120,
				hopCount: 2,
			}),
		);
		expect(firstRes.status).toBe(200);
		const firstData = await firstRes.json();
		expect(firstData).toEqual({
			sos: {
				id: "sos-relayed-1",
				clientSosId: "a1b2c3d4e5f60718",
				trailId: "bucegi-1",
				status: "active",
				reason: "injury",
				isMine: false,
			},
		});
		expect(firstData.pushTargets).toBeUndefined();
		expect(firstData.created).toBeUndefined();

		expect(fetchSpy).toHaveBeenCalledTimes(1);
		const [relayUrl, relayInit] = fetchSpy.mock.calls[0] as [string, RequestInit];
		expect(relayUrl).toBe("http://pocketbase.internal:8090/live/sos/relay");
		expect(JSON.parse(String(relayInit.body))).toEqual({
			clientSosId: "a1b2c3d4e5f60718",
			sosClaimHash: "fedcba9876543210",
			trailId: "bucegi-1",
			reason: "injury",
			message: "Picior luxat în vale",
			requesterName: "Mihai",
			lat: 45.412,
			lon: 25.456,
			ele: 1680,
			packetEpochSec: 1_795_000_120,
			hopCount: 2,
		});
		expect(pushMock).toHaveBeenCalledTimes(1);

		// 3. Duplicate relay (created: false) -> MUST NOT trigger VAPID push even if pushTargets were non-empty
		pushMock.mockClear();
		fetchSpy.mockResolvedValueOnce(
			Response.json({
				sos: { id: "sos-relayed-1", clientSosId: "a1b2c3d4e5f60718", status: "active" },
				pushTargets: [
					{
						endpoint: "https://push.example/target-1",
						p256dh: "p256dh-1",
						auth: "auth-1",
						distanceM: 520,
					},
				],
				created: false,
			}),
		);
		const dupRes = await postSosRelay(
			makeRelayEvent(
				{
					clientSosId: "a1b2c3d4e5f60718",
					sosClaimHash: "fedcba9876543210",
					lat: 45.4125,
					lon: 25.4565,
					packetEpochSec: 1_795_000_180,
				},
				VALID_TOKEN_B,
			),
		);
		expect(dupRes.status).toBe(200);
		expect(pushMock).not.toHaveBeenCalled();

		// 4. Relayed resolution (status === "resolved") -> coordinates not required, optional sosClaimSecret normalized lowercase
		fetchSpy.mockResolvedValueOnce(
			Response.json({
				sos: { id: "sos-relayed-1", clientSosId: "a1b2c3d4e5f60718", status: "resolved" },
				pushTargets: [],
				created: false,
			}),
		);
		const resolveRes = await postSosRelay(
			makeRelayEvent({
				clientSosId: "A1B2C3D4E5F60718",
				status: "resolved",
				sosClaimSecret: "00112233445566778899AABBCCDDEEFF",
				packetEpochSec: 1_795_000_300,
			}),
		);
		expect(resolveRes.status).toBe(200);
		const [, resolveInit] = fetchSpy.mock.calls[2] as [string, RequestInit];
		expect(JSON.parse(String(resolveInit.body))).toMatchObject({
			clientSosId: "a1b2c3d4e5f60718",
			status: "resolved",
			sosClaimSecret: "00112233445566778899aabbccddeeff",
			packetEpochSec: 1_795_000_300,
		});
		expect(pushMock).not.toHaveBeenCalled();

		// 5. Rate limiter enforces 20 req / 5 min per deviceHash
		liveRateLimiters.sosRelay.reset();
		fetchSpy.mockImplementation(() =>
			Promise.resolve(
				Response.json({
					sos: { id: "sos-r", status: "active" },
					pushTargets: [],
					created: false,
				}),
			),
		);
		for (let i = 0; i < 20; i++) {
			const okRes = await postSosRelay(
				makeRelayEvent({
					clientSosId: "a1b2c3d4e5f60718",
					sosClaimHash: "fedcba9876543210",
					lat: 45.4,
					lon: 25.5,
				}),
			);
			expect(okRes.status).toBe(200);
		}
		const rateLimitedRes = await postSosRelay(
			makeRelayEvent({
				clientSosId: "a1b2c3d4e5f60718",
				sosClaimHash: "fedcba9876543210",
				lat: 45.4,
				lon: 25.5,
			}),
		);
		expect(rateLimitedRes.status).toBe(429);
		liveRateLimiters.sosRelay.reset();
	});

	it("forwards optional clientSosId & sosClaimSecret on POST /sos & PATCH /sos/[id] and optional preferredCode on POST /groups", async () => {
		liveRateLimiters.sos.reset();
		liveRateLimiters.sosUpdate.reset();
		liveRateLimiters.groupCreate.reset();

		const fetchSpy = vi.fn().mockImplementation((url: string) => {
			if (url.endsWith("/live/groups")) {
				return Promise.resolve(
					Response.json({
						code: "K7M9P2",
						trailId: "bucegi-1",
						expiresAt: "2026-11-18T22:00:00Z",
						selfMemberId: "a1b2c3d4e5f6",
						members: [],
					}),
				);
			}
			return Promise.resolve(
				Response.json({
					sos: {
						id: "sos-claimed",
						clientSosId: "a1b2c3d4e5f60718",
						status: "active",
						isMine: true,
					},
					pushTargets: [],
				}),
			);
		});
		vi.stubGlobal("fetch", fetchSpy);

		// 1. POST /api/v1/live/sos rejects bad clientSosId / sosClaimSecret, normalizes & forwards valid ones
		const badClaimPost = new Request("https://trasee.skillfy.ro/api/v1/live/sos", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({
				reason: "injury",
				lat: 45.41,
				lon: 25.45,
				clientSosId: "invalid-hex",
			}),
		});
		expect(
			(
				await postSos({
					request: badClaimPost,
					url: new URL(badClaimPost.url),
					locals: {},
				} as never)
			).status,
		).toBe(400);

		const claimPostReq = new Request("https://trasee.skillfy.ro/api/v1/live/sos", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({
				trailId: "bucegi-1",
				reason: "injury",
				lat: 45.41,
				lon: 25.45,
				clientSosId: "A1B2C3D4E5F60718",
				sosClaimSecret: "00112233445566778899AABBCCDDEEFF",
			}),
		});
		const claimPostRes = await postSos({
			request: claimPostReq,
			url: new URL(claimPostReq.url),
			locals: {},
		} as never);
		expect(claimPostRes.status).toBe(200);
		expect(JSON.parse(String((fetchSpy.mock.calls[0] as [string, RequestInit])[1].body))).toMatchObject({
			clientSosId: "a1b2c3d4e5f60718",
			sosClaimSecret: "00112233445566778899aabbccddeeff",
		});

		// 2. PATCH /api/v1/live/sos/[id] rejects malformed sosClaimSecret, forwards valid lowercase
		const badPatchReq = new Request("https://trasee.skillfy.ro/api/v1/live/sos/sos-claimed", {
			method: "PATCH",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({ status: "resolved", sosClaimSecret: "short" }),
		});
		expect(
			(
				await patchSos({
					request: badPatchReq,
					url: new URL(badPatchReq.url),
					params: { id: "sos-claimed" },
					locals: {},
				} as never)
			).status,
		).toBe(400);

		const validPatchReq = new Request("https://trasee.skillfy.ro/api/v1/live/sos/sos-claimed", {
			method: "PATCH",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({
				status: "resolved",
				sosClaimSecret: "FFEEDDCCBBAA99887766554433221100",
			}),
		});
		const validPatchRes = await patchSos({
			request: validPatchReq,
			url: new URL(validPatchReq.url),
			params: { id: "sos-claimed" },
			locals: {},
		} as never);
		expect(validPatchRes.status).toBe(200);
		expect(JSON.parse(String((fetchSpy.mock.calls[1] as [string, RequestInit])[1].body))).toEqual({
			status: "resolved",
			sosClaimSecret: "ffeeddccbbaa99887766554433221100",
		});

		// 3. POST /api/v1/live/groups validates & normalizes optional preferredCode uppercase
		const badGroupPrefReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({
				displayName: "Diana",
				preferredCode: "AB01IO", // 0, 1, I, O forbidden
			}),
		});
		expect(
			(
				await postCreateGroup({
					request: badGroupPrefReq,
					url: new URL(badGroupPrefReq.url),
					locals: {},
				} as never)
			).status,
		).toBe(400);

		const validGroupPrefReq = new Request("https://trasee.skillfy.ro/api/v1/live/groups", {
			method: "POST",
			headers: { "Content-Type": "application/json", "X-Device-Token": VALID_TOKEN_A },
			body: JSON.stringify({
				displayName: "Diana",
				trailId: "bucegi-1",
				preferredCode: "  k7m9p2 ",
			}),
		});
		const validGroupPrefRes = await postCreateGroup({
			request: validGroupPrefReq,
			url: new URL(validGroupPrefReq.url),
			locals: {},
		} as never);
		expect(validGroupPrefRes.status).toBe(200);
		expect(JSON.parse(String((fetchSpy.mock.calls[2] as [string, RequestInit])[1].body))).toEqual({
			displayName: "Diana",
			trailId: "bucegi-1",
			preferredCode: "K7M9P2",
		});
	});
});
