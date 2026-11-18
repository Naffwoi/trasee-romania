import fs from "node:fs";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";
import type { TrailFilter } from "#lib/models/trail.ts";
import { trailCardSearchAttributes, defaultTrailSearchAttributes } from "#lib/models/trail.ts";
import { trails_search_filter, trails_show } from "./trail_store";
import { load as mapTrailLoad } from "../../routes/map/trail/[handle]/[id]/+page";
import { load as viewTrailLoad } from "../../routes/trail/view/[handle]/[id]/+page";
import { load as navigateTrailLoad, ssr as navigateSsr } from "../../routes/map/trail/[handle]/[id]/navigate/+page";

const filter: TrailFilter = {
	q: "Bucegi",
	category: [],
	subcategory: [],
	tags: [],
	difficulty: [],
	author: "",
	public: true,
	private: false,
	shared: false,
	liked: false,
	near: { lat: null as unknown as number, lon: null as unknown as number, radius: 0, name: "" },
	distanceMin: 0,
	distanceMax: 50_000,
	distanceLimit: 50_000,
	elevationGainMin: 0,
	elevationGainMax: 4_000,
	elevationGainLimit: 4_000,
	elevationLossMin: 0,
	elevationLossMax: 4_000,
	elevationLossLimit: 4_000,
	sort: "relevance",
	sortOrder: "-",
};

describe("Phase 4 search payload, N+1 summit-log GPX waterfall, SSR deferral, and SW allowlist", () => {
	it("omits multi-KB polyline strings from card list search queries while keeping defaultTrailSearchAttributes intact", async () => {
		expect(defaultTrailSearchAttributes).toContain("polyline");
		expect(trailCardSearchAttributes).not.toContain("polyline");

		const mockFetch = vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) =>
			Response.json({ hits: [], page: 1, hitsPerPage: 48, totalHits: 0, totalPages: 0 }),
		);
		await trails_search_filter(filter, 1, 48, mockFetch);
		const sentBody = JSON.parse(String(mockFetch.mock.calls[0][1]?.body));
		expect(sentBody.options.attributesToRetrieve).not.toContain("polyline");
		expect(sentBody.options.attributesToRetrieve).toContain("name");
		expect(sentBody.options.attributesToRetrieve).toContain("thumbnail");
	});

	it("does not trigger N+1 summit-log GPX fetches in trails_show unless loadSummitLogGPX is explicitly requested", async () => {
		const requestedUrls: string[] = [];
		const mockFetch = vi.fn(async (url: RequestInfo | URL) => {
			const str = String(url);
			requestedUrls.push(str);
			if (str.startsWith("/api/v1/trail/t-1")) {
				return Response.json({
					id: "t-1",
					collectionId: "trails",
					name: "Jepii Mici",
					gpx: "main.gpx",
					expand: {
						waypoints_via_trail: [],
						summit_logs_via_trail: [
							{ id: "sl-1", collectionId: "summit_logs", date: "2026-06-01", gpx: "log1.gpx" },
							{ id: "sl-2", collectionId: "summit_logs", date: "2026-06-02", gpx: "log2.gpx" },
						],
					},
				});
			}
			return new Response("<gpx><trk><trkseg></trkseg></trk></gpx>", { status: 200 });
		});

		const loaded = await trails_show("t-1", "@ro", undefined, true, mockFetch);
		expect(loaded.expand?.gpx_data).toContain("<gpx>");
		expect(requestedUrls).toHaveLength(2);
		expect(requestedUrls.some((u) => u.includes("log1.gpx"))).toBe(false);
		expect(requestedUrls.some((u) => u.includes("log2.gpx"))).toBe(false);

		requestedUrls.length = 0;
		const loadedWithLogs = await trails_show("t-1", "@ro", undefined, true, mockFetch, true);
		expect(loadedWithLogs.expand?.summit_logs_via_trail?.[0]?.expand?.gpx_data).toContain("<gpx>");
		expect(loadedWithLogs.expand?.summit_logs_via_trail?.[1]?.expand?.gpx_data).toContain("<gpx>");
		expect(requestedUrls).toHaveLength(4);
	});

	it("defers multi-MB GPX XML download during Node SSR and disables SSR on /navigate", async () => {
		expect(navigateSsr).toBe(false);

		const ssrUrls: string[] = [];
		const mockSsrFetch = vi.fn(async (url: RequestInfo | URL) => {
			const str = String(url);
			ssrUrls.push(str);
			if (str.startsWith("/api/v1/trail/")) {
				return Response.json({
					id: "t-ssr",
					collectionId: "trails",
					name: "SSR Fast Trail",
					gpx: "huge-track.gpx",
					polyline: "_p~iF~ps|U_ulLnnqC",
					photos: [],
					expand: { waypoints_via_trail: [], summit_logs_via_trail: [] },
				});
			}
			throw new Error(`Unexpected GPX fetch during SSR: ${str}`);
		});

		const event = {
			params: { id: "t-ssr", handle: "@ro" },
			url: new URL("https://trasee.local/map/trail/@ro/t-ssr"),
			fetch: mockSsrFetch,
		} as never;

		await mapTrailLoad(event);
		await viewTrailLoad(event);
		await navigateTrailLoad(event);

		expect(ssrUrls.every((u) => u.startsWith("/api/v1/trail/"))).toBe(true);
	});

	it("enforces strict allowlist-only caching in service-worker.ts with explicit API, SSE, and navigation bypass", () => {
		const swSrc = fs.readFileSync(
			path.resolve(import.meta.dirname, "../../service-worker.ts"),
			"utf8",
		);
		expect(swSrc).toContain('pathname.startsWith("/_app/immutable/")');
		expect(swSrc).toContain('pathname.startsWith("/api/")');
		expect(swSrc).toContain("text/event-stream");
		expect(swSrc).toContain('req.mode === "navigate"');
	});
});
