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

	const rateLimited = liveRateLimiters.heartbeat.enforce(identity.deviceHash);
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

	const lat = Number(body.lat);
	const lon = Number(body.lon);
	if (!Number.isFinite(lat) || lat < -90 || lat > 90 || !Number.isFinite(lon) || lon < -180 || lon > 180) {
		return Response.json({ message: "invalid_coordinates" }, { status: 400 });
	}

	return forwardAndProxyLiveJson(
		"/heartbeat",
		{
			method: "POST",
			body: JSON.stringify({
				trailId: typeof body.trailId === "string" ? body.trailId : "",
				lat,
				lon,
				ele: typeof body.ele === "number" && Number.isFinite(body.ele) ? body.ele : undefined,
				inNavigation: Boolean(body.inNavigation),
			}),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
