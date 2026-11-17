import { afterEach, describe, expect, it, vi } from "vitest";
import {
    UserLocationControl,
    computeNextTrackingMode,
    resolveEffectiveHeading,
} from "./user-location-control";

function createFakeElement(tag: string) {
    const attrs: Record<string, string> = {};
    const listeners: Record<string, Array<(e: any) => void>> = {};
    const classes = new Set<string>();
    const children: any[] = [];
    let _className = "";

    const el: any = {
        tagName: tag.toUpperCase(),
        dataset: {} as Record<string, string>,
        style: { cssText: "", display: "", color: "" } as Record<string, string>,
        title: "",
        type: "",
        children,
        get className() {
            return _className;
        },
        set className(val: string) {
            _className = val;
            classes.clear();
            for (const c of val.split(/\s+/).filter(Boolean)) {
                classes.add(c);
            }
        },
        classList: {
            add: (...tokens: string[]) => {
                for (const t of tokens) classes.add(t);
                _className = Array.from(classes).join(" ");
            },
            remove: (...tokens: string[]) => {
                for (const t of tokens) classes.delete(t);
                _className = Array.from(classes).join(" ");
            },
            toggle: (token: string, force?: boolean) => {
                const shouldAdd = force ?? !classes.has(token);
                if (shouldAdd) classes.add(token);
                else classes.delete(token);
                _className = Array.from(classes).join(" ");
                return shouldAdd;
            },
            contains: (token: string) => classes.has(token),
        },
        setAttribute: vi.fn((k: string, v: string) => {
            attrs[k] = v;
        }),
        getAttribute: (k: string) => attrs[k] ?? null,
        appendChild: vi.fn((child: any) => {
            child.parentNode = el;
            children.push(child);
            return child;
        }),
        removeChild: vi.fn((child: any) => {
            child.parentNode = null;
            return child;
        }),
        addEventListener: vi.fn((type: string, cb: (e: any) => void) => {
            (listeners[type] ??= []).push(cb);
        }),
        removeEventListener: vi.fn((type: string, cb: (e: any) => void) => {
            if (!listeners[type]) return;
            listeners[type] = listeners[type].filter((fn) => fn !== cb);
        }),
        remove: vi.fn(),
        getBoundingClientRect: () => ({ width: 88, height: 88, top: 0, left: 0, right: 88, bottom: 88 }),
        click: () => {
            for (const cb of listeners["click"] ?? []) cb({});
        },
    };
    return el;
}

describe("UserLocationControl state machine & heading fusion", () => {
    afterEach(() => {
        vi.unstubAllGlobals();
        vi.restoreAllMocks();
    });

    it("transitions Inactive -> FollowNorthUp -> FollowHeadingUp -> FollowNorthUp when heading exists", () => {
        expect(computeNextTrackingMode("inactive", true)).toBe("followNorthUp");
        expect(computeNextTrackingMode("freeTracking", true)).toBe("followNorthUp");
        expect(computeNextTrackingMode("followNorthUp", true)).toBe("followHeadingUp");
        expect(computeNextTrackingMode("followHeadingUp", true)).toBe("followNorthUp");
    });

    it("stays in followNorthUp on second tap if no compass or GPS heading is available", () => {
        expect(computeNextTrackingMode("followNorthUp", false)).toBe("followNorthUp");
    });

    it("prefers compass reading even when stationary, and falls back to GPS only at >= 0.8 m/s", () => {
        expect(
            resolveEffectiveHeading(
                { heading: 215, accuracy: 12 },
                { latitude: 45, longitude: 25, accuracy: 10, gpsHeading: null, speed: 0 },
            ),
        ).toEqual({ heading: 215, accuracy: 12 });

        expect(
            resolveEffectiveHeading(
                null,
                { latitude: 45, longitude: 25, accuracy: 10, gpsHeading: 92, speed: 1.4 },
            ),
        ).toEqual({ heading: 92, accuracy: 20 });

        expect(
            resolveEffectiveHeading(
                null,
                { latitude: 45, longitude: 25, accuracy: 10, gpsHeading: 92, speed: 0.2 },
            ),
        ).toBeNull();
    });

    it("handles full control lifecycle, smart zoom, user drag exit, and permission errors", async () => {
        const winListeners: Record<string, Array<(ev: any) => void>> = {};
        const mapEvents: Record<string, Array<(ev: any) => void>> = {};
        const sources = new Map<string, any>();
        const layers = new Set<string>();
        let zoom = 10;
        let bearing = 0;

        vi.stubGlobal("document", {
            createElement: vi.fn((tag: string) => createFakeElement(tag)),
            createElementNS: vi.fn((_ns: string, tag: string) => createFakeElement(tag)),
        });
        vi.stubGlobal("DeviceOrientationEvent", class {});
        vi.stubGlobal("window", {
            isSecureContext: true,
            location: { hostname: "localhost" },
            screen: { orientation: { angle: 0 } },
            addEventListener: vi.fn((type: string, cb: (ev: any) => void) => {
                (winListeners[type] ??= []).push(cb);
            }),
            removeEventListener: vi.fn((type: string, cb: (ev: any) => void) => {
                if (!winListeners[type]) return;
                winListeners[type] = winListeners[type].filter((fn) => fn !== cb);
            }),
        });

        let watchSuccess: PositionCallback | null = null;
        let watchError: PositionErrorCallback | null = null;
        const clearWatch = vi.fn();
        vi.stubGlobal("navigator", {
            geolocation: {
                watchPosition: vi.fn((onSuccess: PositionCallback, onError: PositionErrorCallback) => {
                    watchSuccess = onSuccess;
                    watchError = onError;
                    return 42;
                }),
                clearWatch,
            },
        });

        const easeTo = vi.fn((opts: any) => {
            if (typeof opts.zoom === "number") zoom = opts.zoom;
            if (typeof opts.bearing === "number") bearing = opts.bearing;
        });

        const canvasContainer = createFakeElement("div");
        const fakeMap: any = {
            getZoom: () => zoom,
            getBearing: () => bearing,
            getPitch: () => 0,
            _camera: {
                transform: {
                    getCoveringTilesDetailsProvider: () => ({ allowWorldCopies: () => false }),
                    isLocationOccluded: () => false,
                    width: 800,
                    height: 600,
                },
            },
            project: () => ({
                x: 100,
                y: 100,
                _add: () => ({ x: 100, y: 100, round: () => ({ x: 100, y: 100 }) }),
            }),
            easeTo,
            isStyleLoaded: () => true,
            getSource: (id: string) => sources.get(id),
            addSource: vi.fn((id: string, spec: any) => {
                sources.set(id, { ...spec, setData: vi.fn() });
            }),
            removeSource: vi.fn((id: string) => sources.delete(id)),
            getLayer: (id: string) => layers.has(id),
            addLayer: vi.fn((spec: any) => layers.add(spec.id)),
            removeLayer: vi.fn((id: string) => layers.delete(id)),
            on: vi.fn((ev: string, cb: (e: any) => void) => {
                (mapEvents[ev] ??= []).push(cb);
            }),
            off: vi.fn((ev: string, cb: (e: any) => void) => {
                if (!mapEvents[ev]) return;
                mapEvents[ev] = mapEvents[ev].filter((fn) => fn !== cb);
            }),
            getCanvasContainer: () => canvasContainer,
        };

        const modes: string[] = [];
        const errors: string[] = [];
        const ctrl = new UserLocationControl({
            onModeChange: (m) => modes.push(m),
            onError: (msg) => errors.push(msg),
        });

        const container = ctrl.onAdd(fakeMap);
        const btn = container.children[0] as HTMLButtonElement;
        expect(ctrl.mode).toBe("inactive");
        expect(btn.classList.contains("maplibregl-ctrl-geolocate")).toBe(true);

        // Tap 1 -> followNorthUp + starts watch & compass
        ctrl.trigger();
        await Promise.resolve();
        expect(ctrl.mode).toBe("followNorthUp");
        expect(btn.classList.contains("maplibregl-ctrl-geolocate-active")).toBe(true);

        // First GPS fix zooms from 10 -> 15.5
        watchSuccess!({
            coords: {
                latitude: 45.6427,
                longitude: 25.5887,
                accuracy: 25,
                altitude: null,
                altitudeAccuracy: null,
                heading: null,
                speed: 0,
                toJSON: () => ({}),
            },
            timestamp: Date.now(),
            toJSON: () => ({}),
        } as GeolocationPosition);
        expect(easeTo).toHaveBeenLastCalledWith(
            expect.objectContaining({ center: [25.5887, 45.6427], zoom: 15.5, bearing: 0 }),
        );

        // Tap 2 without compass -> stays followNorthUp
        btn.click();
        await Promise.resolve();
        expect(ctrl.mode).toBe("followNorthUp");

        // Emit stationary compass heading -> 120 deg
        for (const cb of winListeners["deviceorientation"] ?? []) {
            cb({ webkitCompassHeading: 120, webkitCompassAccuracy: 10 });
        }

        // Tap 2 with compass -> followHeadingUp
        btn.click();
        await Promise.resolve();
        expect(ctrl.mode).toBe("followHeadingUp");
        expect(easeTo).toHaveBeenLastCalledWith(
            expect.objectContaining({ bearing: 120 }),
        );

        // Programmatic rotatestart (no originalEvent) does not exit tracking
        for (const cb of mapEvents["rotatestart"] ?? []) {
            cb({});
        }
        expect(ctrl.mode).toBe("followHeadingUp");

        // User dragstart (with originalEvent) exits to freeTracking
        for (const cb of mapEvents["dragstart"] ?? []) {
            cb({ originalEvent: { type: "mousedown" } });
        }
        expect(ctrl.mode).toBe("freeTracking");
        expect(btn.classList.contains("maplibregl-ctrl-geolocate-active")).toBe(false);

        // Tap from freeTracking -> returns to followNorthUp with bearing 0
        btn.click();
        await Promise.resolve();
        expect(ctrl.mode).toBe("followNorthUp");
        expect(bearing).toBe(0);

        // Geolocation permission denied resets cleanly to inactive
        watchError!({ code: 1, PERMISSION_DENIED: 1 } as GeolocationPositionError);
        expect(ctrl.mode).toBe("inactive");
        expect(clearWatch).toHaveBeenCalledWith(42);
        expect(errors).toHaveLength(1);

        ctrl.onRemove();
        expect(modes).toEqual([
            "followNorthUp",
            "followHeadingUp",
            "freeTracking",
            "followNorthUp",
            "inactive",
        ]);
    });

    it("reports insecureContext error on non-localhost HTTP", () => {
        const errors: string[] = [];
        vi.stubGlobal("document", {
            createElement: vi.fn((tag: string) => createFakeElement(tag)),
            createElementNS: vi.fn((_ns: string, tag: string) => createFakeElement(tag)),
        });
        vi.stubGlobal("window", {
            isSecureContext: false,
            location: { hostname: "192.168.1.50" },
        });
        const fakeMap: any = {
            on: vi.fn(),
            off: vi.fn(),
            isStyleLoaded: () => false,
        };
        const ctrl = new UserLocationControl({ onError: (m) => errors.push(m) });
        ctrl.onAdd(fakeMap);
        ctrl.trigger();
        expect(ctrl.mode).toBe("inactive");
        expect(errors).toEqual(["Location & compass require an HTTPS connection."]);
    });
});
