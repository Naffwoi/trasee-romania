const MAX_VERIFIED_AGE_MS = 2 * 60 * 60 * 1000;
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const MAX_VERIFIED_DISTANCE_M = 250.0;
const MAX_IMAGE_DIMENSION_PX = 1280;
const JPEG_ENCODE_QUALITY = 0.82;

export interface ParsedPhotoExif {
	lat: number | null;
	lon: number | null;
	capturedAtMs: number | null;
	directionDeg: number | null;
}

function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const R = 6_371_000;
	const dLat = ((lat2 - lat1) * Math.PI) / 180;
	const dLon = ((lon2 - lon1) * Math.PI) / 180;
	const a =
		Math.sin(dLat / 2) ** 2 +
		Math.cos((lat1 * Math.PI) / 180) *
			Math.cos((lat2 * Math.PI) / 180) *
			Math.sin(dLon / 2) ** 2;
	return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
}

function findExifTiffStart(bytes: Uint8Array): number {
	const scanLimit = Math.min(bytes.length - 14, 256 * 1024);
	for (let i = 0; i < scanLimit; i++) {
		if (
			bytes[i] === 0x45 &&
			bytes[i + 1] === 0x78 &&
			bytes[i + 2] === 0x69 &&
			bytes[i + 3] === 0x66 &&
			bytes[i + 4] === 0x00 &&
			bytes[i + 5] === 0x00
		) {
			const b0 = bytes[i + 6];
			const b1 = bytes[i + 7];
			if ((b0 === 0x49 && b1 === 0x49) || (b0 === 0x4d && b1 === 0x4d)) {
				return i + 6;
			}
		}
	}
	return -1;
}

function readAscii(dv: DataView, offset: number, count: number): string {
	const end = Math.min(dv.byteLength, offset + count);
	let out = "";
	for (let i = offset; i < end; i++) {
		const ch = dv.getUint8(i);
		if (ch === 0) break;
		out += String.fromCharCode(ch);
	}
	return out.trim();
}

function readRationalTriple(
	dv: DataView,
	valueOffset: number,
	le: boolean,
): [number, number, number] | null {
	if (valueOffset < 0 || valueOffset + 24 > dv.byteLength) return null;
	const vals: [number, number, number] = [0, 0, 0];
	for (let i = 0; i < 3; i++) {
		const num = dv.getUint32(valueOffset + i * 8, le);
		const den = dv.getUint32(valueOffset + i * 8 + 4, le);
		if (den === 0) return null;
		vals[i] = num / den;
	}
	return vals;
}

function parseExifTimestampMs(dateTimeRaw: string | null, offsetRaw: string | null): number | null {
	if (!dateTimeRaw) return null;
	const m = /^(\d{4}):(\d{2}):(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/.exec(dateTimeRaw.trim());
	if (!m) return null;
	const [, y, mo, d, hh, mm, ss] = m;
	const tz = offsetRaw && /^[+-]\d{2}:\d{2}$/.test(offsetRaw.trim()) ? offsetRaw.trim() : "";
	const iso = tz ? `${y}-${mo}-${d}T${hh}:${mm}:${ss}${tz}` : `${y}-${mo}-${d}T${hh}:${mm}:${ss}`;
	const parsed = Date.parse(iso);
	return Number.isFinite(parsed) ? parsed : null;
}

/** Extracts GPS coordinates and DateTimeOriginal from JPEG APP1 or HEIC ISO-BMFF byte streams. */
export function extractPhotoExifFromBuffer(buffer: ArrayBuffer): ParsedPhotoExif {
	const bytes = new Uint8Array(buffer);
	const tiffStart = findExifTiffStart(bytes);
	if (tiffStart < 0 || tiffStart + 8 > bytes.length) {
		return { lat: null, lon: null, capturedAtMs: null, directionDeg: null };
	}

	const dv = new DataView(buffer);
	const le = dv.getUint16(tiffStart, false) === 0x4949;
	if (dv.getUint16(tiffStart + 2, le) !== 42) {
		return { lat: null, lon: null, capturedAtMs: null, directionDeg: null };
	}

	const ifd0Rel = dv.getUint32(tiffStart + 4, le);
	const ifd0Off = tiffStart + ifd0Rel;
	if (ifd0Off + 2 > dv.byteLength) {
		return { lat: null, lon: null, capturedAtMs: null, directionDeg: null };
	}

	let exifIfdRel = 0;
	let gpsIfdRel = 0;
	let ifd0DateTime: string | null = null;

	const count0 = dv.getUint16(ifd0Off, le);
	for (let i = 0; i < count0; i++) {
		const ent = ifd0Off + 2 + i * 12;
		if (ent + 12 > dv.byteLength) break;
		const tag = dv.getUint16(ent, le);
		const type = dv.getUint16(ent + 2, le);
		const num = dv.getUint32(ent + 4, le);
		const valOrOff = dv.getUint32(ent + 8, le);

		if (tag === 0x8769) exifIfdRel = valOrOff;
		else if (tag === 0x8825) gpsIfdRel = valOrOff;
		else if (tag === 0x0132 && type === 2 && num <= 32) {
			const off = num > 4 ? tiffStart + valOrOff : ent + 8;
			if (off + num <= dv.byteLength) ifd0DateTime = readAscii(dv, off, num);
		}
	}

	let dateTimeOriginal: string | null = null;
	let offsetTimeOriginal: string | null = null;
	if (exifIfdRel > 0 && tiffStart + exifIfdRel + 2 <= dv.byteLength) {
		const exifOff = tiffStart + exifIfdRel;
		const exifCount = dv.getUint16(exifOff, le);
		for (let i = 0; i < exifCount; i++) {
			const ent = exifOff + 2 + i * 12;
			if (ent + 12 > dv.byteLength) break;
			const tag = dv.getUint16(ent, le);
			const type = dv.getUint16(ent + 2, le);
			const num = dv.getUint32(ent + 4, le);
			const valOrOff = dv.getUint32(ent + 8, le);
			if (type === 2 && num <= 32) {
				const off = num > 4 ? tiffStart + valOrOff : ent + 8;
				if (off + num > dv.byteLength) continue;
				if (tag === 0x9003) dateTimeOriginal = readAscii(dv, off, num);
				else if (tag === 0x9011) offsetTimeOriginal = readAscii(dv, off, num);
			}
		}
	}

	let latRef = "N";
	let lonRef = "E";
	let latTriple: [number, number, number] | null = null;
	let lonTriple: [number, number, number] | null = null;
	let directionDeg: number | null = null;
	let gpsDateStamp: string | null = null;
	let gpsTimeTriple: [number, number, number] | null = null;

	if (gpsIfdRel > 0 && tiffStart + gpsIfdRel + 2 <= dv.byteLength) {
		const gpsOff = tiffStart + gpsIfdRel;
		const gpsCount = dv.getUint16(gpsOff, le);
		for (let i = 0; i < gpsCount; i++) {
			const ent = gpsOff + 2 + i * 12;
			if (ent + 12 > dv.byteLength) break;
			const tag = dv.getUint16(ent, le);
			const type = dv.getUint16(ent + 2, le);
			const num = dv.getUint32(ent + 4, le);
			const valOrOff = dv.getUint32(ent + 8, le);

			if (tag === 0x0001 && type === 2) {
				latRef = readAscii(dv, ent + 8, Math.min(4, num)).toUpperCase() || "N";
			} else if (tag === 0x0003 && type === 2) {
				lonRef = readAscii(dv, ent + 8, Math.min(4, num)).toUpperCase() || "E";
			} else if (tag === 0x0002 && type === 5 && num === 3) {
				latTriple = readRationalTriple(dv, tiffStart + valOrOff, le);
			} else if (tag === 0x0004 && type === 5 && num === 3) {
				lonTriple = readRationalTriple(dv, tiffStart + valOrOff, le);
			} else if (tag === 0x0007 && type === 5 && num === 3) {
				gpsTimeTriple = readRationalTriple(dv, tiffStart + valOrOff, le);
			} else if (tag === 0x001d && type === 2 && num <= 16) {
				const off = num > 4 ? tiffStart + valOrOff : ent + 8;
				if (off + num <= dv.byteLength) gpsDateStamp = readAscii(dv, off, num);
			} else if (tag === 0x0011 && type === 5 && num === 1) {
				const off = tiffStart + valOrOff;
				if (off + 8 <= dv.byteLength) {
					const nVal = dv.getUint32(off, le);
					const dVal = dv.getUint32(off + 4, le);
					if (dVal > 0) directionDeg = (((nVal / dVal) % 360) + 360) % 360;
				}
			}
		}
	}

	let lat: number | null = null;
	let lon: number | null = null;
	if (latTriple && lonTriple) {
		lat = latTriple[0] + latTriple[1] / 60 + latTriple[2] / 3600;
		if (latRef === "S") lat = -lat;
		lon = lonTriple[0] + lonTriple[1] / 60 + lonTriple[2] / 3600;
		if (lonRef === "W") lon = -lon;
		if (!Number.isFinite(lat) || !Number.isFinite(lon) || (lat === 0 && lon === 0)) {
			lat = null;
			lon = null;
		}
	}

	let capturedAtMs = parseExifTimestampMs(dateTimeOriginal ?? ifd0DateTime, offsetTimeOriginal);
	if (capturedAtMs === null && gpsDateStamp && gpsTimeTriple) {
		const dm = /^(\d{4}):(\d{2}):(\d{2})$/.exec(gpsDateStamp);
		if (dm) {
			const hh = String(Math.floor(gpsTimeTriple[0])).padStart(2, "0");
			const mm = String(Math.floor(gpsTimeTriple[1])).padStart(2, "0");
			const ss = String(Math.floor(gpsTimeTriple[2])).padStart(2, "0");
			const ts = Date.parse(`${dm[1]}-${dm[2]}-${dm[3]}T${hh}:${mm}:${ss}Z`);
			if (Number.isFinite(ts)) capturedAtMs = ts;
		}
	}

	return { lat, lon, capturedAtMs, directionDeg };
}

/** Verifies whether parsed photo EXIF falls within 2h and 250m of the report pin. */
export function evaluateExifOnSiteTrust(
	exif: ParsedPhotoExif,
	pin: { lat: number; lon: number },
	nowMs = Date.now(),
): { verified: boolean; distanceM: number | null; ageMinutes: number | null } {
	if (
		exif.lat === null ||
		exif.lon === null ||
		exif.capturedAtMs === null ||
		!Number.isFinite(pin.lat) ||
		!Number.isFinite(pin.lon)
	) {
		return { verified: false, distanceM: null, ageMinutes: null };
	}

	const deltaMs = nowMs - exif.capturedAtMs;
	const distM = haversineMeters(exif.lat, exif.lon, pin.lat, pin.lon);
	const ageMinutes = Math.round(deltaMs / 60_000);
	const isFresh = deltaMs >= -MAX_CLOCK_SKEW_MS && deltaMs <= MAX_VERIFIED_AGE_MS;
	const isNear = distM <= MAX_VERIFIED_DISTANCE_M;

	return {
		verified: isFresh && isNear,
		distanceM: Math.round(distM),
		ageMinutes,
	};
}

/** Verifies photo EXIF on-device and re-encodes via Canvas to a <=1280px JPEG with zero EXIF metadata. */
export async function verifyAndStripReportPhoto(
	file: File,
	pin: { lat: number; lon: number },
	nowMs = Date.now(),
): Promise<{
	strippedBlob: Blob;
	filename: string;
	photoVerified: boolean;
	width: number;
	height: number;
}> {
	const rawBuffer = await file.arrayBuffer();
	const exif = extractPhotoExifFromBuffer(rawBuffer);
	const trust = evaluateExifOnSiteTrust(exif, pin, nowMs);

	let decodeSource: Blob = file;
	const isHeic =
		file.type.toLowerCase().includes("heic") ||
		file.type.toLowerCase().includes("heif") ||
		/\.hei[cf]$/i.test(file.name);

	let bitmap: ImageBitmap | null = null;
	if (typeof createImageBitmap === "function") {
		try {
			bitmap = await createImageBitmap(decodeSource, { imageOrientation: "from-image" });
		} catch {
			if (isHeic) {
				const heic2any = (await import("heic2any")).default;
				const converted = await heic2any({
					blob: file,
					toType: "image/jpeg",
					quality: JPEG_ENCODE_QUALITY,
				});
				decodeSource = Array.isArray(converted) ? converted[0] : converted;
				bitmap = await createImageBitmap(decodeSource, { imageOrientation: "from-image" });
			}
		}
	}

	if (bitmap) {
		try {
			const scale = Math.min(1, MAX_IMAGE_DIMENSION_PX / Math.max(bitmap.width, bitmap.height));
			const outW = Math.max(1, Math.round(bitmap.width * scale));
			const outH = Math.max(1, Math.round(bitmap.height * scale));

			const canvas = document.createElement("canvas");
			canvas.width = outW;
			canvas.height = outH;
			const ctx = canvas.getContext("2d");
			if (!ctx) throw new Error("canvas_2d_unavailable");
			ctx.drawImage(bitmap, 0, 0, outW, outH);

			const strippedBlob = await new Promise<Blob>((resolve, reject) => {
				canvas.toBlob(
					(b) => (b ? resolve(b) : reject(new Error("jpeg_encode_failed"))),
					"image/jpeg",
					JPEG_ENCODE_QUALITY,
				);
			});

			return {
				strippedBlob,
				filename: "report.jpg",
				photoVerified: trust.verified,
				width: outW,
				height: outH,
			};
		} finally {
			bitmap.close?.();
		}
	}

	throw new Error("image_decode_unsupported");
}
