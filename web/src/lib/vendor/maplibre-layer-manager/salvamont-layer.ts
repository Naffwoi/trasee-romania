import {
	formatRoPhoneDisplay,
	getSalvamontDataset,
	type SalvamontPoint,
} from "#lib/emergency/salvamont_resolver.ts";
import { bearingDegrees, cardinalDirection, haversineMeters } from "#lib/navigation/geo_math.ts";
import * as M from "maplibre-gl";
import type { MapMouseEvent, StyleSpecification } from "maplibre-gl";
import type { BaseLayer } from "./layers";

export interface SalvamontUserContext {
	lat: number;
	lon: number;
	ele?: number | null;
	mode: "user_gps" | "trail";
}

export interface SalvamontLayerOptions {
	getUserContext?: () => SalvamontUserContext | null;
	onRouteToPoint?: (point: SalvamontPoint) => void;
	locale?: string;
}

const BASE_BADGE_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect x="4" y="4" width="56" height="56" rx="16" fill="#242734" stroke="#ffffff" stroke-width="4.5"/>
  <path d="M28 17h8v11h11v8H36v11h-8V36H17v-8h11V17z" fill="#ffffff"/>
  <circle cx="50" cy="14" r="6" fill="#dc2626" stroke="#ffffff" stroke-width="2"/>
</svg>`;

const REFUGE_BADGE_SVG = `<svg xmlns="http://www.w3.org/2000/svg" width="56" height="56" viewBox="0 0 56 56">
  <rect x="4" y="4" width="48" height="48" rx="14" fill="#334155" stroke="#ffffff" stroke-width="4"/>
  <path d="M28 13L13 25.5h4V41h22V25.5h4L28 13zm5 19h-3.5v3.5h-3V32H23v-3h3.5v-3.5h3V29H33v3z" fill="#ffffff"/>
</svg>`;

/** Builds the offline GeoJSON FeatureCollection for all Salvamont bases and refuges. */
export function buildSalvamontFeatureCollection(): GeoJSON.FeatureCollection {
	const ds = getSalvamontDataset();
	return {
		type: "FeatureCollection",
		features: ds.points.map((pt) => ({
			type: "Feature",
			geometry: {
				type: "Point",
				coordinates: [pt.lon, pt.lat],
			},
			properties: {
				id: pt.id,
				name: pt.name,
				kind: pt.kind,
				isRefuge: pt.kind === "refuge",
				icon: pt.kind === "refuge" ? "salvamont-refuge-badge" : "salvamont-base-badge",
			},
		})),
	};
}

/** Builds the DOM content for a Salvamont point popup with verified E.164 phone links and optional routing action. */
export function buildSalvamontPopupDom(
	point: SalvamontPoint,
	options: SalvamontLayerOptions = {},
): HTMLDivElement {
	const ds = getSalvamontDataset();
	const svc = ds.services[point.serviceId];
	const isRo = (options.locale ?? "ro").toLowerCase().startsWith("ro");
	const directPhone = point.directBasePhone ?? svc?.primaryPhone ?? ds.nationalDispatchPhone;

	const root = document.createElement("div");
	root.setAttribute("data-testid", "salvamont-map-popup");
	root.style.cssText =
		"padding:12px 13px;min-width:235px;max-width:295px;font-family:IBMPlexSans,system-ui,sans-serif;color:#242734;background:#ffffff;";

	const topRow = document.createElement("div");
	topRow.style.cssText = "display:flex;align-items:center;gap:6px;margin-bottom:4px;flex-wrap:wrap;";

	const kindBadge = document.createElement("span");
	const kindLabel =
		point.kind === "refuge"
			? isRo
				? "Refugiu Salvamont (fără personal)"
				: "Rescue Refuge (unmanned)"
			: point.permanence === "seasonal"
				? isRo
					? "Post Salvamont sezonier"
					: "Seasonal Rescue Post"
				: isRo
					? "Bază Salvamont 24/7"
					: "24/7 Rescue Base";
	kindBadge.textContent = kindLabel;
	kindBadge.style.cssText =
		"padding:2px 7px;border-radius:9999px;font-size:10px;font-weight:700;background:#242734;color:#ffffff;";
	topRow.appendChild(kindBadge);
	root.appendChild(topRow);

	const titleEl = document.createElement("div");
	titleEl.style.cssText = "font-weight:800;font-size:13.5px;line-height:1.25;color:#242734;";
	titleEl.textContent = point.name;
	root.appendChild(titleEl);

	const metaEl = document.createElement("div");
	metaEl.style.cssText = "margin-top:3px;font-size:11.5px;color:#475569;font-weight:600;";
	metaEl.textContent = point.ele > 0 ? `${point.massif} · ${point.ele} m` : point.massif;
	root.appendChild(metaEl);

	const ctx = options.getUserContext?.();
	if (ctx && Number.isFinite(ctx.lat) && Number.isFinite(ctx.lon)) {
		const distM = haversineMeters(ctx.lat, ctx.lon, point.lat, point.lon);
		if (distM <= 60_000) {
			const brg = bearingDegrees(ctx.lat, ctx.lon, point.lat, point.lon);
			const card = cardinalDirection(brg, isRo ? "ro" : "en");
			const distLabel =
				distM >= 1000 ? `${(distM / 1000).toFixed(1)} km` : `${Math.round(distM)} m`;
			const refSuffix =
				ctx.mode === "trail"
					? isRo
						? "de traseu"
						: "from trail"
					: isRo
						? "de tine"
						: "from you";
			let eleSuffix = "";
			if (
				ctx.ele !== undefined &&
				ctx.ele !== null &&
				Number.isFinite(ctx.ele) &&
				point.ele > 0
			) {
				const dEle = Math.round(point.ele - ctx.ele);
				eleSuffix = ` · ${dEle >= 0 ? `+${dEle}` : dEle} m`;
			}
			const distEl = document.createElement("div");
			distEl.style.cssText =
				"margin-top:4px;font-size:11.5px;font-weight:700;color:#1e293b;font-variant-numeric:tabular-nums;";
			distEl.textContent = `📍 ${distLabel} ${card} ${refSuffix}${eleSuffix}`;
			root.appendChild(distEl);
		}
	}

	if (svc) {
		const svcEl = document.createElement("div");
		svcEl.style.cssText =
			"margin-top:6px;padding:5px 8px;border-radius:8px;background:#f8fafc;border:1px solid #e2e8f0;font-size:11px;color:#334155;";
		svcEl.textContent = `${svc.name} · ${svc.phoneRoleRo}`;
		root.appendChild(svcEl);
	}

	const callGrid = document.createElement("div");
	callGrid.style.cssText = "margin-top:8px;display:grid;grid-template-columns:1fr 1fr;gap:6px;";

	const makeTelLink = (href: string, label: string, bg: string, fg: string, fullRow = false) => {
		const a = document.createElement("a");
		a.href = href;
		a.setAttribute("href", href);
		a.textContent = label;
		a.style.cssText = `padding:6px 8px;border-radius:10px;background:${bg};color:${fg};font-size:11.5px;font-weight:800;text-align:center;text-decoration:none;display:block;${fullRow ? "grid-column:1 / -1;border:1px solid #cbd5e1;" : ""}`;
		return a;
	};

	callGrid.appendChild(makeTelLink("tel:112", "📞 112", "#dc2626", "#ffffff"));
	callGrid.appendChild(
		makeTelLink(`tel:${ds.nationalDispatchPhone}`, "📞 0-SALVAMONT", "#242734", "#ffffff"),
	);

	if (directPhone && directPhone !== ds.nationalDispatchPhone) {
		const shortSvc = svc?.shortName ?? "Salvamont Local";
		callGrid.appendChild(
			makeTelLink(
				`tel:${directPhone}`,
				`📞 ${shortSvc} (${formatRoPhoneDisplay(directPhone)})`,
				"#f1f5f9",
				"#242734",
				true,
			),
		);
	}
	root.appendChild(callGrid);

	if (options.onRouteToPoint) {
		const routeBtn = document.createElement("button");
		routeBtn.type = "button";
		routeBtn.setAttribute("data-testid", "salvamont-popup-route-btn");
		routeBtn.textContent = isRo
			? "🧭 Rută spre Baza Salvamont"
			: "🧭 Route to Salvamont Base";
		routeBtn.style.cssText =
			"margin-top:7px;width:100%;padding:7px 10px;border-radius:10px;background:#242734;color:#ffffff;font-size:11.5px;font-weight:700;border:none;cursor:pointer;";
		routeBtn.addEventListener("click", (ev) => {
			ev.stopPropagation();
			options.onRouteToPoint?.(point);
		});
		root.appendChild(routeBtn);
	}

	return root;
}

/** Offline MapLibre layer rendering Romania Salvamont rescue bases and mountain refuges. */
export class SalvamontLayer implements BaseLayer {
	private map: M.Map;
	private popup: M.Popup;
	private options: SalvamontLayerOptions;
	private pointsById: Map<string, SalvamontPoint>;

	spec: StyleSpecification;

	listeners = {
		"salvamont-bases": {
			onMouseDown: (e: MapMouseEvent) => this.openPopup(e),
		},
		"salvamont-refuges": {
			onMouseDown: (e: MapMouseEvent) => this.openPopup(e),
		},
	};

	constructor(map: M.Map, options: SalvamontLayerOptions = {}) {
		this.map = map;
		this.options = options;
		this.popup = new M.Popup({ closeButton: true, maxWidth: "310px", offset: 16 });
		const ds = getSalvamontDataset();
		this.pointsById = new Map(ds.points.map((p) => [p.id, p]));

		this.spec = {
			version: 8,
			name: "salvamont",
			glyphs: "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
			sources: {
				"salvamont-ro": {
					type: "geojson",
					data: buildSalvamontFeatureCollection(),
				},
			},
			layers: [
				{
					id: "salvamont-refuges",
					type: "symbol",
					source: "salvamont-ro",
					minzoom: 9,
					filter: ["==", ["get", "isRefuge"], true],
					layout: {
						"icon-image": "salvamont-refuge-badge",
						"icon-size": ["interpolate", ["linear"], ["zoom"], 9, 0.36, 13, 0.48],
						"icon-allow-overlap": ["step", ["zoom"], false, 12, true],
					},
				},
				{
					id: "salvamont-bases",
					type: "symbol",
					source: "salvamont-ro",
					minzoom: 7,
					filter: ["==", ["get", "isRefuge"], false],
					layout: {
						"icon-image": "salvamont-base-badge",
						"icon-size": ["interpolate", ["linear"], ["zoom"], 7, 0.34, 11, 0.44, 14, 0.52],
						"icon-allow-overlap": ["step", ["zoom"], false, 10, true],
						"text-field": ["step", ["zoom"], "", 12, ["get", "name"]],
						"text-font": ["Noto Sans Regular"],
						"text-size": 11,
						"text-offset": [0, 1.35],
						"text-anchor": "top",
						"text-optional": true,
					},
					paint: {
						"text-color": "#242734",
						"text-halo-color": "rgba(255,255,255,0.92)",
						"text-halo-width": 1.6,
					},
				},
			],
		};

		this.ensureImagesLoaded();
	}

	setOptions(next: Partial<SalvamontLayerOptions>): void {
		this.options = { ...this.options, ...next };
	}

	ensureImagesLoaded(): void {
		for (const [id, svg] of [
			["salvamont-base-badge", BASE_BADGE_SVG],
			["salvamont-refuge-badge", REFUGE_BADGE_SVG],
		] as const) {
			if (this.map.hasImage(id)) continue;
			const img = new Image(64, 64);
			img.onload = () => {
				if (!this.map.hasImage(id)) {
					this.map.addImage(id, img);
				}
			};
			img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
		}
	}

	private openPopup(e: MapMouseEvent): void {
		const feat = (e as unknown as { features?: GeoJSON.Feature[] }).features?.[0];
		const id = feat?.properties?.id;
		const pt = typeof id === "string" ? this.pointsById.get(id) : undefined;
		if (!pt) return;
		const dom = buildSalvamontPopupDom(pt, {
			...this.options,
			onRouteToPoint: this.options.onRouteToPoint
				? (selected) => {
						this.popup.remove();
						this.options.onRouteToPoint?.(selected);
					}
				: undefined,
		});
		this.popup.setLngLat([pt.lon, pt.lat]).setDOMContent(dom).addTo(this.map);
	}
}
