import * as M from "maplibre-gl";
import {
	formatConfirmedAgo,
	getReportCategoryMeta,
	isReportVisibleOnMap,
	SOS_REASON_META,
	type GroupMemberDto,
	type ReportVoteType,
	type SosAlertDto,
	type TrailReportDto,
} from "./live_client.ts";

function buildReportPopupDom(
	report: TrailReportDto,
	onVote?: (reportId: string, vote: ReportVoteType) => void,
): HTMLDivElement {
	const meta = getReportCategoryMeta(report.category);
	const root = document.createElement("div");
	root.style.cssText =
		"padding:10px 12px;min-width:195px;max-width:250px;font-family:system-ui,-apple-system,sans-serif;color:#0f172a;background:#ffffff;";

	const header = document.createElement("div");
	header.style.cssText = "display:flex;align-items:center;gap:6px;font-weight:700;font-size:13px;";

	const emojiSpan = document.createElement("span");
	emojiSpan.style.fontSize = "16px";
	emojiSpan.textContent = meta.emoji;

	const titleSpan = document.createElement("span");
	titleSpan.textContent = meta.labelRo;

	header.appendChild(emojiSpan);
	header.appendChild(titleSpan);
	root.appendChild(header);

	const sub = document.createElement("div");
	sub.style.cssText =
		"margin-top:3px;font-size:11px;color:#475569;display:flex;flex-wrap:wrap;gap:6px;align-items:center;";
	const ago = formatConfirmedAgo(report.lastConfirmedAt || report.createdAt, "ro");
	const statusText =
		report.conditionStatus === "dry_or_closed"
			? report.category === "spring"
				? "⚠️ Secat momentan"
				: "⚠️ Închis / Indisponibil"
			: report.isPermanent
				? "Reper permanent"
				: `${ago} (${report.confirmCount}×)`;
	sub.textContent = statusText;
	root.appendChild(sub);

	if (report.isPermanent && (report.lastConfirmedAt || report.createdAt)) {
		const confirmedEl = document.createElement("div");
		confirmedEl.style.cssText = "margin-top:2px;font-size:10.5px;color:#64748b;";
		confirmedEl.textContent = ago;
		root.appendChild(confirmedEl);
	}

	if (report.note) {
		const noteEl = document.createElement("p");
		noteEl.style.cssText =
			"margin:6px 0 0;font-size:12px;line-height:1.35;color:#1e293b;background:#f8fafc;padding:5px 7px;border-radius:6px;border:1px solid #e2e8f0;word-break:break-word;";
		noteEl.textContent = report.note;
		root.appendChild(noteEl);
	}

	if (onVote) {
		const actions = document.createElement("div");
		actions.style.cssText = "margin-top:8px;display:flex;gap:5px;flex-wrap:wrap;";

		const makeBtn = (label: string, bg: string, fg: string, vote: ReportVoteType) => {
			const btn = document.createElement("button");
			btn.type = "button";
			btn.textContent = label;
			btn.style.cssText = `padding:4px 8px;border-radius:9999px;font-size:11px;font-weight:600;border:none;cursor:pointer;background:${bg};color:${fg};`;
			btn.addEventListener("click", (ev) => {
				ev.stopPropagation();
				onVote(report.id, vote);
			});
			return btn;
		};

		if (report.isPermanent) {
			const okLabel =
				report.category === "spring"
					? "💧 Curge apă"
					: report.category === "shelter"
						? "🛖 Deschis"
						: "📸 Vizibil";
			const dryLabel =
				report.category === "spring" ? "⚠️ Secat" : "⚠️ Indisponibil";
			actions.appendChild(makeBtn(okLabel, "#dcfce7", "#166534", "seasonal_ok"));
			actions.appendChild(makeBtn(dryLabel, "#fef3c7", "#92400e", "seasonal_dry"));
		} else {
			actions.appendChild(makeBtn("👍 OK, mai este", "#dcfce7", "#166534", "confirm"));
			actions.appendChild(makeBtn("👎 Nu mai e", "#fee2e2", "#991b1b", "dismiss"));
		}
		root.appendChild(actions);
	}

	return root;
}

export function syncReportMapMarkers(
	map: M.Map | null,
	existing: M.Marker[],
	reports: TrailReportDto[],
	options: {
		onVote?: (reportId: string, vote: ReportVoteType) => void;
	} = {},
): M.Marker[] {
	for (const m of existing) {
		try {
			m.remove();
		} catch {
			// Ignore marker removal errors
		}
	}
	if (!map) return [];

	const nextMarkers: M.Marker[] = [];
	const nowMs = Date.now();

	for (const report of reports) {
		if (!isReportVisibleOnMap(report, nowMs)) continue;
		const meta = getReportCategoryMeta(report.category);
		const isDry = report.conditionStatus === "dry_or_closed";

		const el = document.createElement("button");
		el.type = "button";
		el.setAttribute("data-testid", "trail-report-marker");
		el.setAttribute("data-report-id", report.id);
		el.setAttribute("data-report-category", report.category);
		el.setAttribute("aria-label", meta.labelRo);
		el.title = report.note ? `${meta.labelRo}: ${report.note}` : meta.labelRo;

		const bg = isDry ? "#64748b" : meta.color;
		el.style.cssText = `
			width:34px;
			height:34px;
			border-radius:9999px;
			background:${bg};
			border:2.5px solid #ffffff;
			box-shadow:0 3px 10px rgba(0,0,0,0.32);
			display:flex;
			align-items:center;
			justify-content:center;
			font-size:17px;
			line-height:1;
			cursor:pointer;
			position:relative;
			padding:0;
		`;

		const iconSpan = document.createElement("span");
		iconSpan.textContent = meta.emoji;
		el.appendChild(iconSpan);

		if (!report.isPermanent && report.confirmCount > 1) {
			const badge = document.createElement("span");
			badge.textContent = String(report.confirmCount);
			badge.style.cssText =
				"position:absolute;top:-5px;right:-5px;min-width:16px;height:16px;padding:0 3px;border-radius:9999px;background:#0f172a;color:#ffffff;font-size:9.5px;font-weight:800;display:flex;align-items:center;justify-content:center;border:1.5px solid #ffffff;";
			el.appendChild(badge);
		}

		const popup = new M.Popup({
			offset: 18,
			closeButton: true,
			maxWidth: "260px",
		}).setDOMContent(buildReportPopupDom(report, options.onVote));

		const marker = new M.Marker({ element: el, anchor: "center" })
			.setLngLat([report.lon, report.lat])
			.setPopup(popup)
			.addTo(map);

		nextMarkers.push(marker);
	}

	return nextMarkers;
}

export function syncSosMapMarkers(
	map: M.Map | null,
	existing: M.Marker[],
	sosAlerts: SosAlertDto[],
	options: {
		onRespond?: (sos: SosAlertDto) => void;
	} = {},
): M.Marker[] {
	for (const m of existing) {
		try {
			m.remove();
		} catch {
			// Ignore
		}
	}
	if (!map) return [];

	const nextMarkers: M.Marker[] = [];

	for (const sos of sosAlerts) {
		if (sos.status !== "active" || !Number.isFinite(sos.lat) || !Number.isFinite(sos.lon)) {
			continue;
		}
		const reasonMeta = SOS_REASON_META[sos.reason] ?? SOS_REASON_META.other;

		const el = document.createElement("button");
		el.type = "button";
		el.setAttribute("data-testid", "sos-map-marker");
		el.setAttribute("data-sos-id", sos.id);
		el.setAttribute("aria-label", `SOS: ${reasonMeta.labelRo}`);
		el.style.cssText = `
			width:42px;
			height:42px;
			border-radius:9999px;
			background:#dc2626;
			color:#ffffff;
			border:3px solid #ffffff;
			box-shadow:0 0 0 5px rgba(220,38,38,0.35), 0 4px 14px rgba(0,0,0,0.4);
			display:flex;
			align-items:center;
			justify-content:center;
			font-size:18px;
			font-weight:900;
			cursor:pointer;
			padding:0;
		`;
		el.textContent = "🆘";

		const popupRoot = document.createElement("div");
		popupRoot.style.cssText =
			"padding:10px 12px;min-width:200px;max-width:250px;font-family:system-ui,-apple-system,sans-serif;color:#0f172a;background:#ffffff;";

		const title = document.createElement("div");
		title.style.cssText = "font-weight:800;font-size:13px;color:#dc2626;";
		title.textContent = `🆘 SOS · ${reasonMeta.labelRo}`;
		popupRoot.appendChild(title);

		if (sos.requesterName) {
			const who = document.createElement("div");
			who.style.cssText = "font-size:11.5px;font-weight:600;color:#334155;margin-top:2px;";
			who.textContent = sos.requesterName;
			popupRoot.appendChild(who);
		}

		if (sos.message) {
			const msg = document.createElement("p");
			msg.style.cssText =
				"margin:6px 0 0;font-size:12px;color:#1e293b;background:#fef2f2;padding:5px 7px;border-radius:6px;border:1px solid #fecaca;word-break:break-word;";
			msg.textContent = sos.message;
			popupRoot.appendChild(msg);
		}

		if (!sos.isMine && options.onRespond) {
			const btn = document.createElement("button");
			btn.type = "button";
			btn.textContent = sos.amResponding ? "🧭 În curs de deplasare" : "Pot să vin să ajut";
			btn.style.cssText =
				"margin-top:8px;width:100%;padding:6px 10px;border-radius:9999px;background:#dc2626;color:#ffffff;font-size:12px;font-weight:700;border:none;cursor:pointer;";
			btn.addEventListener("click", (ev) => {
				ev.stopPropagation();
				options.onRespond?.(sos);
			});
			popupRoot.appendChild(btn);
		}

		const popup = new M.Popup({ offset: 22, closeButton: true, maxWidth: "260px" }).setDOMContent(
			popupRoot,
		);

		const marker = new M.Marker({ element: el, anchor: "center" })
			.setLngLat([sos.lon, sos.lat])
			.setPopup(popup)
			.addTo(map);
		nextMarkers.push(marker);
	}

	return nextMarkers;
}

export interface SyncGroupMarkersOptions {
	selfAlongTrackM?: number | null;
	selfLat?: number | null;
	selfLon?: number | null;
	locale?: string;
	onSelectMember?: (member: GroupMemberDto) => void;
}

export function getGroupMemberInitials(displayName: string): string {
	const cleaned = (displayName ?? "").trim();
	if (!cleaned) return "DR";
	const parts = cleaned.split(/\s+/).filter(Boolean);
	if (parts.length >= 2) {
		const first = Array.from(parts[0])[0] ?? "";
		const second = Array.from(parts[1])[0] ?? "";
		return (first + second).toUpperCase();
	}
	return Array.from(cleaned).slice(0, 2).join("").toUpperCase();
}

function formatCompactDistance(meters: number): string {
	const absM = Math.abs(Math.round(meters));
	if (absM >= 1000) {
		return `${(absM / 1000).toFixed(1)} km`;
	}
	return `${absM} m`;
}

function haversineDistanceM(lat1: number, lon1: number, lat2: number, lon2: number): number {
	const R = 6_371_000;
	const dLat = ((lat2 - lat1) * Math.PI) / 180;
	const dLon = ((lon2 - lon1) * Math.PI) / 180;
	const a =
		Math.sin(dLat / 2) ** 2 +
		Math.cos((lat1 * Math.PI) / 180) *
			Math.cos((lat2 * Math.PI) / 180) *
			Math.sin(dLon / 2) ** 2;
	return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
}

function formatGroupMemberSubtitle(
	member: GroupMemberDto,
	options: SyncGroupMarkersOptions,
): string {
	const isRo = (options.locale ?? "ro").toLowerCase().startsWith("ro");
	const parts: string[] = [];

	if (
		options.selfAlongTrackM !== null &&
		options.selfAlongTrackM !== undefined &&
		Number.isFinite(options.selfAlongTrackM) &&
		member.alongTrackM !== null &&
		member.alongTrackM !== undefined &&
		Number.isFinite(member.alongTrackM)
	) {
		const deltaM = Math.round(member.alongTrackM - options.selfAlongTrackM);
		if (Math.abs(deltaM) < 10) {
			parts.push(isRo ? "Lângă tine" : "Right by you");
		} else if (deltaM > 0) {
			parts.push(
				isRo
					? `+${formatCompactDistance(deltaM)} în față`
					: `+${formatCompactDistance(deltaM)} ahead`,
			);
		} else {
			parts.push(
				isRo
					? `${formatCompactDistance(deltaM)} în urmă`
					: `${formatCompactDistance(deltaM)} behind`,
			);
		}
	} else if (
		options.selfLat !== null &&
		options.selfLat !== undefined &&
		Number.isFinite(options.selfLat) &&
		options.selfLon !== null &&
		options.selfLon !== undefined &&
		Number.isFinite(options.selfLon)
	) {
		const distM = haversineDistanceM(options.selfLat, options.selfLon, member.lat, member.lon);
		parts.push(
			isRo ? `la ${formatCompactDistance(distM)}` : `${formatCompactDistance(distM)} away`,
		);
	}

	if (Number.isFinite(member.accuracy) && member.accuracy > 0) {
		parts.push(`±${Math.max(1, Math.round(member.accuracy))} m`);
	}

	return parts.join(" · ");
}

export function syncGroupMapMarkers(
	map: M.Map | null,
	prevMarkers: M.Marker[],
	members: readonly GroupMemberDto[],
	options: SyncGroupMarkersOptions = {},
): M.Marker[] {
	for (const m of prevMarkers) {
		try {
			m.remove();
		} catch {
			// Ignore marker removal errors
		}
	}
	if (!map) return [];

	const nextMarkers: M.Marker[] = [];

	for (const member of members) {
		if (member.isSelf) continue;
		if (!Number.isFinite(member.lat) || !Number.isFinite(member.lon)) continue;
		if (member.lat === 0 && member.lon === 0) continue;

		const rawColor = (member.colorHex ?? "").trim();
		const bg = /^#[0-9a-fA-F]{3,8}$/.test(rawColor) ? rawColor : "#242734";
		const initials = getGroupMemberInitials(member.displayName);
		const subtitle = formatGroupMemberSubtitle(member, options);

		const el = document.createElement("button");
		el.type = "button";
		el.setAttribute("data-testid", "group-member-marker");
		el.setAttribute("data-member-id", member.memberId);
		el.setAttribute("aria-label", member.displayName);
		el.title = subtitle ? `${member.displayName} · ${subtitle}` : member.displayName;
		el.style.cssText = `
			width:34px;
			height:34px;
			border-radius:9999px;
			background:${bg};
			color:#ffffff;
			border:2px solid #ffffff;
			box-shadow:0 3px 10px rgba(36,39,52,0.28);
			display:flex;
			align-items:center;
			justify-content:center;
			font-family:system-ui,-apple-system,sans-serif;
			font-size:12px;
			font-weight:800;
			letter-spacing:0.02em;
			line-height:1;
			cursor:pointer;
			padding:0;
			user-select:none;
		`;
		el.textContent = initials;

		if (options.onSelectMember) {
			el.addEventListener("click", () => {
				options.onSelectMember?.(member);
			});
		}

		const popupRoot = document.createElement("div");
		popupRoot.style.cssText =
			"padding:8px 11px;min-width:140px;max-width:220px;font-family:system-ui,-apple-system,sans-serif;color:#242734;background:#ffffff;";

		const header = document.createElement("div");
		header.style.cssText = "display:flex;align-items:center;gap:6px;font-weight:700;font-size:13px;color:#242734;";

		const dot = document.createElement("span");
		dot.style.cssText = `width:8px;height:8px;border-radius:9999px;background:${bg};flex-shrink:0;`;
		header.appendChild(dot);

		const nameSpan = document.createElement("span");
		nameSpan.textContent = member.displayName;
		header.appendChild(nameSpan);
		popupRoot.appendChild(header);

		if (subtitle) {
			const subEl = document.createElement("div");
			subEl.style.cssText = "margin-top:3px;font-size:11.5px;color:#475569;font-weight:500;";
			subEl.textContent = subtitle;
			popupRoot.appendChild(subEl);
		}

		const popup = new M.Popup({
			offset: 18,
			closeButton: false,
			maxWidth: "230px",
		}).setDOMContent(popupRoot);

		const marker = new M.Marker({ element: el, anchor: "center" })
			.setLngLat([member.lon, member.lat])
			.setPopup(popup)
			.addTo(map);
		nextMarkers.push(marker);
	}

	return nextMarkers;
}
