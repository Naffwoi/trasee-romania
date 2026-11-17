import { proxyJsonResponse } from "#lib/server/http.ts";
import {
	forwardLiveToDb,
	resolveActorId,
	resolveDeviceIdentity,
} from "#lib/server/live/device_identity.ts";
import type { RequestEvent } from "@sveltejs/kit";

const STREAM_CONNECT_TIMEOUT_MS = 15_000;

export async function GET(event: RequestEvent) {
	const identity = resolveDeviceIdentity(event, {
		optional: true,
		allowQueryToken: true,
	});
	if (!identity.ok) {
		return identity.response;
	}

	const forwardParams = new URLSearchParams();
	for (const key of ["lat", "lon", "trailId"]) {
		const val = event.url.searchParams.get(key);
		if (val !== null && val.trim().length > 0) {
			forwardParams.set(key, val.trim());
		}
	}
	const qs = forwardParams.toString();
	const upstreamPath = qs ? `/stream?${qs}` : "/stream";

	const upstreamController = new AbortController();
	const onClientAbort = () => upstreamController.abort();
	if (event.request.signal.aborted) {
		upstreamController.abort();
	} else {
		event.request.signal.addEventListener("abort", onClientAbort, { once: true });
	}

	const connectTimeout = setTimeout(
		() => upstreamController.abort(),
		STREAM_CONNECT_TIMEOUT_MS,
	);

	let upstream: Response;
	try {
		upstream = await forwardLiveToDb(
			upstreamPath,
			{
				method: "GET",
				headers: {
					Accept: "text/event-stream",
				},
				signal: upstreamController.signal,
			},
			identity.deviceHash,
			resolveActorId(event),
		);
	} catch {
		clearTimeout(connectTimeout);
		event.request.signal.removeEventListener("abort", onClientAbort);
		return Response.json({ message: "backend_unavailable" }, { status: 503 });
	} finally {
		clearTimeout(connectTimeout);
	}

	if (!upstream.ok || !upstream.body) {
		event.request.signal.removeEventListener("abort", onClientAbort);
		upstreamController.abort();
		return proxyJsonResponse(upstream);
	}

	const reader = upstream.body.getReader();
	let closed = false;

	const cleanup = () => {
		if (closed) {
			return;
		}
		closed = true;
		event.request.signal.removeEventListener("abort", onClientAbort);
		upstreamController.abort();
		void reader
			.cancel()
			.catch(() => {})
			.finally(() => {
				try {
					reader.releaseLock();
				} catch {
					// Already released.
				}
			});
	};

	const stream = new ReadableStream<Uint8Array>({
		async pull(controller) {
			try {
				const { value, done } = await reader.read();
				if (done) {
					cleanup();
					controller.close();
					return;
				}
				if (value) {
					controller.enqueue(value);
				}
			} catch {
				cleanup();
				try {
					controller.close();
				} catch {
					// Stream already closed or cancelled.
				}
			}
		},
		cancel() {
			cleanup();
		},
	});

	return new Response(stream, {
		status: 200,
		headers: {
			"Content-Type": "text/event-stream",
			"Cache-Control": "no-cache",
			"X-Accel-Buffering": "no",
		},
	});
}
