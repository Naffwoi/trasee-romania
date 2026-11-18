import { proxyJsonResponse } from "#lib/server/http.ts";
import {
	CLIENT_SOS_ID_RE,
	forwardLiveToDb,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
	SOS_CLAIM_SECRET_RE,
} from "#lib/server/live/device_identity.ts";
import {
	dispatchSosPushNotifications,
	type SosPushAlertInfo,
	type SosPushTarget,
} from "#lib/server/live/vapid_push.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function POST(event: RequestEvent) {
	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.sos.enforce(identity.deviceHash);
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

	let clientSosId: string | undefined;
	if (body.clientSosId !== undefined && body.clientSosId !== null && body.clientSosId !== "") {
		if (typeof body.clientSosId !== "string" || !CLIENT_SOS_ID_RE.test(body.clientSosId.trim())) {
			return Response.json({ message: "invalid_client_sos_id" }, { status: 400 });
		}
		clientSosId = body.clientSosId.trim().toLowerCase();
	}

	let sosClaimSecret: string | undefined;
	if (
		body.sosClaimSecret !== undefined &&
		body.sosClaimSecret !== null &&
		body.sosClaimSecret !== ""
	) {
		if (
			typeof body.sosClaimSecret !== "string" ||
			!SOS_CLAIM_SECRET_RE.test(body.sosClaimSecret.trim())
		) {
			return Response.json({ message: "invalid_sos_claim_secret" }, { status: 400 });
		}
		sosClaimSecret = body.sosClaimSecret.trim().toLowerCase();
	}

	const actorId = resolveActorId(event);

	let upstream: Response;
	try {
		upstream = await forwardLiveToDb(
			"/sos",
			{
				method: "POST",
				body: JSON.stringify({
					trailId: typeof body.trailId === "string" ? body.trailId : "",
					reason: typeof body.reason === "string" ? body.reason.trim() : "other",
					message: typeof body.message === "string" ? body.message : "",
					requesterName: typeof body.requesterName === "string" ? body.requesterName : "",
					lat,
					lon,
					ele: typeof body.ele === "number" && Number.isFinite(body.ele) ? body.ele : undefined,
					...(clientSosId !== undefined ? { clientSosId } : {}),
					...(sosClaimSecret !== undefined ? { sosClaimSecret } : {}),
				}),
			},
			identity.deviceHash,
			actorId,
		);
	} catch {
		return Response.json({ message: "backend_unavailable" }, { status: 503 });
	}

	if (!upstream.ok) {
		return proxyJsonResponse(upstream);
	}

	let upstreamJson: { sos?: SosPushAlertInfo; pushTargets?: SosPushTarget[] };
	try {
		upstreamJson = (await upstream.json()) as {
			sos?: SosPushAlertInfo;
			pushTargets?: SosPushTarget[];
		};
	} catch {
		return Response.json({ message: "invalid_backend_response" }, { status: 502 });
	}

	const sos = upstreamJson?.sos;
	const pushTargets = Array.isArray(upstreamJson?.pushTargets) ? upstreamJson.pushTargets : [];

	if (sos && pushTargets.length > 0) {
		void dispatchSosPushNotifications(sos, pushTargets, async (staleEndpoint) => {
			await forwardLiveToDb(
				"/push/subscribe",
				{
					method: "DELETE",
					body: JSON.stringify({ endpoint: staleEndpoint }),
				},
				identity.deviceHash,
				actorId,
			);
		}).catch((err) => {
			console.error("[live/sos] Web Push dispatch failed:", err);
		});
	}

	return Response.json({ sos }, { status: upstream.status });
}
