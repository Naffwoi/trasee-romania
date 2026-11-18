import { expect, test } from "@playwright/test";
import {
	resolveNearestSalvamont,
	resolveTrailSalvamontSummary,
} from "../../../src/lib/emergency/salvamont_resolver";

test.describe("Salvamont Map Layer, SOS Ridge-Border & Route Integration", () => {
	test("resolves Vf. Omu multi-county border and builds offline popup DOM with E.164 links", async ({
		page,
	}) => {
		const omuRes = resolveNearestSalvamont(45.4458, 25.4563, { userEle: 2505, locale: "ro" });
		expect(omuRes.isRidgeBorderZone).toBe(true);
		expect(omuRes.activeServices.length).toBeGreaterThanOrEqual(2);

		await page.setContent(`<!doctype html><html><body><div id="host"></div></body></html>`);
		const nearestPt = omuRes.nearestBases[0].point;

		const htmlSummary = await page.evaluate(
			({ pt, res }) => {
				const host = document.getElementById("host")!;
				const card = document.createElement("div");
				card.setAttribute("data-testid", "sos-salvamont-nearest-card");
				if (res.isRidgeBorderZone) {
					const badge = document.createElement("span");
					badge.setAttribute("data-testid", "sos-ridge-border-badge");
					badge.textContent = `Graniță montană (${res.borderCountyCodes.join(" / ")})`;
					card.appendChild(badge);
				}
				for (const svcEntry of res.activeServices) {
					const a = document.createElement("a");
					a.setAttribute("data-testid", `sos-call-local-${svcEntry.service.id}`);
					a.href = `tel:${svcEntry.service.primaryPhone}`;
					a.textContent = svcEntry.service.shortName;
					card.appendChild(a);
				}
				const nat = document.createElement("a");
				nat.setAttribute("data-testid", "sos-call-salvamont");
				nat.href = `tel:${res.nationalDispatchPhone}`;
				card.appendChild(nat);
				host.appendChild(card);
				return {
					ptName: pt.name,
					hrefs: Array.from(card.querySelectorAll("a")).map((x) => x.getAttribute("href")),
				};
			},
			{ pt: nearestPt, res: omuRes },
		);

		await expect(page.getByTestId("sos-ridge-border-badge")).toBeVisible();
		expect(htmlSummary.hrefs).toContain("tel:+40725826668");
		for (const href of htmlSummary.hrefs) {
			expect(href).toMatch(/^tel:\+40[237]\d{8}$/);
		}
	});

	test("computes cross-county TrailSalvamontSummary with zero network dependency", () => {
		const summary = resolveTrailSalvamontSummary([
			{ lat: 45.6048, lon: 24.6141, ele: 2040 },
			{ lat: 45.5972, lon: 24.6507, ele: 2175 },
		]);
		expect(summary).not.toBeNull();
		expect(summary!.isRidgeBorderTrail).toBe(true);
		expect(summary!.nearestRefuge?.point.id).toBe("refugiu-salvamont-fereastra-zmeilor");
	});
});
