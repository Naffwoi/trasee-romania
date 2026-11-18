import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { isSafeFontAwesomeSlug } from "./location_icon_util";
import { fromKML } from "./gpx_util";

const SRC_ROOT = path.resolve(import.meta.dirname, "../..");

function readSrc(relPath: string): string {
	return fs.readFileSync(path.join(SRC_ROOT, relPath), "utf8");
}

describe("Phase 4 bundle code-splitting guards", () => {
	it("validates FontAwesome icon slugs without importing the 1,390-entry icon_util array", () => {
		expect(isSafeFontAwesomeSlug("mountain-sun")).toBe(true);
		expect(isSafeFontAwesomeSlug("circle")).toBe(true);
		expect(isSafeFontAwesomeSlug("bad\" onclick=\"alert(1)")).toBe(false);
		expect(isSafeFontAwesomeSlug("")).toBe(false);

		const maplibreUtilSrc = readSrc("lib/util/maplibre_util.ts");
		expect(maplibreUtilSrc).not.toMatch(/from\s+["']\.\/icon_util/);
	});

	it("removes static JSZip, FitParser, toGeoJSON, @xmldom/xmldom, and icon_util imports from gpx_util.ts", async () => {
		const gpxUtilSrc = readSrc("lib/util/gpx_util.ts");
		expect(gpxUtilSrc).not.toMatch(/^import\s+JSZip\s+from\s+["']jszip["']/m);
		expect(gpxUtilSrc).not.toMatch(/^import\s+FitParser\s+from/m);
		expect(gpxUtilSrc).not.toMatch(/^import\s+\{[^}]*\}\s+from\s+["']#lib\/vendor\/toGeoJSON/m);
		expect(gpxUtilSrc).not.toMatch(/^import\s+\{[^}]*XMLDOMParser[^}]*\}\s+from\s+["']@xmldom\/xmldom["']/m);
		expect(gpxUtilSrc).not.toMatch(/from\s+["']\.\/icon_util/);

		const kmlSample = `<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><Placemark><name>Peak</name><Point><coordinates>25.54,45.44,1200</coordinates></Point></Placemark></Document>
</kml>`;
		const gpxOut = await fromKML(kmlSample);
		expect(gpxOut).toContain("<wpt");
	});

	it("routes trail viewer panels through lazy_editor.svelte so TipTap is excluded from initial route chunks", () => {
		for (const rel of [
			"lib/components/trail/trail_info_panel.svelte",
			"lib/components/comment/comment_card.svelte",
			"lib/components/summit_log/summit_log_modal.svelte",
		]) {
			const content = readSrc(rel);
			expect(content).not.toContain('base/editor.svelte"');
			expect(content).toContain('base/lazy_editor.svelte"');
		}
	});

	it("does not block MapLibre Map instantiation on ElevationProfileControl import and removes dead mountain.svelte", () => {
		const mapComponentSrc = readSrc("lib/components/trail/map_with_elevation_maplibre.svelte");
		const mapConstructorIdx = mapComponentSrc.indexOf("map = new M.Map(");
		const epcImportIdx = mapComponentSrc.indexOf("elevationprofile-control.ts");
		expect(mapConstructorIdx).toBeGreaterThan(0);
		expect(epcImportIdx).toBeGreaterThan(mapConstructorIdx);

		const homeSrc = readSrc("routes/+page.svelte");
		expect(homeSrc).not.toMatch(/^import\s+\{\s*Canvas\s*\}\s+from\s+["']@threlte\/core["']/m);
		expect(homeSrc).not.toMatch(/^import\s+Scene\s+from/m);
		expect(fs.existsSync(path.join(SRC_ROOT, "lib/components/mountain.svelte"))).toBe(false);
	});
});
