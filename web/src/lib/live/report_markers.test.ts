import { describe, expect, it, vi } from "vitest";
import { syncGroupMapMarkers } from "./report_markers";
import type { GroupMemberDto } from "./live_client";

vi.mock("maplibre-gl", () => {
	class FakePopup {
		dom: HTMLElement | null = null;
		setDOMContent(el: HTMLElement) {
			this.dom = el;
			return this;
		}
	}
	class FakeMarker {
		_el: HTMLElement;
		lngLat: [number, number] = [0, 0];
		popup: FakePopup | null = null;
		removed = false;
		setLngLatCalls = 0;
		constructor(opts: { element: HTMLElement }) {
			this._el = opts.element;
		}
		getElement() {
			return this._el;
		}
		setLngLat(coords: [number, number]) {
			this.lngLat = coords;
			this.setLngLatCalls++;
			return this;
		}
		setPopup(p: FakePopup) {
			this.popup = p;
			return this;
		}
		getPopup() {
			return this.popup;
		}
		addTo() {
			return this;
		}
		remove() {
			this.removed = true;
		}
	}
	return { Marker: FakeMarker, Popup: FakePopup };
});

describe("report_markers keyed in-place reconciliation", () => {
	it("reuses existing group member Marker & Popup DOM across 5.5s pings instead of destroying them", () => {
		const fakeDom = {
			createElement: (tag: string) => {
				const attrs = new Map<string, string>();
				const children: any[] = [];
				return {
					tagName: tag.toUpperCase(),
					type: "",
					title: "",
					textContent: "",
					style: { cssText: "" },
					children,
					setAttribute: (k: string, v: string) => attrs.set(k, v),
					getAttribute: (k: string) => attrs.get(k) ?? null,
					appendChild: (c: any) => children.push(c),
					addEventListener: () => {},
				};
			},
		};
		vi.stubGlobal("document", fakeDom);

		const map = {} as any;
		const m1: GroupMemberDto = {
			memberId: "peer-1",
			displayName: "Diana Ionescu",
			colorHex: "#0f766e",
			lat: 45.441,
			lon: 25.55,
			ele: 1010,
			accuracy: 6,
			alongTrackM: 200,
			inNavigation: true,
			isSelf: false,
			updatedAt: new Date().toISOString(),
		};

		const first = syncGroupMapMarkers(map, [], [m1], { selfAlongTrackM: 180, locale: "ro" });
		expect(first).toHaveLength(1);
		const initialMarker = first[0] as any;
		expect(initialMarker.removed).toBe(false);

		// Second sync 5.5s later: Diana walked 25m forward
		const m1Moved: GroupMemberDto = { ...m1, lat: 45.44122, alongTrackM: 225 };
		const second = syncGroupMapMarkers(map, first, [m1Moved], {
			selfAlongTrackM: 190,
			locale: "ro",
		});

		expect(second).toHaveLength(1);
		expect(second[0]).toBe(initialMarker);
		expect(initialMarker.removed).toBe(false);
		expect(initialMarker.lngLat).toEqual([25.55, 45.44122]);

		// Third sync: Diana left the group -> marker is removed cleanly
		const third = syncGroupMapMarkers(map, second, [], { selfAlongTrackM: 190, locale: "ro" });
		expect(third).toHaveLength(0);
		expect(initialMarker.removed).toBe(true);

		vi.unstubAllGlobals();
	});
});
