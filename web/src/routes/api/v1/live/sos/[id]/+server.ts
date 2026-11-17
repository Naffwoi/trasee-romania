import {
	forwardAndProxyLiveJson,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function PATCH(event: RequestEvent) {
	const id = event.params.id?.trim();
	if (!id) {
		return Response.json({ message: "invalid_sos_id" }, { status: 400 });
	}

	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.sosUpdate.enforce(identity.deviceHash);
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

	const payload: Record<string, unknown> = {};
	if (typeof body.status === "string" && body.status.trim()) {
		payload.status = body.status.trim();
	}
	if (body.lat !== undefined) {
		const lat = Number(body.lat);
		if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
			return Response.json({ message: "invalid_coordinates" }, { status: 400 });
		}
		payload.lat = lat;
	}
	if (body.lon !== undefined) {
		const lon = Number(body.lon);
		if (!Number.isFinite(lon) || lon < -180 || lon > 180) {
			return Response.json({ message: "invalid_coordinates" }, { status: 400 });
		}
		payload.lon = lon;
	}
	if (typeof body.ele === "number" && Number.isFinite(body.ele)) {
		payload.ele = body.ele;
	}

	return forwardAndProxyLiveJson(
		`/sos/${encodeURIComponent(id)}`,
		{
			method: "PATCH",
			body: JSON.stringify(payload),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
