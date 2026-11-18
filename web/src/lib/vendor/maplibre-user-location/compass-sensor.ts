import { CircularHeadingFilter, extractHeadingFromOrientationEvent } from "./heading-math";
import type { CompassReading } from "./types";

type OrientationPermissionFn = () => Promise<"granted" | "denied" | "default" | "prompt">;
type OrientationEventName = "deviceorientationabsolute" | "deviceorientation";

type WebKitDeviceOrientationEvent = DeviceOrientationEvent & {
    webkitCompassHeading?: number;
    webkitCompassAccuracy?: number;
};

/**
 * Subscribes to device orientation / magnetometer events across iOS Safari
 * (`webkitCompassHeading`) and Android/W3C (`deviceorientationabsolute`),
 * smoothing readings with a circular low-pass filter and 1.2° deadband + rAF coalescing.
 */
export class CompassSensor {
    private readonly filter = new CircularHeadingFilter(0.22, 0.5);
    private activeListeners: Array<{ type: OrientationEventName; handler: (event: Event) => void }> = [];
    private hasReceivedAbsoluteEvent = false;
    private permissionGranted: boolean | null = null;
    private lastEmittedHeading: number | null = null;
    private lastEmitTimeMs = 0;
    private pendingReading: CompassReading | null = null;
    private rafId: number | null = null;
    private readonly deadbandDeg: number;

    constructor(options?: { deadbandDeg?: number }) {
        this.deadbandDeg = options?.deadbandDeg ?? 1.2;
    }

    /**
     * Must be invoked synchronously inside a user gesture handler (e.g., button click)
     * so iOS Safari allows the DeviceOrientation permission prompt.
     */
    async requestPermissionFromGesture(): Promise<boolean> {
        if (typeof DeviceOrientationEvent === "undefined") {
            this.permissionGranted = false;
            return false;
        }
        const maybeReq = (
            DeviceOrientationEvent as unknown as { requestPermission?: OrientationPermissionFn }
        ).requestPermission;

        if (typeof maybeReq === "function") {
            try {
                const state = await maybeReq.call(DeviceOrientationEvent);
                // Chrome returns "prompt" when sensors are not explicitly blocked,
                // whereas iOS Safari resolves to "granted" or "denied".
                this.permissionGranted = state !== "denied";
                return this.permissionGranted;
            } catch {
                this.permissionGranted = false;
                return false;
            }
        }
        this.permissionGranted = true;
        return true;
    }

    start(onReading: (reading: CompassReading) => void): void {
        this.stop();
        if (typeof window === "undefined" || this.permissionGranted === false) {
            return;
        }

        const angularDiff = (a: number, b: number): number => {
            const d = Math.abs(a - b) % 360;
            return d > 180 ? 360 - d : d;
        };

        const flushReading = (reading: CompassReading, nowMs: number) => {
            this.lastEmittedHeading = reading.heading;
            this.lastEmitTimeMs = nowMs;
            this.pendingReading = null;
            onReading(reading);
        };

        const emitReading = (event: WebKitDeviceOrientationEvent) => {
            const screenAngle =
                typeof window.screen?.orientation?.angle === "number"
                    ? window.screen.orientation.angle
                    : 0;
            const extracted = extractHeadingFromOrientationEvent(event, screenAngle);
            if (!extracted) {
                return;
            }
            const smoothed = this.filter.update(extracted.heading);
            if (smoothed === null) return;
            if (
                this.lastEmittedHeading !== null &&
                angularDiff(smoothed, this.lastEmittedHeading) < this.deadbandDeg
            ) {
                return;
            }

            const nextReading: CompassReading = { heading: smoothed, accuracy: extracted.accuracy };
            const nowMs = typeof performance !== "undefined" ? performance.now() : Date.now();
            if (
                this.lastEmittedHeading === null ||
                nowMs - this.lastEmitTimeMs >= 16 ||
                typeof requestAnimationFrame !== "function"
            ) {
                flushReading(nextReading, nowMs);
                return;
            }

            this.pendingReading = nextReading;
            if (this.rafId === null) {
                this.rafId = requestAnimationFrame(() => {
                    this.rafId = null;
                    if (this.pendingReading) {
                        const ts = typeof performance !== "undefined" ? performance.now() : Date.now();
                        flushReading(this.pendingReading, ts);
                    }
                });
            }
        };

        if ("ondeviceorientationabsolute" in window) {
            const absHandler = (rawEvent: Event) => {
                this.hasReceivedAbsoluteEvent = true;
                emitReading(rawEvent as WebKitDeviceOrientationEvent);
            };
            window.addEventListener("deviceorientationabsolute", absHandler, true);
            this.activeListeners.push({ type: "deviceorientationabsolute", handler: absHandler });
        }

        const stdHandler = (rawEvent: Event) => {
            const event = rawEvent as WebKitDeviceOrientationEvent;
            const hasWebkitHeading =
                typeof event.webkitCompassHeading === "number" &&
                Number.isFinite(event.webkitCompassHeading) &&
                event.webkitCompassHeading >= 0;
            // Ignore non-absolute alpha frames, and avoid duplicate emissions when
            // `deviceorientationabsolute` is already delivering Earth-north frames.
            if (!hasWebkitHeading && (event.absolute !== true || this.hasReceivedAbsoluteEvent)) {
                return;
            }
            emitReading(event);
        };
        window.addEventListener("deviceorientation", stdHandler, true);
        this.activeListeners.push({ type: "deviceorientation", handler: stdHandler });
    }

    stop(): void {
        if (this.rafId !== null && typeof cancelAnimationFrame === "function") {
            cancelAnimationFrame(this.rafId);
            this.rafId = null;
        }
        if (typeof window !== "undefined") {
            for (const { type, handler } of this.activeListeners) {
                window.removeEventListener(type, handler, true);
            }
        }
        this.activeListeners = [];
        this.hasReceivedAbsoluteEvent = false;
        this.lastEmittedHeading = null;
        this.lastEmitTimeMs = 0;
        this.pendingReading = null;
        this.filter.reset();
    }
}
