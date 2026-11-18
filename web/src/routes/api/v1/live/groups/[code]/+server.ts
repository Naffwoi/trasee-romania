import {
	forwardAndProxyLiveJson,
	isValidGroupCode,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function GET(event: RequestEvent) {
	const code = event.params.code?.trim() ?? "";
	if (!isValidGroupCode(code)) {
		return Response.json({ message: "invalid_group_code" }, { status: 400 });
	}

	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	return forwardAndProxyLiveJson(
		`/groups/${encodeURIComponent(code)}`,
		{ method: "GET" },
		identity.deviceHash,
		resolveActorId(event),
	);
}
