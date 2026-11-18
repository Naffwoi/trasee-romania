import { describe, expect, it } from "vitest";
import {
	evaluateExifOnSiteTrust,
	extractPhotoExifFromBuffer,
} from "./exif_photo_verifier";

function buildSyntheticExifBlock(params: {
	dateTimeStr: string;
	offsetStr?: string;
	latDeg: number;
	lonDeg: number;
	wrapAsHeicIsoBmff?: boolean;
}): ArrayBuffer {
	const tiff = new Uint8Array(512);
	const dv = new DataView(tiff.buffer);
	dv.setUint16(0, 0x4949, true);
	dv.setUint16(2, 42, true);
	dv.setUint32(4, 8, true);

	dv.setUint16(8, 2, true);
	dv.setUint16(10, 0x8769, true);
	dv.setUint16(12, 4, true);
	dv.setUint32(14, 1, true);
	dv.setUint32(18, 64, true);

	dv.setUint16(22, 0x8825, true);
	dv.setUint16(24, 4, true);
	dv.setUint32(26, 1, true);
	dv.setUint32(30, 160, true);
	dv.setUint32(34, 0, true);

	const writeAscii = (offset: number, s: string) => {
		for (let i = 0; i < s.length; i++) tiff[offset + i] = s.charCodeAt(i);
		tiff[offset + s.length] = 0;
	};

	const exifCount = params.offsetStr ? 2 : 1;
	dv.setUint16(64, exifCount, true);
	dv.setUint16(66, 0x9003, true);
	dv.setUint16(68, 2, true);
	dv.setUint32(70, 20, true);
	dv.setUint32(74, 110, true);
	writeAscii(110, params.dateTimeStr);

	if (params.offsetStr) {
		dv.setUint16(78, 0x9011, true);
		dv.setUint16(80, 2, true);
		dv.setUint32(82, 7, true);
		dv.setUint32(86, 136, true);
		writeAscii(136, params.offsetStr);
	}

	dv.setUint16(160, 4, true);
	dv.setUint16(162, 0x0001, true);
	dv.setUint16(164, 2, true);
	dv.setUint32(166, 2, true);
	tiff[170] = "N".charCodeAt(0);
	dv.setUint16(174, 0x0002, true);
	dv.setUint16(176, 5, true);
	dv.setUint32(178, 3, true);
	dv.setUint32(182, 240, true);
	dv.setUint16(186, 0x0003, true);
	dv.setUint16(188, 2, true);
	dv.setUint32(190, 2, true);
	tiff[194] = "E".charCodeAt(0);
	dv.setUint16(198, 0x0004, true);
	dv.setUint16(200, 5, true);
	dv.setUint32(202, 3, true);
	dv.setUint32(206, 264, true);

	const writeCoordRationals = (off: number, deg: number) => {
		const d = Math.floor(deg);
		const mFloat = (deg - d) * 60;
		const m = Math.floor(mFloat);
		const sMilli = Math.round((mFloat - m) * 60 * 1000);
		dv.setUint32(off, d, true);
		dv.setUint32(off + 4, 1, true);
		dv.setUint32(off + 8, m, true);
		dv.setUint32(off + 12, 1, true);
		dv.setUint32(off + 16, sMilli, true);
		dv.setUint32(off + 20, 1000, true);
	};
	writeCoordRationals(240, params.latDeg);
	writeCoordRationals(264, params.lonDeg);

	const exifHeader = new Uint8Array([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]);
	if (params.wrapAsHeicIsoBmff) {
		const prefix = new TextEncoder().encode("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic");
		const out = new Uint8Array(prefix.length + exifHeader.length + tiff.length);
		out.set(prefix, 0);
		out.set(exifHeader, prefix.length);
		out.set(tiff, prefix.length + exifHeader.length);
		return out.buffer;
	}

	const app1Len = 2 + exifHeader.length + tiff.length;
	const full = new Uint8Array(2 + 4 + exifHeader.length + tiff.length + 2);
	full[0] = 0xff;
	full[1] = 0xd8;
	full[2] = 0xff;
	full[3] = 0xe1;
	full[4] = (app1Len >> 8) & 0xff;
	full[5] = app1Len & 0xff;
	full.set(exifHeader, 6);
	full.set(tiff, 12);
	full[full.length - 2] = 0xff;
	full[full.length - 1] = 0xd9;
	return full.buffer;
}

describe("extractPhotoExifFromBuffer & evaluateExifOnSiteTrust", () => {
	it("extracts GPS and DateTimeOriginal from both JPEG and iOS HEIC byte streams", () => {
		const nowMs = Date.parse("2026-11-18T11:45:00Z");
		const jpegBuf = buildSyntheticExifBlock({
			dateTimeStr: "2026:11:18 13:15:00",
			offsetStr: "+02:00",
			latDeg: 45.4458,
			lonDeg: 25.4563,
		});
		const parsedJpeg = extractPhotoExifFromBuffer(jpegBuf);
		expect(parsedJpeg.lat).toBeCloseTo(45.4458, 4);
		expect(parsedJpeg.lon).toBeCloseTo(25.4563, 4);

		const trustOk = evaluateExifOnSiteTrust(parsedJpeg, { lat: 45.4462, lon: 25.4565 }, nowMs);
		expect(trustOk.verified).toBe(true);
		expect(trustOk.distanceM!).toBeLessThan(80);
		expect(trustOk.ageMinutes).toBe(30);

		const heicBuf = buildSyntheticExifBlock({
			dateTimeStr: "2026:11:18 13:20:00",
			offsetStr: "+02:00",
			latDeg: 45.4459,
			lonDeg: 25.4564,
			wrapAsHeicIsoBmff: true,
		});
		const parsedHeic = extractPhotoExifFromBuffer(heicBuf);
		expect(parsedHeic.lat).toBeCloseTo(45.4459, 4);
		expect(
			evaluateExifOnSiteTrust(parsedHeic, { lat: 45.4458, lon: 25.4563 }, nowMs).verified,
		).toBe(true);
	});

	it("marks photo unverified (without throwing) when >250m away, >2h old, or stripped by OS", () => {
		const nowMs = Date.parse("2026-11-18T16:00:00Z");
		const oldBuf = buildSyntheticExifBlock({
			dateTimeStr: "2026:11:18 12:00:00",
			offsetStr: "+02:00",
			latDeg: 45.4458,
			lonDeg: 25.4563,
		});
		const oldExif = extractPhotoExifFromBuffer(oldBuf);
		expect(
			evaluateExifOnSiteTrust(oldExif, { lat: 45.4458, lon: 25.4563 }, nowMs).verified,
		).toBe(false);

		const freshMs = Date.parse("2026-11-18T10:30:00Z");
		expect(
			evaluateExifOnSiteTrust(oldExif, { lat: 45.4570, lon: 25.4563 }, freshMs).verified,
		).toBe(false);

		const emptyExif = extractPhotoExifFromBuffer(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]).buffer);
		expect(
			evaluateExifOnSiteTrust(emptyExif, { lat: 45.4458, lon: 25.4563 }, freshMs).verified,
		).toBe(false);
	});
});
