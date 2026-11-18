import {
	forwardAndProxyLiveJson,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function GET(event: RequestEvent) {
	const id = event.params.id?.trim();
	if (!id) {
		return Response.json({ message: "invalid_trail_id" }, { status: 400 });
	}

	const identity = resolveDeviceIdentity(event, { optional: true });
	if (!identity.ok) {
		return identity.response;
	}

	const qs = new URLSearchParams();
	const latRaw = event.url.searchParams.get("lat")?.trim() ?? "";
	const lonRaw = event.url.searchParams.get("lon")?.trim() ?? "";
	if (latRaw && lonRaw) {
		const lat = Number(latRaw);
		const lon = Number(lonRaw);
		if (Number.isFinite(lat) && lat >= -90 && lat <= 90 && Number.isFinite(lon) && lon >= -180 && lon <= 180) {
			qs.set("lat", String(lat));
			qs.set("lon", String(lon));
		}
	}
	const querySuffix = qs.size > 0 ? `?${qs.toString()}` : "";

	return forwardAndProxyLiveJson(
		`/trail/${encodeURIComponent(id)}/summary${querySuffix}`,
		{ method: "GET" },
		identity.deviceHash,
		resolveActorId(event),
	);
}
