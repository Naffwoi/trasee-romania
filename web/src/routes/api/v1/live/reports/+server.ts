import {
	forwardAndProxyLiveJson,
	liveRateLimiters,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

const MAX_PHOTO_BYTES = 2 * 1024 * 1024;

export async function POST(event: RequestEvent) {
	const identity = resolveDeviceIdentity(event);
	if (!identity.ok) {
		return identity.response;
	}

	const rateLimited = liveRateLimiters.reports.enforce(identity.deviceHash);
	if (rateLimited) {
		return rateLimited;
	}

	const contentType = (event.request.headers.get("content-type") ?? "").toLowerCase();

	if (contentType.startsWith("multipart/form-data")) {
		let form: FormData;
		try {
			form = await event.request.formData();
		} catch {
			return Response.json({ message: "invalid_multipart" }, { status: 400 });
		}

		const category = String(form.get("category") ?? "").trim();
		const lat = Number(form.get("lat"));
		const lon = Number(form.get("lon"));
		if (!category) {
			return Response.json({ message: "invalid_category" }, { status: 400 });
		}
		if (
			!Number.isFinite(lat) ||
			lat < -90 ||
			lat > 90 ||
			!Number.isFinite(lon) ||
			lon < -180 ||
			lon > 180
		) {
			return Response.json({ message: "invalid_coordinates" }, { status: 400 });
		}

		const upstreamForm = new FormData();
		upstreamForm.set("trailId", String(form.get("trailId") ?? ""));
		upstreamForm.set("category", category);
		upstreamForm.set("note", String(form.get("note") ?? ""));
		upstreamForm.set("lat", String(lat));
		upstreamForm.set("lon", String(lon));
		const ele = Number(form.get("ele"));
		if (Number.isFinite(ele)) upstreamForm.set("ele", String(ele));
		const along = Number(form.get("alongTrackM"));
		if (Number.isFinite(along)) upstreamForm.set("alongTrackM", String(along));
		upstreamForm.set("photoVerified", form.get("photoVerified") === "true" ? "true" : "false");

		const photoEntry = form.get("photo");
		if (photoEntry instanceof Blob && photoEntry.size > 0) {
			if (photoEntry.size > MAX_PHOTO_BYTES) {
				return Response.json({ message: "photo_too_large" }, { status: 413 });
			}
			const filename =
				photoEntry instanceof File && photoEntry.name ? photoEntry.name : "report.jpg";
			upstreamForm.set("photo", photoEntry, filename);
		}

		return forwardAndProxyLiveJson(
			"/reports",
			{ method: "POST", body: upstreamForm },
			identity.deviceHash,
			resolveActorId(event),
		);
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

	const category = typeof body.category === "string" ? body.category.trim() : "";
	const lat = Number(body.lat);
	const lon = Number(body.lon);
	if (!category) {
		return Response.json({ message: "invalid_category" }, { status: 400 });
	}
	if (
		!Number.isFinite(lat) ||
		lat < -90 ||
		lat > 90 ||
		!Number.isFinite(lon) ||
		lon < -180 ||
		lon > 180
	) {
		return Response.json({ message: "invalid_coordinates" }, { status: 400 });
	}

	return forwardAndProxyLiveJson(
		"/reports",
		{
			method: "POST",
			body: JSON.stringify({
				trailId: typeof body.trailId === "string" ? body.trailId : "",
				category,
				note: typeof body.note === "string" ? body.note : "",
				lat,
				lon,
				ele: typeof body.ele === "number" && Number.isFinite(body.ele) ? body.ele : undefined,
				alongTrackM:
					typeof body.alongTrackM === "number" && Number.isFinite(body.alongTrackM)
						? body.alongTrackM
						: undefined,
			}),
		},
		identity.deviceHash,
		resolveActorId(event),
	);
}
