// Minimal SvelteKit PWA Service Worker strictly for Web Push & SOS Notification Clicks.
// Intentionally omits a `fetch` handler so dynamic SvelteKit SSR, PocketBase auth cookies,
// and live SSE streams are never intercepted or cached.

interface SosNotificationData {
	type?: string;
	sosId?: string;
	trailId?: string;
	title?: string;
	body?: string;
	url?: string;
	[key: string]: unknown;
}

interface SwWindowClient {
	url: string;
	focus(): Promise<SwWindowClient>;
	navigate?(url: string): Promise<SwWindowClient | null>;
}

interface SwClients {
	claim(): Promise<void>;
	matchAll(options?: {
		type?: "window" | "worker" | "sharedworker" | "all";
		includeUncontrolled?: boolean;
	}): Promise<SwWindowClient[]>;
	openWindow?(url: string): Promise<SwWindowClient | null>;
}

interface SwRegistration {
	showNotification(
		title: string,
		options?: {
			body?: string;
			icon?: string;
			badge?: string;
			tag?: string;
			requireInteraction?: boolean;
			data?: SosNotificationData;
		},
	): Promise<void>;
}

interface SwExtendableEvent extends Event {
	waitUntil(promise: Promise<unknown>): void;
}

interface SwPushMessageData {
	json(): unknown;
	text(): string;
}

interface SwPushEvent extends SwExtendableEvent {
	readonly data: SwPushMessageData | null;
}

interface SwNotificationEvent extends SwExtendableEvent {
	readonly notification: {
		data?: SosNotificationData;
		close(): void;
	};
}

interface SwGlobal {
	readonly location: Location;
	readonly clients: SwClients;
	readonly registration: SwRegistration;
	skipWaiting(): Promise<void>;
	addEventListener(type: "install" | "activate", listener: (event: SwExtendableEvent) => void): void;
	addEventListener(type: "push", listener: (event: SwPushEvent) => void): void;
	addEventListener(
		type: "notificationclick",
		listener: (event: SwNotificationEvent) => void,
	): void;
}

const sw = self as unknown as SwGlobal;

sw.addEventListener("install", (event) => {
	event.waitUntil(sw.skipWaiting());
});

sw.addEventListener("activate", (event) => {
	event.waitUntil(sw.clients.claim());
});

sw.addEventListener("push", (event) => {
	let parsed: SosNotificationData = {};
	if (event.data) {
		try {
			const json = event.data.json();
			if (json && typeof json === "object") {
				parsed = json as SosNotificationData;
			}
		} catch {
			const fallbackText = event.data.text();
			if (fallbackText) {
				parsed = { body: fallbackText };
			}
		}
	}

	const title =
		typeof parsed.title === "string" && parsed.title.trim().length > 0
			? parsed.title
			: "🆘 Ajutor solicitat în apropiere!";
	const body =
		typeof parsed.body === "string" && parsed.body.trim().length > 0
			? parsed.body
			: "Un drumeț din apropiere are nevoie de ajutor.";
	const sosId =
		typeof parsed.sosId === "string" && parsed.sosId.trim().length > 0
			? parsed.sosId.trim()
			: "alert";
	const url =
		typeof parsed.url === "string" && parsed.url.startsWith("/") ? parsed.url : "/map";

	const data: SosNotificationData = {
		...parsed,
		sosId,
		url,
	};

	event.waitUntil(
		sw.registration.showNotification(title, {
			body,
			icon: "/favicon-192x192.png",
			badge: "/favicon-192x192.png",
			tag: "sos-" + sosId,
			requireInteraction: true,
			data,
		}),
	);
});

sw.addEventListener("notificationclick", (event) => {
	event.notification.close();
	const rawUrl = event.notification.data?.url;
	const safeRelativePath =
		typeof rawUrl === "string" && rawUrl.startsWith("/") ? rawUrl : "/map";
	const targetUrl = new URL(safeRelativePath, sw.location.origin).href;

	event.waitUntil(
		(async () => {
			const windowClients = await sw.clients.matchAll({
				type: "window",
				includeUncontrolled: true,
			});

			for (const client of windowClients) {
				try {
					if (new URL(client.url).origin === sw.location.origin) {
						if (typeof client.navigate === "function") {
							try {
								await client.navigate(targetUrl);
							} catch {
								// Some mobile browsers disallow navigate on backgrounded clients; still focus or openWindow below.
							}
						}
						await client.focus();
						return;
					}
				} catch {
					// Ignore malformed client URLs.
				}
			}

			if (typeof sw.clients.openWindow === "function") {
				await sw.clients.openWindow(targetUrl);
			}
		})(),
	);
});

export {};
