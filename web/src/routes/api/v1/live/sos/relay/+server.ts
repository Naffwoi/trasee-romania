import { proxyJsonResponse } from "#lib/server/http.ts";
import {
	CLIENT_SOS_ID_RE,
	forwardLiveToDb,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
	SOS_CLAIM_HASH_RE,
	SOS_CLAIM_SECRET_RE,
} from "#lib/server/live/device_identity.ts";
import {
	dispatchSosPushNotifications,
	type SosPushAlertInfo,
	type SosPushTarget,
} from "#lib/server/live/vapid_push.ts";
import type { RequestEvent } from "@sveltejs/kit";

function parseFiniteCoordinate(raw: unknown): number | null {
	if (raw === undefined || raw === null || raw === "" || typeof raw === "boolean") {
		return null;
	}
	const num = Number(raw);
	return Number.isFinite(num) ? num : null;
}

export async function POST(event: RequestEvent) {
	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.sosRelay.enforce(identity.deviceHash);
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

	const rawClientSosId = typeof body.clientSosId === "string" ? body.clientSosId.trim() : "";
	if (!CLIENT_SOS_ID_RE.test(rawClientSosId)) {
		return Response.json({ message: "invalid_client_sos_id" }, { status: 400 });
	}
	const clientSosId = rawClientSosId.toLowerCase();

	const rawStatus = typeof body.status === "string" ? body.status.trim().toLowerCase() : "";
	if (rawStatus && rawStatus !== "active" && rawStatus !== "resolved" && rawStatus !== "cancelled") {
		return Response.json({ message: "invalid_status" }, { status: 400 });
	}
	const isResolved = rawStatus === "resolved" || rawStatus === "cancelled";

	let sosClaimHash: string | undefined;
	if (body.sosClaimHash !== undefined && body.sosClaimHash !== null && body.sosClaimHash !== "") {
		if (typeof body.sosClaimHash !== "string" || !SOS_CLAIM_HASH_RE.test(body.sosClaimHash.trim())) {
			return Response.json({ message: "invalid_sos_claim_hash" }, { status: 400 });
		}
		sosClaimHash = body.sosClaimHash.trim().toLowerCase();
	} else if (!isResolved) {
		return Response.json({ message: "invalid_sos_claim_hash" }, { status: 400 });
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

	const payload: Record<string, unknown> = {
		clientSosId,
	};
	if (sosClaimHash !== undefined) {
		payload.sosClaimHash = sosClaimHash;
	}
	if (rawStatus) {
		payload.status = rawStatus;
	}
	if (sosClaimSecret !== undefined) {
		payload.sosClaimSecret = sosClaimSecret;
	}

	const hasLat = body.lat !== undefined && body.lat !== null && body.lat !== "";
	const hasLon = body.lon !== undefined && body.lon !== null && body.lon !== "";

	if (!isResolved || hasLat || hasLon) {
		const lat = parseFiniteCoordinate(body.lat);
		const lon = parseFiniteCoordinate(body.lon);
		if (lat === null || lat < -90 || lat > 90 || lon === null || lon < -180 || lon > 180) {
			return Response.json({ message: "invalid_coordinates" }, { status: 400 });
		}
		payload.lat = lat;
		payload.lon = lon;
	}

	if (!isResolved || typeof body.trailId === "string") {
		payload.trailId = typeof body.trailId === "string" ? body.trailId.trim() : "";
	}
	if (!isResolved || typeof body.reason === "string") {
		const trimmedReason = typeof body.reason === "string" ? body.reason.trim() : "";
		payload.reason = trimmedReason || "other";
	}
	if (!isResolved || typeof body.message === "string") {
		payload.message = typeof body.message === "string" ? body.message : "";
	}
	if (!isResolved || typeof body.requesterName === "string") {
		payload.requesterName = typeof body.requesterName === "string" ? body.requesterName : "";
	}
	if (typeof body.ele === "number" && Number.isFinite(body.ele)) {
		payload.ele = body.ele;
	}
	if (typeof body.packetEpochSec === "number" && Number.isFinite(body.packetEpochSec)) {
		payload.packetEpochSec = Math.trunc(body.packetEpochSec);
	}
	if (typeof body.hopCount === "number" && Number.isFinite(body.hopCount) && body.hopCount >= 0) {
		payload.hopCount = Math.trunc(body.hopCount);
	}

	const actorId = resolveActorId(event);

	let upstream: Response;
	try {
		upstream = await forwardLiveToDb(
			"/sos/relay",
			{
				method: "POST",
				body: JSON.stringify(payload),
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

	let upstreamJson: {
		sos?: SosPushAlertInfo;
		pushTargets?: SosPushTarget[];
		created?: boolean;
	};
	try {
		upstreamJson = (await upstream.json()) as {
			sos?: SosPushAlertInfo;
			pushTargets?: SosPushTarget[];
			created?: boolean;
		};
	} catch {
		return Response.json({ message: "invalid_backend_response" }, { status: 502 });
	}

	const sos = upstreamJson?.sos;
	const pushTargets = Array.isArray(upstreamJson?.pushTargets) ? upstreamJson.pushTargets : [];

	if (upstreamJson?.created === true && sos && pushTargets.length > 0) {
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
			console.error("[live/sos/relay] Web Push dispatch failed:", err);
		});
	}

	return Response.json({ sos }, { status: upstream.status });
}
