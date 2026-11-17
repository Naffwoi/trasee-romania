import { expect, test } from "@playwright/test";
import { loadFontawesome } from "./fontawesome-fixture";
import { mountEngine, waitForEngine } from "./map-engine-fixture";
import { buildMapPageFixture } from "./map-page-fixture";

test.describe("Google Maps user location & compass control", () => {
    let bundle: string;

    test.beforeAll(async () => {
        bundle = await buildMapPageFixture(false, true, true, false, true, true);
    });

    test("renders blue puck, accuracy halo, stationary compass cone, and cycles 3 camera states", async ({
        page,
    }) => {
        await page.addInitScript(() => {
            Object.defineProperty(navigator, "geolocation", {
                configurable: true,
                value: {
                    watchPosition: (success: PositionCallback) => {
                        setTimeout(() => {
                            success({
                                coords: {
                                    latitude: 45.6427,
                                    longitude: 25.5887,
                                    accuracy: 25,
                                    altitude: null,
                                    altitudeAccuracy: null,
                                    heading: null,
                                    speed: 0,
                                    toJSON: () => ({}),
                                },
                                timestamp: Date.now(),
                                toJSON: () => ({}),
                            } as GeolocationPosition);
                        }, 10);
                        return 1;
                    },
                    clearWatch: () => {},
                },
            });
        });

        await mountEngine(page, bundle, false, false);
        await loadFontawesome(page);

        const btn = page.locator(".wanderer-user-location-btn");
        await expect(btn).toHaveAttribute("data-tracking-mode", "inactive");

        // Tap 1 -> FollowNorthUp
        await btn.click();
        await expect(btn).toHaveAttribute("data-tracking-mode", "followNorthUp");
        await expect(btn).toHaveClass(/maplibregl-ctrl-geolocate-active/);
        const puck = page.locator(".wanderer-gmaps-location-puck");
        await expect(puck).toBeVisible();

        // Accuracy halo layers are added to the MapLibre style
        await expect
            .poll(() =>
                page.evaluate(() => {
                    const m = (window as any).realMap;
                    return Boolean(
                        m.getLayer("wanderer-user-accuracy-fill") &&
                            m.getLayer("wanderer-user-accuracy-outline"),
                    );
                }),
            )
            .toBe(true);

        // Dispatch compass event (iOS webkitCompassHeading = 120 deg SE) while stationary
        await page.evaluate(() => {
            const ev = new Event("deviceorientation") as any;
            ev.webkitCompassHeading = 120;
            ev.webkitCompassAccuracy = 10;
            window.dispatchEvent(ev);
        });

        const coneGroup = puck.locator("g");
        await expect(coneGroup).toBeVisible();
        await expect(coneGroup).toHaveAttribute("transform", /rotate\(120\.0 44 44\)/);

        // Tap 2 -> FollowHeadingUp (rotates map camera bearing to ~120 deg)
        await btn.click();
        await expect(btn).toHaveAttribute("data-tracking-mode", "followHeadingUp");
        await expect
            .poll(() =>
                page.evaluate(() => Math.round(((window as any).realMap.getBearing() + 360) % 360)),
            )
            .toBe(120);

        // Tap 3 -> Back to FollowNorthUp (resets map camera bearing to 0)
        await btn.click();
        await expect(btn).toHaveAttribute("data-tracking-mode", "followNorthUp");
        await expect
            .poll(() =>
                page.evaluate(() => Math.round(((window as any).realMap.getBearing() + 360) % 360)),
            )
            .toBe(0);

        // Style swap preserves the geodesic accuracy halo layers
        await page.evaluate(() => {
            (window as any).realMap.setStyle({
                version: 8,
                sources: {},
                layers: [
                    {
                        id: "background",
                        type: "background",
                        paint: { "background-color": "#222222" },
                    },
                ],
            });
        });
        await expect
            .poll(() =>
                page.evaluate(() => {
                    const m = (window as any).realMap;
                    return Boolean(
                        m.getLayer("wanderer-user-accuracy-fill") &&
                            m.getLayer("wanderer-user-accuracy-outline"),
                    );
                }),
            )
            .toBe(true);

        // Manual user drag transitions out of followNorthUp into freeTracking while keeping puck visible
        await waitForEngine(page);
        const box = (await page.locator("#trail-map").boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.down();
        await page.mouse.move(box.x + box.width / 2 + 80, box.y + box.height / 2 + 40, {
            steps: 5,
        });
        await page.mouse.up();
        await expect(btn).toHaveAttribute("data-tracking-mode", "freeTracking");
        await expect(btn).not.toHaveClass(/maplibregl-ctrl-geolocate-active/);
        await expect(puck).toBeVisible();
    });

    test("handles tilt-compensated W3C deviceorientationabsolute while stationary", async ({
        page,
    }) => {
        await page.addInitScript(() => {
            Object.defineProperty(navigator, "geolocation", {
                configurable: true,
                value: {
                    watchPosition: (success: PositionCallback) => {
                        setTimeout(() => {
                            success({
                                coords: {
                                    latitude: 45.6427,
                                    longitude: 25.5887,
                                    accuracy: 15,
                                    altitude: null,
                                    altitudeAccuracy: null,
                                    heading: null,
                                    speed: 0,
                                    toJSON: () => ({}),
                                },
                                timestamp: Date.now(),
                                toJSON: () => ({}),
                            } as GeolocationPosition);
                        }, 10);
                        return 1;
                    },
                    clearWatch: () => {},
                },
            });
        });

        await mountEngine(page, bundle, false, false);
        await loadFontawesome(page);

        const btn = page.locator(".wanderer-user-location-btn");
        await btn.click();
        await expect(btn).toHaveAttribute("data-tracking-mode", "followNorthUp");

        const puck = page.locator(".wanderer-gmaps-location-puck");
        await expect(puck).toBeVisible();

        // Device held tilted (beta=30) facing East (alpha=270 -> 90 deg)
        await page.evaluate(() => {
            const ev = new Event("deviceorientationabsolute") as any;
            ev.alpha = 270;
            ev.beta = 30;
            ev.gamma = 0;
            ev.absolute = true;
            window.dispatchEvent(ev);
        });

        const coneGroup = puck.locator("g");
        await expect(coneGroup).toBeVisible();
        await expect(coneGroup).toHaveAttribute("transform", /rotate\(90\.0 44 44\)/);
    });
});
