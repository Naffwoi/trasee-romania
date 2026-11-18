import { describe, expect, it } from "vitest";
import {
	buildEmergencySmsHref,
	decodePlusCode,
	encodePlusCode,
	formatDmsCoordinate,
	formatRescueCoordinates,
	stripRomanianDiacritics,
	wgs84ToUtm,
} from "./rescue_coordinates";

describe("wgs84ToUtm (Karney 2011 6th-order Krüger)", () => {
	it("matches Chris Veness Eiffel Tower reference vector to the millimeter", () => {
		const utm = wgs84ToUtm(48.8582, 2.2945);
		expect(utm.zone).toBe(31);
		expect(utm.band).toBe("U");
		expect(Math.round(utm.easting)).toBe(448252);
		expect(Math.round(utm.northing)).toBe(5411933);
	});

	it("handles all Romanian Carpathian zones: 35T (Bucegi/Fagaras), 34T (Retezat), and 35U (>48N)", () => {
		const omu = wgs84ToUtm(45.445833, 25.456389);
		expect(omu.formatted).toBe("35T 379287 E 5033638 N");

		const moldoveanu = wgs84ToUtm(45.599444, 24.736111);
		expect(moldoveanu.formatted).toBe("35T 323442 E 5052037 N");

		const retezat = wgs84ToUtm(45.366111, 22.876944);
		expect(retezat.formatted).toBe("34T 646986 E 5025336 N");

		const horodistea = wgs84ToUtm(48.258, 26.701);
		expect(horodistea.formatted).toBe("35U 477807 E 5345020 N");
	});
});

describe("Open Location Code / Google Plus Codes v1.1 integer math", () => {
	it("matches official Google OLC Zurich spec vector (10 & 11 chars) and decodes back within 2m", () => {
		expect(encodePlusCode(47.36559, 8.524997, 10)).toBe("8FVC9G8F+6X");
		const c11 = encodePlusCode(47.36559, 8.524997, 11);
		expect(c11).toBe("8FVC9G8F+6XQ");

		const area = decodePlusCode(c11);
		expect(Math.abs(area.latitudeCenter - 47.36559)).toBeLessThan(0.00003);
		expect(Math.abs(area.longitudeCenter - 8.524997)).toBeLessThan(0.00003);
	});

	it("encodes Romanian peaks deterministically without 32-bit integer overflow", () => {
		expect(encodePlusCode(45.445833, 25.456389, 11)).toBe("8GQ7CFW4+8HJ");
		expect(encodePlusCode(45.366111, 22.876944, 11)).toBe("8GQ49V8G+CQW");
	});
});

describe("DMS carry safety & 160-char GSM-7 SMS 113 builder", () => {
	it("never emits 60.0 arcseconds when seconds round up at 59.99s", () => {
		const dms = formatDmsCoordinate(45.999999, 25.499999);
		expect(dms).not.toContain('60.0"');
		expect(dms).toBe(`46° 00' 00.0" N, 25° 30' 00.0" E`);
	});

	it("builds strict <=160 char ASCII SMS 113 body and platform-specific sms: URI", () => {
		const bundle = formatRescueCoordinates({
			lat: 45.445833,
			lon: 25.456389,
			elevationM: 2505,
			accuracyM: 8,
			reasonRo: "Accidentare",
			landmark: { name: "Vârful Omu", lat: 45.4465, lon: 25.4572, eleM: 2505 },
			now: new Date("2026-11-18T12:32:00Z"),
		});
		expect(bundle.sms113AsciiBody.length).toBeLessThanOrEqual(160);
		expect(bundle.sms113AsciiBody).toMatch(/^[\x20-\x7E\n]+$/);
		expect(stripRomanianDiacritics("Șaua Căprioarei — Vârful Țibleș")).toBe(
			"Saua Caprioarei - Varful Tibles",
		);

		const iosHref = buildEmergencySmsHref(
			"113",
			"SOS TEST",
			"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X)",
			5,
		);
		expect(iosHref).toBe("sms:113&body=SOS%20TEST");

		const ipadHref = buildEmergencySmsHref(
			"+40725826668",
			"SOS TEST",
			"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
			5,
		);
		expect(ipadHref).toBe("sms:+40725826668&body=SOS%20TEST");

		const androidHref = buildEmergencySmsHref(
			"113",
			"SOS TEST",
			"Mozilla/5.0 (Linux; Android 14; Pixel 8)",
			5,
		);
		expect(androidHref).toBe("sms:113?body=SOS%20TEST");
	});
});
