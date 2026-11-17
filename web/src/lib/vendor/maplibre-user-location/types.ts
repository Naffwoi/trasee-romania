export type LocationTrackingMode =
    | "inactive"
    | "freeTracking"
    | "followNorthUp"
    | "followHeadingUp";

export interface CompassReading {
    heading: number;
    accuracy: number | null;
}

export interface UserLocationFix {
    latitude: number;
    longitude: number;
    accuracy: number;
    gpsHeading: number | null;
    speed: number | null;
}

export interface UserLocationControlLabels {
    locateMe: string;
    followNorthUp: string;
    followHeadingUp: string;
    permissionDenied: string;
    insecureContext: string;
}

export interface UserLocationControlOptions {
    enableHighAccuracy?: boolean;
    animate?: boolean;
    labels?: Partial<UserLocationControlLabels>;
    onModeChange?: (mode: LocationTrackingMode) => void;
    onError?: (message: string) => void;
}
