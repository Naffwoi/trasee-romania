import { describe, expect, it } from "vitest";
import { classifyFastPathRequest } from "./hooks.server";

describe("hooks.server classifyFastPathRequest", () => {
	it("short-circuits all /api/v1/live/* endpoints except POST /api/v1/live/reports with zero DB queries", () => {
		expect(classifyFastPathRequest("/api/v1/live/heartbeat", "POST", false)).toBe(
			"live_stateless",
		);
		expect(classifyFastPathRequest("/api/v1/live/groups/ABC234/ping", "POST", true)).toBe(
			"live_stateless",
		);
		expect(classifyFastPathRequest("/api/v1/live/stream", "GET", true)).toBe("live_stateless");
		expect(classifyFastPathRequest("/api/v1/live/sos", "POST", false)).toBe("live_stateless");
		expect(classifyFastPathRequest("/api/v1/live/reports", "POST", false)).toBe(
			"live_optional_actor",
		);
	});

	it("short-circuits /api/v1/files/* on public instances while keeping auth check on private instances", () => {
		expect(
			classifyFastPathRequest("/api/v1/files/trails/abc123456789012/photo.jpg", "GET", false),
		).toBe("public_file");
		expect(
			classifyFastPathRequest("/api/v1/files/trails/abc123456789012/photo.jpg", "GET", true),
		).toBe(null);
	});

	it("leaves SSR pages and standard authenticated API endpoints on full auth hook", () => {
		expect(classifyFastPathRequest("/map", "GET", false)).toBe(null);
		expect(classifyFastPathRequest("/api/v1/trail", "GET", false)).toBe(null);
		expect(classifyFastPathRequest("/api/v1/regions/romania/download", "GET", false)).toBe(
			null,
		);
	});
});
