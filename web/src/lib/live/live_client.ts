export type TemporaryReportCategory =
	| "bear"
	| "deer"
	| "shepherd_dogs"
	| "ice_mud"
	| "fallen_tree_terrain";

export type PermanentLandmarkCategory = "spring" | "viewpoint" | "shelter";

export type TrailReportCategory = TemporaryReportCategory | PermanentLandmarkCategory;

export type ReportKind = "hazard" | "wildlife_good" | "landmark_permanent";

export type ReportConditionStatus = "active" | "dry_or_closed" | "resolved" | "spam_hidden";

export type ReportVoteType = "confirm" | "dismiss" | "seasonal_ok" | "seasonal_dry" | "spam";

export type SosReason = "lost" | "injury" | "exhaustion" | "other";

export type SosStatus = "active" | "resolved" | "cancelled";

export interface TrailReportDto {
	id: string;
	trailId: string;
	category: TrailReportCategory;
	kind: ReportKind | string;
	isPermanent: boolean;
	conditionStatus: ReportConditionStatus;
	note: string;
	lat: number;
	lon: number;
	ele: number;
	alongTrackM: number;
	confirmCount: number;
	dismissCount: number;
	createdAt: string;
	lastConfirmedAt: string;
	expiresAt: string | null;
}

export interface SosAlertDto {
	id: string;
	trailId: string;
	status: SosStatus;
	reason: SosReason;
	message: string;
	requesterName: string;
	lat: number;
	lon: number;
	ele: number;
	responderCount: number;
	nearestEtaSec: number | null;
	nearestDistanceM: number | null;
	isMine: boolean;
	amResponding: boolean;
	createdAt: string;
	expiresAt: string | null;
}

export interface TrailLiveSummaryDto {
	trailId: string;
	activeHikers30m: number;
	reports: TrailReportDto[];
	sosAlerts: SosAlertDto[];
}

export interface GroupMemberDto {
	memberId: string;
	displayName: string;
	colorHex: string;
	lat: number;
	lon: number;
	ele: number;
	accuracy: number;
	heading?: number | null;
	speed?: number | null;
	alongTrackM?: number | null;
	inNavigation: boolean;
	isSelf: boolean;
	updatedAt: string;
}

export interface GroupSessionDto {
	code: string;
	trailId: string;
	expiresAt: string;
	selfMemberId: string;
	members: GroupMemberDto[];
}

export interface SavedGroupSession {
	code: string;
	trailId: string;
	displayName: string;
	selfMemberId: string;
	expiresAt: string;
}

export const GROUP_CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/;

export function isValidGroupCode(raw: unknown): raw is string {
	return typeof raw === "string" && GROUP_CODE_RE.test(raw);
}

export function normalizeGroupCode(raw: string | null | undefined): string | null {
	if (typeof raw !== "string") return null;
	const cleaned = raw.trim().toUpperCase();
	return GROUP_CODE_RE.test(cleaned) ? cleaned : null;
}

export interface ReportCategoryMeta {
	category: TrailReportCategory;
	emoji: string;
	labelRo: string;
	labelEn: string;
	ttlLabelRo: string;
	isPermanent: boolean;
	kind: ReportKind;
	color: string;
	badgeBg: string;
}

export const REPORT_CATEGORIES: readonly ReportCategoryMeta[] = [
	{
		category: "bear",
		emoji: "🐻",
		labelRo: "Urs",
		labelEn: "Bear",
		ttlLabelRo: "Activ 3h",
		isPermanent: false,
		kind: "hazard",
		color: "#dc2626",
		badgeBg: "rgba(220, 38, 38, 0.14)",
	},
	{
		category: "shepherd_dogs",
		emoji: "🐕",
		labelRo: "Câini la stână",
		labelEn: "Shepherd dogs",
		ttlLabelRo: "Activ 24h",
		isPermanent: false,
		kind: "hazard",
		color: "#ea580c",
		badgeBg: "rgba(234, 88, 12, 0.14)",
	},
	{
		category: "fallen_tree_terrain",
		emoji: "🌲",
		labelRo: "Teren cu probleme / Copac căzut",
		labelEn: "Fallen tree / Bad terrain",
		ttlLabelRo: "Activ 14 zile",
		isPermanent: false,
		kind: "hazard",
		color: "#d97706",
		badgeBg: "rgba(217, 119, 6, 0.14)",
	},
	{
		category: "ice_mud",
		emoji: "🧊",
		labelRo: "Gheață / Noroi",
		labelEn: "Ice / Mud",
		ttlLabelRo: "Activ 48h",
		isPermanent: false,
		kind: "hazard",
		color: "#0284c7",
		badgeBg: "rgba(2, 132, 199, 0.14)",
	},
	{
		category: "deer",
		emoji: "🦌",
		labelRo: "Căprioare",
		labelEn: "Deer",
		ttlLabelRo: "Activ 3h · Faună",
		isPermanent: false,
		kind: "wildlife_good",
		color: "#16a34a",
		badgeBg: "rgba(22, 163, 74, 0.16)",
	},
	{
		category: "spring",
		emoji: "💧",
		labelRo: "Izvor",
		labelEn: "Water spring",
		ttlLabelRo: "Permanent",
		isPermanent: true,
		kind: "landmark_permanent",
		color: "#0ea5e9",
		badgeBg: "rgba(14, 165, 233, 0.14)",
	},
	{
		category: "viewpoint",
		emoji: "📸",
		labelRo: "Belvedere",
		labelEn: "Viewpoint",
		ttlLabelRo: "Permanent",
		isPermanent: true,
		kind: "landmark_permanent",
		color: "#8b5cf6",
		badgeBg: "rgba(139, 92, 246, 0.14)",
	},
	{
		category: "shelter",
		emoji: "🛖",
		labelRo: "Refugiu",
		labelEn: "Mountain shelter",
		ttlLabelRo: "Permanent",
		isPermanent: true,
		kind: "landmark_permanent",
		color: "#059669",
		badgeBg: "rgba(5, 150, 105, 0.14)",
	},
] as const;

const CATEGORY_MAP = new Map<string, ReportCategoryMeta>(
	REPORT_CATEGORIES.map((c) => [c.category, c]),
);

export function getReportCategoryMeta(category: string): ReportCategoryMeta {
	return (
		CATEGORY_MAP.get(category) ?? {
			category: "fallen_tree_terrain",
			emoji: "⚠️",
			labelRo: "Atenționare",
			labelEn: "Alert",
			ttlLabelRo: "Temporar",
			isPermanent: false,
			kind: "hazard",
			color: "#f59e0b",
			badgeBg: "rgba(245, 158, 11, 0.14)",
		}
	);
}

export const SOS_REASON_META: Record<
	SosReason,
	{ emoji: string; labelRo: string; labelEn: string }
> = {
	lost: { emoji: "🧭", labelRo: "Rătăcit", labelEn: "Lost" },
	injury: { emoji: "🩹", labelRo: "Accidentare", labelEn: "Injury" },
	exhaustion: {
		emoji: "💧",
		labelRo: "Epuizare / Fără apă",
		labelEn: "Exhaustion / No water",
	},
	other: { emoji: "⚠️", labelRo: "Alt motiv", labelEn: "Other reason" },
};

const DEVICE_TOKEN_KEY = "wanderer_device_token";
const VOTED_REPORTS_KEY = "wanderer_voted_reports";
const SAVED_GROUP_SESSION_KEY = "wanderer_live_group_session";

let memoryDeviceToken: string | null = null;
const memoryVotes = new Map<string, ReportVoteType>();
const knownMySosIds = new Set<string>();
const knownRespondingSosIds = new Set<string>();
const knownSelfMemberByGroup = new Map<string, string>();
let activeSelfMemberId: string | null = null;
let memorySavedGroup: SavedGroupSession | null = null;

function bytesToHex(bytes: Uint8Array): string {
	let hex = "";
	for (let i = 0; i < bytes.length; i++) {
		hex += bytes[i].toString(16).padStart(2, "0");
	}
	return hex;
}

export function generateRandomDeviceToken(): string {
	const bytes = new Uint8Array(32);
	if (typeof globalThis.crypto?.getRandomValues === "function") {
		globalThis.crypto.getRandomValues(bytes);
	} else {
		for (let i = 0; i < bytes.length; i++) {
			bytes[i] = Math.floor(Math.random() * 256);
		}
	}
	return bytesToHex(bytes);
}

export function getOrCreateDeviceToken(): string {
	if (typeof window !== "undefined") {
		try {
			const existing = window.localStorage.getItem(DEVICE_TOKEN_KEY);
			if (existing && existing.length >= 24 && existing.length <= 128) {
				memoryDeviceToken = existing;
				return existing;
			}
			const created = generateRandomDeviceToken();
			window.localStorage.setItem(DEVICE_TOKEN_KEY, created);
			memoryDeviceToken = created;
			return created;
		} catch {
			// Fall back to in-memory token when localStorage is restricted
		}
	}
	if (!memoryDeviceToken) {
		memoryDeviceToken = generateRandomDeviceToken();
	}
	return memoryDeviceToken;
}

export function getVotedReportsMap(): Record<string, ReportVoteType> {
	const out: Record<string, ReportVoteType> = {};
	for (const [k, v] of memoryVotes.entries()) {
		out[k] = v;
	}
	if (typeof window !== "undefined") {
		try {
			const raw = window.localStorage.getItem(VOTED_REPORTS_KEY);
			if (raw) {
				const parsed = JSON.parse(raw) as Record<string, ReportVoteType>;
				if (parsed && typeof parsed === "object") {
					Object.assign(out, parsed);
				}
			}
		} catch {
			// Ignore malformed storage
		}
	}
	return out;
}

export function hasVotedOnReport(reportId: string): boolean {
	if (memoryVotes.has(reportId)) return true;
	const map = getVotedReportsMap();
	return Boolean(map[reportId]);
}

export function recordLocalReportVote(reportId: string, vote: ReportVoteType): void {
	memoryVotes.set(reportId, vote);
	if (typeof window !== "undefined") {
		try {
			const current = getVotedReportsMap();
			current[reportId] = vote;
			const keys = Object.keys(current);
			if (keys.length > 300) {
				for (const oldKey of keys.slice(0, keys.length - 300)) {
					delete current[oldKey];
				}
			}
			window.localStorage.setItem(VOTED_REPORTS_KEY, JSON.stringify(current));
		} catch {
			// Ignore storage quota errors
		}
	}
}

export function isReportVisibleOnMap(report: TrailReportDto, nowMs = Date.now()): boolean {
	if (!report || !Number.isFinite(report.lat) || !Number.isFinite(report.lon)) {
		return false;
	}
	if (report.conditionStatus === "resolved" || report.conditionStatus === "spam_hidden") {
		return false;
	}
	if (!report.isPermanent && report.expiresAt) {
		const expMs = Date.parse(report.expiresAt);
		if (Number.isFinite(expMs) && expMs <= nowMs) {
			return false;
		}
	}
	return true;
}

export function formatConfirmedAgo(
	isoString: string | null | undefined,
	locale = "ro",
	nowMs = Date.now(),
): string {
	const isRo = locale.toLowerCase().startsWith("ro");
	if (!isoString) {
		return isRo ? "Confirmat recent" : "Confirmed recently";
	}
	const ts = Date.parse(isoString);
	if (!Number.isFinite(ts)) {
		return isRo ? "Confirmat recent" : "Confirmed recently";
	}
	const diffMin = Math.max(0, Math.round((nowMs - ts) / 60_000));
	if (diffMin < 1) {
		return isRo ? "Confirmat chiar acum" : "Confirmed just now";
	}
	if (diffMin < 60) {
		return isRo ? `Confirmat acum ${diffMin} min` : `Confirmed ${diffMin} min ago`;
	}
	const diffHours = Math.round(diffMin / 60);
	if (diffHours < 24) {
		return isRo ? `Confirmat acum ${diffHours} h` : `Confirmed ${diffHours} h ago`;
	}
	const diffDays = Math.round(diffHours / 24);
	return isRo ? `Confirmat acum ${diffDays} zile` : `Confirmed ${diffDays}d ago`;
}

export function normalizeReportDto(raw: Record<string, unknown>): TrailReportDto | null {
	if (!raw || typeof raw.id !== "string") return null;
	const category = String(raw.category ?? "fallen_tree_terrain") as TrailReportCategory;
	const meta = getReportCategoryMeta(category);
	const isPermanent =
		typeof raw.isPermanent === "boolean" ? raw.isPermanent : meta.isPermanent;
	const expiresRaw = raw.expiresAt;
	const expiresAt =
		isPermanent || expiresRaw === null || expiresRaw === undefined || expiresRaw === ""
			? null
			: String(expiresRaw);

	return {
		id: raw.id,
		trailId: String(raw.trailId ?? ""),
		category,
		kind: String(raw.kind ?? meta.kind),
		isPermanent,
		conditionStatus: (raw.conditionStatus as ReportConditionStatus) ?? "active",
		note: String(raw.note ?? ""),
		lat: Number(raw.lat ?? 0),
		lon: Number(raw.lon ?? 0),
		ele: Number(raw.ele ?? 0),
		alongTrackM: Number(raw.alongTrackM ?? 0),
		confirmCount: Math.max(0, Number(raw.confirmCount ?? 1)),
		dismissCount: Math.max(0, Number(raw.dismissCount ?? 0)),
		createdAt: String(raw.createdAt ?? ""),
		lastConfirmedAt: String(raw.lastConfirmedAt ?? raw.createdAt ?? ""),
		expiresAt,
	};
}

export function normalizeSosDto(raw: Record<string, unknown>): SosAlertDto | null {
	if (!raw || typeof raw.id !== "string") return null;
	const id = raw.id;
	const isMine = Boolean(raw.isMine) || knownMySosIds.has(id);
	const amResponding = Boolean(raw.amResponding) || knownRespondingSosIds.has(id);
	if (isMine) knownMySosIds.add(id);
	if (amResponding) knownRespondingSosIds.add(id);

	const nearestEtaRaw = raw.nearestEtaSec;
	const nearestDistRaw = raw.nearestDistanceM;

	return {
		id,
		trailId: String(raw.trailId ?? ""),
		status: (raw.status as SosStatus) ?? "active",
		reason: (raw.reason as SosReason) ?? "other",
		message: String(raw.message ?? ""),
		requesterName: String(raw.requesterName ?? ""),
		lat: Number(raw.lat ?? 0),
		lon: Number(raw.lon ?? 0),
		ele: Number(raw.ele ?? 0),
		responderCount: Math.max(0, Number(raw.responderCount ?? 0)),
		nearestEtaSec:
			nearestEtaRaw !== null &&
			nearestEtaRaw !== undefined &&
			Number(nearestEtaRaw) > 0
				? Number(nearestEtaRaw)
				: null,
		nearestDistanceM:
			nearestDistRaw !== null &&
			nearestDistRaw !== undefined &&
			Number(nearestDistRaw) > 0
				? Number(nearestDistRaw)
				: null,
		isMine,
		amResponding,
		createdAt: String(raw.createdAt ?? ""),
		expiresAt: raw.expiresAt ? String(raw.expiresAt) : null,
	};
}

function normalizeSummaryResponse(
	raw: Record<string, unknown>,
	fallbackTrailId = "",
): TrailLiveSummaryDto {
	const rawReports = Array.isArray(raw.reports)
		? raw.reports
		: Array.isArray(raw.nearbyReports)
			? raw.nearbyReports
			: [];
	const rawSos = Array.isArray(raw.sosAlerts)
		? raw.sosAlerts
		: Array.isArray(raw.activeSosAlerts)
			? raw.activeSosAlerts
			: [];

	const reports = rawReports
		.map((item) => normalizeReportDto(item as Record<string, unknown>))
		.filter((item): item is TrailReportDto => item !== null && isReportVisibleOnMap(item));

	const sosList = rawSos
		.map((item) => normalizeSosDto(item as Record<string, unknown>))
		.filter((item): item is SosAlertDto => item !== null && item.status === "active");

	if (raw.myActiveSos && typeof raw.myActiveSos === "object") {
		const mine = normalizeSosDto({
			...(raw.myActiveSos as Record<string, unknown>),
			isMine: true,
		});
		if (mine && mine.status === "active" && !sosList.some((s) => s.id === mine.id)) {
			sosList.unshift(mine);
		}
	}

	return {
		trailId: String(raw.trailId ?? fallbackTrailId),
		activeHikers30m: Math.max(0, Number(raw.activeHikers30m ?? 0)),
		reports,
		sosAlerts: sosList,
	};
}

async function liveJsonFetch<T = Record<string, unknown>>(
	path: string,
	init: RequestInit = {},
): Promise<T | null> {
	try {
		const headers = new Headers(init.headers ?? {});
		headers.set("X-Device-Token", getOrCreateDeviceToken());
		if (init.body && !headers.has("Content-Type")) {
			headers.set("Content-Type", "application/json");
		}
		const res = await fetch(path, {
			...init,
			headers,
		});
		if (!res.ok) return null;
		const ct = res.headers.get("content-type") ?? "";
		if (!ct.includes("application/json")) return null;
		return (await res.json()) as T;
	} catch {
		return null;
	}
}

export async function sendHeartbeat(params: {
	trailId?: string;
	lat: number;
	lon: number;
	ele?: number | null;
	inNavigation?: boolean;
}): Promise<TrailLiveSummaryDto | null> {
	if (!Number.isFinite(params.lat) || !Number.isFinite(params.lon)) {
		return null;
	}
	const data = await liveJsonFetch<Record<string, unknown>>("/api/v1/live/heartbeat", {
		method: "POST",
		body: JSON.stringify({
			trailId: params.trailId ?? "",
			lat: params.lat,
			lon: params.lon,
			ele: params.ele ?? 0,
			inNavigation: Boolean(params.inNavigation),
		}),
	});
	if (!data) return null;
	return normalizeSummaryResponse(data, params.trailId ?? "");
}

export async function clearHeartbeat(): Promise<void> {
	try {
		const headers = new Headers();
		headers.set("X-Device-Token", getOrCreateDeviceToken());
		await fetch("/api/v1/live/heartbeat", {
			method: "DELETE",
			headers,
			keepalive: true,
		});
	} catch {
		// Best-effort presence cleanup on page unload / backgrounding
	}
}

export async function fetchTrailLiveSummary(
	trailId: string,
	coords?: { lat?: number | null; lon?: number | null },
): Promise<TrailLiveSummaryDto | null> {
	if (!trailId) return null;
	const qs = new URLSearchParams();
	if (
		coords &&
		typeof coords.lat === "number" &&
		Number.isFinite(coords.lat) &&
		typeof coords.lon === "number" &&
		Number.isFinite(coords.lon)
	) {
		qs.set("lat", String(coords.lat));
		qs.set("lon", String(coords.lon));
	}
	const suffix = qs.size > 0 ? `?${qs.toString()}` : "";
	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/trail/${encodeURIComponent(trailId)}/summary${suffix}`,
		{ method: "GET" },
	);
	if (!data) return null;
	return normalizeSummaryResponse(data, trailId);
}

export async function createReport(params: {
	trailId?: string;
	category: TrailReportCategory;
	note?: string;
	lat: number;
	lon: number;
	ele?: number | null;
	alongTrackM?: number | null;
}): Promise<TrailReportDto | null> {
	const data = await liveJsonFetch<Record<string, unknown>>("/api/v1/live/reports", {
		method: "POST",
		body: JSON.stringify({
			trailId: params.trailId ?? "",
			category: params.category,
			note: (params.note ?? "").trim().slice(0, 160),
			lat: params.lat,
			lon: params.lon,
			ele: params.ele ?? 0,
			alongTrackM: params.alongTrackM ?? 0,
		}),
	});
	if (!data) return null;
	const rawReport = (data.report ?? data) as Record<string, unknown>;
	const normalized = normalizeReportDto(rawReport);
	if (normalized) {
		recordLocalReportVote(normalized.id, "confirm");
	}
	return normalized;
}

export async function voteReport(
	reportId: string,
	vote: ReportVoteType,
): Promise<TrailReportDto | null> {
	if (!reportId) return null;
	recordLocalReportVote(reportId, vote);
	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/reports/${encodeURIComponent(reportId)}/vote`,
		{
			method: "POST",
			body: JSON.stringify({ vote }),
		},
	);
	if (!data) return null;
	const rawReport = (data.report ?? data) as Record<string, unknown>;
	return normalizeReportDto(rawReport);
}

export async function triggerSos(params: {
	trailId?: string;
	reason: SosReason;
	message?: string;
	requesterName?: string;
	lat: number;
	lon: number;
	ele?: number | null;
}): Promise<SosAlertDto | null> {
	const data = await liveJsonFetch<Record<string, unknown>>("/api/v1/live/sos", {
		method: "POST",
		body: JSON.stringify({
			trailId: params.trailId ?? "",
			reason: params.reason,
			message: (params.message ?? "").trim().slice(0, 200),
			requesterName: (params.requesterName ?? "").trim().slice(0, 40),
			lat: params.lat,
			lon: params.lon,
			ele: params.ele ?? 0,
		}),
	});
	if (!data) return null;
	const rawSos = (data.sos ?? data) as Record<string, unknown>;
	const normalized = normalizeSosDto({ ...rawSos, isMine: true });
	if (normalized) {
		knownMySosIds.add(normalized.id);
	}
	return normalized;
}

export async function updateSos(
	sosId: string,
	patch: {
		status?: SosStatus;
		lat?: number;
		lon?: number;
		ele?: number | null;
	},
): Promise<SosAlertDto | null> {
	if (!sosId) return null;
	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/sos/${encodeURIComponent(sosId)}`,
		{
			method: "PATCH",
			body: JSON.stringify(patch),
		},
	);
	if (patch.status === "resolved" || patch.status === "cancelled") {
		knownMySosIds.delete(sosId);
	}
	if (!data) return null;
	const rawSos = (data.sos ?? data) as Record<string, unknown>;
	return normalizeSosDto(rawSos);
}

export async function respondToSos(
	sosId: string,
	params: {
		status: "coming" | "cancelled";
		lat: number;
		lon: number;
		ele?: number | null;
		distanceM?: number;
		etaSec?: number;
	},
): Promise<SosAlertDto | null> {
	if (!sosId) return null;
	if (params.status === "coming") {
		knownRespondingSosIds.add(sosId);
	} else {
		knownRespondingSosIds.delete(sosId);
	}
	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/sos/${encodeURIComponent(sosId)}/respond`,
		{
			method: "POST",
			body: JSON.stringify({
				status: params.status,
				lat: params.lat,
				lon: params.lon,
				ele: params.ele ?? 0,
				distanceM: Math.round(params.distanceM ?? 0),
				etaSec: Math.round(params.etaSec ?? 0),
			}),
		},
	);
	if (!data) return null;
	const rawSos = (data.sos ?? data) as Record<string, unknown>;
	return normalizeSosDto({
		...rawSos,
		amResponding: params.status === "coming",
	});
}

export function urlBase64ToUint8Array(base64String: string): Uint8Array<ArrayBuffer> {
	const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
	const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
	const rawData =
		typeof window !== "undefined" && typeof window.atob === "function"
			? window.atob(base64)
			: Buffer.from(base64, "base64").toString("binary");
	const buffer = new ArrayBuffer(rawData.length);
	const outputArray = new Uint8Array(buffer);
	for (let i = 0; i < rawData.length; ++i) {
		outputArray[i] = rawData.charCodeAt(i);
	}
	return outputArray;
}

export type WebPushSubscribeResult = "subscribed" | "denied" | "unsupported" | "error";

export async function subscribeWebPushIfSupported(
	lat?: number | null,
	lon?: number | null,
	trailId?: string,
	options: { requestPermission?: boolean } = {},
): Promise<WebPushSubscribeResult> {
	if (
		typeof window === "undefined" ||
		typeof navigator === "undefined" ||
		!("serviceWorker" in navigator) ||
		!("PushManager" in window) ||
		(!("Notification" in window) && typeof Notification === "undefined")
	) {
		return "unsupported";
	}

	try {
		let perm = Notification.permission;
		if (perm === "default" && options.requestPermission !== false) {
			try {
				perm = await Notification.requestPermission();
			} catch {
				return "error";
			}
		}
		if (perm !== "granted") {
			return perm === "denied" ? "denied" : "unsupported";
		}

		const vapidRes = await liveJsonFetch<{ publicKey?: string }>(
			"/api/v1/live/push/vapid-public-key",
			{ method: "GET" },
		);
		if (!vapidRes?.publicKey) {
			return "error";
		}

		const registration = await navigator.serviceWorker.register("/service-worker.js");
		await Promise.race([
			navigator.serviceWorker.ready,
			new Promise((resolve) => setTimeout(resolve, 2500)),
		]);

		let sub = await registration.pushManager.getSubscription();
		if (!sub) {
			const applicationServerKey = urlBase64ToUint8Array(vapidRes.publicKey);
			sub = await registration.pushManager.subscribe({
				userVisibleOnly: true,
				applicationServerKey,
			});
		}

		const subJson = sub.toJSON();
		if (!subJson.endpoint || !subJson.keys?.p256dh || !subJson.keys?.auth) {
			return "error";
		}

		const saved = await liveJsonFetch("/api/v1/live/push/subscribe", {
			method: "POST",
			body: JSON.stringify({
				endpoint: subJson.endpoint,
				keys: {
					p256dh: subJson.keys.p256dh,
					auth: subJson.keys.auth,
				},
				lat: lat ?? 0,
				lon: lon ?? 0,
				trailId: trailId ?? "",
			}),
		});
		return saved ? "subscribed" : "error";
	} catch {
		return "error";
	}
}

/**
 * Plays a short, subtle two-note WebAudio chime when a new nearby SOS alert arrives.
 * Strictly uses WebAudio oscillators (no speechSynthesis / TTS).
 */
export function playSosTone(): void {
	if (typeof window === "undefined") return;
	try {
		const AudioCtx =
			window.AudioContext ||
			(window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
		if (!AudioCtx) return;

		const ctx = new AudioCtx();
		const now = ctx.currentTime;

		const playNote = (freq: number, startOffset: number, duration: number) => {
			const osc = ctx.createOscillator();
			const gain = ctx.createGain();
			osc.type = "sine";
			osc.frequency.setValueAtTime(freq, now + startOffset);
			gain.gain.setValueAtTime(0.001, now + startOffset);
			gain.gain.exponentialRampToValueAtTime(0.11, now + startOffset + 0.015);
			gain.gain.exponentialRampToValueAtTime(0.0001, now + startOffset + duration);
			osc.connect(gain);
			gain.connect(ctx.destination);
			osc.start(now + startOffset);
			osc.stop(now + startOffset + duration + 0.02);
		};

		playNote(740, 0, 0.14);
		playNote(987.77, 0.16, 0.20);

		setTimeout(() => {
			void ctx.close().catch(() => {});
		}, 600);
	} catch {
		// Ignore browser autoplay or AudioContext restrictions
	}
}

export function mergeReportIntoList(
	list: TrailReportDto[],
	incoming: TrailReportDto,
): TrailReportDto[] {
	const visible = isReportVisibleOnMap(incoming);
	const idx = list.findIndex((r) => r.id === incoming.id);
	if (!visible) {
		return idx === -1 ? list : list.filter((r) => r.id !== incoming.id);
	}
	if (idx === -1) {
		return [incoming, ...list];
	}
	const copy = list.slice();
	copy[idx] = incoming;
	return copy;
}

export function mergeSosIntoList(list: SosAlertDto[], incoming: SosAlertDto): SosAlertDto[] {
	const idx = list.findIndex((s) => s.id === incoming.id);
	if (incoming.status !== "active") {
		return idx === -1 ? list : list.filter((s) => s.id !== incoming.id);
	}
	if (idx === -1) {
		return [incoming, ...list];
	}
	const copy = list.slice();
	copy[idx] = incoming;
	return copy;
}

export function normalizeGroupMemberDto(
	raw: Record<string, unknown>,
	explicitSelfMemberId?: string | null,
): GroupMemberDto | null {
	if (!raw || typeof raw.memberId !== "string" || !raw.memberId.trim()) {
		return null;
	}
	const memberId = raw.memberId.trim();
	const isSelf =
		explicitSelfMemberId !== undefined && explicitSelfMemberId !== null && explicitSelfMemberId !== ""
			? Boolean(raw.isSelf) || memberId === explicitSelfMemberId
			: Boolean(raw.isSelf) || (activeSelfMemberId !== null && memberId === activeSelfMemberId);

	const colorRaw = typeof raw.colorHex === "string" ? raw.colorHex.trim() : "";
	const colorHex = /^#[0-9a-fA-F]{3,8}$/.test(colorRaw) ? colorRaw : "#242734";

	const optNum = (v: unknown): number | null =>
		v !== null && v !== undefined && Number.isFinite(Number(v)) ? Number(v) : null;

	return {
		memberId,
		displayName: String(raw.displayName ?? "").trim() || "Drumeț",
		colorHex,
		lat: Number(raw.lat ?? 0),
		lon: Number(raw.lon ?? 0),
		ele: Number(raw.ele ?? 0),
		accuracy: Math.max(0, Number(raw.accuracy ?? 0)),
		heading: optNum(raw.heading),
		speed: optNum(raw.speed),
		alongTrackM: optNum(raw.alongTrackM),
		inNavigation: Boolean(raw.inNavigation),
		isSelf,
		updatedAt: String(raw.updatedAt ?? ""),
	};
}

export function normalizeGroupSessionDto(
	raw: Record<string, unknown>,
	fallbackCode = "",
): GroupSessionDto | null {
	if (!raw || typeof raw !== "object") return null;
	const code = normalizeGroupCode(String(raw.code ?? fallbackCode));
	if (!code) return null;

	const selfMemberId =
		typeof raw.selfMemberId === "string" && raw.selfMemberId.trim()
			? raw.selfMemberId.trim()
			: knownSelfMemberByGroup.get(code) ?? "";
	if (selfMemberId) {
		knownSelfMemberByGroup.set(code, selfMemberId);
		activeSelfMemberId = selfMemberId;
	}

	const rawMembers = Array.isArray(raw.members) ? raw.members : [];
	const members = rawMembers
		.map((item) => normalizeGroupMemberDto(item as Record<string, unknown>, selfMemberId))
		.filter((item): item is GroupMemberDto => item !== null);

	return {
		code,
		trailId: String(raw.trailId ?? ""),
		expiresAt: String(raw.expiresAt ?? ""),
		selfMemberId,
		members,
	};
}

export function saveGroupSession(session: {
	code: string;
	trailId?: string;
	displayName?: string;
	selfMemberId?: string;
	expiresAt?: string;
}): void {
	const code = normalizeGroupCode(session.code);
	if (!code) return;

	const selfMemberId =
		session.selfMemberId?.trim() || knownSelfMemberByGroup.get(code) || "";
	if (selfMemberId) {
		knownSelfMemberByGroup.set(code, selfMemberId);
		activeSelfMemberId = selfMemberId;
	}

	const entry: SavedGroupSession = {
		code,
		trailId: (session.trailId ?? memorySavedGroup?.trailId ?? "").trim(),
		displayName: (session.displayName ?? memorySavedGroup?.displayName ?? "").trim().slice(0, 24),
		selfMemberId,
		expiresAt: (session.expiresAt ?? memorySavedGroup?.expiresAt ?? "").trim(),
	};
	memorySavedGroup = entry;

	if (typeof window !== "undefined") {
		try {
			window.localStorage.setItem(SAVED_GROUP_SESSION_KEY, JSON.stringify(entry));
		} catch {
			// Ignore storage quota errors
		}
	}
}

export function clearSavedGroupSession(code?: string): void {
	const normCode = code ? normalizeGroupCode(code) : null;
	if (normCode) {
		knownSelfMemberByGroup.delete(normCode);
		if (memorySavedGroup && memorySavedGroup.code === normCode) {
			if (activeSelfMemberId === memorySavedGroup.selfMemberId) {
				activeSelfMemberId = null;
			}
			memorySavedGroup = null;
		}
	} else {
		knownSelfMemberByGroup.clear();
		activeSelfMemberId = null;
		memorySavedGroup = null;
	}

	if (typeof window !== "undefined") {
		try {
			if (!normCode) {
				window.localStorage.removeItem(SAVED_GROUP_SESSION_KEY);
			} else {
				const raw = window.localStorage.getItem(SAVED_GROUP_SESSION_KEY);
				if (raw) {
					const parsed = JSON.parse(raw) as Partial<SavedGroupSession>;
					if (!parsed?.code || normalizeGroupCode(parsed.code) === normCode) {
						window.localStorage.removeItem(SAVED_GROUP_SESSION_KEY);
					}
				}
			}
		} catch {
			// Ignore malformed storage
		}
	}
}

export function getSavedGroupSession(trailId?: string): SavedGroupSession | null {
	let candidate: SavedGroupSession | null = memorySavedGroup;
	if (typeof window !== "undefined") {
		try {
			const raw = window.localStorage.getItem(SAVED_GROUP_SESSION_KEY);
			if (raw) {
				const parsed = JSON.parse(raw) as Partial<SavedGroupSession>;
				const code = normalizeGroupCode(parsed?.code);
				if (code) {
					candidate = {
						code,
						trailId: String(parsed?.trailId ?? ""),
						displayName: String(parsed?.displayName ?? ""),
						selfMemberId: String(parsed?.selfMemberId ?? ""),
						expiresAt: String(parsed?.expiresAt ?? ""),
					};
				} else {
					candidate = null;
				}
			}
		} catch {
			// Fall back to in-memory candidate
		}
	}

	if (!candidate) return null;

	if (candidate.expiresAt) {
		const expMs = Date.parse(candidate.expiresAt);
		if (Number.isFinite(expMs) && expMs <= Date.now()) {
			clearSavedGroupSession(candidate.code);
			return null;
		}
	}

	const expectedTrail = trailId?.trim() ?? "";
	if (expectedTrail && candidate.trailId && candidate.trailId !== expectedTrail) {
		return null;
	}

	if (candidate.selfMemberId) {
		knownSelfMemberByGroup.set(candidate.code, candidate.selfMemberId);
		activeSelfMemberId = candidate.selfMemberId;
	}
	memorySavedGroup = candidate;
	return candidate;
}

export async function createLiveGroup(params: {
	displayName: string;
	trailId?: string;
	lat?: number | null;
	lon?: number | null;
	ele?: number | null;
	accuracy?: number | null;
	alongTrackM?: number | null;
	inNavigation?: boolean;
}): Promise<GroupSessionDto | null> {
	const displayName = (params.displayName ?? "").trim().slice(0, 24);
	if (!displayName) return null;

	const body: Record<string, unknown> = {
		displayName,
		trailId: params.trailId ?? "",
	};
	if (
		typeof params.lat === "number" &&
		Number.isFinite(params.lat) &&
		typeof params.lon === "number" &&
		Number.isFinite(params.lon)
	) {
		body.lat = params.lat;
		body.lon = params.lon;
	}
	if (typeof params.ele === "number" && Number.isFinite(params.ele)) {
		body.ele = params.ele;
	}
	if (typeof params.accuracy === "number" && Number.isFinite(params.accuracy)) {
		body.accuracy = params.accuracy;
	}
	if (typeof params.alongTrackM === "number" && Number.isFinite(params.alongTrackM)) {
		body.alongTrackM = params.alongTrackM;
	}
	if (typeof params.inNavigation === "boolean") {
		body.inNavigation = params.inNavigation;
	}

	const data = await liveJsonFetch<Record<string, unknown>>("/api/v1/live/groups", {
		method: "POST",
		body: JSON.stringify(body),
	});
	if (!data) return null;

	const normalized = normalizeGroupSessionDto(data);
	if (normalized) {
		saveGroupSession({
			code: normalized.code,
			trailId: normalized.trailId || params.trailId || "",
			displayName,
			selfMemberId: normalized.selfMemberId,
			expiresAt: normalized.expiresAt,
		});
	}
	return normalized;
}

export async function fetchLiveGroup(code: string): Promise<GroupSessionDto | null> {
	const normCode = normalizeGroupCode(code);
	if (!normCode) return null;

	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/groups/${encodeURIComponent(normCode)}`,
		{ method: "GET" },
	);
	if (!data) return null;
	return normalizeGroupSessionDto(data, normCode);
}

export async function joinLiveGroup(
	code: string,
	params: {
		displayName: string;
		trailId?: string;
		lat?: number | null;
		lon?: number | null;
		ele?: number | null;
		accuracy?: number | null;
		alongTrackM?: number | null;
		inNavigation?: boolean;
	},
): Promise<GroupSessionDto | null> {
	const normCode = normalizeGroupCode(code);
	const displayName = (params.displayName ?? "").trim().slice(0, 24);
	if (!normCode || !displayName) return null;

	const body: Record<string, unknown> = { displayName };
	if (
		typeof params.lat === "number" &&
		Number.isFinite(params.lat) &&
		typeof params.lon === "number" &&
		Number.isFinite(params.lon)
	) {
		body.lat = params.lat;
		body.lon = params.lon;
	}
	if (typeof params.ele === "number" && Number.isFinite(params.ele)) {
		body.ele = params.ele;
	}
	if (typeof params.accuracy === "number" && Number.isFinite(params.accuracy)) {
		body.accuracy = params.accuracy;
	}
	if (typeof params.alongTrackM === "number" && Number.isFinite(params.alongTrackM)) {
		body.alongTrackM = params.alongTrackM;
	}
	if (typeof params.inNavigation === "boolean") {
		body.inNavigation = params.inNavigation;
	}

	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/groups/${encodeURIComponent(normCode)}/join`,
		{
			method: "POST",
			body: JSON.stringify(body),
		},
	);
	if (!data) return null;

	const normalized = normalizeGroupSessionDto(data, normCode);
	if (normalized) {
		saveGroupSession({
			code: normalized.code,
			trailId: normalized.trailId || params.trailId || "",
			displayName,
			selfMemberId: normalized.selfMemberId,
			expiresAt: normalized.expiresAt,
		});
	}
	return normalized;
}

export async function pingLiveGroup(
	code: string,
	params: {
		lat: number;
		lon: number;
		ele?: number | null;
		accuracy?: number | null;
		heading?: number | null;
		speed?: number | null;
		alongTrackM?: number | null;
		inNavigation?: boolean;
	},
): Promise<GroupSessionDto | null> {
	const normCode = normalizeGroupCode(code);
	if (!normCode || !Number.isFinite(params.lat) || !Number.isFinite(params.lon)) {
		return null;
	}

	const body: Record<string, unknown> = {
		lat: params.lat,
		lon: params.lon,
		inNavigation: Boolean(params.inNavigation),
	};
	if (typeof params.ele === "number" && Number.isFinite(params.ele)) {
		body.ele = params.ele;
	}
	if (typeof params.accuracy === "number" && Number.isFinite(params.accuracy)) {
		body.accuracy = params.accuracy;
	}
	if (typeof params.heading === "number" && Number.isFinite(params.heading)) {
		body.heading = params.heading;
	}
	if (typeof params.speed === "number" && Number.isFinite(params.speed)) {
		body.speed = params.speed;
	}
	if (typeof params.alongTrackM === "number" && Number.isFinite(params.alongTrackM)) {
		body.alongTrackM = params.alongTrackM;
	}

	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/groups/${encodeURIComponent(normCode)}/ping`,
		{
			method: "POST",
			body: JSON.stringify(body),
		},
	);
	if (!data) return null;
	return normalizeGroupSessionDto(data, normCode);
}

export async function leaveLiveGroup(code: string): Promise<boolean> {
	const normCode = normalizeGroupCode(code);
	if (!normCode) return false;

	const data = await liveJsonFetch<Record<string, unknown>>(
		`/api/v1/live/groups/${encodeURIComponent(normCode)}/leave`,
		{
			method: "POST",
			body: JSON.stringify({}),
		},
	);
	clearSavedGroupSession(normCode);
	return data !== null;
}

export function mergeGroupMemberIntoList(
	list: readonly GroupMemberDto[],
	incoming: GroupMemberDto,
): GroupMemberDto[] {
	if (!incoming || !incoming.memberId) {
		return list.slice();
	}
	const isKnownSelf =
		incoming.isSelf ||
		(activeSelfMemberId !== null && incoming.memberId === activeSelfMemberId);
	const normalized =
		isKnownSelf !== incoming.isSelf ? { ...incoming, isSelf: isKnownSelf } : incoming;

	const idx = list.findIndex((m) => m.memberId === normalized.memberId);
	if (idx === -1) {
		return [...list, normalized];
	}
	const copy = list.slice();
	copy[idx] = normalized;
	return copy;
}

export function removeGroupMemberFromList(
	list: readonly GroupMemberDto[],
	memberId: string,
): GroupMemberDto[] {
	if (!memberId) return list.slice();
	const idx = list.findIndex((m) => m.memberId === memberId);
	if (idx === -1) return list.slice();
	return list.filter((m) => m.memberId !== memberId);
}

export interface LiveStreamCallbacks {
	onReportUpdate?: (report: TrailReportDto) => void;
	onSosUpdate?: (sos: SosAlertDto) => void;
	onGroupMemberUpdate?: (member: GroupMemberDto) => void;
	onGroupMemberLeft?: (payload: { groupCode: string; memberId: string }) => void;
}

export interface LiveStreamHandle {
	updateCoords: (lat: number, lon: number) => void;
	updateGroupCode: (code: string | null) => void;
	close: () => void;
}

/**
 * Opens an SSE EventSource to `/api/v1/live/stream` with exponential backoff reconnect.
 */
export function connectLiveStream(params: {
	trailId?: string;
	lat?: number | null;
	lon?: number | null;
	groupCode?: string | null;
	callbacks: LiveStreamCallbacks;
}): LiveStreamHandle {
	let closed = false;
	let es: EventSource | null = null;
	let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
	let backoffMs = 2000;
	let curLat = params.lat ?? null;
	let curLon = params.lon ?? null;
	let curGroupCode: string | null = normalizeGroupCode(params.groupCode);
	let openedLat = curLat;
	let openedLon = curLon;

	const clearTimer = () => {
		if (reconnectTimer !== null) {
			clearTimeout(reconnectTimer);
			reconnectTimer = null;
		}
	};

	const handleRawReportEvent = (e: MessageEvent) => {
		backoffMs = 2000;
		try {
			const parsed = JSON.parse(e.data) as Record<string, unknown>;
			const report = normalizeReportDto(
				(parsed.report ?? parsed) as Record<string, unknown>,
			);
			if (report) {
				params.callbacks.onReportUpdate?.(report);
			}
		} catch {
			// Ignore malformed SSE frame
		}
	};

	const handleRawSosEvent = (e: MessageEvent) => {
		backoffMs = 2000;
		try {
			const parsed = JSON.parse(e.data) as Record<string, unknown>;
			const sos = normalizeSosDto((parsed.sos ?? parsed) as Record<string, unknown>);
			if (sos) {
				params.callbacks.onSosUpdate?.(sos);
			}
		} catch {
			// Ignore malformed SSE frame
		}
	};

	const handleRawGroupMemberUpdate = (e: MessageEvent) => {
		backoffMs = 2000;
		try {
			const parsed = JSON.parse(e.data) as Record<string, unknown>;
			const selfForGroup = curGroupCode
				? knownSelfMemberByGroup.get(curGroupCode) ?? activeSelfMemberId
				: activeSelfMemberId;
			const member = normalizeGroupMemberDto(
				(parsed.member ?? parsed) as Record<string, unknown>,
				selfForGroup,
			);
			if (member) {
				params.callbacks.onGroupMemberUpdate?.(member);
			}
		} catch {
			// Ignore malformed SSE frame
		}
	};

	const handleRawGroupMemberLeft = (e: MessageEvent) => {
		backoffMs = 2000;
		try {
			const parsed = JSON.parse(e.data) as Record<string, unknown>;
			const memberId = typeof parsed.memberId === "string" ? parsed.memberId.trim() : "";
			const groupCode =
				normalizeGroupCode(String(parsed.groupCode ?? curGroupCode ?? "")) ??
				String(parsed.groupCode ?? curGroupCode ?? "");
			if (memberId) {
				params.callbacks.onGroupMemberLeft?.({ groupCode, memberId });
			}
		} catch {
			// Ignore malformed SSE frame
		}
	};

	const handleGenericMessage = (e: MessageEvent) => {
		backoffMs = 2000;
		try {
			const parsed = JSON.parse(e.data) as Record<string, unknown>;
			const type = String(parsed.type ?? "");
			if (type === "report_update" || type === "report_change") {
				const report = normalizeReportDto(
					(parsed.report ?? parsed) as Record<string, unknown>,
				);
				if (report) params.callbacks.onReportUpdate?.(report);
			} else if (type === "sos_update" || type === "sos_alert") {
				const sos = normalizeSosDto((parsed.sos ?? parsed) as Record<string, unknown>);
				if (sos) params.callbacks.onSosUpdate?.(sos);
			} else if (type === "group_member_update") {
				handleRawGroupMemberUpdate(e);
			} else if (type === "group_member_left") {
				handleRawGroupMemberLeft(e);
			}
		} catch {
			// Ignore keepalive or non-JSON frames
		}
	};

	const open = () => {
		if (closed || typeof EventSource === "undefined") return;
		clearTimer();
		try {
			es?.close();
		} catch {
			// Ignore close errors
		}

		const qs = new URLSearchParams();
		if (params.trailId) qs.set("trailId", params.trailId);
		if (curLat !== null && Number.isFinite(curLat)) qs.set("lat", curLat.toFixed(6));
		if (curLon !== null && Number.isFinite(curLon)) qs.set("lon", curLon.toFixed(6));
		if (curGroupCode) qs.set("groupCode", curGroupCode);
		qs.set("deviceToken", getOrCreateDeviceToken());

		openedLat = curLat;
		openedLon = curLon;

		try {
			const source = new EventSource(`/api/v1/live/stream?${qs.toString()}`);
			es = source;
			source.addEventListener("open", () => {
				backoffMs = 2000;
			});
			source.addEventListener("report_update", handleRawReportEvent as EventListener);
			source.addEventListener("report_change", handleRawReportEvent as EventListener);
			source.addEventListener("sos_update", handleRawSosEvent as EventListener);
			source.addEventListener("sos_alert", handleRawSosEvent as EventListener);
			source.addEventListener("group_member_update", handleRawGroupMemberUpdate as EventListener);
			source.addEventListener("group_member_left", handleRawGroupMemberLeft as EventListener);
			source.addEventListener("message", handleGenericMessage as EventListener);
			source.onerror = () => {
				try {
					source.close();
				} catch {
					// Ignore
				}
				if (es === source) {
					es = null;
				}
				if (!closed) {
					const delay = backoffMs;
					backoffMs = Math.min(30_000, backoffMs * 2);
					reconnectTimer = setTimeout(open, delay);
				}
			};
		} catch {
			if (!closed) {
				const delay = backoffMs;
				backoffMs = Math.min(30_000, backoffMs * 2);
				reconnectTimer = setTimeout(open, delay);
			}
		}
	};

	open();

	return {
		updateCoords(lat: number, lon: number) {
			if (!Number.isFinite(lat) || !Number.isFinite(lon)) return;
			curLat = lat;
			curLon = lon;
			if (openedLat === null || openedLon === null) {
				open();
				return;
			}
			const dLat = (lat - openedLat) * 111_132;
			const dLon = (lon - openedLon) * 111_132 * Math.cos((lat * Math.PI) / 180);
			if (Math.hypot(dLat, dLon) > 1200) {
				open();
			}
		},
		updateGroupCode(code: string | null) {
			const next = normalizeGroupCode(code);
			if (next === curGroupCode) return;
			curGroupCode = next;
			backoffMs = 2000;
			if (!closed) {
				open();
			}
		},
		close() {
			closed = true;
			clearTimer();
			try {
				es?.close();
			} catch {
				// Ignore
			}
			es = null;
		},
	};
}
