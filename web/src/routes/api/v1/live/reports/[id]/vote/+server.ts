import {
	forwardAndProxyLiveJson,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function POST(event: RequestEvent) {
	const id = event.params.id?.trim();
	if (!id) {
		return Response.json({ message: "invalid_report_id" }, { status: 400 });
	}

	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.votes.enforce(identity.deviceHash);
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

	const vote = typeof body.vote === "string" ? body.vote.trim() : "";
	if (!vote) {
		return Response.json({ message: "invalid_vote" }, { status: 400 });
	}

	return forwardAndProxyLiveJson(
		`/reports/${encodeURIComponent(id)}/vote`,
		{
			method: "POST",
			body: JSON.stringify({ vote }),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
