import { describe, expect, it } from "vitest";
import {
    CircularHeadingFilter,
    computeTiltCompensatedHeading,
    coneHalfAngleFromAccuracy,
    extractHeadingFromOrientationEvent,
    normalizeHeading,
    shortestAngleDelta,
} from "./heading-math";

describe("heading-math", () => {
    it("normalizes arbitrary angles into [0, 360)", () => {
        expect(normalizeHeading(0)).toBe(0);
        expect(normalizeHeading(360)).toBe(0);
        expect(normalizeHeading(-10)).toBe(350);
        expect(normalizeHeading(725)).toBe(5);
        expect(normalizeHeading(-0)).toBe(0);
    });

    it("computes shortest signed delta across the 359 <-> 0 boundary", () => {
        expect(shortestAngleDelta(355, 5)).toBeCloseTo(10, 5);
        expect(shortestAngleDelta(5, 355)).toBeCloseTo(-10, 5);
        expect(shortestAngleDelta(90, 270)).toBeCloseTo(180, 5);
        expect(shortestAngleDelta(0, 0)).toBeCloseTo(0, 5);
    });

    it("smooths across 359 -> 1 without passing through 180", () => {
        const filter = new CircularHeadingFilter(0.22, 0.5);
        expect(filter.update(358)).toBeCloseTo(358, 2);
        const next = filter.update(2);
        expect(next).not.toBeNull();
        expect(next! > 358 || next! < 3).toBe(true);
    });

    it("smooths across 1 -> 359 without passing through 180", () => {
        const filter = new CircularHeadingFilter(0.22, 0.5);
        expect(filter.update(2)).toBeCloseTo(2, 2);
        const next = filter.update(358);
        expect(next).not.toBeNull();
        expect(next! > 357 || next! < 2).toBe(true);
    });

    it("suppresses sub-deadband jitter (< 0.5 deg) by returning null", () => {
        const filter = new CircularHeadingFilter(0.22, 0.5);
        expect(filter.update(100)).toBeCloseTo(100, 2);
        expect(filter.update(100.2)).toBeNull();
        expect(filter.current).toBeCloseTo(100, 2);
        filter.reset();
        expect(filter.current).toBeNull();
    });

    it("ignores non-finite inputs", () => {
        const filter = new CircularHeadingFilter(0.22, 0.5);
        expect(filter.update(Number.NaN)).toBeNull();
        expect(filter.update(Number.POSITIVE_INFINITY)).toBeNull();
    });

    it("maps compass accuracy to Google Maps cone half-angles", () => {
        expect(coneHalfAngleFromAccuracy(null)).toBe(25);
        expect(coneHalfAngleFromAccuracy(undefined)).toBe(25);
        expect(coneHalfAngleFromAccuracy(10)).toBe(25);
        expect(coneHalfAngleFromAccuracy(15)).toBe(25);
        expect(coneHalfAngleFromAccuracy(25)).toBe(35);
        expect(coneHalfAngleFromAccuracy(35)).toBe(35);
        expect(coneHalfAngleFromAccuracy(50)).toBe(45);
        expect(coneHalfAngleFromAccuracy(-1)).toBe(45);
    });

    it("computes tilt-compensated heading from W3C Euler angles", () => {
        // Flat device facing North (alpha=0, beta=0, gamma=0) -> 0 deg
        expect(computeTiltCompensatedHeading(0, 0, 0, 0)).toBeCloseTo(0, 1);
        // Flat device rotated 90 deg CW to face East (W3C alpha increases CCW, so alpha=270 => 90 deg East)
        expect(computeTiltCompensatedHeading(270, 0, 0, 0)).toBeCloseTo(90, 1);
        // Tilted 45 deg in hand facing East (alpha=270, beta=45, gamma=0) stays ~90 deg East
        expect(computeTiltCompensatedHeading(270, 45, 0, 0)).toBeCloseTo(90, 1);
        // Landscape orientation compensates screenAngle (0, 90, 180, 270)
        expect(computeTiltCompensatedHeading(0, 0, 0, 90)).toBeCloseTo(90, 1);
        expect(computeTiltCompensatedHeading(0, 0, 0, 180)).toBeCloseTo(180, 1);
        expect(computeTiltCompensatedHeading(0, 0, 0, 270)).toBeCloseTo(270, 1);
    });

    it("prefers iOS webkitCompassHeading and compensates screen angle", () => {
        const reading = extractHeadingFromOrientationEvent(
            {
                webkitCompassHeading: 350,
                webkitCompassAccuracy: 12,
                alpha: null,
                beta: null,
                gamma: null,
                absolute: false,
            },
            90,
        );
        expect(reading).toEqual({ heading: 80, accuracy: 12 });
    });
});
