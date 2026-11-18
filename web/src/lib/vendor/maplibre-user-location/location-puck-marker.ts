import * as M from "maplibre-gl";
import { coneHalfAngleFromAccuracy } from "./heading-math";

const SVG_NS = "http://www.w3.org/2000/svg";
const SIZE = 88;
const CENTER = 44;
const OUTER_RADIUS = 44;

/** Builds an SVG sector path pointing North (-Y in SVG space) centered at `(center, center)`. */
export function buildConeSvgPath(
    halfAngleDeg: number,
    outerRadius = OUTER_RADIUS,
    center = CENTER,
): string {
    const rad = (halfAngleDeg * Math.PI) / 180;
    const x1 = center - outerRadius * Math.sin(rad);
    const y1 = center - outerRadius * Math.cos(rad);
    const x2 = center + outerRadius * Math.sin(rad);
    const y2 = center - outerRadius * Math.cos(rad);
    const largeArc = halfAngleDeg * 2 > 180 ? 1 : 0;
    return `M ${center} ${center} L ${x1.toFixed(2)} ${y1.toFixed(2)} A ${outerRadius} ${outerRadius} 0 ${largeArc} 1 ${x2.toFixed(2)} ${y2.toFixed(2)} Z`;
}

export interface PuckElementHandle {
    root: HTMLDivElement;
    coneGroup: SVGGElement;
    conePath: SVGPathElement;
    updateHeading: (headingDeg: number | null, accuracyDeg?: number | null) => void;
}

let gradientCounter = 0;

/** Creates the Google Maps-style 88x88px SVG blue dot, pulse ring, and radial-gradient flashlight cone. */
export function createPuckElement(): PuckElementHandle {
    const gradId = `wanderer-gmaps-cone-grad-${++gradientCounter}`;
    const root = document.createElement("div");
    root.className = "wanderer-gmaps-location-puck";
    // Leave `position` unset so MapLibre's `.maplibregl-marker` (`position: absolute`) governs placement.
    root.style.cssText = `width:${SIZE}px;height:${SIZE}px;pointer-events:none;display:flex;align-items:center;justify-content:center;`;

    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("width", String(SIZE));
    svg.setAttribute("height", String(SIZE));
    svg.setAttribute("viewBox", `0 0 ${SIZE} ${SIZE}`);
    svg.style.cssText = "overflow:visible;display:block;";

    const defs = document.createElementNS(SVG_NS, "defs");
    const styleEl = document.createElementNS(SVG_NS, "style");
    styleEl.textContent = `
        @keyframes wanderer-puck-pulse {
            0%, 100% { transform: scale(0.82); opacity: 0.55; }
            50% { transform: scale(1.36); opacity: 0.08; }
        }
        .wanderer-puck-pulse-ring { transform-origin: ${CENTER}px ${CENTER}px; animation: wanderer-puck-pulse 2.5s ease-in-out infinite; will-change: transform, opacity; }
    `;
    defs.appendChild(styleEl);
    const radial = document.createElementNS(SVG_NS, "radialGradient");
    radial.setAttribute("id", gradId);
    radial.setAttribute("cx", String(CENTER));
    radial.setAttribute("cy", String(CENTER));
    radial.setAttribute("r", String(OUTER_RADIUS));
    radial.setAttribute("gradientUnits", "userSpaceOnUse");

    const stops: Array<[string, string]> = [
        ["18%", "0.48"],
        ["60%", "0.18"],
        ["100%", "0"],
    ];
    for (const [offset, opacity] of stops) {
        const stop = document.createElementNS(SVG_NS, "stop");
        stop.setAttribute("offset", offset);
        stop.setAttribute("stop-color", "#4285F4");
        stop.setAttribute("stop-opacity", opacity);
        radial.appendChild(stop);
    }
    defs.appendChild(radial);
    svg.appendChild(defs);

    const pulseCircle = document.createElementNS(SVG_NS, "circle");
    pulseCircle.setAttribute("cx", String(CENTER));
    pulseCircle.setAttribute("cy", String(CENTER));
    pulseCircle.setAttribute("r", "11");
    pulseCircle.setAttribute("fill", "rgba(66, 133, 244, 0.25)");
    pulseCircle.setAttribute("class", "wanderer-puck-pulse-ring");

    const coneGroup = document.createElementNS(SVG_NS, "g");
    coneGroup.style.display = "none";
    const conePath = document.createElementNS(SVG_NS, "path");
    conePath.setAttribute("d", buildConeSvgPath(25));
    conePath.setAttribute("fill", `url(#${gradId})`);
    coneGroup.appendChild(conePath);

    const shadowCircle = document.createElementNS(SVG_NS, "circle");
    shadowCircle.setAttribute("cx", String(CENTER));
    shadowCircle.setAttribute("cy", String(CENTER + 1));
    shadowCircle.setAttribute("r", "10.5");
    shadowCircle.setAttribute("fill", "rgba(0, 0, 0, 0.35)");

    // 18px diameter dot (r=9) with 3px crisp white border
    const dotCircle = document.createElementNS(SVG_NS, "circle");
    dotCircle.setAttribute("cx", String(CENTER));
    dotCircle.setAttribute("cy", String(CENTER));
    dotCircle.setAttribute("r", "9");
    dotCircle.setAttribute("fill", "#4285F4");
    dotCircle.setAttribute("stroke", "#FFFFFF");
    dotCircle.setAttribute("stroke-width", "3");

    svg.appendChild(coneGroup);
    svg.appendChild(pulseCircle);
    svg.appendChild(shadowCircle);
    svg.appendChild(dotCircle);
    root.appendChild(svg);

    let lastHalfAngle = 25;

    return {
        root,
        coneGroup,
        conePath,
        updateHeading(headingDeg: number | null, accuracyDeg?: number | null) {
            if (headingDeg === null || !Number.isFinite(headingDeg)) {
                coneGroup.style.display = "none";
                return;
            }
            const halfAngle = coneHalfAngleFromAccuracy(accuracyDeg);
            if (halfAngle !== lastHalfAngle) {
                conePath.setAttribute("d", buildConeSvgPath(halfAngle));
                lastHalfAngle = halfAngle;
            }
            coneGroup.style.display = "block";
            coneGroup.setAttribute("transform", `rotate(${headingDeg.toFixed(1)} ${CENTER} ${CENTER})`);
        },
    };
}

/** MapLibre marker wrapper anchoring the Google Maps puck on the map plane (`rotationAlignment: "map"`). */
export class LocationPuckMarker {
    private map: M.Map | null = null;
    private marker: M.Marker | null = null;
    private ui: PuckElementHandle | null = null;
    private attachedToMap = false;

    attach(map: M.Map): void {
        this.remove();
        this.map = map;
        this.ui = createPuckElement();
        this.marker = new M.Marker({
            element: this.ui.root,
            anchor: "center",
            rotationAlignment: "map",
            pitchAlignment: "map",
        });
    }

    setPosition(lon: number, lat: number): void {
        if (!this.map || !this.marker || !Number.isFinite(lon) || !Number.isFinite(lat)) {
            return;
        }
        this.marker.setLngLat([lon, lat]);
        if (!this.attachedToMap) {
            this.marker.addTo(this.map);
            this.attachedToMap = true;
        }
    }

    setHeading(headingDeg: number | null, accuracyDeg?: number | null): void {
        this.ui?.updateHeading(headingDeg, accuracyDeg);
    }

    hide(): void {
        if (this.attachedToMap) {
            this.marker?.remove();
            this.attachedToMap = false;
        }
        this.ui?.updateHeading(null, null);
    }

    remove(): void {
        this.marker?.remove();
        this.marker = null;
        this.ui = null;
        this.map = null;
        this.attachedToMap = false;
    }
}
