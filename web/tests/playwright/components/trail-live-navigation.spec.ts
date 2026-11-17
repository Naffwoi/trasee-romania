import { readFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import { extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import { expect, test, type Page } from "@playwright/test";
import { compile, compileModule } from "svelte/compiler";
import { build } from "vite";
import { loadFontawesome } from "./fontawesome-fixture";

const webRoot = fileURLToPath(new URL("../../../", import.meta.url));
const maplibreDist = fileURLToPath(new URL("../../../node_modules/maplibre-gl/dist/", import.meta.url));

function buildSampleTrailGpx(): string {
    const pts: Array<{ lat: number; lon: number; ele: number }> = [];
    // Leg 1: ~1450 m North along lon 25.5500, climbing from 900 m to 1080 m
    for (let i = 0; i <= 29; i++) {
        pts.push({
            lat: 45.44 + i * 0.00045,
            lon: 25.55,
            ele: Math.round(900 + i * 6.2),
        });
    }
    // Leg 2: ~1000 m East along lat 45.45305, rising to a 1180 m peak then descending to 1120 m
    const turnLat = pts[pts.length - 1].lat;
    for (let j = 1; j <= 20; j++) {
        const ele = j <= 10 ? 1080 + j * 10 : 1180 - (j - 10) * 6;
        pts.push({
            lat: turnLat,
            lon: 25.55 + j * 0.00064,
            ele: Math.round(ele),
        });
    }

    const trkpts = pts
        .map(
            (p) =>
                `      <trkpt lat="${p.lat.toFixed(6)}" lon="${p.lon.toFixed(6)}"><ele>${p.ele}</ele></trkpt>`,
        )
        .join("\n");

    return `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="wanderer-test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Sinaia - Vf. Test</name>
    <trkseg>
${trkpts}
    </trkseg>
  </trk>
</gpx>`;
}

const sampleTrail = {
    id: "trail-nav-test-1",
    name: "Sinaia - Culmea Test",
    author: "actor-ro",
    lat: 45.44,
    lon: 25.55,
    photos: [],
    public: true,
    completed: false,
    tags: [],
    like_count: 0,
    distance: 2450,
    duration: 3600,
    elevation_gain: 280,
    elevation_loss: 60,
    category: "cat-hiking",
    expand: {
        category: { id: "cat-hiking", name: "Hiking", icon: "fa-person-hiking" },
        waypoints_via_trail: [],
        gpx_data: buildSampleTrailGpx(),
    },
};

async function buildNavigatePageBundle(): Promise<string> {
    const pagePath = resolve(webRoot, "src/routes/map/trail/[handle]/[id]/navigate/+page.svelte");
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
                name: "navigate-page-fixture",
                enforce: "pre",
                resolveId(id) {
                    if (id.startsWith("fixture:")) return `\0${id}`;
                    if (id === "$app/env") return "\0fixture:env";
                    if (id === "$app/navigation") return "\0fixture:navigation";
                    if (id === "$app/state") return "\0fixture:state.svelte.js";
                    if (id === "svelte-i18n") return "\0fixture:i18n";
                    if (id === "maplibre-gl/dist/maplibre-gl.css") return "\0fixture:empty";
                    if (id === "maplibre-gl") return "\0fixture:maplibre";
                    if (id.startsWith("#lib/")) {
                        const target = resolve(webRoot, "src/lib", id.slice(5));
                        return extname(id) ? target : [target + ".ts", target + ".js"].find(existsSync);
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
                            `
                            export const page = $state({
                                url: new URL(location.href),
                                params: { handle: "@romania", id: "trail-nav-test-1" },
                                state: {},
                                route: { id: "/map/trail/[handle]/[id]/navigate" },
                                data: { settings: { unit: "metric" } },
                            });
                            `,
                            { filename: "fixture-state.svelte.js", generate: "client", dev: false },
                        ).js.code;
                    }
                    if (id === "\0fixture:navigation") {
                        return `
                            export function goto(url) { window.__navGotoCalls = (window.__navGotoCalls || []); window.__navGotoCalls.push(url); return Promise.resolve(); }
                            export function beforeNavigate() {}
                            export function pushState() {}
                            export function replaceState() {}
                        `;
                    }
                    if (id === "\0fixture:i18n") {
                        return `
                            import { writable } from "svelte/store";
                            const messages = ${enLocaleJson};
                            function translate(key, opts) {
                                const override = window.fixtureMessages?.[key];
                                let template = override ?? messages[key] ?? opts?.default ?? key;
                                if (typeof template === "string" && opts?.values) {
                                    for (const [k, v] of Object.entries(opts.values)) {
                                        template = template.replaceAll("{" + k + "}", String(v));
                                    }
                                }
                                return template;
                            }
                            export const _ = writable(translate);
                            export const t = _;
                            export const locale = writable("en");
                        `;
                    }
                    if (id === "\0fixture:entry") {
                        return `
                            import { mount, unmount } from "svelte";
                            import NavigatePage from ${JSON.stringify(pagePath)};
                            import ${JSON.stringify(resolve(webRoot, "src/css/app.css"))};
                            import ${JSON.stringify(resolve(webRoot, "src/css/components.css"))};
                            import ${JSON.stringify(resolve(webRoot, "src/css/theme.css"))};

                            document.documentElement.classList.add("light");
                            const app = mount(NavigatePage, {
                                target: document.body,
                                props: { data: { trail: window.__testTrail } },
                            });
                            window.__unmountNav = () => unmount(app);
                        `;
                    }
                    if (id.endsWith(".svelte")) {
                        const source = await readFile(id, "utf8");
                        return compile(source, {
                            filename: id,
                            generate: "client",
                            dev: false,
                            css: "injected",
                        }).js.code;
                    }
                },
            },
        ],
        build: {
            write: false,
            minify: false,
            rolldownOptions: { input: "fixture:entry", output: { format: "iife" } },
        },
    });

    if (Array.isArray(result) || !("output" in result)) {
        throw new Error("Expected a single bundle");
    }
    const chunk = result.output.find((o) => o.type === "chunk");
    if (!chunk) throw new Error("Missing bundle chunk");
    const css = result.output
        .flatMap((o) => (o.type === "asset" && o.fileName.endsWith(".css") ? [String(o.source)] : []))
        .join("\n");
    return `document.head.appendChild(Object.assign(document.createElement("style"), { textContent: ${JSON.stringify(css)} }));\n${chunk.code}`;
}

async function mountNavigatePage(page: Page, bundle: string) {
    await page.setViewportSize({ width: 390, height: 844 });
    page.on("pageerror", (err) => {
        throw err;
    });

    await page.addInitScript((trail) => {
        (window as any).__testTrail = trail;
        // Disable real browser geolocation in this deterministic E2E harness
        Object.defineProperty(navigator, "geolocation", {
            configurable: true,
            value: {
                watchPosition: () => 1,
                clearWatch: () => {},
            },
        });
    }, sampleTrail);

    await page.route("https://search-page.test/**", async (route) => {
        const pathname = new URL(route.request().url()).pathname;
        if (pathname.startsWith("/maplibre/")) {
            const name = pathname.split("/").at(-1)!;
            return route.fulfill({
                contentType: name.endsWith(".css") ? "text/css" : "text/javascript",
                body: await readFile(maplibreDist + name, "utf8"),
            });
        }
        if (pathname === "/styles/ofm.json") {
            return route.fulfill({
                json: {
                    version: 8,
                    sources: {},
                    layers: [
                        {
                            id: "background",
                            type: "background",
                            paint: { "background-color": "#dae5df" },
                        },
                    ],
                },
            });
        }
        if (pathname.startsWith("/fonts/")) {
            return route.fulfill({ status: 404, body: "" });
        }
        return route.fulfill({
            contentType: "text/html",
            body: `<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/maplibre/maplibre-gl.css">
</head>
<body>
<script type="module">
import * as M from "/maplibre/maplibre-gl.mjs";
const OrigMap = M.Map;
window.RealMapLibre = {
    ...M,
    Map: class extends OrigMap {
        constructor(opts) {
            super(opts);
            window.realMap = this;
        }
    },
};
</script>
</body>
</html>`,
        });
    });
    await page.route((url) => url.hostname !== "search-page.test", (route) => route.abort());

    await page.goto("https://search-page.test/map/trail/@romania/trail-nav-test-1/navigate");
    await expect.poll(() => page.evaluate(() => Boolean((window as any).RealMapLibre))).toBe(true);
    await page.addScriptTag({ content: bundle });
    await loadFontawesome(page);

    await expect
        .poll(() =>
            page.evaluate(
                () =>
                    Boolean((window as any).realMap?.loaded()) &&
                    Boolean((window as any).__wandererNavTest),
            ),
        )
        .toBe(true);
}

function parseDistanceMeters(text: string): number {
    const trimmed = text.trim();
    const kmMatch = trimmed.match(/([\d.]+)\s*km/i);
    if (kmMatch) return Number(kmMatch[1]) * 1000;
    const mMatch = trimmed.match(/([\d.]+)\s*m\b/i);
    if (mMatch) return Number(mMatch[1]);
    return NaN;
}

test.describe("Live Trail Navigation & Off-Trail Rerouting", () => {
    let bundle: string;

    test.beforeAll(async () => {
        bundle = await buildNavigatePageBundle();
    });

    test("handles on-trail progress, off-trail DEM reroute mode switching, and trail rejoin", async ({
        page,
    }) => {
        await mountNavigatePage(page, bundle);

        // 1. Initial start state: green Google Maps banner, remaining time & arrival ETA, split elevation canvas
        const banner = page.locator('[data-testid="nav-banner"]');
        await expect(banner).toBeVisible();
        await expect(banner).toHaveAttribute("data-nav-state", "on-trail");
        await expect(banner).toHaveClass(/bg-emerald-700/);

        const remainingDuration = page.locator('[data-testid="nav-remaining-duration"]');
        const arrivalTime = page.locator('[data-testid="nav-arrival-time"]');
        const remainingDistEl = page.locator('[data-testid="nav-remaining-distance"]');
        await expect(remainingDuration).toBeVisible();
        await expect(remainingDuration).not.toHaveText("-");
        await expect(arrivalTime).toHaveText(/^\d{2}:\d{2}$/);

        const initialRemainingText = await remainingDistEl.innerText();
        const initialRemainingM = parseDistanceMeters(initialRemainingText);
        expect(initialRemainingM).toBeGreaterThan(2200);

        const canvas = page.locator('[data-testid="live-elevation-canvas"]');
        await expect(canvas).toBeVisible();
        const canvasBox = await canvas.boundingBox();
        expect(canvasBox).not.toBeNull();
        expect(canvasBox!.width).toBeGreaterThan(150);
        expect(canvasBox!.height).toBeGreaterThan(60);

        // 2. Walk 300 m along trail -> remaining distance shrinks
        await page.evaluate(() => {
            const hook = (window as any).__wandererNavTest;
            const now = Date.now();
            hook.setCompass(0, 8);
            hook.pushFix({ lat: 45.44, lon: 25.55, accuracy: 8, speed: 1.2, heading: 0, timestampMs: now });
            hook.pushFix({ lat: 45.4409, lon: 25.55, accuracy: 8, speed: 1.2, heading: 0, timestampMs: now + 80_000 });
            hook.pushFix({ lat: 45.4418, lon: 25.55, accuracy: 8, speed: 1.2, heading: 0, timestampMs: now + 160_000 });
            hook.pushFix({ lat: 45.4427, lon: 25.55, accuracy: 8, speed: 1.2, heading: 0, timestampMs: now + 240_000 });
        });

        await expect
            .poll(async () => parseDistanceMeters(await remainingDistEl.innerText()))
            .toBeLessThan(initialRemainingM - 200);
        await expect(banner).toHaveAttribute("data-nav-state", "on-trail");

        // 3. Stray 110+ m off-trail into forest for 3 fixes with a synthetic DEM sampler
        await page.evaluate(() => {
            const hook = (window as any).__wandererNavTest;
            // Synthetic terrain with a steep knoll right between user (25.5485) and trail (25.5500) at lat=45.4427
            hook.setCustomDemSampler((lat: number, lon: number) => {
                const base = 900 + ((lat - 45.44) / 0.0135) * 180;
                const dLatM = (lat - 45.4427) * 111132;
                const dLonM = (lon - 25.5493) * 78108;
                const r2 = dLatM * dLatM + dLonM * dLonM;
                const knoll = 55 * Math.exp(-r2 / (2 * 28 * 28));
                return base + knoll;
            });

            const now = Date.now() + 300_000;
            hook.setCompass(90, 10);
            hook.pushFix({ lat: 45.4427, lon: 25.5485, accuracy: 8, speed: 1.0, heading: 270, timestampMs: now });
            hook.pushFix({ lat: 45.4427, lon: 25.54845, accuracy: 8, speed: 0.9, heading: 270, timestampMs: now + 5_000 });
            hook.pushFix({ lat: 45.4427, lon: 25.5484, accuracy: 8, speed: 0.8, heading: 270, timestampMs: now + 10_000 });
        });

        await expect(banner).toHaveAttribute("data-nav-state", "off-trail");
        await expect(banner).toHaveClass(/bg-orange-600/);
        await expect(banner).toContainText(/trail/i);

        // nav-offtrail-line layer appears in MapLibre with GeoJSON feature
        await expect
            .poll(() =>
                page.evaluate(async () => {
                    const m = (window as any).realMap;
                    const hasLayer = Boolean(m.getLayer("nav-offtrail-line") && m.getLayer("nav-rejoin-point"));
                    const src = m.getSource("nav-offtrail") as any;
                    const data = src ? await src.getData() : null;
                    const feature = data?.features?.[0];
                    return {
                        hasLayer,
                        coordCount: feature?.geometry?.coordinates?.length ?? 0,
                        mode: feature?.properties?.mode ?? null,
                    };
                }),
            )
            .toMatchObject({
                hasLayer: true,
                mode: "min-climb",
            });

        // Switch mode from min-climb -> shortest-safe and verify recalculation
        const shortestBtn = page.locator('[data-testid="offtrail-mode-shortest-safe"]');
        const minClimbBtn = page.locator('[data-testid="offtrail-mode-min-climb"]');
        await shortestBtn.click();
        await expect(shortestBtn).toHaveAttribute("aria-pressed", "true");
        await expect(minClimbBtn).toHaveAttribute("aria-pressed", "false");
        await expect
            .poll(() =>
                page.evaluate(async () => {
                    const src = (window as any).realMap.getSource("nav-offtrail") as any;
                    const data = src ? await src.getData() : null;
                    return data?.features?.[0]?.properties?.mode ?? null;
                }),
            )
            .toBe("shortest-safe");

        // Switch back to min-climb
        await minClimbBtn.click();
        await expect(minClimbBtn).toHaveAttribute("aria-pressed", "true");
        await expect
            .poll(() =>
                page.evaluate(async () => {
                    const src = (window as any).realMap.getSource("nav-offtrail") as any;
                    const data = src ? await src.getData() : null;
                    return data?.features?.[0]?.properties?.mode ?? null;
                }),
            )
            .toBe("min-climb");

        // 4. Walk back within 10 m of trail -> orange reroute clears and green on-trail banner returns
        await page.evaluate(() => {
            const hook = (window as any).__wandererNavTest;
            hook.pushFix({
                lat: 45.4436,
                lon: 25.55,
                accuracy: 6,
                speed: 1.1,
                heading: 0,
                timestampMs: Date.now() + 400_000,
            });
        });

        await expect(banner).toHaveAttribute("data-nav-state", "on-trail");
        await expect(banner).toHaveClass(/bg-emerald-700/);
        await expect(page.locator('[data-testid="nav-rejoined-badge"]')).toBeVisible();

        await expect
            .poll(() =>
                page.evaluate(async () => {
                    const m = (window as any).realMap;
                    const src = m.getSource("nav-offtrail") as any;
                    const data = src ? await src.getData() : null;
                    return {
                        offTrailLayer: Boolean(m.getLayer("nav-offtrail-line")),
                        offTrailFeatures: data?.features?.length ?? 0,
                    };
                }),
            )
            .toEqual({ offTrailLayer: false, offTrailFeatures: 0 });
    });

    test("supports 3D/2D pitch toggle, drag break-out recenter pill, chart zoom, pause, and exit confirm", async ({
        page,
    }) => {
        await mountNavigatePage(page, bundle);

        // Push initial fix so map centers on user in 3D follow mode
        await page.evaluate(() => {
            const hook = (window as any).__wandererNavTest;
            hook.setCompass(15, 8);
            hook.pushFix({ lat: 45.44, lon: 25.55, accuracy: 8, speed: 1.0, heading: 0 });
        });

        await expect
            .poll(() =>
                page.evaluate(() => {
                    const m = (window as any).realMap;
                    return Boolean(
                        m.getLayer("nav-trail-walked") &&
                            m.getLayer("nav-trail-upcoming") &&
                            m.getLayer("nav-trail-upcoming-casing") &&
                            m.getLayer("nav-breadcrumb"),
                    );
                }),
            )
            .toBe(true);

        // Toggle 3D -> 2D -> 3D
        const pitchBtn = page.locator('[data-testid="nav-pitch-toggle"]');
        await expect(pitchBtn).toHaveAttribute("aria-pressed", "true");
        await pitchBtn.click();
        await expect(pitchBtn).toHaveAttribute("aria-pressed", "false");
        await expect
            .poll(() => page.evaluate(() => Math.round((window as any).realMap.getPitch())))
            .toBe(0);
        await pitchBtn.click();
        await expect(pitchBtn).toHaveAttribute("aria-pressed", "true");
        await expect
            .poll(() => page.evaluate(() => Math.round((window as any).realMap.getPitch())))
            .toBe(50);

        // Manual drag breaks follow and shows Recenter pill
        const recenterBtn = page.locator('[data-testid="nav-recenter-btn"]');
        await expect(recenterBtn).toHaveCount(0);
        const box = (await page.locator('[data-testid="nav-map"]').boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.down();
        await page.mouse.move(box.x + box.width / 2 + 80, box.y + box.height / 2 + 50, { steps: 6 });
        await page.mouse.up();
        await expect(recenterBtn).toBeVisible();

        // Click Recenter -> follow resumes and Recenter hides
        await recenterBtn.click();
        await expect(recenterBtn).toHaveCount(0);

        // Chart zoom toggle Next 2 km <-> Full trail & collapse/expand
        await page.locator('[data-testid="chart-zoom-full"]').click();
        await expect(page.locator('[data-testid="chart-zoom-full"]')).toHaveAttribute("aria-pressed", "true");
        await page.locator('[data-testid="chart-zoom-2km"]').click();
        await expect(page.locator('[data-testid="chart-zoom-2km"]')).toHaveAttribute("aria-pressed", "true");

        await page.locator('[data-testid="nav-expand-chart-btn"]').click();
        await expect(page.locator('[data-testid="live-elevation-canvas"]')).toHaveCount(0);
        await page.locator('[data-testid="nav-expand-chart-btn"]').click();
        await expect(page.locator('[data-testid="live-elevation-canvas"]')).toBeVisible();

        // Pause & Reverse & Exit confirm
        await page.locator('[data-testid="nav-pause-btn"]').click();
        await expect(page.locator('[data-testid="live-elevation-sheet"]')).toContainText("Paused");
        await page.locator('[data-testid="nav-pause-btn"]').click();

        const revBtn = page.locator('[data-testid="nav-reverse-btn"]');
        await revBtn.click();
        await expect(revBtn).toHaveAttribute("aria-pressed", "true");

        await page.locator('[data-testid="nav-exit-btn"]').click();
        await expect(page.locator('[data-testid="nav-exit-confirm-bar"]')).toBeVisible();
        await page.locator('[data-testid="nav-confirm-exit-btn"]').click();
        await expect
            .poll(() => page.evaluate(() => ((window as any).__navGotoCalls ?? []).length))
            .toBe(1);
    });
});
