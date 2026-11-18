import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("maplibre-gl", () => {
	class MockPopup {
		domContent: unknown = null;
		setDOMContent(dom: unknown) {
			this.domContent = dom;
			return this;
		}
	}
	class MockMarker {
		element: unknown;
		lngLat: [number, number] | null = null;
		popup: MockPopup | null = null;
		removed = false;
		constructor(opts?: { element?: unknown }) {
			this.element = opts?.element ?? null;
		}
		setLngLat(coords: [number, number]) {
			this.lngLat = coords;
			return this;
		}
		setPopup(popup: MockPopup) {
			this.popup = popup;
			return this;
		}
		addTo() {
			return this;
		}
		remove() {
			this.removed = true;
		}
	}
	return { Marker: MockMarker, Popup: MockPopup };
});

import { computeDirectRescueRoute } from "#lib/navigation/off_trail_router.ts";
import {
	clearHeartbeat,
	clearSavedGroupSession,
	connectLiveStream,
	createLiveGroup,
	createReport,
	fetchLiveGroup,
	fetchTrailLiveSummary,
	formatConfirmedAgo,
	getOrCreateDeviceToken,
	getReportCategoryMeta,
	getSavedGroupSession,
	GROUP_CODE_RE,
	hasVotedOnReport,
	isReportVisibleOnMap,
	joinLiveGroup,
	leaveLiveGroup,
	mergeGroupMemberIntoList,
	mergeReportIntoList,
	mergeSosIntoList,
	normalizeSosDto,
	pingLiveGroup,
	removeGroupMemberFromList,
	REPORT_CATEGORIES,
	respondToSos,
	saveGroupSession,
	sendHeartbeat,
	subscribeWebPushIfSupported,
	triggerSos,
	updateSos,
	urlBase64ToUint8Array,
	voteReport,
	type GroupMemberDto,
} from "./live_client.ts";
import { getGroupMemberInitials, syncGroupMapMarkers } from "./report_markers.ts";

const BASE_LAT = 45.45;
const BASE_LON = 25.55;
const M_PER_DEG_LAT = (Math.PI / 180) * 6371000;
const M_PER_DEG_LON = M_PER_DEG_LAT * Math.cos((BASE_LAT * Math.PI) / 180);

function offsetLatLon(eastM: number, northM: number): { lat: number; lon: number } {
	return {
		lat: BASE_LAT + northM / M_PER_DEG_LAT,
		lon: BASE_LON + eastM / M_PER_DEG_LON,
	};
}

describe("live_client device token, categories, and report lifecycle", () => {
	const origWindow = globalThis.window;
	const origFetch = globalThis.fetch;
	let store: Record<string, string> = {};

	beforeEach(() => {
		store = {};
		(globalThis as Record<string, unknown>).window = {
			localStorage: {
				getItem: (k: string) => store[k] ?? null,
				setItem: (k: string, v: string) => {
					store[k] = v;
				},
				removeItem: (k: string) => {
					delete store[k];
				},
			},
			atob: (b64: string) => Buffer.from(b64, "base64").toString("binary"),
		};
	});

	afterEach(() => {
		(globalThis as Record<string, unknown>).window = origWindow;
		globalThis.fetch = origFetch;
		vi.restoreAllMocks();
	});

	it("generates and persists a 64-char hex wanderer_device_token", () => {
		const token1 = getOrCreateDeviceToken();
		expect(token1).toMatch(/^[0-9a-f]{64}$/);
		expect(store.wanderer_device_token).toBe(token1);

		const token2 = getOrCreateDeviceToken();
		expect(token2).toBe(token1);
	});

	it("exposes all 5 temporary categories (including positive green deer) and 3 permanent landmarks", () => {
		const temp = REPORT_CATEGORIES.filter((c) => !c.isPermanent);
		const perm = REPORT_CATEGORIES.filter((c) => c.isPermanent);
		expect(temp.map((c) => c.category)).toEqual([
			"bear",
			"shepherd_dogs",
			"fallen_tree_terrain",
			"ice_mud",
			"deer",
		]);
		expect(perm.map((c) => c.category)).toEqual(["spring", "viewpoint", "shelter"]);

		const deerMeta = getReportCategoryMeta("deer");
		expect(deerMeta.kind).toBe("wildlife_good");
		expect(deerMeta.isPermanent).toBe(false);
		expect(getReportCategoryMeta("spring").isPermanent).toBe(true);
	});

	it("evaluates report visibility for temporary TTL vs permanent seasonal landmarks", () => {
		const now = Date.parse("2026-11-17T18:00:00Z");

		const activeBear = {
			id: "r-bear",
			trailId: "t1",
			category: "bear" as const,
			kind: "hazard",
			isPermanent: false,
			conditionStatus: "active" as const,
			note: "Urs pe potecă",
			lat: 45.45,
			lon: 25.55,
			ele: 1200,
			alongTrackM: 450,
			confirmCount: 2,
			dismissCount: 0,
			createdAt: "2026-11-17T17:30:00Z",
			lastConfirmedAt: "2026-11-17T17:45:00Z",
			expiresAt: "2026-11-17T20:45:00Z",
		};
		expect(isReportVisibleOnMap(activeBear, now)).toBe(true);
		expect(formatConfirmedAgo(activeBear.lastConfirmedAt, "ro", now)).toBe(
			"Confirmat acum 15 min",
		);

		// Expired temporary alert hides automatically
		expect(
			isReportVisibleOnMap(
				{ ...activeBear, expiresAt: "2026-11-17T17:59:00Z" },
				now,
			),
		).toBe(false);

		// Resolved temporary alert hides immediately
		expect(
			isReportVisibleOnMap({ ...activeBear, conditionStatus: "resolved" }, now),
		).toBe(false);

		// Permanent spring with seasonal dry_or_closed status never expires and remains visible
		const drySpring = {
			...activeBear,
			id: "r-spring",
			category: "spring" as const,
			kind: "landmark_permanent",
			isPermanent: true,
			conditionStatus: "dry_or_closed" as const,
			expiresAt: null,
		};
		expect(isReportVisibleOnMap(drySpring, now + 90 * 86_400_000)).toBe(true);
		expect(
			mergeReportIntoList([activeBear], {
				...activeBear,
				conditionStatus: "resolved",
			}),
		).toEqual([]);
	});

	it("sends X-Device-Token across heartbeat, summary, report vote, SOS, and Web Push endpoints", async () => {
		const calls: Array<{ url: string; method: string; token: string | null; body: unknown }> =
			[];

		globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const url = String(input);
			const headers = new Headers(init?.headers);
			const body = init?.body ? JSON.parse(String(init.body)) : null;
			calls.push({
				url,
				method: init?.method ?? "GET",
				token: headers.get("X-Device-Token"),
				body,
			});

			if (url === "/api/v1/live/heartbeat") {
				return new Response(
					JSON.stringify({
						activeHikers30m: 4,
						reports: [
							{
								id: "rep-1",
								trailId: "trail-1",
								category: "spring",
								kind: "landmark_permanent",
								isPermanent: true,
								conditionStatus: "active",
								note: "Apă rece",
								lat: 45.45,
								lon: 25.55,
								ele: 1100,
								alongTrackM: 320,
								confirmCount: 3,
								dismissCount: 0,
								createdAt: "2026-11-17T17:00:00Z",
								lastConfirmedAt: "2026-11-17T17:10:00Z",
								expiresAt: null,
							},
						],
						sosAlerts: [],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/trail/trail-1/summary") {
				return new Response(
					JSON.stringify({
						trailId: "trail-1",
						activeHikers30m: 4,
						reports: [],
						sosAlerts: [],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/reports") {
				return new Response(
					JSON.stringify({
						report: {
							id: "rep-bear-1",
							trailId: "trail-1",
							category: "bear",
							kind: "hazard",
							isPermanent: false,
							conditionStatus: "active",
							note: "Urme proaspete",
							lat: 45.451,
							lon: 25.551,
							ele: 1140,
							alongTrackM: 600,
							confirmCount: 1,
							dismissCount: 0,
							createdAt: "2026-11-17T17:30:00Z",
							lastConfirmedAt: "2026-11-17T17:30:00Z",
							expiresAt: "2026-11-17T20:30:00Z",
						},
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/reports/rep-1/vote") {
				return new Response(
					JSON.stringify({
						report: {
							id: "rep-1",
							trailId: "trail-1",
							category: "spring",
							kind: "landmark_permanent",
							isPermanent: true,
							conditionStatus: "dry_or_closed",
							note: "Apă rece",
							lat: 45.45,
							lon: 25.55,
							ele: 1100,
							alongTrackM: 320,
							confirmCount: 3,
							dismissCount: 0,
							createdAt: "2026-11-17T17:00:00Z",
							lastConfirmedAt: "2026-11-17T17:35:00Z",
							expiresAt: null,
						},
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/sos") {
				return new Response(
					JSON.stringify({
						sos: {
							id: "sos-99",
							trailId: "trail-1",
							status: "active",
							reason: "injury",
							message: "Entorsă gleznă",
							requesterName: "Andrei",
							lat: 45.452,
							lon: 25.552,
							ele: 1320,
							responderCount: 0,
							nearestEtaSec: null,
							nearestDistanceM: null,
							isMine: true,
							amResponding: false,
							createdAt: "2026-11-17T17:40:00Z",
							expiresAt: "2026-11-17T23:40:00Z",
						},
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/sos/sos-other/respond") {
				return new Response(
					JSON.stringify({
						sos: {
							id: "sos-other",
							trailId: "trail-1",
							status: "active",
							reason: "lost",
							message: "",
							requesterName: "Elena",
							lat: 45.46,
							lon: 25.56,
							ele: 1400,
							responderCount: 1,
							nearestEtaSec: 780,
							nearestDistanceM: 920,
							isMine: false,
							amResponding: true,
							createdAt: "2026-11-17T17:40:00Z",
							expiresAt: "2026-11-17T23:40:00Z",
						},
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/sos/sos-99") {
				return new Response(
					JSON.stringify({
						sos: {
							id: "sos-99",
							status: "resolved",
						},
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/push/vapid-public-key") {
				return new Response(JSON.stringify({ publicKey: "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U" }), {
					status: 200,
					headers: { "content-type": "application/json" },
				});
			}
			if (url === "/api/v1/live/push/subscribe") {
				return new Response(JSON.stringify({ ok: true }), {
					status: 200,
					headers: { "content-type": "application/json" },
				});
			}
			// Fallback HTML (simulates unmocked route in Playwright harness)
			return new Response("<!doctype html><html></html>", {
				status: 200,
				headers: { "content-type": "text/html" },
			});
		}) as unknown as typeof fetch;

		const hb = await sendHeartbeat({
			trailId: "trail-1",
			lat: 45.45,
			lon: 25.55,
			ele: 1100,
			inNavigation: true,
		});
		expect(hb?.activeHikers30m).toBe(4);
		expect(hb?.reports).toHaveLength(1);

		const sum = await fetchTrailLiveSummary("trail-1");
		expect(sum?.activeHikers30m).toBe(4);

		const created = await createReport({
			trailId: "trail-1",
			category: "bear",
			note: "Urme proaspete",
			lat: 45.451,
			lon: 25.551,
			ele: 1140,
			alongTrackM: 600,
		});
		expect(created?.id).toBe("rep-bear-1");
		expect(hasVotedOnReport("rep-bear-1")).toBe(true);

		const voted = await voteReport("rep-1", "seasonal_dry");
		expect(voted?.conditionStatus).toBe("dry_or_closed");
		expect(hasVotedOnReport("rep-1")).toBe(true);

		const mySos = await triggerSos({
			trailId: "trail-1",
			reason: "injury",
			message: "Entorsă gleznă",
			requesterName: "Andrei",
			lat: 45.452,
			lon: 25.552,
			ele: 1320,
		});
		expect(mySos?.isMine).toBe(true);

		// Even if an SSE broadcast arrives with isMine: false, knownMySosIds preserves isMine === true!
		const sseMerged = normalizeSosDto({
			id: "sos-99",
			trailId: "trail-1",
			status: "active",
			reason: "injury",
			responderCount: 2,
			nearestDistanceM: 450,
			nearestEtaSec: 360,
			isMine: false,
		});
		expect(sseMerged?.isMine).toBe(true);
		expect(sseMerged?.responderCount).toBe(2);

		const respSos = await respondToSos("sos-other", {
			status: "coming",
			lat: 45.45,
			lon: 25.55,
			ele: 1100,
			distanceM: 920.4,
			etaSec: 780.2,
		});
		expect(respSos?.amResponding).toBe(true);

		const resolved = await updateSos("sos-99", { status: "resolved" });
		expect(mergeSosIntoList([mySos!], resolved!)).toEqual([]);

		// Non-JSON HTML fallback returns null gracefully without throwing
		const htmlFallback = await fetchTrailLiveSummary("unmocked-trail");
		expect(htmlFallback).toBeNull();

		// Every call carried the exact same 64-char X-Device-Token
		const token = getOrCreateDeviceToken();
		for (const c of calls) {
			expect(c.token).toBe(token);
		}

		// Verify base64url VAPID helper + Web Push subscription flow
		const keyBytes = urlBase64ToUint8Array("BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U");
		expect(keyBytes.byteLength).toBe(65);

		const mockNotification = {
			permission: "granted",
			requestPermission: vi.fn().mockResolvedValue("granted"),
		};
		(globalThis.window as unknown as Record<string, unknown>).PushManager = class {};
		(globalThis.window as unknown as Record<string, unknown>).Notification = mockNotification;
		(globalThis as unknown as Record<string, unknown>).Notification = mockNotification;
		const origNav = globalThis.navigator;
		Object.defineProperty(globalThis, "navigator", {
			configurable: true,
			value: {
				serviceWorker: {
					register: vi.fn().mockResolvedValue({
						pushManager: {
							getSubscription: vi.fn().mockResolvedValue(null),
							subscribe: vi.fn().mockResolvedValue({
								toJSON: () => ({
									endpoint: "https://push.example.test/sub/1",
									keys: { p256dh: "k-p256dh", auth: "k-auth" },
								}),
							}),
						},
					}),
					ready: Promise.resolve({}),
				},
			},
		});
		try {
			const pushResult = await subscribeWebPushIfSupported(45.45, 25.55, "trail-1");
			expect(pushResult).toBe("subscribed");
			expect(calls.some((c) => c.url === "/api/v1/live/push/subscribe")).toBe(true);
		} finally {
			Object.defineProperty(globalThis, "navigator", {
				configurable: true,
				value: origNav,
			});
			delete (globalThis as Record<string, unknown>).Notification;
		}
	});

	it("connects EventSource with deviceToken query param and parses SSE report_update & sos_update", () => {
		const origES = globalThis.EventSource;
		const instances: Array<{
			url: string;
			listeners: Record<string, EventListener>;
			onerror: (() => void) | null;
			closed: boolean;
		}> = [];

		(globalThis as Record<string, unknown>).EventSource = class {
			url: string;
			listeners: Record<string, EventListener> = {};
			onerror: (() => void) | null = null;
			closed = false;
			constructor(url: string) {
				this.url = url;
				instances.push(this);
			}
			addEventListener(type: string, fn: EventListener) {
				this.listeners[type] = fn;
			}
			close() {
				this.closed = true;
			}
		};

		try {
			const receivedReports: string[] = [];
			const receivedSos: string[] = [];
			const handle = connectLiveStream({
				trailId: "trail-sse",
				lat: 45.45,
				lon: 25.55,
				callbacks: {
					onReportUpdate: (r) => receivedReports.push(r.id),
					onSosUpdate: (s) => receivedSos.push(s.id),
				},
			});

			expect(instances).toHaveLength(1);
			expect(instances[0].url).toContain("trailId=trail-sse");
			expect(instances[0].url).toContain(`deviceToken=${getOrCreateDeviceToken()}`);

			instances[0].listeners.report_update({
				data: JSON.stringify({
					report: {
						id: "r-sse-1",
						category: "deer",
						lat: 45.45,
						lon: 25.55,
					},
				}),
			} as unknown as Event);

			instances[0].listeners.sos_update({
				data: JSON.stringify({
					sos: {
						id: "sos-sse-1",
						status: "active",
						reason: "lost",
						lat: 45.46,
						lon: 25.56,
					},
				}),
			} as unknown as Event);

			expect(receivedReports).toEqual(["r-sse-1"]);
			expect(receivedSos).toEqual(["sos-sse-1"]);

			handle.close();
			expect(instances[0].closed).toBe(true);
		} finally {
			(globalThis as Record<string, unknown>).EventSource = origES;
		}
	});
});

describe("computeDirectRescueRoute (DEM A* to SOS victim)", () => {
	it("contours around a steep 45° cliff ridge directly to the SOS target and scales to 3.5 km rescue radius", () => {
		const responder = offsetLatLon(0, 0);
		const victim = offsetLatLon(0, 220);

		// Steep 45° cliff wall blocking direct North path (east in [-90..90], north in [80..130])
		const cliffSampler = (lat: number, lon: number): number => {
			const e = (lon - BASE_LON) * M_PER_DEG_LON;
			const n = (lat - BASE_LAT) * M_PER_DEG_LAT;
			if (e >= -90 && e <= 90 && n >= 80 && n <= 130) {
				const distEdge = Math.min(n - 80, 130 - n);
				return 1100 + Math.min(55, distEdge * 2.3);
			}
			return 1100 + (n / 220) * 18;
		};

		const route = computeDirectRescueRoute({
			fromLat: responder.lat,
			fromLon: responder.lon,
			fromEle: 1100,
			targetLat: victim.lat,
			targetLon: victim.lon,
			targetEle: 1118,
			sampler: cliffSampler,
			mode: "min-climb",
			locale: "ro",
		});

		expect(route.points.length).toBeGreaterThan(2);
		expect(route.maxSlopeDeg).toBeLessThan(37);
		expect(route.avoidedSteepHazard).toBe(true);
		expect(route.distanceM).toBeGreaterThan(220);
		expect(route.estimatedSeconds).toBeGreaterThan(100);
		expect(route.instruction).toContain("SOS");

		// Verify 3.5 km SOS rescue distance reaches exact victim coordinates without grid boundary clipping
		const farVictim = offsetLatLon(2400, 2500); // ~3,465 m away
		const farRoute = computeDirectRescueRoute({
			fromLat: responder.lat,
			fromLon: responder.lon,
			fromEle: 1000,
			targetLat: farVictim.lat,
			targetLon: farVictim.lon,
			targetEle: 1350,
			sampler: () => null,
			mode: "min-climb",
			locale: "ro",
		});

		expect(farRoute.distanceM).toBeGreaterThan(3350);
		expect(farRoute.ascentM).toBeGreaterThan(300);
		const endPt = farRoute.points[farRoute.points.length - 1];
		expect(endPt.lat).toBeCloseTo(farVictim.lat, 5);
		expect(endPt.lon).toBeCloseTo(farVictim.lon, 5);
		expect(endPt.ele).toBeCloseTo(1350, 1);
	});
});

describe("live_client location-based summary & clearHeartbeat", () => {
	const origWindow = globalThis.window;
	const origFetch = globalThis.fetch;

	afterEach(() => {
		(globalThis as Record<string, unknown>).window = origWindow;
		globalThis.fetch = origFetch;
	});

	it("passes optional lat/lon to fetchTrailLiveSummary and sends DELETE on clearHeartbeat", async () => {
		const calls: Array<{ url: string; method: string }> = [];
		globalThis.fetch = vi.fn().mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
			const url = typeof input === "string" ? input : input.toString();
			calls.push({ url, method: init?.method ?? "GET" });
			return new Response(
				JSON.stringify({ trailId: "t-1", activeHikers30m: 2, reports: [], sosAlerts: [] }),
				{ status: 200, headers: { "content-type": "application/json" } },
			);
		});

		const sum = await fetchTrailLiveSummary("t-1", { lat: 45.44, lon: 25.55 });
		expect(sum?.activeHikers30m).toBe(2);
		expect(calls[0]).toEqual({
			url: "/api/v1/live/trail/t-1/summary?lat=45.44&lon=25.55",
			method: "GET",
		});

		await clearHeartbeat();
		expect(calls[1]).toEqual({
			url: "/api/v1/live/heartbeat",
			method: "DELETE",
		});
	});
});

describe("live_client groups API, SSE group events, localStorage persistence, and syncGroupMapMarkers", () => {
	const origWindow = globalThis.window;
	const origDocument = globalThis.document;
	const origFetch = globalThis.fetch;
	const origES = globalThis.EventSource;
	let store: Record<string, string> = {};

	beforeEach(() => {
		store = {};
		clearSavedGroupSession();
		(globalThis as Record<string, unknown>).window = {
			localStorage: {
				getItem: (k: string) => store[k] ?? null,
				setItem: (k: string, v: string) => {
					store[k] = v;
				},
				removeItem: (k: string) => {
					delete store[k];
				},
			},
		};
	});

	afterEach(() => {
		clearSavedGroupSession();
		(globalThis as Record<string, unknown>).window = origWindow;
		(globalThis as Record<string, unknown>).document = origDocument;
		globalThis.fetch = origFetch;
		(globalThis as Record<string, unknown>).EventSource = origES;
		vi.restoreAllMocks();
	});

	it("creates, joins, fetches, pings, and leaves live groups, enforces /^[A-HJ-NP-Z2-9]{6}$/, and persists saved session", async () => {
		expect(GROUP_CODE_RE.source).toBe("^[A-HJ-NP-Z2-9]{6}$");

		const calls: Array<{ url: string; method: string; body: unknown }> = [];
		globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const url = String(input);
			calls.push({
				url,
				method: init?.method ?? "GET",
				body: init?.body ? JSON.parse(String(init.body)) : null,
			});

			if (url === "/api/v1/live/groups" && init?.method === "POST") {
				return new Response(
					JSON.stringify({
						code: "K7M9P2",
						trailId: "trail-g1",
						expiresAt: "2099-11-18T22:00:00Z",
						selfMemberId: "self-hex-001",
						members: [
							{
								memberId: "self-hex-001",
								displayName: "Diana",
								colorHex: "#242734",
								lat: 45.45,
								lon: 25.55,
								ele: 1200,
								accuracy: 6,
								inNavigation: true,
								isSelf: true,
								updatedAt: "2026-11-18T10:00:00Z",
							},
						],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/groups/K7M9P2/join" && init?.method === "POST") {
				return new Response(
					JSON.stringify({
						code: "K7M9P2",
						trailId: "trail-g1",
						expiresAt: "2099-11-18T22:00:00Z",
						selfMemberId: "self-hex-002",
						members: [
							{
								memberId: "self-hex-001",
								displayName: "Diana",
								colorHex: "#242734",
								lat: 45.45,
								lon: 25.55,
								ele: 1200,
								accuracy: 6,
								alongTrackM: 320,
								inNavigation: true,
								isSelf: false,
								updatedAt: "2026-11-18T10:00:00Z",
							},
							{
								memberId: "self-hex-002",
								displayName: "Andrei",
								colorHex: "#0f766e",
								lat: 45.449,
								lon: 25.549,
								ele: 1190,
								accuracy: 8.5,
								alongTrackM: 225,
								inNavigation: true,
								isSelf: true,
								updatedAt: "2026-11-18T10:01:00Z",
							},
						],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/groups/K7M9P2" && (init?.method ?? "GET") === "GET") {
				return new Response(
					JSON.stringify({
						code: "K7M9P2",
						trailId: "trail-g1",
						expiresAt: "2099-11-18T22:00:00Z",
						selfMemberId: "self-hex-002",
						members: [],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/groups/K7M9P2/ping" && init?.method === "POST") {
				return new Response(
					JSON.stringify({
						code: "K7M9P2",
						selfMemberId: "self-hex-002",
						members: [
							{
								memberId: "self-hex-002",
								displayName: "Andrei",
								colorHex: "#0f766e",
								lat: 45.4505,
								lon: 25.5502,
								ele: 1204,
								accuracy: 5.2,
								heading: 42,
								speed: 1.4,
								alongTrackM: 310,
								inNavigation: true,
								isSelf: true,
								updatedAt: "2026-11-18T10:02:00Z",
							},
						],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			if (url === "/api/v1/live/groups/K7M9P2/leave" && init?.method === "POST") {
				return new Response(JSON.stringify({ ok: true }), {
					status: 200,
					headers: { "content-type": "application/json" },
				});
			}
			return new Response("{}", { status: 404 });
		}) as unknown as typeof fetch;

		// Reject invalid group codes client-side without hitting network
		expect(await fetchLiveGroup("AB01IO")).toBeNull();
		expect(await joinLiveGroup("SHORT", { displayName: "Ana" })).toBeNull();
		expect(await pingLiveGroup("123456", { lat: 45.4, lon: 25.5 })).toBeNull();
		expect(await leaveLiveGroup("BAD_12")).toBe(false);
		expect(calls).toHaveLength(0);

		const created = await createLiveGroup({
			displayName: "  Diana  ",
			trailId: "trail-g1",
			lat: 45.45,
			lon: 25.55,
			ele: 1200,
			accuracy: 6,
			inNavigation: true,
		});
		expect(created?.code).toBe("K7M9P2");
		expect(created?.selfMemberId).toBe("self-hex-001");
		expect(getSavedGroupSession("trail-g1")?.code).toBe("K7M9P2");
		expect(getSavedGroupSession("different-trail")).toBeNull();

		// Lowercase input code is normalized to uppercase K7M9P2
		const joined = await joinLiveGroup("k7m9p2", {
			displayName: "Andrei",
			lat: 45.449,
			lon: 25.549,
			accuracy: 8.5,
			alongTrackM: 225,
			inNavigation: true,
		});
		expect(joined?.members).toHaveLength(2);
		expect(joined?.selfMemberId).toBe("self-hex-002");

		const fetched = await fetchLiveGroup("k7m9p2");
		expect(fetched?.code).toBe("K7M9P2");

		const pinged = await pingLiveGroup("K7M9P2", {
			lat: 45.4505,
			lon: 25.5502,
			ele: 1204,
			accuracy: 5.2,
			heading: 42,
			speed: 1.4,
			alongTrackM: 310,
			inNavigation: true,
		});
		expect(pinged?.members[0].accuracy).toBe(5.2);
		expect(pinged?.members[0].alongTrackM).toBe(310);

		// List merge & remove helpers + preserving isSelf for known selfMemberId
		const mergedList = mergeGroupMemberIntoList(joined!.members, {
			memberId: "self-hex-002",
			displayName: "Andrei",
			colorHex: "#0f766e",
			lat: 45.451,
			lon: 25.551,
			ele: 1210,
			accuracy: 4.8,
			inNavigation: true,
			isSelf: false, // SSE broadcast sends isSelf: false; client preserves true!
			updatedAt: "2026-11-18T10:02:05Z",
		});
		expect(mergedList).toHaveLength(2);
		expect(mergedList.find((m) => m.memberId === "self-hex-002")?.isSelf).toBe(true);

		const afterRemove = removeGroupMemberFromList(mergedList, "self-hex-001");
		expect(afterRemove.map((m) => m.memberId)).toEqual(["self-hex-002"]);

		// Expired saved group session returns null
		saveGroupSession({
			code: "K7M9P2",
			trailId: "trail-g1",
			displayName: "Andrei",
			expiresAt: "2020-01-01T00:00:00Z",
		});
		expect(getSavedGroupSession("trail-g1")).toBeNull();

		saveGroupSession({
			code: "K7M9P2",
			trailId: "trail-g1",
			displayName: "Andrei",
			expiresAt: "2099-01-01T00:00:00Z",
		});
		expect(getSavedGroupSession("trail-g1")?.displayName).toBe("Andrei");

		const left = await leaveLiveGroup("K7M9P2");
		expect(left).toBe(true);
		expect(getSavedGroupSession("trail-g1")).toBeNull();
	});

	it("streams groupCode via connectLiveStream, reconnects on updateGroupCode, and parses group_member_update & group_member_left", () => {
		const instances: Array<{
			url: string;
			listeners: Record<string, EventListener>;
			closed: boolean;
		}> = [];

		(globalThis as Record<string, unknown>).EventSource = class {
			url: string;
			listeners: Record<string, EventListener> = {};
			onerror: (() => void) | null = null;
			closed = false;
			constructor(url: string) {
				this.url = url;
				instances.push(this);
			}
			addEventListener(type: string, fn: EventListener) {
				this.listeners[type] = fn;
			}
			close() {
				this.closed = true;
			}
		};

		const memberUpdates: GroupMemberDto[] = [];
		const memberLeftEvents: Array<{ groupCode: string; memberId: string }> = [];

		const handle = connectLiveStream({
			trailId: "trail-1",
			lat: 45.45,
			lon: 25.55,
			groupCode: "k7m9p2",
			callbacks: {
				onGroupMemberUpdate: (m) => memberUpdates.push(m),
				onGroupMemberLeft: (ev) => memberLeftEvents.push(ev),
			},
		});

		expect(instances).toHaveLength(1);
		expect(instances[0].url).toContain("groupCode=K7M9P2");

		instances[0].listeners.group_member_update({
			data: JSON.stringify({
				memberId: "peer-diana",
				displayName: "Diana",
				colorHex: "#0f766e",
				lat: 45.452,
				lon: 25.553,
				ele: 1230,
				accuracy: 5.5,
				alongTrackM: 415,
				inNavigation: true,
				isSelf: false,
				updatedAt: "2026-11-18T10:03:00Z",
			}),
		} as unknown as Event);

		instances[0].listeners.group_member_left({
			data: JSON.stringify({
				groupCode: "K7M9P2",
				memberId: "peer-diana",
			}),
		} as unknown as Event);

		expect(memberUpdates).toHaveLength(1);
		expect(memberUpdates[0]).toMatchObject({
			memberId: "peer-diana",
			displayName: "Diana",
			colorHex: "#0f766e",
			accuracy: 5.5,
			alongTrackM: 415,
			isSelf: false,
		});
		expect(memberLeftEvents).toEqual([{ groupCode: "K7M9P2", memberId: "peer-diana" }]);

		// No-op when same code passed
		handle.updateGroupCode("K7M9P2");
		expect(instances).toHaveLength(1);

		// Reconnects cleanly when switching or clearing groupCode
		handle.updateGroupCode("P9Q8R7");
		expect(instances).toHaveLength(2);
		expect(instances[0].closed).toBe(true);
		expect(instances[1].url).toContain("groupCode=P9Q8R7");

		handle.updateGroupCode(null);
		expect(instances).toHaveLength(3);
		expect(instances[2].url).not.toContain("groupCode=");

		handle.close();
		expect(instances[2].closed).toBe(true);
	});

	it("renders crisp 34x34 Slate/Brand circular avatar pills in syncGroupMapMarkers and skips self", () => {
		class FakeElement {
			tagName: string;
			type = "";
			textContent = "";
			title = "";
			style: { cssText: string } = { cssText: "" };
			attrs: Record<string, string> = {};
			children: FakeElement[] = [];
			listeners: Record<string, Array<(ev: { stopPropagation: () => void }) => void>> = {};
			constructor(tag: string) {
				this.tagName = tag.toUpperCase();
			}
			setAttribute(k: string, v: string) {
				this.attrs[k] = v;
			}
			getAttribute(k: string) {
				return this.attrs[k] ?? null;
			}
			appendChild(child: FakeElement) {
				this.children.push(child);
				return child;
			}
			addEventListener(type: string, fn: (ev: { stopPropagation: () => void }) => void) {
				(this.listeners[type] ??= []).push(fn);
			}
		}

		(globalThis as Record<string, unknown>).document = {
			createElement: (tag: string) => new FakeElement(tag),
		};

		expect(getGroupMemberInitials("Diana")).toBe("DI");
		expect(getGroupMemberInitials("Andrei Popescu")).toBe("AP");

		const clicked: string[] = [];
		const prevMarker = { removed: false, remove() { this.removed = true; } };

		const markers = syncGroupMapMarkers(
			{} as never,
			[prevMarker as never],
			[
				{
					memberId: "self-1",
					displayName: "Eu",
					colorHex: "#242734",
					lat: 45.45,
					lon: 25.55,
					ele: 1200,
					accuracy: 6,
					alongTrackM: 300,
					inNavigation: true,
					isSelf: true,
					updatedAt: "2026-11-18T10:00:00Z",
				},
				{
					memberId: "peer-diana",
					displayName: "Diana",
					colorHex: "",
					lat: 45.451,
					lon: 25.551,
					ele: 1212,
					accuracy: 6.2,
					alongTrackM: 395,
					inNavigation: true,
					isSelf: false,
					updatedAt: "2026-11-18T10:00:00Z",
				},
			],
			{
				selfAlongTrackM: 300,
				onSelectMember: (m) => clicked.push(m.memberId),
			},
		);

		expect(prevMarker.removed).toBe(true);
		expect(markers).toHaveLength(1);

		const markerAny = markers[0] as unknown as {
			element: FakeElement;
			lngLat: [number, number];
		};
		expect(markerAny.lngLat).toEqual([25.551, 45.451]);
		expect(markerAny.element.getAttribute("data-testid")).toBe("group-member-marker");
		expect(markerAny.element.textContent).toBe("DI");
		expect(markerAny.element.style.cssText).toContain("width:34px");
		expect(markerAny.element.style.cssText).toContain("height:34px");
		expect(markerAny.element.style.cssText).toContain("#242734");
		expect(markerAny.element.style.cssText).toContain("2px solid #ffffff");
		expect(markerAny.element.title).toContain("+95 m");

		markerAny.element.listeners.click?.[0]?.({ stopPropagation: () => {} });
		expect(clicked).toEqual(["peer-diana"]);
	});

	it("parses optional clientSosId in normalizeSosDto and forwards optional BLE sync fields in live_client", async () => {
		const withClientId = normalizeSosDto({
			id: "sos-ble-1",
			clientSosId: "  A1B2C3D4E5F60718 ",
			trailId: "bucegi-1",
			status: "active",
			reason: "injury",
			lat: 45.41,
			lon: 25.45,
			ele: 1620,
		});
		expect(withClientId?.clientSosId).toBe("a1b2c3d4e5f60718");

		const withoutClientId = normalizeSosDto({
			id: "sos-legacy-1",
			trailId: "bucegi-1",
			status: "active",
			reason: "lost",
			lat: 45.41,
			lon: 25.45,
		});
		expect(withoutClientId?.clientSosId).toBeUndefined();
		expect("clientSosId" in (withoutClientId as unknown as Record<string, unknown>)).toBe(false);

		// Deduplicates by clientSosId when local BLE placeholder upgrades to PocketBase ID
		const localPlaceholder = normalizeSosDto({
			id: "ble-sos:a1b2c3d4e5f60718",
			clientSosId: "a1b2c3d4e5f60718",
			status: "active",
			reason: "injury",
			lat: 45.41,
			lon: 25.45,
		})!;
		const mergedUpgraded = mergeSosIntoList([localPlaceholder], withClientId!);
		expect(mergedUpgraded).toHaveLength(1);
		expect(mergedUpgraded[0].id).toBe("sos-ble-1");
		expect(mergedUpgraded[0].clientSosId).toBe("a1b2c3d4e5f60718");

		const calls: Array<{ url: string; body: unknown }> = [];
		globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			const url = String(input);
			calls.push({ url, body: init?.body ? JSON.parse(String(init.body)) : null });
			if (url === "/api/v1/live/groups") {
				return new Response(
					JSON.stringify({
						code: "K7M9P2",
						trailId: "bucegi-1",
						expiresAt: "2099-01-01T00:00:00Z",
						selfMemberId: "m1",
						members: [],
					}),
					{ status: 200, headers: { "content-type": "application/json" } },
				);
			}
			return new Response(
				JSON.stringify({
					sos: {
						id: "sos-ble-1",
						clientSosId: "a1b2c3d4e5f60718",
						status: "active",
					},
				}),
				{ status: 200, headers: { "content-type": "application/json" } },
			);
		}) as unknown as typeof fetch;

		await triggerSos({
			trailId: "bucegi-1",
			reason: "injury",
			lat: 45.41,
			lon: 25.45,
			clientSosId: "A1B2C3D4E5F60718",
			sosClaimSecret: "00112233445566778899AABBCCDDEEFF",
		});
		expect(calls[0].body).toMatchObject({
			clientSosId: "a1b2c3d4e5f60718",
			sosClaimSecret: "00112233445566778899aabbccddeeff",
		});

		await updateSos("sos-ble-1", {
			status: "resolved",
			sosClaimSecret: "00112233445566778899aabbccddeeff",
		});
		expect(calls[1].body).toEqual({
			status: "resolved",
			sosClaimSecret: "00112233445566778899aabbccddeeff",
		});

		await createLiveGroup({
			displayName: "Diana",
			trailId: "bucegi-1",
			preferredCode: "k7m9p2",
		});
		expect(calls[2].body).toMatchObject({
			displayName: "Diana",
			preferredCode: "K7M9P2",
		});
	});
});
