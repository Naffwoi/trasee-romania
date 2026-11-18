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

	const rateLimited = liveRateLimiters.groupJoin.enforce(identity.deviceHash);
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

	const displayName = typeof body.displayName === "string" ? body.displayName.trim() : "";
	if (displayName.length < 1 || displayName.length > 24) {
		return Response.json({ message: "invalid_display_name" }, { status: 400 });
	}

	const payload: Record<string, unknown> = {
		displayName,
	};

	const hasLat = body.lat !== undefined && body.lat !== null;
	const hasLon = body.lon !== undefined && body.lon !== null;
	if (hasLat || hasLon) {
		const lat = Number(body.lat);
		const lon = Number(body.lon);
		if (!Number.isFinite(lat) || lat < -90 || lat > 90 || !Number.isFinite(lon) || lon < -180 || lon > 180) {
			return Response.json({ message: "invalid_coordinates" }, { status: 400 });
		}
		payload.lat = lat;
		payload.lon = lon;
	}

	if (typeof body.ele === "number" && Number.isFinite(body.ele)) {
		payload.ele = body.ele;
	}
	if (typeof body.accuracy === "number" && Number.isFinite(body.accuracy) && body.accuracy >= 0) {
		payload.accuracy = body.accuracy;
	}
	if (typeof body.alongTrackM === "number" && Number.isFinite(body.alongTrackM)) {
		payload.alongTrackM = body.alongTrackM;
	}
	if (typeof body.inNavigation === "boolean") {
		payload.inNavigation = body.inNavigation;
	}

	return forwardAndProxyLiveJson(
		`/groups/${encodeURIComponent(code)}/join`,
		{
			method: "POST",
			body: JSON.stringify(payload),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
