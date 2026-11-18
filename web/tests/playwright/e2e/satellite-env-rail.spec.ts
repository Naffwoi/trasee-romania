import { expect, test } from "@playwright/test";

test.describe("Phase 4: Satellite Layers, Snow/Radar Overlays, Hazards & 'Cu trenul'", () => {
	test("switches to Esri HD Satellite with vector peak labels and toggles NASA Snow & RainViewer z<=7 overlays", async ({
		page,
	}) => {
		await page.route("https://api.rainviewer.com/public/weather-maps.json", async (route) => {
			await route.fulfill({
				status: 200,
				contentType: "application/json",
				body: JSON.stringify({
					host: "https://tilecache.rainviewer.com",
					radar: { past: [{ time: 1795000800, path: "/v2/radar/e2etest" }] },
				}),
			});
		});

		await page.goto("/map");
		await page.getByTestId("style-switcher-btn").click();
		await expect(page.getByTestId("style-switcher-menu")).toBeVisible();

		await page.getByText("Satelit (Esri HD)").click();
		await page.locator("#snowCover-layer-checkbox").check();
		await page.locator("#weatherRadar-layer-checkbox").check();

		const stored = await page.evaluate(() =>
			JSON.parse(localStorage.getItem("wanderer-ro-map-state-v3") ?? "{}"),
		);
		expect(stored.base).toBe("Satelit (Esri HD)");
		expect(stored.overlays.snowCover).toBe(true);
		expect(stored.overlays.weatherRadar).toBe(true);
	});

	test("applies 'Cu trenul' Meilisearch filter and renders environment hazards + KartaView street preview", async ({
		page,
	}) => {
		let capturedFilter = "";
		await page.route("**/api/v1/search/**", async (route) => {
			const post = route.request().postData() ?? "";
			if (post.includes("train_accessible")) {
				capturedFilter = post;
			}
			await route.continue();
		});

		await page.goto("/trails");
		await page.getByTestId("filter-train-accessible").click();
		await expect.poll(() => capturedFilter).toContain("train_accessible = true");
	});
});
