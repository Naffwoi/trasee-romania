import * as privateEnv from "$app/env/private";
import fs from "node:fs";
import path from "node:path";
import * as webpush from "web-push";

export const VAPID_SUBJECT = "mailto:trasee@skillfy.ro";

export interface VapidKeyPair {
	publicKey: string;
	privateKey: string;
}

export interface SosPushAlertInfo {
	id: string;
	trailId?: string | null;
	reason?: string | null;
	message?: string | null;
	requesterName?: string | null;
	lat?: number;
	lon?: number;
	ele?: number;
}

export interface SosPushTarget {
	endpoint: string;
	p256dh?: string;
	auth?: string;
	keys?: {
		p256dh: string;
		auth: string;
	};
	distanceM?: number | null;
}

export interface SosPushPayload {
	type: "sos_alert";
	sosId: string;
	trailId: string;
	title: string;
	body: string;
	url: string;
}

export interface EnsureVapidOptions {
	uploadFolder?: string;
	webpushClient?: Pick<typeof webpush, "generateVAPIDKeys" | "setVapidDetails">;
}

export interface DispatchSosPushOptions {
	sendNotification?: typeof webpush.sendNotification;
	uploadFolder?: string;
	webpushClient?: Pick<typeof webpush, "generateVAPIDKeys" | "setVapidDetails">;
}

export interface DispatchSosPushSummary {
	sent: number;
	staleRemoved: number;
	failed: number;
}

const REASON_LABELS_RO: Record<string, string> = {
	lost: "Rătăcit",
	injury: "Accidentare",
	exhaustion: "Epuizare / Fără apă",
	other: "Ajutor pe traseu",
};

let cachedVapidKeys: VapidKeyPair | null = null;
let cachedKeyFolder: string | null = null;

export function resetVapidKeysCache(): void {
	cachedVapidKeys = null;
	cachedKeyFolder = null;
}

function resolveUploadFolder(overrideFolder?: string): string {
	if (overrideFolder && overrideFolder.trim().length > 0) {
		return overrideFolder.trim();
	}
	const envFolder =
		(privateEnv as Record<string, string | undefined>).UPLOAD_FOLDER ||
		process.env.UPLOAD_FOLDER ||
		"./uploads";
	return envFolder;
}

function tryReadPersistedVapidKeys(filePath: string): VapidKeyPair | null {
	try {
		if (!fs.existsSync(filePath)) {
			return null;
		}
		const raw = fs.readFileSync(filePath, "utf-8");
		const parsed = JSON.parse(raw) as Partial<VapidKeyPair>;
		if (
			typeof parsed?.publicKey === "string" &&
			parsed.publicKey.trim().length > 0 &&
			typeof parsed?.privateKey === "string" &&
			parsed.privateKey.trim().length > 0
		) {
			return {
				publicKey: parsed.publicKey.trim(),
				privateKey: parsed.privateKey.trim(),
			};
		}
		return null;
	} catch {
		return null;
	}
}

function persistVapidKeysAtomically(uploadFolder: string, keys: VapidKeyPair): void {
	const keyFilePath = path.join(uploadFolder, ".vapid_keys.json");
	const tmpFilePath = `${keyFilePath}.${process.pid}.${Date.now()}.tmp`;
	try {
		fs.mkdirSync(uploadFolder, { recursive: true });
		fs.writeFileSync(tmpFilePath, JSON.stringify(keys, null, 2), {
			encoding: "utf-8",
			mode: 0o600,
		});
		fs.renameSync(tmpFilePath, keyFilePath);
	} catch {
		// Read-only filesystem (e.g. unit tests or locked container rootfs):
		// fall back gracefully to in-memory VAPID keys for this process.
		try {
			if (fs.existsSync(tmpFilePath)) {
				fs.unlinkSync(tmpFilePath);
			}
		} catch {
			// Ignore cleanup error on read-only FS.
		}
	}
}

export function ensureVapidKeys(options: EnsureVapidOptions = {}): VapidKeyPair {
	const uploadFolder = resolveUploadFolder(options.uploadFolder);
	const client = options.webpushClient ?? webpush;

	if (cachedVapidKeys && cachedKeyFolder === uploadFolder) {
		return cachedVapidKeys;
	}

	const keyFilePath = path.join(uploadFolder, ".vapid_keys.json");
	const persisted = tryReadPersistedVapidKeys(keyFilePath);
	if (persisted) {
		try {
			client.setVapidDetails(VAPID_SUBJECT, persisted.publicKey, persisted.privateKey);
			cachedVapidKeys = persisted;
			cachedKeyFolder = uploadFolder;
			return persisted;
		} catch {
			// Corrupted key material on disk: regenerate below.
		}
	}

	const generated = client.generateVAPIDKeys();
	const keys: VapidKeyPair = {
		publicKey: generated.publicKey,
		privateKey: generated.privateKey,
	};
	client.setVapidDetails(VAPID_SUBJECT, keys.publicKey, keys.privateKey);
	persistVapidKeysAtomically(uploadFolder, keys);

	cachedVapidKeys = keys;
	cachedKeyFolder = uploadFolder;
	return keys;
}

export function getVapidPublicKey(options: EnsureVapidOptions = {}): string {
	return ensureVapidKeys(options).publicKey;
}

function formatDistanceRo(distanceM?: number | null): string {
	if (typeof distanceM !== "number" || !Number.isFinite(distanceM) || distanceM < 0) {
		return "";
	}
	if (distanceM >= 1000) {
		return `la ${(distanceM / 1000).toFixed(1)} km`;
	}
	return `la ${Math.round(distanceM)} m`;
}

export function buildSosPushPayload(
	sos: SosPushAlertInfo,
	distanceM?: number | null,
): SosPushPayload {
	const trailId = sos.trailId?.trim() ?? "";
	const rawReason = sos.reason?.trim() ?? "";
	const reasonLabel = REASON_LABELS_RO[rawReason] || rawReason || "Ajutor pe traseu";
	const distancePart = formatDistanceRo(distanceM);
	const requesterPart = sos.requesterName?.trim() ? `(${sos.requesterName.trim()})` : "";
	const headerParts = [reasonLabel, requesterPart, distancePart].filter(Boolean).join(" · ");
	const messagePart = sos.message?.trim() ?? "";
	const body = messagePart ? `${headerParts} — ${messagePart}` : headerParts;

	const url = trailId
		? "/map/trail/@romania/" + trailId + "/navigate?sos=" + sos.id
		: "/map?sos=" + sos.id;

	return {
		type: "sos_alert",
		sosId: sos.id,
		trailId,
		title: "🆘 Ajutor solicitat în apropiere!",
		body,
		url,
	};
}

export async function dispatchSosPushNotifications(
	sos: SosPushAlertInfo,
	pushTargets: SosPushTarget[],
	removeStaleEndpoint: (endpoint: string) => Promise<unknown> | unknown,
	options: DispatchSosPushOptions = {},
): Promise<DispatchSosPushSummary> {
	if (!Array.isArray(pushTargets) || pushTargets.length === 0) {
		return { sent: 0, staleRemoved: 0, failed: 0 };
	}

	ensureVapidKeys({
		uploadFolder: options.uploadFolder,
		webpushClient: options.webpushClient,
	});

	const sendFn = options.sendNotification ?? webpush.sendNotification;
	let sent = 0;
	let staleRemoved = 0;
	let failed = 0;

	await Promise.allSettled(
		pushTargets.map(async (target) => {
			const endpoint = target.endpoint?.trim() ?? "";
			const p256dh = (target.p256dh ?? target.keys?.p256dh ?? "").trim();
			const auth = (target.auth ?? target.keys?.auth ?? "").trim();

			if (!endpoint || !p256dh || !auth) {
				failed++;
				return;
			}

			const payload = buildSosPushPayload(sos, target.distanceM);

			try {
				const res = await sendFn(
					{
						endpoint,
						keys: { p256dh, auth },
					},
					JSON.stringify(payload),
					{
						TTL: 3600,
						urgency: "high",
					},
				);
				if (res && (res.statusCode === 404 || res.statusCode === 410)) {
					staleRemoved++;
					try {
						await removeStaleEndpoint(endpoint);
					} catch {
						// Never fail notification batch if stale endpoint removal fails.
					}
					return;
				}
				sent++;
			} catch (err) {
				const statusCode = (err as { statusCode?: number } | null)?.statusCode;
				if (statusCode === 404 || statusCode === 410) {
					staleRemoved++;
					try {
						await removeStaleEndpoint(endpoint);
					} catch {
						// Ignore cleanup error so other push notifications are unaffected.
					}
					return;
				}
				failed++;
			}
		}),
	);

	return { sent, staleRemoved, failed };
}
