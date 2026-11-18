import {
	forwardAndProxyLiveJson,
	isValidGroupCode,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function POST(event: RequestEvent) {
	const code = event.params.code?.trim() ?? "";
	if (!isValidGroupCode(code)) {
		return Response.json({ message: "invalid_group_code" }, { status: 400 });
	}

	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.groupPing.enforce(identity.deviceHash);
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

	const payload: Record<string, unknown> = {
		lat,
		lon,
		inNavigation: Boolean(body.inNavigation),
	};

	if (typeof body.ele === "number" && Number.isFinite(body.ele)) {
		payload.ele = body.ele;
	}
	if (typeof body.accuracy === "number" && Number.isFinite(body.accuracy) && body.accuracy >= 0) {
		payload.accuracy = body.accuracy;
	}
	if (typeof body.heading === "number" && Number.isFinite(body.heading)) {
		payload.heading = body.heading;
	}
	if (typeof body.speed === "number" && Number.isFinite(body.speed)) {
		payload.speed = body.speed;
	}
	if (typeof body.alongTrackM === "number" && Number.isFinite(body.alongTrackM)) {
		payload.alongTrackM = body.alongTrackM;
	}

	return forwardAndProxyLiveJson(
		`/groups/${encodeURIComponent(code)}/ping`,
		{
			method: "POST",
			body: JSON.stringify(payload),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
