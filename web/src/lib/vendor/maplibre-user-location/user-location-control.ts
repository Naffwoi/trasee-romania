import type { IControl, Map as MapLibreMap } from "maplibre-gl";
import { AccuracyLayer } from "./accuracy-layer";
import { CompassSensor } from "./compass-sensor";
import { CircularHeadingFilter } from "./heading-math";
import { LocationPuckMarker } from "./location-puck-marker";
import type {
    CompassReading,
    LocationTrackingMode,
    UserLocationControlLabels,
    UserLocationControlOptions,
    UserLocationFix,
} from "./types";

const DEFAULT_LABELS: UserLocationControlLabels = {
    locateMe: "Show my location",
    followNorthUp: "Center on my location (tap again to rotate map by compass)",
    followHeadingUp: "Compass mode active (tap for North up)",
    permissionDenied: "Location access was denied.",
    insecureContext: "Location & compass require an HTTPS connection.",
};

/** Computes the next 3-state tracking mode on a control button tap. */
export function computeNextTrackingMode(
    current: LocationTrackingMode,
    hasHeading: boolean,
): LocationTrackingMode {
    switch (current) {
        case "inactive":
        case "freeTracking":
            return "followNorthUp";
        case "followNorthUp":
            return hasHeading ? "followHeadingUp" : "followNorthUp";
        case "followHeadingUp":
            return "followNorthUp";
    }
}

/**
 * Selects the active orientation heading: compass/device orientation has priority
 * (including while stationary); GPS course-over-ground is used only when `speed >= 0.8 m/s`.
 */
export function resolveEffectiveHeading(
    compass: CompassReading | null,
    fix: UserLocationFix | null,
): CompassReading | null {
    if (compass !== null && Number.isFinite(compass.heading)) {
        return compass;
    }
    if (
        fix !== null &&
        fix.speed !== null &&
        fix.speed >= 0.8 &&
        fix.gpsHeading !== null &&
        Number.isFinite(fix.gpsHeading) &&
        fix.gpsHeading >= 0
    ) {
        return { heading: fix.gpsHeading, accuracy: 20 };
    }
    return null;
}

/**
 * Google Maps-style MapLibre IControl combining live GPS, geodesic accuracy halo,
 * stationary/moving compass flashlight cone, and 3-state camera tracking.
 */
export class UserLocationControl implements IControl {
    private map: MapLibreMap | null = null;
    private container: HTMLDivElement | null = null;
    private button: HTMLButtonElement | null = null;
    private iconEl: HTMLElement | null = null;

    private readonly compass = new CompassSensor();
    private readonly gpsHeadingFilter = new CircularHeadingFilter(0.22, 0.5);
    private readonly accuracyLayer = new AccuracyLayer();
    private readonly puck = new LocationPuckMarker();
    private readonly labels: UserLocationControlLabels;

    private watchId: number | null = null;
    private latestFix: UserLocationFix | null = null;
    private latestCompass: CompassReading | null = null;
    private _mode: LocationTrackingMode = "inactive";
    private isProgrammaticMove = false;
    private hasPerformedInitialZoom = false;
    private errorNoticeEl: HTMLDivElement | null = null;
    private errorNoticeTimer: ReturnType<typeof setTimeout> | null = null;

    private readonly handleButtonClick = () => {
        void this.onButtonTap();
    };

    private readonly handleUserGestureStart = (e: { originalEvent?: unknown }) => {
        if (this.isProgrammaticMove || !e.originalEvent) return;
        if (this._mode === "followNorthUp" || this._mode === "followHeadingUp") {
            this.setMode("freeTracking");
        }
    };

    constructor(private readonly options: UserLocationControlOptions = {}) {
        this.labels = { ...DEFAULT_LABELS, ...options.labels };
    }

    get mode(): LocationTrackingMode {
        return this._mode;
    }

    onAdd(map: MapLibreMap): HTMLElement {
        this.map = map;
        this.accuracyLayer.attach(map);
        this.puck.attach(map);

        map.on("dragstart", this.handleUserGestureStart);
        map.on("rotatestart", this.handleUserGestureStart);
        map.on("pitchstart", this.handleUserGestureStart);

        this.container = document.createElement("div");
        this.container.className = "maplibregl-ctrl maplibregl-ctrl-group";

        this.button = document.createElement("button");
        this.button.type = "button";
        this.button.className = "maplibregl-ctrl-geolocate wanderer-user-location-btn";
        this.button.addEventListener("click", this.handleButtonClick);

        this.iconEl = document.createElement("i");
        this.iconEl.setAttribute("aria-hidden", "true");
        this.button.appendChild(this.iconEl);
        this.container.appendChild(this.button);

        this.syncButtonAppearance();
        return this.container;
    }

    onRemove(): void {
        this.stopSensors();
        if (this.map) {
            this.map.off("dragstart", this.handleUserGestureStart);
            this.map.off("rotatestart", this.handleUserGestureStart);
            this.map.off("pitchstart", this.handleUserGestureStart);
        }
        this.accuracyLayer.detach();
        this.puck.remove();
        this.clearErrorNotice();
        this.button?.removeEventListener("click", this.handleButtonClick);
        this.container?.remove();
        this.button = null;
        this.iconEl = null;
        this.container = null;
        this.map = null;
    }

    /** Programmatic activation used by Wanderer's `allowAutoGeolocate` / `autoGeolocateOnDrawing`. */
    trigger(): void {
        if (this._mode === "inactive") {
            void this.onButtonTap();
        }
    }

    private async onButtonTap(): Promise<void> {
        const hostname = typeof window !== "undefined" ? window.location?.hostname : undefined;
        if (
            typeof window !== "undefined" &&
            !window.isSecureContext &&
            hostname !== "localhost" &&
            hostname !== "127.0.0.1"
        ) {
            this.reportError(this.labels.insecureContext);
            return;
        }
        if (typeof navigator === "undefined" || !navigator.geolocation) {
            this.reportError(this.labels.permissionDenied);
            return;
        }

        if (this._mode === "inactive") {
            // Request iOS compass permission immediately inside the click gesture
            await this.compass.requestPermissionFromGesture();
            this.startSensors();
            this.setMode("followNorthUp");
            if (this.latestFix) {
                this.applyCameraForMode(true);
            }
            return;
        }

        const prevMode = this._mode;
        const effective = resolveEffectiveHeading(this.latestCompass, this.latestFix);
        const nextMode = computeNextTrackingMode(this._mode, effective !== null);
        this.setMode(nextMode);
        const shouldSmartZoom = prevMode === "freeTracking" && nextMode === "followNorthUp";
        this.applyCameraForMode(shouldSmartZoom);
    }

    private startSensors(): void {
        if (this.watchId === null && typeof navigator !== "undefined" && navigator.geolocation) {
            this.watchId = navigator.geolocation.watchPosition(
                (pos) => {
                    const rawGpsHeading =
                        pos.coords.heading !== null &&
                        Number.isFinite(pos.coords.heading) &&
                        pos.coords.heading >= 0
                            ? (this.gpsHeadingFilter.update(pos.coords.heading) ??
                                this.gpsHeadingFilter.current)
                            : null;
                    this.latestFix = {
                        latitude: pos.coords.latitude,
                        longitude: pos.coords.longitude,
                        accuracy: pos.coords.accuracy,
                        gpsHeading: rawGpsHeading,
                        speed: pos.coords.speed,
                    };
                    this.puck.setPosition(this.latestFix.longitude, this.latestFix.latitude);
                    this.accuracyLayer.update(
                        this.latestFix.longitude,
                        this.latestFix.latitude,
                        this.latestFix.accuracy,
                    );
                    this.refreshHeadingVisuals();
                    this.options.onPositionUpdate?.(this.latestFix);
                    if (this._mode === "followNorthUp" || this._mode === "followHeadingUp") {
                        this.applyCameraForMode(!this.hasPerformedInitialZoom);
                        this.hasPerformedInitialZoom = true;
                    }
                },
                (err) => {
                    if (err.code === (err.PERMISSION_DENIED ?? 1)) {
                        this.stopSensors();
                        this.accuracyLayer.clear();
                        this.puck.hide();
                        this.latestFix = null;
                        this.hasPerformedInitialZoom = false;
                        this.setMode("inactive");
                        this.reportError(this.labels.permissionDenied);
                    }
                },
                {
                    enableHighAccuracy: this.options.enableHighAccuracy ?? true,
                    maximumAge: 3000,
                    timeout: 15000,
                },
            );
        }

        this.compass.start((reading) => {
            this.latestCompass = reading;
            this.refreshHeadingVisuals();
            if (this._mode === "followHeadingUp" && this.map) {
                this.runProgrammaticCamera(() => {
                    if (typeof this.map!.jumpTo === "function") {
                        this.map!.jumpTo({ bearing: reading.heading });
                    } else {
                        this.map!.easeTo({ bearing: reading.heading, duration: 0 });
                    }
                });
            }
        });
    }

    private stopSensors(): void {
        if (this.watchId !== null && typeof navigator !== "undefined" && navigator.geolocation) {
            navigator.geolocation.clearWatch(this.watchId);
            this.watchId = null;
        }
        this.compass.stop();
        this.gpsHeadingFilter.reset();
        this.latestCompass = null;
    }

    private refreshHeadingVisuals(): void {
        const effective = resolveEffectiveHeading(this.latestCompass, this.latestFix);
        this.puck.setHeading(effective?.heading ?? null, effective?.accuracy ?? null);
    }

    private applyCameraForMode(allowSmartZoom: boolean): void {
        if (!this.map || !this.latestFix) return;
        const currentZoom = this.map.getZoom();
        const targetZoom = allowSmartZoom && currentZoom < 14 ? 15.5 : currentZoom;
        const effective = resolveEffectiveHeading(this.latestCompass, this.latestFix);
        const targetBearing =
            this._mode === "followHeadingUp"
                ? (effective !== null ? effective.heading : this.map.getBearing())
                : 0;

        this.runProgrammaticCamera(() => {
            this.map!.easeTo({
                center: [this.latestFix!.longitude, this.latestFix!.latitude],
                zoom: targetZoom,
                bearing: targetBearing,
                duration: this.options.animate === false ? 0 : 350,
            });
        });
    }

    private runProgrammaticCamera(fn: () => void): void {
        this.isProgrammaticMove = true;
        try {
            fn();
        } finally {
            this.isProgrammaticMove = false;
        }
    }

    private setMode(next: LocationTrackingMode): void {
        if (this._mode === next) return;
        this._mode = next;
        this.syncButtonAppearance();
        this.options.onModeChange?.(next);
    }

    private reportError(message: string): void {
        this.options.onError?.(message);
        if (this.options.onError || typeof document === "undefined" || !this.map) {
            return;
        }
        const mapContainer =
            typeof this.map.getContainer === "function" ? this.map.getContainer() : null;
        if (!mapContainer) return;
        this.clearErrorNotice();
        const notice = document.createElement("div");
        notice.className = "wanderer-user-location-notice";
        notice.setAttribute("role", "status");
        notice.textContent = message;
        notice.style.cssText =
            "position:absolute;bottom:16px;left:50%;transform:translateX(-50%);z-index:10;background:rgba(17,24,39,0.9);color:#fff;padding:6px 12px;border-radius:8px;font-size:12px;pointer-events:none;max-width:90%;text-align:center;";
        mapContainer.appendChild(notice);
        this.errorNoticeEl = notice;
        this.errorNoticeTimer = setTimeout(() => this.clearErrorNotice(), 4000);
    }

    private clearErrorNotice(): void {
        if (this.errorNoticeTimer !== null) {
            clearTimeout(this.errorNoticeTimer);
            this.errorNoticeTimer = null;
        }
        this.errorNoticeEl?.remove();
        this.errorNoticeEl = null;
    }

    private syncButtonAppearance(): void {
        if (!this.button || !this.iconEl) return;
        this.button.dataset.trackingMode = this._mode;
        const isActive =
            this._mode === "followNorthUp" || this._mode === "followHeadingUp";
        this.button.classList.toggle("maplibregl-ctrl-geolocate-active", isActive);

        if (this._mode === "followHeadingUp") {
            this.button.title = this.labels.followHeadingUp;
            this.button.setAttribute("aria-label", this.labels.followHeadingUp);
            this.button.setAttribute("aria-pressed", "true");
            this.iconEl.className = "fa fa-location-arrow";
            this.iconEl.style.color = "#4285F4";
        } else if (this._mode === "followNorthUp") {
            this.button.title = this.labels.followNorthUp;
            this.button.setAttribute("aria-label", this.labels.followNorthUp);
            this.button.setAttribute("aria-pressed", "true");
            this.iconEl.className = "fa fa-crosshairs";
            this.iconEl.style.color = "#4285F4";
        } else {
            this.button.title = this.labels.locateMe;
            this.button.setAttribute("aria-label", this.labels.locateMe);
            this.button.setAttribute("aria-pressed", "false");
            this.iconEl.className = "fa fa-crosshairs text-black";
            this.iconEl.style.color = "";
        }
    }
}
