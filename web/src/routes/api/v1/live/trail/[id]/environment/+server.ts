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
	const maxEleRaw = event.url.searchParams.get("maxEle")?.trim() ?? "";
	if (maxEleRaw) {
		const maxEle = Number(maxEleRaw);
		if (Number.isFinite(maxEle) && maxEle >= -500 && maxEle <= 9000) {
			qs.set("maxEle", String(Math.round(maxEle)));
		}
	}
	const querySuffix = qs.size > 0 ? `?${qs.toString()}` : "";

	return forwardAndProxyLiveJson(
		`/trail/${encodeURIComponent(id)}/environment${querySuffix}`,
		{ method: "GET" },
		identity.deviceHash,
		resolveActorId(event),
	);
}
