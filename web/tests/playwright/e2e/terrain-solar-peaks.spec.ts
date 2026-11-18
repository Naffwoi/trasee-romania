import { expect, test } from "@playwright/test";

test.describe("Phase 3: Terrain Intelligence, Ridge Sunset ETA, Avalanche Slope & Offline Peak Finder", () => {
	test("renders Ridge Sunset warning in deep western valley, toggles Slope/Shadow overlays, and identifies Carpathian peaks offline", async ({
		page,
		context,
	}) => {
		await page.goto("/trails");
		const firstTrailLink = page.locator('a[href*="/map/trail/"]').first();
		await expect(firstTrailLink).toBeVisible();
		const trailHref = await firstTrailLink.getAttribute("href");
		expect(trailHref).toBeTruthy();

		const navUrl = trailHref!.replace(/(\?.*)?$/, "/navigate$1");
		await page.goto(navUrl);
		await expect(page.getByTestId("live-elevation-sheet")).toBeVisible();

		await page.evaluate(() => {
			const hook = (window as unknown as Record<string, any>).__wandererNavTest;
			hook.setCustomDemSampler((_lat: number, lon: number) => (lon < 25.48 ? 2350 : 1150));
			hook.setSimulatedTimeMs(Date.parse("2026-11-18T12:30:00Z"));
			hook.pushFix({
				lat: 45.44,
				lon: 25.5,
				accuracy: 8,
				altitude: 1150,
				timestampMs: Date.parse("2026-11-18T12:30:00Z"),
			});
		});

		await expect(page.getByTestId("nav-ridge-sunset-badge")).toBeVisible();
		await expect(page.locator(".bg-orange-600")).toHaveCount(0);

		await page.getByTestId("style-switcher-btn").click();
		await page.locator("#avalancheSlope-layer-checkbox").check();
		await page.locator("#solarShadows-layer-checkbox").check();
		await expect(page.getByTestId("slope-legend-pill")).toBeVisible();
		await expect(page.getByTestId("solar-time-scrubber")).toBeVisible();

		await page.evaluate(() => {
			const hook = (window as unknown as Record<string, any>).__wandererNavTest;
			hook.injectPeaks([
				{
					id: 9001,
					name: "Vârful Bucșoiu",
					lat: 45.468,
					lon: 25.5,
					ele: 2492,
					prominenceM: 450,
					kind: "peak",
				},
			]);
			hook.setCustomDemSampler(() => 1150);
			hook.setCompass(0, 8);
		});
		await context.setOffline(true);

		await page.getByTestId("nav-peak-finder-btn").click();
		await expect(page.getByTestId("peak-finder-sheet")).toBeVisible();
		await expect(page.getByTestId("peak-finder-list")).toContainText("Vârful Bucșoiu");

		await context.setOffline(false);
	});
});
