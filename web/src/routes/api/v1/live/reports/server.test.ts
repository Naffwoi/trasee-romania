import { afterEach, describe, expect, it, vi } from "vitest";
import { POST } from "./+server";

const VALID_TOKEN = "a".repeat(64);

describe("POST /api/v1/live/reports", () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it("forwards multipart/form-data report with stripped photo blob to PocketBase /live/reports", async () => {
		let capturedHeaders: Headers | null = null;
		let capturedBody: BodyInit | null | undefined = null;

		const origFetch = globalThis.fetch;
		vi.stubGlobal(
			"fetch",
			vi.fn(async (_url: RequestInfo | URL, init?: RequestInit) => {
				capturedHeaders = new Headers(init?.headers);
				capturedBody = init?.body;
				return Response.json({
					report: {
						id: "rep123456789012",
						category: "spring",
						kind: "landmark_permanent",
						isPermanent: true,
						conditionStatus: "active",
						note: "Izvor rece",
						lat: 45.44,
						lon: 25.45,
						ele: 1850,
						photoUrl: "/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=600x0",
						photoThumbUrl: "/api/v1/files/trail_reports/rep123456789012/report.jpg?thumb=300x300",
						photoVerified: true,
						confirmCount: 1,
						dismissCount: 0,
						createdAt: "2026-11-18T12:00:00Z",
						lastConfirmedAt: "2026-11-18T12:00:00Z",
						expiresAt: null,
					},
				});
			}) as typeof origFetch,
		);

		const fd = new FormData();
		fd.set("category", "spring");
		fd.set("note", "Izvor rece");
		fd.set("lat", "45.44");
		fd.set("lon", "25.45");
		fd.set("ele", "1850");
		fd.set("photoVerified", "true");
		fd.set(
			"photo",
			new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], { type: "image/jpeg" }),
			"report.jpg",
		);

		const req = new Request("http://localhost/api/v1/live/reports", {
			method: "POST",
			headers: { "X-Device-Token": VALID_TOKEN },
			body: fd,
		});

		const res = await POST({ request: req, locals: {} } as never);
		expect(res.status).toBe(200);
		expect(capturedBody).toBeInstanceOf(FormData);
		expect(capturedHeaders!.get("content-type")).toBeNull();
		expect(capturedHeaders!.get("x-device-hash")).toMatch(/^[0-9a-f]{64}$/);
	});

	it("rejects oversized photos (> 2 MB) with HTTP 413", async () => {
		const fd = new FormData();
		fd.set("category", "bear");
		fd.set("lat", "45.44");
		fd.set("lon", "25.45");
		fd.set(
			"photo",
			new Blob([new Uint8Array(2 * 1024 * 1024 + 1024)], { type: "image/jpeg" }),
			"huge.jpg",
		);

		const req = new Request("http://localhost/api/v1/live/reports", {
			method: "POST",
			headers: { "X-Device-Token": VALID_TOKEN },
			body: fd,
		});

		const res = await POST({ request: req, locals: {} } as never);
		expect(res.status).toBe(413);
	});
});
