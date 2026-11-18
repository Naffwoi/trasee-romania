import { describe, expect, it } from "vitest";
import { getSunPosition, getSunTimes } from "./sun_calc";

describe("sun_calc (Meeus Ch.25 + rtsafe ephemeris)", () => {
	it("computes accurate North-clockwise azimuth and altitude at Vf. Omu (45.4457N, 25.4563E)", () => {
		const noonPos = getSunPosition(Date.parse("2026-06-21T10:20:00Z"), 45.4457, 25.4563);
		expect(noonPos.azimuthDeg).toBeGreaterThan(177);
		expect(noonPos.azimuthDeg).toBeLessThan(183);
		expect(noonPos.altitudeDeg).toBeGreaterThan(67.5);
		expect(noonPos.altitudeDeg).toBeLessThan(68.3);

		const morning = getSunPosition(Date.parse("2026-06-21T05:30:00Z"), 45.4457, 25.4563);
		const afternoon = getSunPosition(Date.parse("2026-06-21T15:30:00Z"), 45.4457, 25.4563);
		expect(morning.azimuthDeg).toBeGreaterThan(70);
		expect(morning.azimuthDeg).toBeLessThan(115);
		expect(afternoon.azimuthDeg).toBeGreaterThan(250);
		expect(afternoon.azimuthDeg).toBeLessThan(290);
	});

	it("computes autumn sunset and civil dusk at Vf. Omu on 2026-11-18", () => {
		const times = getSunTimes(Date.parse("2026-11-18T12:00:00Z"), 45.4457, 25.4563);
		expect(times.polarState).toBe("normal");
		expect(times.sunrise).not.toBeNull();
		expect(times.sunset).not.toBeNull();
		expect(times.dusk).not.toBeNull();

		const sunsetUtcMin = times.sunset!.getUTCHours() * 60 + times.sunset!.getUTCMinutes();
		expect(sunsetUtcMin).toBeGreaterThanOrEqual(14 * 60 + 38);
		expect(sunsetUtcMin).toBeLessThanOrEqual(14 * 60 + 49);
		expect(times.dusk!.getTime() - times.sunset!.getTime()).toBeGreaterThan(25 * 60_000);
		expect(times.dusk!.getTime() - times.sunset!.getTime()).toBeLessThan(42 * 60_000);
	});

	it("handles Arctic midnight sun and polar night without NaN or Invalid Date", () => {
		const tromsoSummer = getSunTimes(Date.parse("2026-06-21T12:00:00Z"), 69.6492, 18.9553);
		expect(tromsoSummer.polarState).toBe("midnight_sun");
		expect(tromsoSummer.sunrise).toBeNull();
		expect(tromsoSummer.sunset).toBeNull();

		const tromsoWinter = getSunTimes(Date.parse("2026-12-21T12:00:00Z"), 69.6492, 18.9553);
		expect(tromsoWinter.polarState).toBe("polar_night");
		expect(tromsoWinter.sunrise).toBeNull();
		expect(tromsoWinter.sunset).toBeNull();
	});
});
