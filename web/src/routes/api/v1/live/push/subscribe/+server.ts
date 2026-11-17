import {
	forwardAndProxyLiveJson,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function POST(event: RequestEvent) {
	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.pushSubscribe.enforce(identity.deviceHash);
	if (rateLimited) {
		return rateLimited;
	}

	let body: Record<string, unknown>;
	try {
		const parsed = await event.request.json();
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			return Response.json({ message: "invalid_body" }, { status: 400 });
		}
		body = parsed as Record<string, unknown>;
	} catch {
		return Response.json({ message: "invalid_json" }, { status: 400 });
	}

	const endpoint = typeof body.endpoint === "string" ? body.endpoint.trim() : "";
	const keysObj =
		body.keys && typeof body.keys === "object" && !Array.isArray(body.keys)
			? (body.keys as Record<string, unknown>)
			: undefined;

	const p256dh =
		typeof keysObj?.p256dh === "string"
			? keysObj.p256dh.trim()
			: typeof body.p256dh === "string"
				? body.p256dh.trim()
				: "";

	const auth =
		typeof keysObj?.auth === "string"
			? keysObj.auth.trim()
			: typeof body.auth === "string"
				? body.auth.trim()
				: "";

	if (!endpoint || !p256dh || !auth) {
		return Response.json({ message: "invalid_push_subscription" }, { status: 400 });
	}

	const lat =
		typeof body.lat === "number" && Number.isFinite(body.lat) && body.lat >= -90 && body.lat <= 90
			? body.lat
			: undefined;
	const lon =
		typeof body.lon === "number" && Number.isFinite(body.lon) && body.lon >= -180 && body.lon <= 180
			? body.lon
			: undefined;
	const trailId = typeof body.trailId === "string" ? body.trailId : "";

	return forwardAndProxyLiveJson(
		"/push/subscribe",
		{
			method: "POST",
			body: JSON.stringify({
				endpoint,
				p256dh,
				auth,
				lat,
				lon,
				trailId,
			}),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}

export async function DELETE(event: RequestEvent) {
	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.pushSubscribe.enforce(identity.deviceHash);
	if (rateLimited) {
		return rateLimited;
	}

	let body: Record<string, unknown>;
	try {
		const parsed = await event.request.json();
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
			return Response.json({ message: "invalid_body" }, { status: 400 });
		}
		body = parsed as Record<string, unknown>;
	} catch {
		return Response.json({ message: "invalid_json" }, { status: 400 });
	}

	const endpoint = typeof body.endpoint === "string" ? body.endpoint.trim() : "";
	if (!endpoint) {
		return Response.json({ message: "invalid_push_subscription" }, { status: 400 });
	}

	return forwardAndProxyLiveJson(
		"/push/subscribe",
		{
			method: "DELETE",
			body: JSON.stringify({ endpoint }),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
