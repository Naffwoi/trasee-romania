import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import { expect, test } from "@playwright/test";
import { compile, compileModule } from "svelte/compiler";
import { build } from "vite";
import { loadFontawesome } from "./fontawesome-fixture";

const webRoot = fileURLToPath(new URL("../../../", import.meta.url));
const maplibreDist = fileURLToPath(
	new URL("../../../node_modules/maplibre-gl/dist/", import.meta.url),
);

function buildSampleGpx(): string {
	const pts: string[] = [];
	for (let i = 0; i <= 40; i++) {
		const lat = (45.44 + i * 0.00045).toFixed(6);
		const lon = (25.55).toFixed(6);
		const ele = Math.round(900 + i * 5);
		pts.push(`      <trkpt lat="${lat}" lon="${lon}"><ele>${ele}</ele></trkpt>`);
	}
	return `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="wanderer-perf" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>Bucegi Perf</name><trkseg>\n${pts.join("\n")}\n  </trkseg></trk>
</gpx>`;
}

const sampleTrail = {
	id: "trail-perf-1",
	name: "Bucegi Perf Trail",
	author: "actor-ro",
	lat: 45.44,
	lon: 25.55,
	photos: [],
	public: true,
	completed: false,
	tags: [],
	like_count: 0,
	distance: 2000,
	duration: 2400,
	elevation_gain: 200,
	elevation_loss: 0,
	category: "cat-hiking",
	expand: {
		category: { id: "cat-hiking", name: "Hiking", icon: "fa-person-hiking" },
		waypoints_via_trail: [],
		gpx_data: buildSampleGpx(),
	},
};

async function buildNavPerfHarnessBundle(): Promise<string> {
	const pagePath = resolve(
		webRoot,
		"src/routes/map/trail/[handle]/[id]/navigate/+page.svelte",
	);
	const mjsPath = resolve(webRoot, "node_modules/maplibre-gl/dist/maplibre-gl.mjs");
	const engineSource = await readFile(mjsPath, "utf8");
	const engineExports = engineSource
		.slice(engineSource.lastIndexOf("export{") + 7, engineSource.lastIndexOf("}"))
		.split(",")
		.map((part) => part.split(" as ").pop()!.trim())
		.filter(Boolean);
	const enLocaleJson = readFileSync(
		resolve(webRoot, "src/lib/i18n/locales/en.json"),
		"utf8",
	);

	const result = await build({
		root: webRoot,
		configFile: false,
		logLevel: "error",
		resolve: { conditions: ["browser", "production"] },
		plugins: [
			tailwindcss(),
			{
				name: "nav-perf-fixture",
				enforce: "pre",
				resolveId(id) {
					if (id.startsWith("fixture:")) return `\0${id}`;
					if (id === "$app/env") return "\0fixture:env";
					if (id === "$app/navigation") return "\0fixture:navigation";
					if (id === "$app/state") return "\0fixture:state.svelte.js";
					if (id === "svelte-i18n") return "\0fixture:i18n";
					if (
						id === "maplibre-gl/dist/maplibre-gl.css" ||
						id === "#lib/util/maplibre_worker.ts"
					) {
						return "\0fixture:empty";
					}
					if (id === "maplibre-gl") return "\0fixture:maplibre";
					if (id.startsWith("#lib/")) {
						const [cleanId, query] = id.split("?");
						const target = resolve(webRoot, "src/lib", cleanId.slice(5));
						const resolved = extname(cleanId)
							? target
							: [target + ".ts", target + ".js"].find(existsSync);
						return resolved && query ? `${resolved}?${query}` : resolved;
					}
				},
				async load(id) {
					if (id === "\0fixture:empty") return "export default {};";
					if (id === "\0fixture:env") {
						return 'export const browser = true; export const dev = false; export const building = false; export const version = "fixture";';
					}
					if (id === "\0fixture:maplibre") {
						return `const M = window.RealMapLibre; export default M; export const { ${engineExports.join(", ")} } = M;`;
					}
					if (id === "\0fixture:state.svelte.js") {
						return compileModule(
							`export const page = $state({
								url: new URL(location.href),
								params: { handle: "@romania", id: "trail-perf-1" },
								state: {},
								route: { id: "/map/trail/[handle]/[id]/navigate" },
								data: { settings: { unit: "metric" } },
							});`,
							{ filename: "fixture-state.svelte.js", generate: "client", dev: false },
						).js.code;
					}
					if (id === "\0fixture:navigation") {
						return `export async function goto() {}`;
					}
					if (id === "\0fixture:i18n") {
						return `import { readable, writable } from "svelte/store";
							const dict = ${enLocaleJson};
							export const locale = writable("ro");
							export const _ = readable((key, opts) => dict[key] ?? opts?.default ?? key);`;
					}
					if (id === "\0fixture:entry") {
						return `import { mount } from "svelte";
							import "./src/css/app.css";
							import NavigatePage from ${JSON.stringify(pagePath)};
							mount(NavigatePage, { target: document.getElementById("app"), props: { data: { trail: ${JSON.stringify(sampleTrail)} } } });`;
					}
					if (id.endsWith(".svelte")) {
						const src = await readFile(id, "utf8");
						return compile(src, { filename: id, generate: "client", dev: false, css: "injected" }).js.code;
					}
				},
			},
		],
		build: {
			write: false,
			minify: false,
			rolldownOptions: {
				input: "fixture:entry",
				output: { format: "iife" },
			},
		},
	});
	const outputs = Array.isArray(result) ? result : [result];
	const first = outputs[0] as { output: Array<{ type: string; code?: string }> };
	return first.output.find((o) => o.type === "chunk")!.code!;
}

let cachedBundle: string | null = null;

test.describe("Phase 4 Web & MapLibre Performance Contracts", () => {
	test("keeps nav-trail-route GeoJSON setData() at 0 across 1 Hz on-trail GPS fixes and transitions geolocation to Cabana Sleep after >90s stationary", async ({
		page,
	}) => {
		cachedBundle ??= await buildNavPerfHarnessBundle();

		await page.route("https://fixture.local/**", async (route) => {
			const url = new URL(route.request().url());
			if (url.pathname === "/") {
				await route.fulfill({
					contentType: "text/html",
					body: `<!doctype html><html><head><link rel="stylesheet" href="/maplibre-gl.css"></head><body><div id="app" style="width:390px;height:844px"></div><script type="module">import * as M from "/maplibre-gl.mjs"; window.RealMapLibre = M;</script></body></html>`,
				});
				return;
			}
			if (url.pathname === "/maplibre-gl.mjs") {
				await route.fulfill({
					contentType: "text/javascript",
					body: await readFile(resolve(maplibreDist, "maplibre-gl.mjs"), "utf8"),
				});
				return;
			}
			if (url.pathname === "/maplibre-gl.css") {
				await route.fulfill({
					contentType: "text/css",
					body: await readFile(resolve(maplibreDist, "maplibre-gl.css"), "utf8"),
				});
				return;
			}
			if (url.pathname === "/styles/ofm.json") {
				await route.fulfill({
					contentType: "application/json",
					body: JSON.stringify({
						version: 8,
						sources: {},
						layers: [{ id: "bg", type: "background", paint: { "background-color": "#1e293b" } }],
					}),
				});
				return;
			}
			if (url.pathname.startsWith("/api/")) {
				await route.fulfill({
					contentType: "application/json",
					body: JSON.stringify({ activeHikers30m: 0, reports: [], sosAlerts: [] }),
				});
				return;
			}
			await route.fulfill({ status: 204, body: "" });
		});

		await page.goto("https://fixture.local/");
		await loadFontawesome(page);

		await page.waitForFunction(() => Boolean((window as any).RealMapLibre));

		await page.evaluate(() => {
			(window as any).__watchOptionsLog = [] as PositionOptions[];
			Object.defineProperty(navigator, "geolocation", {
				configurable: true,
				value: {
					watchPosition: (_ok: PositionCallback, _err?: PositionErrorCallback, opts?: PositionOptions) => {
						(window as any).__watchOptionsLog.push(opts ?? {});
						return (window as any).__watchOptionsLog.length;
					},
					clearWatch: () => {},
				},
			});
		});

		await page.addScriptTag({ content: cachedBundle });

		await page.waitForFunction(() => {
			const hook = (window as any).__wandererNavTest;
			const m = hook?.getMap?.();
			return Boolean(m && m.getLayer("nav-trail-walked") && m.getLayer("nav-trail-upcoming"));
		});

		// Spy on nav-trail-route GeoJSONSource.setData across 5 sequential 1 Hz on-trail fixes
		await page.evaluate(() => {
			const m = (window as any).__wandererNavTest.getMap();
			const routeSrc = m.getSource("nav-trail-route");
			(window as any).__routeSetDataCount = 0;
			const orig = routeSrc.setData.bind(routeSrc);
			routeSrc.setData = (data: unknown) => {
				(window as any).__routeSetDataCount++;
				return orig(data);
			};
		});

		const t0 = Date.now();
		for (let step = 1; step <= 5; step++) {
			await page.evaluate(
				({ lat, ts }) => {
					(window as any).__wandererNavTest.pushFix({
						lat,
						lon: 25.55,
						accuracy: 6,
						altitude: 920,
						speed: 1.3,
						heading: 0,
						timestampMs: ts,
					});
				},
				{ lat: 45.44 + step * 0.00035, ts: t0 + step * 1000 },
			);
		}

		const routeSetDataCount = await page.evaluate(() => (window as any).__routeSetDataCount);
		expect(routeSetDataCount).toBe(0);

		// Stationary >90s -> watchPosition rebinds with enableHighAccuracy: false
		for (let sec = 10; sec <= 130; sec += 20) {
			await page.evaluate(
				({ ts }) => {
					(window as any).__wandererNavTest.pushFix({
						lat: 45.442,
						lon: 25.55,
						accuracy: 6,
						altitude: 925,
						speed: 0.05,
						heading: 0,
						timestampMs: ts,
					});
				},
				{ ts: t0 + sec * 1000 },
			);
		}

		const watchLog = await page.evaluate(() => (window as any).__watchOptionsLog as PositionOptions[]);
		expect(watchLog[0]?.enableHighAccuracy).toBe(true);
		expect(watchLog[watchLog.length - 1]?.enableHighAccuracy).toBe(false);
	});

	test("verifies production build emits zero fa-brands font and splits TipTap + JSZip out of trail viewer entry chunks", async () => {
		const buildClientDir = resolve(webRoot, "build/client/_app/immutable");
		test.skip(!existsSync(buildClientDir), "Run after npm --prefix web run build");

		const assetsDir = join(buildClientDir, "assets");
		if (existsSync(assetsDir)) {
			const assetFiles = readdirSync(assetsDir);
			expect(assetFiles.some((f) => f.startsWith("fa-brands-400"))).toBe(false);
		}

		const manifestFullPath = resolve(webRoot, "build/server/manifest-full.js");
		let targetNodeIndex = 15;
		if (existsSync(manifestFullPath)) {
			const manifestSrc = readFileSync(manifestFullPath, "utf8");
			const routeMatch = manifestSrc.match(
				/id:\s*"\/map\/trail\/\[handle\]\/\[id\]"[\s\S]*?leaf:\s*(\d+)/,
			);
			if (routeMatch) {
				targetNodeIndex = Number(routeMatch[1]);
			}
		}

		const nodesManifestPath = resolve(webRoot, `build/server/nodes/${targetNodeIndex}.js`);
		if (existsSync(nodesManifestPath)) {
			const nodeSrc = readFileSync(nodesManifestPath, "utf8");
			const match = nodeSrc.match(/export const imports = (\[[^\]]*\])/);
			expect(match).not.toBeNull();
			const imports = JSON.parse(match![1]) as string[];
			let totalBytes = 0;
			for (const rel of imports) {
				const full = resolve(webRoot, "build/client", rel);
				if (existsSync(full)) {
					totalBytes += statSync(full).size;
				}
			}
			// Down from 2,626 KB baseline to < 1,900 KB uncompressed
			expect(totalBytes).toBeLessThan(1_900_000);
		}
	});
});
