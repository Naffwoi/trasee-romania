import {
	forwardAndProxyLiveJson,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function GET(event: RequestEvent) {
	const latRaw = event.url.searchParams.get("lat")?.trim() ?? "";
	const lonRaw = event.url.searchParams.get("lon")?.trim() ?? "";
	const lat = Number(latRaw);
	const lon = Number(lonRaw);
	if (
		!latRaw ||
		!lonRaw ||
		!Number.isFinite(lat) ||
		lat < -90 ||
		lat > 90 ||
		!Number.isFinite(lon) ||
		lon < -180 ||
		lon > 180
	) {
		return Response.json({ message: "invalid_coordinates" }, { status: 400 });
	}

	const identity = resolveDeviceIdentity(event, { optional: true });
	if (!identity.ok) {
		return identity.response;
	}

	return forwardAndProxyLiveJson(
		`/street-preview?lat=${lat.toFixed(6)}&lon=${lon.toFixed(6)}`,
		{ method: "GET" },
		identity.deviceHash,
		resolveActorId(event),
	);
}
