import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, test, type Page } from "@playwright/test";
import { encodePolyline } from "../../../src/lib/util/polyline_util";
import { loadFontawesome } from "./fontawesome-fixture";
import { mountEngine } from "./map-engine-fixture";
import { buildMapPageFixture } from "./map-page-fixture";

const mapConfigPath = fileURLToPath(new URL("../../../src/lib/config/map.ts", import.meta.url));

const loopLine = [
    [7.96, 46.98],
    [8.02, 46.98],
    [8.02, 47.03],
    [7.96, 47.03],
    [7.96, 46.98],
];
const encodedLoop = encodePolyline(
    loopLine.map(([lon, lat]) => [lat, lon]),
    5,
);

const sampleTrail = {
    id: "trail-azuga-1",
    name: "Gara Azuga - Culmea Grecului",
    author: "romania",
    lat: 47.04,
    lon: 8.0,
    photos: [],
    public: true,
    completed: false,
    polyline: encodedLoop,
    location: "Gara Azuga",
    difficulty: "moderate",
    category: "cat-hiking",
    distance: 10930,
    duration: 11280,
    elevation_gain: 514,
    elevation_loss: 94,
    expand: {
        category: { id: "cat-hiking", name: "Hiking", icon: "fa-person-hiking" },
        author: {
            id: "actor-ro",
            preferred_username: "romania",
            is_local: true,
            domain: "trasee.skillfy.ro",
        },
    },
};

async function openMobileMap(page: Page, bundle: string) {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.addInitScript(() => {
        (window as any).fixtureMessages = {
            trail: "Traseu",
            list: "Liste",
            create: "Creare",
            library: "Bibliotecă",
            profile: "Profil",
            search: "Caută",
            filter: "Filtrare",
            sort: "Sortare",
            close: "Închide",
            moderate: "Moderat",
        };
    });
    await mountEngine(page, bundle, false, false);
    await loadFontawesome(page);
    await expect.poll(() => page.evaluate(() => (window as any).realMap.loaded())).toBe(true);
}

async function publishSampleTrail(page: Page) {
    await page.evaluate(() => {
        (window as any).fixture.autoResolve = false;
    });
    const searchInput = page.locator(".mobile-pill input[type='search']");
    await searchInput.fill("Azuga");
    await searchInput.press("Enter");
    await expect
        .poll(() =>
            page.evaluate(() =>
                (window as any).fixture.requests.filter((r: any) => r.body.filter?.q === "Azuga")
                    .length,
            ),
        )
        .toBeGreaterThanOrEqual(2);
    await page.evaluate((trail) => {
        const fixture = (window as any).fixture;
        const requests = fixture.requests.filter((r: any) => r.body.filter?.q === "Azuga");
        for (const req of requests) {
            req.resolve(
                req.channel === "map"
                    ? {
                          mapTrails: [{ ...trail, polyline: undefined, hover_polyline: trail.polyline }],
                          clusters: {
                              type: "FeatureCollection",
                              features: [
                                  {
                                      type: "Feature",
                                      properties: {
                                          id: trail.id,
                                          point_count: 1,
                                          is_large: false,
                                          category_icon: "fa-person-hiking",
                                      },
                                      geometry: {
                                          type: "Point",
                                          coordinates: [trail.lon, trail.lat],
                                      },
                                  },
                              ],
                          },
                      }
                    : { items: [trail], page: 1, totalPages: 1, totalHits: 1 },
            );
        }
    }, sampleTrail);
}

test.describe("Mobile 1:1 Web UI Parity", () => {
    let bundle: string;

    test.beforeAll(async () => {
        bundle = await buildMapPageFixture(false, true, true, true, true, true);
    });

    test("renders docked bottom navbar, floating pill search + stadium chips, and selection-only route", async ({
        page,
    }) => {
        expect(readFileSync(mapConfigPath, "utf8")).toMatch(/:\s*0;/);
        await openMobileMap(page, bundle);

        // 1. Docked Bottom App Bar
        const navbar = page.locator("nav.app-navbar");
        await expect(navbar).toBeVisible();
        await expect(navbar.locator('a[href="/map"]')).toBeVisible();
        await expect(navbar.locator('a[href="/lists"]')).toBeVisible();
        await expect(navbar.getByRole("button", { name: "Creare" })).toBeVisible();
        await expect(navbar.locator('a[href="/trails"]')).toBeVisible();
        await expect(navbar.getByRole("button", { name: "Open user menu" })).toBeVisible();

        // 2. Floating search pill + Filter & Sort stadium chips + collapsed sheet
        await expect(page.locator(".mobile-pill input[type='search']")).toBeVisible();
        await expect(page.locator(".filter-stadium-chip")).toBeVisible();
        await expect(page.locator(".result-controls.mobile-chip")).toBeVisible();
        const sheet = page.locator(".mobile-trails-sheet");
        await expect(sheet).toBeVisible();

        // 3. Publish trailhead pin: verify NO static polyline is drawn before selection
        await publishSampleTrail(page);
        await expect
            .poll(() =>
                page.evaluate(() => {
                    const map = (window as any).realMap;
                    const hits = map.queryRenderedFeatures(map.project([8.0, 47.04]), {
                        layers: ["unclustered-point"],
                    });
                    return hits.length > 0;
                }),
            )
            .toBe(true);

        const hasPreSelectionRoute = await page.evaluate(() => {
            const map = (window as any).realMap;
            return {
                selectedLayer: Boolean(map.getLayer("selected-trail-route")),
                previewFeatures: map.getSource("preview")?._data?.features?.length ?? 0,
            };
        });
        expect(hasPreSelectionRoute.selectedLayer).toBe(false);
        expect(hasPreSelectionRoute.previewFeatures).toBe(0);

        // 4. Click trailhead pin -> MobileSelectedTrailCard + white-cased loop route
        const pinPoint = await page.evaluate(() => {
            const map = (window as any).realMap;
            const p = map.project([8.0, 47.04]);
            const box = map.getCanvas().getBoundingClientRect();
            return { x: box.x + p.x, y: box.y + p.y };
        });
        await page.mouse.click(pinPoint.x, pinPoint.y);

        const selectedCard = page.locator(".mobile-selected-trail-card");
        await expect(selectedCard).toBeVisible();
        await expect(selectedCard).toContainText("Gara Azuga - Culmea Grecului");
        // Verify 4 stat chips (distance, duration, gain, loss)
        await expect(selectedCard.locator("span.rounded-full.whitespace-nowrap")).toHaveCount(4);

        await expect
            .poll(() =>
                page.evaluate(() => {
                    const map = (window as any).realMap;
                    return Boolean(
                        map.getLayer("selected-trail-route") &&
                            map.getLayer("selected-trail-casing") &&
                            map.getLayer("selected-trail-loop-fill"),
                    );
                }),
            )
            .toBe(true);

        // 5. Dismiss card -> route disappears and sheet returns
        await selectedCard.getByRole("button", { name: "Închide" }).click();
        await expect(selectedCard).toHaveCount(0);
        await expect(sheet).toBeVisible();
        await expect
            .poll(() =>
                page.evaluate(() => Boolean((window as any).realMap.getLayer("selected-trail-route"))),
            )
            .toBe(false);

        // 6. Layer switcher button opens an unclipped interactive menu (regression test for .maplibregl-ctrl-group overflow:hidden)
        const layerBtn = page.locator("#trail-map .maplibregl-ctrl-top-right button").filter({
            has: page.locator(".fa-layer-group"),
        });
        await expect(layerBtn).toBeVisible();
        await layerBtn.click();
        const topoLabel = page.locator("#trail-map").getByText("OpenTopoMap");
        await expect(topoLabel).toBeVisible();
        // Real pointer click verifies the dropdown is NOT clipped by parent overflow:hidden
        await topoLabel.click({ timeout: 3000 });
    });
});
