// SvelteKit PWA Service Worker for Web Push, SOS Notification Clicks, and strict allowlist
// static shell caching. Dynamic SvelteKit SSR HTML, PocketBase auth cookies, `/api/*`, and
// live SSE (`text/event-stream`) requests return immediately without `respondWith()`.

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

interface SwFetchEvent extends SwExtendableEvent {
	readonly request: Request;
	respondWith(response: Promise<Response> | Response): void;
}

interface SwGlobal {
	readonly location: Location;
	readonly clients: SwClients;
	readonly registration: SwRegistration;
	skipWaiting(): Promise<void>;
	addEventListener(type: "install" | "activate", listener: (event: SwExtendableEvent) => void): void;
	addEventListener(type: "fetch", listener: (event: SwFetchEvent) => void): void;
	addEventListener(type: "push", listener: (event: SwPushEvent) => void): void;
	addEventListener(
		type: "notificationclick",
		listener: (event: SwNotificationEvent) => void,
	): void;
}

const sw = self as unknown as SwGlobal;
const IMMUTABLE_CACHE = "wanderer-immutable-v1";
const STATIC_SHELL_CACHE = "wanderer-static-v1";
const ACTIVE_CACHES = new Set([
	IMMUTABLE_CACHE,
	STATIC_SHELL_CACHE,
	"wanderer-gpx-v1",
	"wanderer-dem16-v1",
]);

function isStaticShellAsset(pathname: string): boolean {
	return (
		pathname.startsWith("/styles/") ||
		pathname.startsWith("/fonts/") ||
		pathname.startsWith("/favicon") ||
		pathname === "/apple-touch-icon.png" ||
		pathname === "/manifest.json"
	);
}

sw.addEventListener("install", (event) => {
	event.waitUntil(sw.skipWaiting());
});

sw.addEventListener("activate", (event) => {
	event.waitUntil(
		(async () => {
			if (typeof caches !== "undefined") {
				const keys = await caches.keys();
				await Promise.all(
					keys
						.filter((k) => k.startsWith("wanderer-") && !ACTIVE_CACHES.has(k))
						.map((k) => caches.delete(k)),
				);
			}
			await sw.clients.claim();
		})(),
	);
});

sw.addEventListener("fetch", (event) => {
	const req = event.request;
	if (req.method !== "GET") return;
	if (req.mode === "navigate") return;
	const accept = req.headers.get("accept") ?? "";
	if (accept.includes("text/event-stream")) return;

	let url: URL;
	try {
		url = new URL(req.url);
	} catch {
		return;
	}
	if (url.origin !== sw.location.origin) return;
	const { pathname } = url;
	if (pathname.startsWith("/api/")) return;

	if (pathname.startsWith("/_app/immutable/")) {
		event.respondWith(
			(async () => {
				const cache = await caches.open(IMMUTABLE_CACHE);
				const cached = await cache.match(req);
				if (cached) return cached;
				const net = await fetch(req);
				if (net.ok) {
					await cache.put(req, net.clone());
				}
				return net;
			})(),
		);
		return;
	}

	if (isStaticShellAsset(pathname)) {
		event.respondWith(
			(async () => {
				const cache = await caches.open(STATIC_SHELL_CACHE);
				const cached = await cache.match(req);
				const revalidate = fetch(req)
					.then(async (net) => {
						if (net.ok) {
							await cache.put(req, net.clone());
						}
						return net;
					})
					.catch(() => null);
				if (cached) {
					event.waitUntil(revalidate);
					return cached;
				}
				const net = await revalidate;
				return net ?? Response.error();
			})(),
		);
	}
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
