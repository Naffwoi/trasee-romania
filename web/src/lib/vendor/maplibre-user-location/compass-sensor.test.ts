import { afterEach, describe, expect, it, vi } from "vitest";
import { CompassSensor } from "./compass-sensor";

describe("CompassSensor", () => {
    afterEach(() => {
        vi.unstubAllGlobals();
    });

    it("calls DeviceOrientationEvent.requestPermission when present on iOS", async () => {
        const requestPermission = vi.fn().mockResolvedValue("granted");
        vi.stubGlobal("DeviceOrientationEvent", { requestPermission });
        vi.stubGlobal("window", {
            addEventListener: vi.fn(),
            removeEventListener: vi.fn(),
            screen: { orientation: { angle: 0 } },
        });

        const sensor = new CompassSensor();
        const granted = await sensor.requestPermissionFromGesture();
        expect(requestPermission).toHaveBeenCalledTimes(1);
        expect(granted).toBe(true);
    });

    it("returns false when DeviceOrientationEvent.requestPermission rejects or denies", async () => {
        const requestPermission = vi.fn().mockResolvedValue("denied");
        vi.stubGlobal("DeviceOrientationEvent", { requestPermission });
        vi.stubGlobal("window", {
            addEventListener: vi.fn(),
            removeEventListener: vi.fn(),
            screen: { orientation: { angle: 0 } },
        });

        const sensor = new CompassSensor();
        expect(await sensor.requestPermissionFromGesture()).toBe(false);

        const promptSensor = new CompassSensor();
        vi.stubGlobal("DeviceOrientationEvent", {
            requestPermission: vi.fn().mockResolvedValue("prompt"),
        });
        expect(await promptSensor.requestPermissionFromGesture()).toBe(true);

        const throwingSensor = new CompassSensor();
        vi.stubGlobal("DeviceOrientationEvent", {
            requestPermission: vi.fn().mockRejectedValue(new Error("not in gesture")),
        });
        expect(await throwingSensor.requestPermissionFromGesture()).toBe(false);
    });

    it("emits smoothed compass readings and removes listeners on stop()", () => {
        const listeners: Record<string, (ev: any) => void> = {};
        vi.stubGlobal("DeviceOrientationEvent", class {});
        vi.stubGlobal("window", {
            ondeviceorientationabsolute: null,
            addEventListener: vi.fn((type: string, cb: any) => {
                listeners[type] = cb;
            }),
            removeEventListener: vi.fn((type: string) => {
                delete listeners[type];
            }),
            screen: { orientation: { angle: 0 } },
        });

        const readings: Array<{ heading: number; accuracy: number | null }> = [];
        const sensor = new CompassSensor();
        sensor.start((r) => readings.push(r));

        listeners["deviceorientationabsolute"]?.({
            alpha: 270,
            beta: 30,
            gamma: 0,
            absolute: true,
        });
        expect(readings).toHaveLength(1);
        expect(readings[0].heading).toBeCloseTo(90, 1);

        // Non-absolute fallback deviceorientation should be ignored when absolute events exist
        listeners["deviceorientation"]?.({
            alpha: 10,
            beta: 0,
            gamma: 0,
            absolute: false,
        });
        expect(readings).toHaveLength(1);

        // iOS-style webkitCompassHeading on deviceorientation should still work
        listeners["deviceorientation"]?.({
            webkitCompassHeading: 180,
            webkitCompassAccuracy: 8,
            alpha: null,
            beta: null,
            gamma: null,
        });
        expect(readings).toHaveLength(2);

        // Sub-1.2 deg stationary micro-jitter around last emitted heading must be suppressed
        // (even when smoothed step ~0.88 deg exceeds filter's 0.5 deg threshold)
        const settled = readings[readings.length - 1].heading;
        listeners["deviceorientation"]?.({
            webkitCompassHeading: (settled + 4) % 360,
            webkitCompassAccuracy: 8,
            alpha: null,
            beta: null,
            gamma: null,
        });
        expect(readings).toHaveLength(2);

        sensor.stop();
        expect(Object.keys(listeners)).toHaveLength(0);
    });
});
