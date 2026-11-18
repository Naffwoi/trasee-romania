import * as privateEnv from "$app/env/private";
import { xyzToEpsg3857Bbox } from "#lib/map/dynamic_raster_overlays.ts";
import type { RequestEvent } from "@sveltejs/kit";

export async function GET(event: RequestEvent) {
	const tpl = ((privateEnv as Record<string, string | undefined>).ANCPI_ORTHO_URL_TEMPLATE ?? "").trim();
	if (!tpl) {
		return new Response("ANCPI_ORTHO_URL_TEMPLATE not configured", { status: 404 });
	}
	const z = Number(event.params.z);
	const x = Number(event.params.x);
	const y = Number(event.params.y);
	if (!Number.isInteger(z) || z < 0 || z > 20 || !Number.isInteger(x) || !Number.isInteger(y)) {
		return new Response("Invalid tile coordinates", { status: 400 });
	}

	let upstreamUrl = tpl
		.replace("{z}", String(z))
		.replace("{x}", String(x))
		.replace("{y}", String(y));
	if (upstreamUrl.includes("{bbox-epsg-3857}")) {
		const [minX, minY, maxX, maxY] = xyzToEpsg3857Bbox(z, x, y);
		upstreamUrl = upstreamUrl.replace("{bbox-epsg-3857}", `${minX},${minY},${maxX},${maxY}`);
	}

	try {
		const upstream = await fetch(upstreamUrl, { signal: AbortSignal.timeout(8_000) });
		if (!upstream.ok) {
			return new Response(null, { status: upstream.status });
		}
		const buf = await upstream.arrayBuffer();
		return new Response(buf, {
			status: 200,
			headers: {
				"Content-Type": upstream.headers.get("content-type") ?? "image/jpeg",
				"Cache-Control": "public, max-age=86400",
			},
		});
	} catch {
		return new Response(null, { status: 502 });
	}
}
