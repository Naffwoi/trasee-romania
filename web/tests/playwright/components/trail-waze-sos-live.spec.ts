import { createHmac } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { compile, compileModule } from "svelte/compiler";
import { build } from "vite";
import { loadFontawesome } from "./fontawesome-fixture";

const webRoot = fileURLToPath(new URL("../../../", import.meta.url));
const maplibreDist = fileURLToPath(
    new URL("../../../node_modules/maplibre-gl/dist/", import.meta.url),
);

const TEST_PROXY_SECRET = "e2e-live-hmac-secret";
const PRESENCE_WINDOW_MS = 30 * 60_000;
const LIVE_PRESENCE_WINDOW_MS = 2 * 60_000;
const PRESENCE_AREA_RADIUS_METERS = 2_000;
const LIVE_RADIUS_METERS = 5_000;

const CATEGORY_META: Record<
    string,
    { kind: string; isPermanent: boolean; ttlMs: number }
> = {
    bear: { kind: "hazard", isPermanent: false, ttlMs: 3 * 3_600_000 },
    deer: { kind: "wildlife_good", isPermanent: false, ttlMs: 3 * 3_600_000 },
    shepherd_dogs: { kind: "hazard", isPermanent: false, ttlMs: 24 * 3_600_000 },
    ice_mud: { kind: "hazard", isPermanent: false, ttlMs: 48 * 3_600_000 },
    fallen_tree_terrain: { kind: "hazard", isPermanent: false, ttlMs: 14 * 24 * 3_600_000 },
    spring: { kind: "landmark_permanent", isPermanent: true, ttlMs: 0 },
    viewpoint: { kind: "landmark_permanent", isPermanent: true, ttlMs: 0 },
    shelter: { kind: "landmark_permanent", isPermanent: true, ttlMs: 0 },
};

function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const R = 6_371_000;
    const toRad = (deg: number) => (deg * Math.PI) / 180;
    const dLat = toRad(lat2 - lat1);
    const dLon = toRad(lon2 - lon1);
    const a =
        Math.sin(dLat / 2) ** 2 +
        Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
    return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function buildSampleTrailGpx(): string {
    const pts: Array<{ lat: number; lon: number; ele: number }> = [];
    for (let i = 0; i <= 30; i++) {
        pts.push({
            lat: 45.44 + i * 0.00045,
            lon: 25.55,
            ele: Math.round(920 + i * 7),
        });
    }
    const trkpts = pts
        .map(
            (p) =>
                `      <trkpt lat="${p.lat.toFixed(6)}" lon="${p.lon.toFixed(6)}"><ele>${p.ele}</ele></trkpt>`,
        )
        .join("\n");

    return `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="wanderer-live-e2e" xmlns="http://www.topografix.com/GPX/1/1">
  <trk>
    <name>Bucegi - Poteca Live E2E</name>
    <trkseg>
${trkpts}
    </trkseg>
  </trk>
</gpx>`;
}

const sampleTrail = {
    id: "trail-live-waze-sos-1",
    name: "Bucegi - Poteca Live E2E",
    author: "actor-ro",
    lat: 45.44,
    lon: 25.55,
    photos: [],
    public: true,
    completed: false,
    tags: [],
    like_count: 0,
    distance: 1500,
    duration: 2700,
    elevation_gain: 210,
    elevation_loss: 20,
    category: "cat-hiking",
    expand: {
        category: { id: "cat-hiking", name: "Hiking", icon: "fa-person-hiking" },
        waypoints_via_trail: [],
        gpx_data: buildSampleTrailGpx(),
    },
};

async function buildNavigatePageBundle(): Promise<string> {
    const pagePath = resolve(
        webRoot,
        "src/routes/map/trail/[handle]/[id]/navigate/+page.svelte",
    );
    const mjsPath = resolve(webRoot, "node_modules/maplibre-gl/dist/maplibre-gl.mjs");
    const engineSource = await readFile(mjsPath, "utf8");
    const engineExports = engineSource
        .slice(engineSource.lastIndexOf("export{") + 7, engineSource.lastIndexOf("}"))
        .split(",")
        .map((part) => part.split(" as ").pop()!.trim())
        .filter(Boolean);
    const roLocaleJson = readFileSync(
        resolve(webRoot, "src/lib/i18n/locales/ro.json"),
        "utf8",
    );

    const result = await build({
        root: webRoot,
        configFile: false,
        logLevel: "error",
        resolve: { conditions: ["browser", "production"] },
        plugins: [
            tailwindcss(),
            {
                name: "navigate-live-e2e-fixture",
                enforce: "pre",
                resolveId(id) {
                    if (id.startsWith("fixture:")) return `\0${id}`;
                    if (id === "$app/env") return "\0fixture:env";
                    if (id === "$app/navigation") return "\0fixture:navigation";
                    if (id === "$app/state") return "\0fixture:state.svelte.js";
                    if (id === "svelte-i18n") return "\0fixture:i18n";
                    if (
                        id === "maplibre-gl/dist/maplibre-gl.css" ||
                        id === "#lib/util/maplibre_worker.ts"
                    ) {
                        return "\0fixture:empty";
                    }
                    if (id === "maplibre-gl") return "\0fixture:maplibre";
                    if (id.startsWith("#lib/")) {
                        const [cleanId, query] = id.split("?");
                        const target = resolve(webRoot, "src/lib", cleanId.slice(5));
                        const resolved = extname(cleanId)
                            ? target
                            : [target + ".ts", target + ".js"].find(existsSync);
                        return resolved && query ? `${resolved}?${query}` : resolved;
                    }
                },
                async load(id) {
                    if (id === "\0fixture:empty") return "export default {};";
                    if (id === "\0fixture:env") {
                        return 'export const browser = true; export const dev = false; export const building = false; export const version = "fixture";';
                    }
                    if (id === "\0fixture:maplibre") {
                        return `const M = window.RealMapLibre; export default M; export const { ${engineExports.join(", ")} } = M;`;
                    }
                    if (id === "\0fixture:state.svelte.js") {
                        return compileModule(
                            `
                            export const page = $state({
                                url: new URL(location.href),
                                params: { handle: "@romania", id: "trail-live-waze-sos-1" },
                                state: {},
                                route: { id: "/map/trail/[handle]/[id]/navigate" },
                                data: { settings: { unit: "metric" } },
                            });
                            `,
                            {
                                filename: "fixture-state.svelte.js",
                                generate: "client",
                                dev: false,
                            },
                        ).js.code;
                    }
                    if (id === "\0fixture:navigation") {
                        return `
                            export function goto(url) { window.__navGotoCalls = (window.__navGotoCalls || []); window.__navGotoCalls.push(url); return Promise.resolve(); }
                            export function beforeNavigate() {}
                            export function pushState() {}
                            export function replaceState() {}
                        `;
                    }
                    if (id === "\0fixture:i18n") {
                        return `
                            import { writable } from "svelte/store";
                            const messages = ${roLocaleJson};
                            function translate(key, opts) {
                                let template = messages[key] ?? opts?.default ?? key;
                                if (typeof template === "string" && opts?.values) {
                                    for (const [k, v] of Object.entries(opts.values)) {
                                        template = template.replaceAll("{" + k + "}", String(v));
                                    }
                                }
                                return template;
                            }
                            export const _ = writable(translate);
                            export const t = _;
                            export const locale = writable("ro");
                        `;
                    }
                    if (id === "\0fixture:entry") {
                        return `
                            import { mount, unmount } from "svelte";
                            import NavigatePage from ${JSON.stringify(pagePath)};
                            import ${JSON.stringify(resolve(webRoot, "src/css/app.css"))};
                            import ${JSON.stringify(resolve(webRoot, "src/css/components.css"))};
                            import ${JSON.stringify(resolve(webRoot, "src/css/theme.css"))};

                            document.documentElement.classList.add("light");
                            const app = mount(NavigatePage, {
                                target: document.body,
                                props: { data: { trail: window.__testTrail } },
                            });
                            window.__unmountNav = () => unmount(app);
                        `;
                    }
                    if (id.endsWith(".svelte")) {
                        const source = await readFile(id, "utf8");
                        return compile(source, {
                            filename: id,
                            generate: "client",
                            dev: false,
                            css: "injected",
                        }).js.code;
                    }
                },
            },
        ],
        build: {
            write: false,
            minify: false,
            rolldownOptions: { input: "fixture:entry", output: { format: "iife" } },
        },
    });

    if (Array.isArray(result) || !("output" in result)) {
        throw new Error("Expected a single bundle");
    }
    const chunk = result.output.find((o) => o.type === "chunk");
    if (!chunk) throw new Error("Missing bundle chunk");
    const css = result.output
        .flatMap((o) =>
            o.type === "asset" && o.fileName.endsWith(".css") ? [String(o.source)] : [],
        )
        .join("\n");
    return `document.head.appendChild(Object.assign(document.createElement("style"), { textContent: ${JSON.stringify(css)} }));\n${chunk.code}`;
}

interface StoredReport {
    id: string;
    trailId: string;
    category: string;
    kind: string;
    isPermanent: boolean;
    conditionStatus: "active" | "dry_or_closed" | "resolved" | "spam_hidden";
    note: string;
    lat: number;
    lon: number;
    ele: number;
    alongTrackM: number;
    confirmCount: number;
    dismissCount: number;
    spamCount: number;
    createdAt: string;
    lastConfirmedAt: string;
    expiresAt: string | null;
    votesByDevice: Map<string, string>;
}

interface StoredResponder {
    deviceHash: string;
    status: "coming" | "cancelled";
    lat: number;
    lon: number;
    ele: number;
    distanceM: number;
    etaSec: number;
    lastSeenMs: number;
}

interface StoredSos {
    id: string;
    trailId: string;
    status: "active" | "resolved" | "cancelled";
    reason: string;
    message: string;
    requesterName: string;
    lat: number;
    lon: number;
    ele: number;
    ownerDeviceHash: string;
    createdAt: string;
    expiresAt: string;
    responders: Map<string, StoredResponder>;
}

interface SseClient {
    res: ServerResponse;
    deviceHash: string;
    trailId: string;
    lat: number | null;
    lon: number | null;
}

class LiveCommunityTestServer {
    private server!: Server;
    public baseUrl = "";
    public clockOffsetMs = 0;

    public presence = new Map<
        string,
        { trailId: string; lat: number; lon: number; ele: number; lastSeenMs: number }
    >();
    public reports = new Map<string, StoredReport>();
    public sosAlerts = new Map<string, StoredSos>();
    private sseClients = new Set<SseClient>();
    private nextSeq = 1;

    public nowMs(): number {
        return Date.now() + this.clockOffsetMs;
    }

    private hashDeviceToken(token: string | null): string {
        if (!token || token.trim().length < 24) return "";
        return createHmac("sha256", TEST_PROXY_SECRET).update(token.trim()).digest("hex");
    }

    private readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
        return new Promise((resolvePromise, rejectPromise) => {
            const chunks: Buffer[] = [];
            req.on("data", (c: Buffer) => chunks.push(c));
            req.on("end", () => {
                const raw = Buffer.concat(chunks).toString("utf8").trim();
                if (!raw) {
                    resolvePromise({});
                    return;
                }
                try {
                    resolvePromise(JSON.parse(raw) as Record<string, unknown>);
                } catch (err) {
                    rejectPromise(err);
                }
            });
            req.on("error", rejectPromise);
        });
    }

    private serializeReport(r: StoredReport) {
        return {
            id: r.id,
            trailId: r.trailId,
            category: r.category,
            kind: r.kind,
            isPermanent: r.isPermanent,
            conditionStatus: r.conditionStatus,
            note: r.note,
            lat: r.lat,
            lon: r.lon,
            ele: r.ele,
            alongTrackM: r.alongTrackM,
            confirmCount: r.confirmCount,
            dismissCount: r.dismissCount,
            createdAt: r.createdAt,
            lastConfirmedAt: r.lastConfirmedAt,
            expiresAt: r.isPermanent ? null : r.expiresAt,
        };
    }

    private isReportVisible(r: StoredReport, now: number): boolean {
        if (r.conditionStatus !== "active" && r.conditionStatus !== "dry_or_closed") {
            return false;
        }
        if (r.isPermanent) return true;
        if (!r.expiresAt) return true;
        return Date.parse(r.expiresAt) >= now;
    }

    private serializeSosForDevice(s: StoredSos, callerHash: string, now: number) {
        const activeResponders = [...s.responders.values()].filter(
            (resp) =>
                resp.status === "coming" && now - resp.lastSeenMs <= PRESENCE_WINDOW_MS,
        );
        let nearestDistanceM: number | null = null;
        let nearestEtaSec: number | null = null;
        for (const resp of activeResponders) {
            if (nearestDistanceM === null || resp.distanceM < nearestDistanceM) {
                nearestDistanceM = Math.round(resp.distanceM);
            }
            if (nearestEtaSec === null || resp.etaSec < nearestEtaSec) {
                nearestEtaSec = Math.round(resp.etaSec);
            }
        }
        return {
            id: s.id,
            trailId: s.trailId,
            status: s.status,
            reason: s.reason,
            message: s.message,
            requesterName: s.requesterName,
            lat: s.lat,
            lon: s.lon,
            ele: s.ele,
            responderCount: activeResponders.length,
            nearestEtaSec,
            nearestDistanceM,
            isMine: Boolean(callerHash && callerHash === s.ownerDeviceHash),
            amResponding: activeResponders.some((r) => r.deviceHash === callerHash),
            createdAt: s.createdAt,
            expiresAt: s.expiresAt,
        };
    }

    private countActiveNearby(
        refLat: number,
        refLon: number,
        callerHash: string,
        now: number,
    ): number {
        let count = 0;
        for (const [dh, p] of this.presence.entries()) {
            if (callerHash && dh === callerHash) continue;
            if (now - p.lastSeenMs > LIVE_PRESENCE_WINDOW_MS) continue;
            if (haversineMeters(refLat, refLon, p.lat, p.lon) <= PRESENCE_AREA_RADIUS_METERS) {
                count++;
            }
        }
        return count;
    }

    private broadcastReport(r: StoredReport) {
        const dto = this.serializeReport(r);
        const payload = JSON.stringify({
            ...dto,
            type: "report_update",
            report: dto,
        });
        for (const client of this.sseClients) {
            const sameTrail = Boolean(r.trailId && client.trailId === r.trailId);
            const nearby =
                client.lat !== null &&
                client.lon !== null &&
                haversineMeters(client.lat, client.lon, r.lat, r.lon) <= LIVE_RADIUS_METERS;
            if (sameTrail || nearby) {
                client.res.write(`event: report_update\ndata: ${payload}\n\n`);
            }
        }
    }

    private broadcastSos(s: StoredSos) {
        const now = this.nowMs();
        for (const client of this.sseClients) {
            const isOwner = Boolean(
                client.deviceHash && client.deviceHash === s.ownerDeviceHash,
            );
            const isResponder = Boolean(
                client.deviceHash && s.responders.get(client.deviceHash)?.status === "coming",
            );
            const sameTrail = Boolean(s.trailId && client.trailId === s.trailId);
            const nearby =
                client.lat !== null &&
                client.lon !== null &&
                haversineMeters(client.lat, client.lon, s.lat, s.lon) <= LIVE_RADIUS_METERS;
            if (isOwner || isResponder || sameTrail || nearby) {
                const dto = this.serializeSosForDevice(s, client.deviceHash, now);
                const payload = JSON.stringify({
                    ...dto,
                    type: "sos_update",
                    sos: dto,
                });
                client.res.write(`event: sos_update\ndata: ${payload}\n\n`);
            }
        }
    }

    private sendJson(res: ServerResponse, status: number, data: unknown) {
        res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify(data));
    }

    public async start(): Promise<void> {
        this.server = createServer(async (req, res) => {
            const url = new URL(req.url ?? "/", "http://127.0.0.1");
            const pathname = url.pathname;
            const method = req.method ?? "GET";

            // Static MapLibre & test HTML shell
            if (pathname.startsWith("/maplibre/")) {
                const name = pathname.split("/").at(-1)!;
                const body = await readFile(maplibreDist + name, "utf8");
                res.writeHead(200, {
                    "Content-Type": name.endsWith(".css")
                        ? "text/css; charset=utf-8"
                        : "text/javascript; charset=utf-8",
                });
                res.end(body);
                return;
            }

            if (pathname === "/styles/ofm.json") {
                this.sendJson(res, 200, {
                    version: 8,
                    sources: {},
                    layers: [
                        {
                            id: "background",
                            type: "background",
                            paint: { "background-color": "#dae5df" },
                        },
                    ],
                });
                return;
            }

            if (pathname.startsWith("/fonts/")) {
                res.writeHead(404);
                res.end("");
                return;
            }

            if (!pathname.startsWith("/api/v1/live/")) {
                // Default HTML shell for /map/trail/@romania/<id>/navigate
                res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
                res.end(`<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/maplibre/maplibre-gl.css">
</head>
<body>
<script type="module">
import * as M from "/maplibre/maplibre-gl.mjs";
const OrigMap = M.Map;
window.RealMapLibre = {
    ...M,
    Map: class extends OrigMap {
        constructor(opts) {
            super(opts);
            window.realMap = this;
        }
    },
};
</script>
</body>
</html>`);
                return;
            }

            // Live Community API endpoints (/api/v1/live/*)
            const headerToken =
                typeof req.headers["x-device-token"] === "string"
                    ? req.headers["x-device-token"]
                    : null;
            const queryToken = url.searchParams.get("deviceToken");
            const deviceHash = this.hashDeviceToken(headerToken ?? queryToken);
            const now = this.nowMs();

            if (pathname === "/api/v1/live/stream" && method === "GET") {
                res.writeHead(200, {
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    Connection: "keep-alive",
                });
                res.write(": connected\n\n");
                const latParam = url.searchParams.get("lat");
                const lonParam = url.searchParams.get("lon");
                const client: SseClient = {
                    res,
                    deviceHash,
                    trailId: url.searchParams.get("trailId") ?? "",
                    lat: latParam !== null ? Number(latParam) : null,
                    lon: lonParam !== null ? Number(lonParam) : null,
                };
                this.sseClients.add(client);
                req.on("close", () => {
                    this.sseClients.delete(client);
                });
                return;
            }

            if (pathname === "/api/v1/live/push/vapid-public-key" && method === "GET") {
                this.sendJson(res, 200, {
                    publicKey:
                        "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U",
                });
                return;
            }

            if (pathname === "/api/v1/live/push/subscribe") {
                this.sendJson(res, 200, { ok: true });
                return;
            }

            const summaryMatch = pathname.match(/^\/api\/v1\/live\/trail\/([^/]+)\/summary$/);
            if (summaryMatch && method === "GET") {
                const trailId = decodeURIComponent(summaryMatch[1]);
                const qLat = Number(url.searchParams.get("lat") ?? sampleTrail.lat);
                const qLon = Number(url.searchParams.get("lon") ?? sampleTrail.lon);
                const reports = [...this.reports.values()]
                    .filter((r) => r.trailId === trailId && this.isReportVisible(r, now))
                    .map((r) => this.serializeReport(r));
                const sosAlerts = [...this.sosAlerts.values()]
                    .filter((s) => s.status === "active" && s.trailId === trailId)
                    .map((s) => this.serializeSosForDevice(s, deviceHash, now));
                this.sendJson(res, 200, {
                    trailId,
                    activeHikers30m: this.countActiveNearby(qLat, qLon, deviceHash, now),
                    reports,
                    sosAlerts,
                });
                return;
            }

            if (!deviceHash) {
                this.sendJson(res, 400, { message: "invalid_device_token" });
                return;
            }

            if (pathname === "/api/v1/live/heartbeat" && method === "DELETE") {
                this.presence.delete(deviceHash);
                this.sendJson(res, 200, { ok: true });
                return;
            }

            if (pathname === "/api/v1/live/heartbeat" && method === "POST") {
                const body = await this.readBody(req);
                const trailId = String(body.trailId ?? "");
                const lat = Number(body.lat ?? 0);
                const lon = Number(body.lon ?? 0);
                const ele = Number(body.ele ?? 0);
                this.presence.set(deviceHash, {
                    trailId,
                    lat,
                    lon,
                    ele,
                    lastSeenMs: now,
                });

                const reports = [...this.reports.values()]
                    .filter(
                        (r) =>
                            this.isReportVisible(r, now) &&
                            ((trailId && r.trailId === trailId) ||
                                haversineMeters(lat, lon, r.lat, r.lon) <= LIVE_RADIUS_METERS),
                    )
                    .map((r) => this.serializeReport(r));
                const sosAlerts = [...this.sosAlerts.values()]
                    .filter(
                        (s) =>
                            s.status === "active" &&
                            (s.ownerDeviceHash === deviceHash ||
                                (trailId && s.trailId === trailId) ||
                                haversineMeters(lat, lon, s.lat, s.lon) <= LIVE_RADIUS_METERS),
                    )
                    .map((s) => this.serializeSosForDevice(s, deviceHash, now));

                const targetLat = trailId === sampleTrail.id ? sampleTrail.lat : lat;
                const targetLon = trailId === sampleTrail.id ? sampleTrail.lon : lon;
                this.sendJson(res, 200, {
                    activeHikers30m: this.countActiveNearby(targetLat, targetLon, deviceHash, now),
                    reports,
                    sosAlerts,
                });
                return;
            }

            if (pathname === "/api/v1/live/reports" && method === "POST") {
                const body = await this.readBody(req);
                const category = String(body.category ?? "");
                const meta = CATEGORY_META[category];
                if (!meta) {
                    this.sendJson(res, 400, { message: "invalid_category" });
                    return;
                }
                const id = `rep-${this.nextSeq++}`;
                const nowIso = new Date(now).toISOString();
                const stored: StoredReport = {
                    id,
                    trailId: String(body.trailId ?? ""),
                    category,
                    kind: meta.kind,
                    isPermanent: meta.isPermanent,
                    conditionStatus: "active",
                    note: String(body.note ?? "").slice(0, 160),
                    lat: Number(body.lat ?? 0),
                    lon: Number(body.lon ?? 0),
                    ele: Number(body.ele ?? 0),
                    alongTrackM: Number(body.alongTrackM ?? 0),
                    confirmCount: 1,
                    dismissCount: 0,
                    spamCount: 0,
                    createdAt: nowIso,
                    lastConfirmedAt: nowIso,
                    expiresAt: meta.isPermanent
                        ? null
                        : new Date(now + meta.ttlMs).toISOString(),
                    votesByDevice: new Map([[deviceHash, "confirm"]]),
                };
                this.reports.set(id, stored);
                this.broadcastReport(stored);
                this.sendJson(res, 200, { report: this.serializeReport(stored) });
                return;
            }

            const voteMatch = pathname.match(/^\/api\/v1\/live\/reports\/([^/]+)\/vote$/);
            if (voteMatch && method === "POST") {
                const reportId = decodeURIComponent(voteMatch[1]);
                const stored = this.reports.get(reportId);
                if (!stored) {
                    this.sendJson(res, 404, { message: "not_found" });
                    return;
                }
                const body = await this.readBody(req);
                const vote = String(body.vote ?? "");
                stored.votesByDevice.set(deviceHash, vote);

                let confirms = 0;
                let dismisses = 0;
                let spams = 0;
                for (const v of stored.votesByDevice.values()) {
                    if (v === "confirm" || v === "seasonal_ok") confirms++;
                    else if (v === "dismiss") dismisses++;
                    else if (v === "spam") spams++;
                }
                stored.confirmCount = confirms;
                stored.dismissCount = dismisses;
                stored.spamCount = spams;

                const nowIso = new Date(now).toISOString();
                const meta = CATEGORY_META[stored.category];
                if (vote === "confirm") {
                    stored.lastConfirmedAt = nowIso;
                    if (!stored.isPermanent && meta?.ttlMs) {
                        const candidateMs = now + meta.ttlMs;
                        const curMs = stored.expiresAt ? Date.parse(stored.expiresAt) : 0;
                        if (candidateMs > curMs) {
                            stored.expiresAt = new Date(candidateMs).toISOString();
                        }
                    }
                } else if (vote === "dismiss" && !stored.isPermanent) {
                    if (dismisses >= 3 || dismisses - confirms >= 2) {
                        stored.conditionStatus = "resolved";
                    }
                } else if (vote === "seasonal_dry" && stored.isPermanent) {
                    stored.conditionStatus = "dry_or_closed";
                    stored.lastConfirmedAt = nowIso;
                    stored.expiresAt = null;
                } else if (vote === "seasonal_ok" && stored.isPermanent) {
                    stored.conditionStatus = "active";
                    stored.lastConfirmedAt = nowIso;
                    stored.expiresAt = null;
                } else if (vote === "spam" && spams >= 5) {
                    stored.conditionStatus = "spam_hidden";
                }

                this.broadcastReport(stored);
                this.sendJson(res, 200, { report: this.serializeReport(stored) });
                return;
            }

            if (pathname === "/api/v1/live/sos" && method === "POST") {
                const body = await this.readBody(req);
                const id = `sos-${this.nextSeq++}`;
                const nowIso = new Date(now).toISOString();
                const sos: StoredSos = {
                    id,
                    trailId: String(body.trailId ?? ""),
                    status: "active",
                    reason: String(body.reason ?? "other"),
                    message: String(body.message ?? "").slice(0, 200),
                    requesterName: String(body.requesterName ?? "").slice(0, 40),
                    lat: Number(body.lat ?? 0),
                    lon: Number(body.lon ?? 0),
                    ele: Number(body.ele ?? 0),
                    ownerDeviceHash: deviceHash,
                    createdAt: nowIso,
                    expiresAt: new Date(now + 6 * 3_600_000).toISOString(),
                    responders: new Map(),
                };
                this.sosAlerts.set(id, sos);
                this.broadcastSos(sos);
                this.sendJson(res, 200, {
                    sos: this.serializeSosForDevice(sos, deviceHash, now),
                });
                return;
            }

            const sosRespondMatch = pathname.match(/^\/api\/v1\/live\/sos\/([^/]+)\/respond$/);
            if (sosRespondMatch && method === "POST") {
                const sosId = decodeURIComponent(sosRespondMatch[1]);
                const sos = this.sosAlerts.get(sosId);
                if (!sos) {
                    this.sendJson(res, 404, { message: "not_found" });
                    return;
                }
                const body = await this.readBody(req);
                const status = body.status === "cancelled" ? "cancelled" : "coming";
                const lat = Number(body.lat ?? 0);
                const lon = Number(body.lon ?? 0);
                const ele = Number(body.ele ?? 0);
                const distM =
                    Number(body.distanceM ?? 0) > 0
                        ? Number(body.distanceM)
                        : haversineMeters(lat, lon, sos.lat, sos.lon);
                const etaSec =
                    Number(body.etaSec ?? 0) > 0
                        ? Number(body.etaSec)
                        : Math.max(60, Math.round(distM / 1.1));
                sos.responders.set(deviceHash, {
                    deviceHash,
                    status,
                    lat,
                    lon,
                    ele,
                    distanceM: distM,
                    etaSec,
                    lastSeenMs: now,
                });
                this.broadcastSos(sos);
                this.sendJson(res, 200, {
                    sos: this.serializeSosForDevice(sos, deviceHash, now),
                });
                return;
            }

            const sosPatchMatch = pathname.match(/^\/api\/v1\/live\/sos\/([^/]+)$/);
            if (sosPatchMatch && method === "PATCH") {
                const sosId = decodeURIComponent(sosPatchMatch[1]);
                const sos = this.sosAlerts.get(sosId);
                if (!sos) {
                    this.sendJson(res, 404, { message: "not_found" });
                    return;
                }
                if (sos.ownerDeviceHash !== deviceHash) {
                    this.sendJson(res, 403, { message: "forbidden" });
                    return;
                }
                const body = await this.readBody(req);
                if (typeof body.status === "string") {
                    sos.status = body.status as StoredSos["status"];
                }
                if (typeof body.lat === "number") sos.lat = body.lat;
                if (typeof body.lon === "number") sos.lon = body.lon;
                if (typeof body.ele === "number") sos.ele = body.ele;
                this.broadcastSos(sos);
                this.sendJson(res, 200, {
                    sos: this.serializeSosForDevice(sos, deviceHash, now),
                });
                return;
            }

            // Default HTML shell for /map/trail/@romania/<id>/navigate
            res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
            res.end(`<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/maplibre/maplibre-gl.css">
</head>
<body>
<script type="module">
import * as M from "/maplibre/maplibre-gl.mjs";
const OrigMap = M.Map;
window.RealMapLibre = {
    ...M,
    Map: class extends OrigMap {
        constructor(opts) {
            super(opts);
            window.realMap = this;
        }
    },
};
</script>
</body>
</html>`);
        });

        await new Promise<void>((resolveListen) => {
            this.server.listen(0, "127.0.0.1", () => resolveListen());
        });
        const addr = this.server.address() as AddressInfo;
        this.baseUrl = `http://127.0.0.1:${addr.port}`;
    }

    public async stop(): Promise<void> {
        for (const client of this.sseClients) {
            try {
                client.res.end();
            } catch {
                // Ignore close error
            }
        }
        this.sseClients.clear();
        await new Promise<void>((resolveClose) => {
            this.server.close(() => resolveClose());
        });
    }
}

async function mountHikerPage(
    context: BrowserContext,
    baseUrl: string,
    bundle: string,
): Promise<Page> {
    await context.route(
        (url) => url.hostname !== "127.0.0.1",
        (route) => route.abort(),
    );

    const page = await context.newPage();
    await page.setViewportSize({ width: 390, height: 844 });
    page.on("pageerror", (err) => {
        throw err;
    });

    await page.addInitScript((trail) => {
        (window as unknown as Record<string, unknown>).__testTrail = trail;
        Object.defineProperty(navigator, "geolocation", {
            configurable: true,
            value: {
                watchPosition: () => 1,
                clearWatch: () => {},
            },
        });
    }, sampleTrail);

    await page.goto(`${baseUrl}/map/trail/@romania/${sampleTrail.id}/navigate`);
    await expect
        .poll(() =>
            page.evaluate(() =>
                Boolean((window as unknown as Record<string, unknown>).RealMapLibre),
            ),
        )
        .toBe(true);
    await page.addScriptTag({ content: bundle });
    await loadFontawesome(page);

    await expect
        .poll(() =>
            page.evaluate(() => {
                const w = window as unknown as {
                    realMap?: { loaded: () => boolean };
                    __wandererNavTest?: unknown;
                };
                return Boolean(w.realMap?.loaded()) && Boolean(w.__wandererNavTest);
            }),
        )
        .toBe(true);

    return page;
}

test.describe("Multi-User Trail Live Community (Waze Alerts, Permanent Landmarks, 30m Presence & 5km SOS DEM Rescue)", () => {
    let bundle: string;
    let liveServer: LiveCommunityTestServer;

    test.beforeAll(async () => {
        bundle = await buildNavigatePageBundle();
        liveServer = new LiveCommunityTestServer();
        await liveServer.start();
    });

    test.afterAll(async () => {
        await liveServer?.stop();
    });

    test("coordinates 2 hikers: 30m presence badge, temporary bear TTL extension vs permanent spring seasonal status, and 5km SOS DEM A* rescue route", async ({
        browser,
    }) => {
        const contextA = await browser.newContext();
        const contextB = await browser.newContext();

        try {
            const pageA = await mountHikerPage(contextA, liveServer.baseUrl, bundle);
            const pageB = await mountHikerPage(contextB, liveServer.baseUrl, bundle);

            // Verify each hiker minted a distinct persistent 64-char hex device token
            const tokenA = await pageA.evaluate(() =>
                window.localStorage.getItem("wanderer_device_token"),
            );
            const tokenB = await pageB.evaluate(() =>
                window.localStorage.getItem("wanderer_device_token"),
            );
            expect(tokenA).toMatch(/^[0-9a-f]{64}$/);
            expect(tokenB).toMatch(/^[0-9a-f]{64}$/);
            expect(tokenA).not.toBe(tokenB);

            // =========================================================================
            // (a) Icon-only Waze controls, Layer Switcher on /navigate & Location Presence
            // =========================================================================
            const sosBtnA = pageA.locator('[data-testid="nav-sos-btn"]');
            const reportBtnA = pageA.locator('[data-testid="nav-waze-report-btn"]');
            await expect(sosBtnA).toBeVisible();
            await expect(reportBtnA).toBeVisible();
            // Icon-only circular buttons: must NOT show aggressive "Ajutor" / "Raportează" text
            await expect(sosBtnA).not.toContainText("Ajutor");
            await expect(reportBtnA).not.toContainText("Raportează");
            const sosBox = (await sosBtnA.boundingBox())!;
            const reportBox = (await reportBtnA.boundingBox())!;
            expect(Math.abs(sosBox.width - sosBox.height)).toBeLessThanOrEqual(2);
            expect(Math.abs(reportBox.width - reportBox.height)).toBeLessThanOrEqual(2);

            // Layer switcher button works on /navigate and opens unclipped menu
            const navLayerBtn = pageA.locator('[data-testid="nav-layers-btn"], [aria-label="Comută straturile hărții"]').first();
            await expect(navLayerBtn).toBeVisible();
            await navLayerBtn.click();
            await expect(pageA.getByText("OpenTopoMap")).toBeVisible();
            await navLayerBtn.click();

            // Hiker A starts ~300 m North along trail -> alone in area (0 OTHERS), so badge MUST STAY HIDDEN!
            await pageA.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        pushFix: (f: Record<string, unknown>) => void;
                    };
                };
                w.__wandererNavTest.pushFix({
                    lat: 45.4427,
                    lon: 25.55,
                    ele: 962,
                    accuracy: 7,
                    speed: 1.2,
                    heading: 0,
                });
            });

            const badgeA = pageA.locator('[data-testid="active-hikers-badge"]');
            await expect(badgeA).toHaveCount(0);

            // Hiker B starts at trailhead (45.4400, 25.5500) -> sees 1 OTHER active person in area ("1 persoană în zonă", NEVER "30 min")!
            await pageB.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        pushFix: (f: Record<string, unknown>) => void;
                    };
                };
                w.__wandererNavTest.pushFix({
                    lat: 45.44,
                    lon: 25.55,
                    ele: 920,
                    accuracy: 7,
                    speed: 1.1,
                    heading: 0,
                });
            });

            const badgeB = pageB.locator('[data-testid="active-hikers-badge"]');
            await expect(badgeB).toHaveAttribute("data-active-count", "1");
            await expect(badgeB).toContainText("1 persoană în zonă");
            await expect(badgeB).not.toContainText("30 min");

            // =========================================================================
            // (b) 1-Tap Minimalist Waze Report Sheet (Temporary `bear` + Permanent `spring`)
            // =========================================================================
            // 1. Hiker A opens report sheet -> zero TTL clutter, optional note + 1-tap category submit!
            await pageA.locator('[data-testid="nav-waze-report-btn"]').click();
            const reportSheetA = pageA.locator('[data-testid="waze-report-sheet"]');
            await expect(reportSheetA).toBeVisible();
            await expect(reportSheetA).not.toContainText("Activ 3h");
            await expect(reportSheetA).not.toContainText("Expiră automat");
            await pageA
                .locator('[data-testid="waze-report-note"]')
                .fill("Ursoaică văzută lângă lizieră");
            // Single tap on category publishes immediately and closes sheet!
            await pageA.locator('[data-testid="waze-cat-bear"]').click();
            await expect(reportSheetA).toHaveCount(0);

            // Real-time SSE delivers `report_update` to Hiker B's map & elevation sheet
            await expect(
                pageB.locator('[data-testid="trail-report-marker"][data-report-category="bear"]'),
            ).toBeVisible();
            await expect(pageB.locator('[data-testid="elevation-report-icon"]')).toHaveCount(1);

            const bearEntry = [...liveServer.reports.values()].find(
                (r) => r.category === "bear",
            );
            expect(bearEntry).toBeDefined();
            expect(bearEntry!.isPermanent).toBe(false);
            expect(bearEntry!.expiresAt).not.toBeNull();
            const initialBearExpiresMs = Date.parse(bearEntry!.expiresAt!);

            // Hiker B is still ~300 m away (>150 m), so nearby Waze prompt must NOT appear yet
            await expect(pageB.locator('[data-testid="waze-nearby-prompt"]')).toHaveCount(0);

            // 2. Hiker A hikes further North to (45.4463, 25.5500) and 1-tap adds permanent `spring`
            await pageA.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        pushFix: (f: Record<string, unknown>) => void;
                    };
                };
                w.__wandererNavTest.pushFix({
                    lat: 45.4463,
                    lon: 25.55,
                    ele: 1018,
                    accuracy: 6,
                    speed: 1.2,
                    heading: 0,
                });
            });

            await pageA.locator('[data-testid="nav-waze-report-btn"]').click();
            await pageA
                .locator('[data-testid="waze-report-note"]')
                .fill("Izvor rece sub stâncă");
            await pageA.locator('[data-testid="waze-cat-spring"]').click();
            await expect(pageA.locator('[data-testid="waze-report-sheet"]')).toHaveCount(0);

            await expect(
                pageB.locator(
                    '[data-testid="trail-report-marker"][data-report-category="spring"]',
                ),
            ).toBeVisible();

            const springEntry = [...liveServer.reports.values()].find(
                (r) => r.category === "spring",
            );
            expect(springEntry).toBeDefined();
            expect(springEntry!.isPermanent).toBe(true);
            expect(springEntry!.expiresAt).toBeNull();

            // 3. Advance server clock +15 min; Hiker B approaches within <150 m (~67 m) of `bear`
            liveServer.clockOffsetMs += 15 * 60_000;
            await pageB.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        pushFix: (f: Record<string, unknown>) => void;
                    };
                };
                w.__wandererNavTest.pushFix({
                    lat: 45.4421,
                    lon: 25.55,
                    ele: 952,
                    accuracy: 6,
                    speed: 1.1,
                    heading: 0,
                });
            });

            const promptB = pageB.locator('[data-testid="waze-nearby-prompt"]');
            await expect(promptB).toBeVisible();
            await expect(promptB).toContainText("Urs");
            await expect(promptB).toContainText("Mai este acolo?");
            await expect(pageB.locator('[data-testid="waze-vote-confirm"]')).toContainText(
                "OK, mai este",
            );

            // Hiker B clicks "OK, mai este" -> extends `expiresAt` by full 3h TTL from now!
            await pageB.locator('[data-testid="waze-vote-confirm"]').click();
            await expect(promptB).toHaveCount(0);

            expect(bearEntry!.confirmCount).toBe(2);
            const extendedBearExpiresMs = Date.parse(bearEntry!.expiresAt!);
            expect(extendedBearExpiresMs).toBeGreaterThanOrEqual(
                initialBearExpiresMs + 14 * 60_000,
            );

            // 4. Hiker B continues North within <150 m (~55 m) of permanent `spring` landmark
            await pageB.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        pushFix: (f: Record<string, unknown>) => void;
                    };
                };
                w.__wandererNavTest.pushFix({
                    lat: 45.4458,
                    lon: 25.55,
                    ele: 1010,
                    accuracy: 6,
                    speed: 1.1,
                    heading: 0,
                });
            });

            await expect(promptB).toBeVisible();
            await expect(promptB).toContainText("Izvor");
            // Permanent landmarks show seasonal water buttons instead of temporary dismiss
            await expect(pageB.locator('[data-testid="waze-vote-dismiss"]')).toHaveCount(0);
            await expect(pageB.locator('[data-testid="waze-vote-seasonal-ok"]')).toContainText(
                "Curge apă",
            );
            await expect(pageB.locator('[data-testid="waze-vote-seasonal-dry"]')).toContainText(
                "Secat momentan",
            );

            await pageB.locator('[data-testid="waze-vote-seasonal-dry"]').click();
            await expect(promptB).toHaveCount(0);
            expect(springEntry!.conditionStatus).toBe("dry_or_closed");
            expect(springEntry!.isPermanent).toBe(true);
            expect(springEntry!.expiresAt).toBeNull();
            // Permanent landmark stays visible on map even when marked dry seasonally
            await expect(
                pageA.locator(
                    '[data-testid="trail-report-marker"][data-report-category="spring"]',
                ),
            ).toBeVisible();

            // =========================================================================
            // (c) Community SOS within 5 km + Tobler 16-neighbor DEM A* Rescue Routing
            // =========================================================================
            // Configure synthetic mountain DEM on Hiker B with a steep knoll between B and A
            await pageB.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        setCustomDemSampler: (
                            fn: (lat: number, lon: number) => number,
                        ) => void;
                    };
                };
                w.__wandererNavTest.setCustomDemSampler((lat: number, lon: number) => {
                    const base = 1010 + ((lat - 45.4458) / 0.004) * 110;
                    const dLatM = (lat - 45.4476) * 111_132;
                    const dLonM = (lon - 25.5512) * 78_100;
                    const cliff = 68 * Math.exp(-(dLatM * dLatM + dLonM * dLonM) / (2 * 38 * 38));
                    return base + cliff;
                });
            });

            // Hiker A is off-trail on an upper slope ~455 m NE of Hiker B and triggers SOS
            await pageA.evaluate(() => {
                const w = window as unknown as {
                    __wandererNavTest: {
                        pushFix: (f: Record<string, unknown>) => void;
                    };
                };
                w.__wandererNavTest.pushFix({
                    lat: 45.4495,
                    lon: 25.5525,
                    ele: 1125,
                    accuracy: 8,
                    speed: 0,
                    heading: 45,
                });
            });

            await pageA.locator('[data-testid="nav-sos-btn"]').click();
            const sosModal = pageA.locator('[data-testid="sos-modal"]');
            await expect(sosModal).toBeVisible();
            await expect(pageA.locator('[data-testid="sos-call-112"]')).toHaveAttribute(
                "href",
                "tel:112",
            );
            await expect(pageA.locator('[data-testid="sos-call-salvamont"]')).toHaveAttribute(
                "href",
                "tel:0725826668",
            );

            await pageA.locator('[data-testid="sos-reason-injury"]').click();
            await pageA
                .locator('[data-testid="sos-message-input"]')
                .fill("Gleznă luxată sub creastă, am nevoie de sprijin");
            await pageA.locator('[data-testid="sos-submit-btn"]').click();
            await expect(sosModal).toHaveCount(0);

            // Hiker A sees own comforting active SOS bar
            const mySosBarA = pageA.locator('[data-testid="my-active-sos-bar"]');
            await expect(mySosBarA).toBeVisible();
            await expect(mySosBarA).toContainText("SOS Activ");

            // Hiker B immediately receives high-priority red SOS rescue banner via SSE
            const rescueBannerB = pageB.locator('[data-testid="sos-rescue-banner"]');
            await expect(rescueBannerB).toBeVisible();
            await expect(rescueBannerB).toContainText("SOS în apropiere");
            await expect(rescueBannerB).toContainText("Accidentare");
            await expect(rescueBannerB).toContainText("Gleznă luxată sub creastă");
            await expect(pageB.locator('[data-testid="sos-map-marker"]')).toBeVisible();

            // Hiker B clicks "Pot să vin să ajut" (`data-testid="sos-respond-btn"`)
            const respondBtnB = pageB.locator('[data-testid="sos-respond-btn"]');
            await expect(respondBtnB).toContainText("Pot să vin să ajut");
            await respondBtnB.click();

            // Verify DEM A* rescue route (`nav-sos-rescue-line`) renders on Hiker B's MapLibre map
            await expect
                .poll(() =>
                    pageB.evaluate(async () => {
                        const m = (window as unknown as { realMap: any }).realMap;
                        const hasLayer = Boolean(
                            m.getLayer("nav-sos-rescue-line") &&
                                m.getLayer("nav-sos-rescue-casing"),
                        );
                        const src = m.getSource("nav-sos-rescue");
                        const data = src ? await src.getData() : null;
                        const coords = data?.features?.[0]?.geometry?.coordinates ?? [];
                        return {
                            hasLayer,
                            coordCount: coords.length,
                            endLon: coords.length ? coords[coords.length - 1][0] : null,
                            endLat: coords.length ? coords[coords.length - 1][1] : null,
                        };
                    }),
                )
                .toMatchObject({
                    hasLayer: true,
                    endLon: 25.5525,
                    endLat: 45.4495,
                });

            const rescueCoordCount = await pageB.evaluate(async () => {
                const src = (window as unknown as { realMap: any }).realMap.getSource(
                    "nav-sos-rescue",
                );
                const data = await src.getData();
                return data?.features?.[0]?.geometry?.coordinates?.length ?? 0;
            });
            expect(rescueCoordCount).toBeGreaterThanOrEqual(2);

            await expect(rescueBannerB).toContainText("Rută DEM activă spre victimă");
            await expect(pageB.locator('[data-testid="nav-rescue-profile-badge"]')).toBeVisible();
            await expect(pageB.locator('[data-testid="elevation-sos-target"]')).toBeVisible();

            // Meanwhile Hiker A's live status bar updates via SSE to show "1 persoană vine spre tine" + ETA!
            await expect(mySosBarA).toContainText("1 persoană vine spre tine");
            await expect(mySosBarA).toContainText("cel mai aproape la");

            // Hiker A resolves SOS ("Sunt în siguranță") -> clears banner & rescue route on both clients
            await pageA.locator('[data-testid="sos-resolve-btn"]').click();
            await expect(mySosBarA).toHaveCount(0);
            await expect(rescueBannerB).toHaveCount(0);
            await expect
                .poll(() =>
                    pageB.evaluate(() =>
                        Boolean(
                            (window as unknown as { realMap: any }).realMap.getLayer(
                                "nav-sos-rescue-line",
                            ),
                        ),
                    ),
                )
                .toBe(false);
        } finally {
            await contextA.close();
            await contextB.close();
        }
    });
});
