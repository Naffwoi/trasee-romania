import { createServer, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { expect, test } from "@playwright/test";

test.describe("Live SSE Last-Event-ID replay & compact delta protocol", () => {
	let server: Server;
	let baseUrl = "";
	let activeSseRes: ServerResponse | null = null;
	const ringBuffer: Array<{ id: number; event: string; data: Record<string, unknown> }> = [];
	const seenLastEventIds: string[] = [];

	test.beforeEach(async () => {
		ringBuffer.length = 0;
		seenLastEventIds.length = 0;
		activeSseRes = null;

		server = createServer((req, res) => {
			const url = new URL(req.url ?? "/", "http://127.0.0.1");
			if (url.pathname === "/") {
				res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
				res.end(`<!doctype html><html><body><div id="log"></div>
<script>
let lastId = "";
const received = [];
window.__received = received;
function openStream() {
  const qs = lastId ? "?lastEventId=" + encodeURIComponent(lastId) : "";
  const es = new EventSource("/api/v1/live/stream" + qs);
  es.addEventListener("sos_update", (e) => {
    if (e.lastEventId) lastId = e.lastEventId;
    received.push(JSON.parse(e.data));
    document.getElementById("log").textContent = received.map((x) => x.id).join(",");
  });
  es.onerror = () => {
    es.close();
    setTimeout(openStream, 150);
  };
}
openStream();
</script></body></html>`);
				return;
			}

			if (url.pathname === "/api/v1/live/stream") {
				const resumeFrom = Number(
					req.headers["last-event-id"] ?? url.searchParams.get("lastEventId") ?? "0",
				);
				seenLastEventIds.push(String(resumeFrom));
				res.writeHead(200, {
					"Content-Type": "text/event-stream",
					"Cache-Control": "no-cache",
					Connection: "keep-alive",
				});
				res.write(": connected\n\n");
				for (const item of ringBuffer) {
					if (item.id > resumeFrom) {
						res.write(`id: ${item.id}\nevent: ${item.event}\ndata: ${JSON.stringify(item.data)}\n\n`);
					}
				}
				activeSseRes = res;
				return;
			}
			res.writeHead(404).end();
		});

		await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
		const port = (server.address() as AddressInfo).port;
		baseUrl = `http://127.0.0.1:${port}`;
	});

	test.afterEach(async () => {
		activeSseRes?.end();
		await new Promise<void>((resolve) => server.close(() => resolve()));
	});

	test("replays missed SOS alert via Last-Event-ID after a simulated cell-tower drop", async ({
		page,
	}) => {
		await page.goto(baseUrl);
		await expect.poll(() => seenLastEventIds.length).toBeGreaterThanOrEqual(1);

		const ev1 = { id: "sos-1", status: "active", reason: "injury" };
		ringBuffer.push({ id: 101, event: "sos_update", data: ev1 });
		activeSseRes?.write(`id: 101\nevent: sos_update\ndata: ${JSON.stringify(ev1)}\n\n`);
		await expect(page.locator("#log")).toHaveText("sos-1");

		activeSseRes?.destroy();
		ringBuffer.push({
			id: 102,
			event: "sos_update",
			data: { id: "sos-2-missed-in-tunnel", status: "active", reason: "lost" },
		});

		await expect(page.locator("#log")).toHaveText("sos-1,sos-2-missed-in-tunnel");
		expect(seenLastEventIds).toContain("101");
	});
});
