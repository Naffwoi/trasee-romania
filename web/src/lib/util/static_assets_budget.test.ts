import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const WEB_ROOT = path.resolve(import.meta.dirname, "../../..");

describe("Phase 4 static font, CSS, and map style budgets", () => {
	it("replaces @fortawesome/fontawesome-free/css/all.min.css and raw-only TTF @font-face rules in app.css", () => {
		const css = fs.readFileSync(path.join(WEB_ROOT, "src/css/app.css"), "utf8");
		expect(css).not.toContain("fontawesome-free/css/all.min.css");
		expect(css).toContain("fontawesome-free/css/fontawesome.min.css");
		expect(css).toContain("fontawesome-free/css/solid.min.css");
		expect(css).toContain("fontawesome-free/css/regular.min.css");
		expect(css).toContain("font-display: swap");
		expect(css).toContain('format("woff2")');
	});

	it("eliminates all fa-brands classes from Svelte templates and exposes arm64 split APK primary button", () => {
		const navBar = fs.readFileSync(path.join(WEB_ROOT, "src/lib/components/nav_bar.svelte"), "utf8");
		const installPage = fs.readFileSync(path.join(WEB_ROOT, "src/routes/install/+page.svelte"), "utf8");
		expect(navBar).not.toContain("fa-brands");
		expect(installPage).not.toContain("fa-brands");
		expect(installPage).toContain("TraseeRomania-Android-arm64.apk");
		expect(installPage).toContain("TraseeRomania-Android.apk");
	});

	it("ships compressed WOFF2 fonts (<95 KB each) and minified valid ofm.json (<95 KB)", () => {
		const requiredWoff2 = [
			"IBMPlexSans-Regular.woff2",
			"IBMPlexSans-Italic.woff2",
			"IBMPlexSans-Medium.woff2",
			"IBMPlexSans-SemiBold.woff2",
			"IBMPlexSans-Bold.woff2",
		];
		for (const file of requiredWoff2) {
			const full = path.join(WEB_ROOT, "static/fonts/IBMPlexSans", file);
			expect(fs.existsSync(full), `missing ${file}`).toBe(true);
			const stat = fs.statSync(full);
			expect(stat.size).toBeGreaterThan(10_000);
			expect(stat.size).toBeLessThan(95_000);
		}

		const ofmPath = path.join(WEB_ROOT, "static/styles/ofm.json");
		const ofmRaw = fs.readFileSync(ofmPath, "utf8");
		expect(Buffer.byteLength(ofmRaw, "utf8")).toBeLessThan(95_000);
		const parsed = JSON.parse(ofmRaw) as { version: number; layers: unknown[] };
		expect(parsed.version).toBe(8);
		expect(Array.isArray(parsed.layers)).toBe(true);
		expect(parsed.layers.length).toBeGreaterThan(20);
	});
});
