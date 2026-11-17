import { afterEach, describe, expect, it, vi } from "vitest";
import { AccuracyLayer, buildAccuracyCircleGeoJSON } from "./accuracy-layer";
import { buildConeSvgPath, createPuckElement } from "./location-puck-marker";

function createFakeDomElement(tag: string) {
    const attrs: Record<string, string> = {};
    const children: any[] = [];
    return {
        tagName: tag,
        className: "",
        style: { cssText: "", display: "" } as Record<string, string>,
        children,
        attrs,
        setAttribute: vi.fn((k: string, v: string) => {
            attrs[k] = v;
        }),
        getAttribute: (k: string) => attrs[k] ?? null,
        appendChild: vi.fn((child: any) => {
            children.push(child);
            return child;
        }),
    };
}

describe("puck-visuals", () => {
    afterEach(() => {
        vi.unstubAllGlobals();
    });

    it("omits accuracy polygon below 5m and caps radius at 2000m", () => {
        const tiny = buildAccuracyCircleGeoJSON(25.0, 45.5, 3);
        expect(tiny.features).toHaveLength(0);

        const nonFinite = buildAccuracyCircleGeoJSON(25.0, 45.5, Number.NaN);
        expect(nonFinite.features).toHaveLength(0);

        const normal = buildAccuracyCircleGeoJSON(25.0, 45.5, 40);
        expect(normal.features).toHaveLength(1);
        expect(normal.features[0].geometry.type).toBe("Polygon");
        const ring = (normal.features[0].geometry as GeoJSON.Polygon).coordinates[0];
        expect(ring).toHaveLength(65); // 64 segments + closed ring

        const huge = buildAccuracyCircleGeoJSON(25.0, 45.5, 9999);
        const capped = buildAccuracyCircleGeoJSON(25.0, 45.5, 2000);
        expect(huge).toEqual(capped);
    });

    it("re-hydrates GeoJSON source and layers when MapLibre fires style.load", () => {
        const events: Record<string, () => void> = {};
        const sources = new Map<string, any>();
        const layers = new Set<string>();
        const fakeMap: any = {
            isStyleLoaded: () => true,
            getSource: (id: string) => sources.get(id),
            addSource: vi.fn((id: string, spec: any) => {
                sources.set(id, { ...spec, setData: vi.fn() });
            }),
            removeSource: vi.fn((id: string) => sources.delete(id)),
            getLayer: (id: string) => layers.has(id),
            addLayer: vi.fn((spec: any) => layers.add(spec.id)),
            removeLayer: vi.fn((id: string) => layers.delete(id)),
            on: vi.fn((ev: string, cb: () => void) => {
                events[ev] = cb;
            }),
            off: vi.fn(),
        };

        const acc = new AccuracyLayer();
        acc.attach(fakeMap);
        acc.update(25.4, 45.4, 30);
        expect(layers.has("wanderer-user-accuracy-fill")).toBe(true);
        expect(layers.has("wanderer-user-accuracy-outline")).toBe(true);

        // Simulate style switch wiping sources and layers
        sources.clear();
        layers.clear();
        events["style.load"]?.();
        expect(layers.has("wanderer-user-accuracy-fill")).toBe(true);
        expect(layers.has("wanderer-user-accuracy-outline")).toBe(true);

        acc.clear();
        expect(sources.get("wanderer-user-accuracy-source").setData).toHaveBeenLastCalledWith({
            type: "FeatureCollection",
            features: [],
        });

        acc.detach();
        expect(fakeMap.off).toHaveBeenCalledWith("style.load", expect.any(Function));
    });

    it("builds valid SVG wedge path and rotates cone inside puck DOM element", () => {
        const dNarrow = buildConeSvgPath(25, 44, 44);
        const dWide = buildConeSvgPath(45, 44, 44);
        expect(dNarrow).toContain("A 44 44");
        expect(dNarrow).not.toEqual(dWide);

        if (typeof document === "undefined") {
            vi.stubGlobal("document", {
                createElement: vi.fn((tag: string) => createFakeDomElement(tag)),
                createElementNS: vi.fn((_ns: string, tag: string) => createFakeDomElement(tag)),
            });
        }

        const ui = createPuckElement();
        ui.updateHeading(135, 10);
        expect(ui.coneGroup.getAttribute("transform")).toBe("rotate(135.0 44 44)");
        expect(ui.coneGroup.style.display).toBe("block");
        expect(ui.conePath.getAttribute("d")).toBe(buildConeSvgPath(25));

        ui.updateHeading(220, 45);
        expect(ui.coneGroup.getAttribute("transform")).toBe("rotate(220.0 44 44)");
        expect(ui.conePath.getAttribute("d")).toBe(buildConeSvgPath(45));

        ui.updateHeading(null, null);
        expect(ui.coneGroup.style.display).toBe("none");
    });
});
