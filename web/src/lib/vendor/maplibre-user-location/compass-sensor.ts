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
 * smoothing readings with a circular low-pass filter.
 */
export class CompassSensor {
    private readonly filter = new CircularHeadingFilter(0.22, 0.5);
    private activeListeners: Array<{ type: OrientationEventName; handler: (event: Event) => void }> = [];
    private hasReceivedAbsoluteEvent = false;
    private permissionGranted: boolean | null = null;

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
            if (smoothed !== null) {
                onReading({ heading: smoothed, accuracy: extracted.accuracy });
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
        if (typeof window !== "undefined") {
            for (const { type, handler } of this.activeListeners) {
                window.removeEventListener(type, handler, true);
            }
        }
        this.activeListeners = [];
        this.hasReceivedAbsoluteEvent = false;
        this.filter.reset();
    }
}
