import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { getSalvamontDataset } from "#lib/emergency/salvamont_resolver.ts";
import { normalizeMapState } from "./maplibre-layer-manager";
import { buildSalvamontFeatureCollection, buildSalvamontPopupDom } from "./salvamont-layer";

class FakeElement {
	tagName: string;
	attrs = new Map<string, string>();
	style: { cssText: string } = { cssText: "" };
	children: FakeElement[] = [];
	listeners = new Map<string, Array<(ev: { stopPropagation: () => void }) => void>>();
	private _text = "";
	href = "";
	type = "";

	constructor(tag: string) {
		this.tagName = tag.toUpperCase();
	}

	setAttribute(k: string, v: string) {
		this.attrs.set(k, v);
	}
	getAttribute(k: string) {
		if (k === "href") return this.attrs.get("href") ?? (this.href || null);
		return this.attrs.get(k) ?? null;
	}
	appendChild(child: FakeElement) {
		this.children.push(child);
		return child;
	}
	addEventListener(type: string, fn: (ev: { stopPropagation: () => void }) => void) {
		const list = this.listeners.get(type) ?? [];
		list.push(fn);
		this.listeners.set(type, list);
	}
	click() {
		for (const fn of this.listeners.get("click") ?? []) {
			fn({ stopPropagation: () => {} });
		}
	}
	get textContent(): string {
		return this._text + this.children.map((c) => c.textContent).join(" ");
	}
	set textContent(val: string) {
		this._text = val;
	}
	querySelectorAll(sel: string): FakeElement[] {
		const out: FakeElement[] = [];
		const walk = (node: FakeElement) => {
			if (sel === "a" && node.tagName === "A") out.push(node);
			if (sel.startsWith("[data-testid=")) {
				const target = sel.slice(13, -1).replaceAll('"', "").replaceAll("'", "");
				if (node.getAttribute("data-testid") === target) out.push(node);
			}
			for (const c of node.children) walk(c);
		};
		walk(this);
		return out;
	}
	querySelector(sel: string): FakeElement | null {
		return this.querySelectorAll(sel)[0] ?? null;
	}
}

const origDocument = globalThis.document;

describe("SalvamontLayer & MapState integration", () => {
	beforeEach(() => {
		globalThis.document = {
			createElement: (tag: string) => new FakeElement(tag),
		} as unknown as Document;
	});

	afterEach(() => {
		globalThis.document = origDocument;
	});

	it("defaults overlays.salvamont to true for legacy v3 localStorage objects while honoring false", () => {
		const migrated = normalizeMapState({
			base: "OpenFreeMap",
			overlays: { hiking: true, cycling: false },
		});
		expect(migrated.overlays.salvamont).toBe(true);
		expect(migrated.overlays.hiking).toBe(true);

		const explicitOff = normalizeMapState({
			base: "OpenFreeMap",
			overlays: { salvamont: false },
		});
		expect(explicitOff.overlays.salvamont).toBe(false);
	});

	it("builds offline GeoJSON FeatureCollection separating manned bases and unmanned refuges", () => {
		const fc = buildSalvamontFeatureCollection();
		expect(fc.features.length).toBeGreaterThanOrEqual(55);
		const hasBase = fc.features.some((f) => f.properties?.icon === "salvamont-base-badge");
		const hasRefuge = fc.features.some((f) => f.properties?.icon === "salvamont-refuge-badge");
		expect(hasBase).toBe(true);
		expect(hasRefuge).toBe(true);
	});

	it("renders popup DOM with 112, +40725826668, verified local E.164 tel link, live distance, and route callback", () => {
		const ds = getSalvamontDataset();
		const balea = ds.points.find((p) => p.id === "baza-salvamont-balea-lac")!;
		const onRoute = vi.fn();

		const dom = buildSalvamontPopupDom(balea, {
			getUserContext: () => ({ lat: 45.5980, lon: 24.6180, ele: 2150, mode: "user_gps" }),
			onRouteToPoint: onRoute,
			locale: "ro",
		});

		const links = Array.from(dom.querySelectorAll("a")).map((a) => a.getAttribute("href"));
		expect(links).toContain("tel:112");
		expect(links).toContain("tel:+40725826668");
		expect(links).toContain("tel:+40269216477");
		expect(dom.textContent).toContain("Baza Salvamont Bâlea Lac");
		expect(dom.textContent).toContain("Munții Făgăraș");

		const routeBtn = dom.querySelector(
			'[data-testid="salvamont-popup-route-btn"]',
		) as unknown as HTMLButtonElement;
		expect(routeBtn).not.toBeNull();
		routeBtn.click();
		expect(onRoute).toHaveBeenCalledWith(balea);
	});
});
