import type { CompassReading } from "./types";

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;

/** Normalizes any angle in degrees into [0, 360). */
export function normalizeHeading(deg: number): number {
    const mod = deg % 360;
    return mod < 0 ? mod + 360 : mod === 0 ? 0 : mod;
}

/** Returns signed shortest angular difference from `fromDeg` to `toDeg` in (-180, 180]. */
export function shortestAngleDelta(fromDeg: number, toDeg: number): number {
    const diff = ((toDeg - fromDeg + 540) % 360) - 180;
    return diff === -180 ? 180 : diff;
}

/** Maps compass accuracy (degrees) to Google Maps flashlight cone half-angle. */
export function coneHalfAngleFromAccuracy(accuracyDeg?: number | null): number {
    if (accuracyDeg === undefined || accuracyDeg === null) {
        return 25;
    }
    if (accuracyDeg < 0 || accuracyDeg > 35) {
        return 45;
    }
    if (accuracyDeg > 15) {
        return 35;
    }
    return 25;
}

/**
 * Low-pass circular EMA filter on the unit circle (sin, cos) with emission deadband,
 * preventing 359° <-> 0° wraparound jumps and sub-threshold magnetometer jitter.
 */
export class CircularHeadingFilter {
    private sinSum: number | null = null;
    private cosSum: number | null = null;
    private lastEmitted: number | null = null;

    constructor(
        private readonly alpha = 0.22,
        private readonly deadbandDeg = 0.5,
    ) {}

    get current(): number | null {
        return this.lastEmitted;
    }

    reset(): void {
        this.sinSum = null;
        this.cosSum = null;
        this.lastEmitted = null;
    }

    update(rawDeg: number): number | null {
        if (!Number.isFinite(rawDeg)) {
            return null;
        }
        const normalized = normalizeHeading(rawDeg);
        const rad = normalized * DEG_TO_RAD;
        const s = Math.sin(rad);
        const c = Math.cos(rad);

        if (this.sinSum === null || this.cosSum === null || this.lastEmitted === null) {
            this.sinSum = s;
            this.cosSum = c;
            this.lastEmitted = normalized;
            return this.lastEmitted;
        }

        this.sinSum = this.alpha * s + (1 - this.alpha) * this.sinSum;
        this.cosSum = this.alpha * c + (1 - this.alpha) * this.cosSum;

        const smoothed = normalizeHeading(Math.atan2(this.sinSum, this.cosSum) * RAD_TO_DEG);
        if (Math.abs(shortestAngleDelta(this.lastEmitted, smoothed)) < this.deadbandDeg) {
            return null;
        }
        this.lastEmitted = smoothed;
        return smoothed;
    }
}

/**
 * Computes tilt-compensated compass heading [0, 360) clockwise from North
 * from W3C DeviceOrientation Euler angles (Z-X'-Y'' intrinsic: alpha, beta, gamma).
 * Projects `[0, 1, -1]` (top edge + rear camera vector) onto the horizontal East-North
 * plane so direction remains continuous when flat (beta=0) and held tilted upright.
 */
export function computeTiltCompensatedHeading(
    alpha: number,
    beta: number,
    gamma: number,
    screenAngle = 0,
): number | null {
    if (!Number.isFinite(alpha) || !Number.isFinite(beta) || !Number.isFinite(gamma)) {
        return null;
    }
    const a = alpha * DEG_TO_RAD;
    const b = beta * DEG_TO_RAD;
    const g = gamma * DEG_TO_RAD;

    const cA = Math.cos(a);
    const sA = Math.sin(a);
    const cB = Math.cos(b);
    const sB = Math.sin(b);
    const cG = Math.cos(g);
    const sG = Math.sin(g);

    const fy = 1;
    const fz = -1;

    // Column 2 of R = Rz(alpha) * Rx(beta) * Ry(gamma) (device +Y)
    const r01 = -sA * cB;
    const r11 = cA * cB;

    // Column 3 of R (device +Z)
    const r02 = cA * sG + sA * sB * cG;
    const r12 = sA * sG - cA * sB * cG;

    const east = r01 * fy + r02 * fz;
    const north = r11 * fy + r12 * fz;

    if (Math.hypot(east, north) < 1e-5) {
        return null;
    }

    const azimuthDeg = Math.atan2(east, north) * RAD_TO_DEG;
    return normalizeHeading(azimuthDeg + screenAngle);
}

export interface OrientationLikeEvent {
    webkitCompassHeading?: number | null;
    webkitCompassAccuracy?: number | null;
    alpha: number | null;
    beta: number | null;
    gamma: number | null;
    absolute?: boolean;
}

/** Extracts a screen-compensated CompassReading from an iOS or W3C orientation event. */
export function extractHeadingFromOrientationEvent(
    event: OrientationLikeEvent,
    screenAngle = 0,
): CompassReading | null {
    if (
        typeof event.webkitCompassHeading === "number" &&
        Number.isFinite(event.webkitCompassHeading) &&
        event.webkitCompassHeading >= 0
    ) {
        const accuracy =
            typeof event.webkitCompassAccuracy === "number" && Number.isFinite(event.webkitCompassAccuracy)
                ? event.webkitCompassAccuracy
                : null;
        return {
            heading: normalizeHeading(event.webkitCompassHeading + screenAngle),
            accuracy,
        };
    }

    if (event.alpha !== null && event.beta !== null && event.gamma !== null) {
        const heading = computeTiltCompensatedHeading(
            event.alpha,
            event.beta,
            event.gamma,
            screenAngle,
        );
        if (heading !== null) {
            return { heading, accuracy: null };
        }
    }
    return null;
}
