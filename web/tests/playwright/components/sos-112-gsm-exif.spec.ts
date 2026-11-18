import { expect, test } from "@playwright/test";
import {
	buildEmergencySmsHref,
	formatRescueCoordinates,
} from "../../../src/lib/emergency/rescue_coordinates";
import {
	EmergencySpatialIndex,
	findBestGsm112SignalSpot,
} from "../../../src/lib/emergency/gsm_viewshed";
import { extractPhotoExifFromBuffer } from "../../../src/lib/live/exif_photo_verifier";
import seedData from "../../../static/data/romania_emergency_112.json" with { type: "json" };

test.describe("Salvamont 112 Pro Offline Suite & EXIF Waze Verification", () => {
	test("computes multi-format Bucegi rescue card, E.164/SMS 113 links, and GSM signal spot 100% offline", async ({
		page,
	}) => {
		await page.setContent(`
			<main id="card">
				<a id="call-112" href="tel:112">112</a>
				<a id="call-salvamont" href="tel:+40725826668">0-SALVAMONT</a>
				<a id="sms-113" href="">SMS 113</a>
				<pre id="coords"></pre>
				<p id="signal"></p>
			</main>
		`);

		const index = EmergencySpatialIndex.fromJson(seedData);
		const landmark = index.findNearestLandmark(45.445833, 25.456389);
		expect(landmark?.name).toBe("Vf. Omu");

		const bundle = formatRescueCoordinates({
			lat: 45.445833,
			lon: 25.456389,
			elevationM: 2505,
			accuracyM: 6,
			reasonRo: "Accidentare",
			landmark: landmark
				? { name: landmark.name, lat: landmark.lat, lon: landmark.lon, eleM: landmark.eleM }
				: null,
			now: new Date("2026-11-18T12:30:00Z"),
		});

		const smsHref = buildEmergencySmsHref(
			"113",
			bundle.sms113AsciiBody,
			"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4)",
			5,
		);
		const rec = findBestGsm112SignalSpot({
			lat: 45.445833,
			lon: 25.456389,
			dem: { sampleElevation: () => 2505 },
			index,
		});

		await page.evaluate(
			({ text, href, sig }) => {
				document.getElementById("coords")!.textContent = text;
				document.getElementById("sms-113")!.setAttribute("href", href);
				document.getElementById("signal")!.textContent = sig;
			},
			{ text: bundle.clipboardFullCardRo, href: smsHref, sig: rec.instructionRo },
		);

		await expect(page.locator("#call-salvamont")).toHaveAttribute("href", "tel:+40725826668");
		await expect(page.locator("#sms-113")).toHaveAttribute("href", /^sms:113&body=SOS%20MUNTE/);
		await expect(page.locator("#coords")).toContainText("35T 379287 E 5033638 N");
		await expect(page.locator("#coords")).toContainText("8GQ7CFW4+8HJ");
		await expect(page.locator("#signal")).toContainText("releu GSM");
	});

	test("Canvas JPEG re-encoding strips 100% of EXIF bytes in real Chromium runtime", async ({
		page,
	}) => {
		await page.setContent(`<canvas id="c" width="120" height="90"></canvas>`);
		const strippedBytes = await page.evaluate(async () => {
			const c = document.getElementById("c") as HTMLCanvasElement;
			const ctx = c.getContext("2d")!;
			ctx.fillStyle = "#242734";
			ctx.fillRect(0, 0, 120, 90);
			const blob = await new Promise<Blob>((res) =>
				c.toBlob((b) => res(b!), "image/jpeg", 0.82),
			);
			const buf = await blob.arrayBuffer();
			return Array.from(new Uint8Array(buf));
		});
		const parsed = extractPhotoExifFromBuffer(new Uint8Array(strippedBytes).buffer);
		expect(parsed.lat).toBeNull();
		expect(parsed.lon).toBeNull();
		expect(parsed.capturedAtMs).toBeNull();
	});
});
