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

	return forwardAndProxyLiveJson(
		`/trail/${encodeURIComponent(id)}/summary`,
		{ method: "GET" },
		identity.deviceHash,
		resolveActorId(event),
	);
}
