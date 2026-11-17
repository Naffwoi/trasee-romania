# Trail Live Community: Waze Alerts, Permanent Landmarks, SOS Nearby Rescue & 30-Minute Trail Presence — Design Spec

**Date:** 2026-11-17  
**Status:** Approved by user  
**Platforms:** PocketBase Go Backend (`db/`), SvelteKit Web & iOS/Android PWA (`web/`), Native Flutter App (`app/`)

---

## 1. Goals & Core Principles

1. **Zero-Account Friction with Anti-Spam Integrity:** Any hiker (logged-in or anonymous) can report trail hazards/landmarks, trigger or respond to an SOS, and contribute to the 30-minute active trail counter. Every device generates a persistent random 32-byte `X-Device-Token`; the backend stores only `device_hash = HMAC-SHA256(POCKETBASE_PROXY_SECRET, token)` to enforce per-device rate limits and single-vote-per-report integrity.
2. **Privacy by Default for Trail Presence:** Raw GPS coordinates from 30-minute trail heartbeats (`trail_presence`) are strictly internal to the Go backend (`listRule: null, viewRule: null`), auto-purged after 30 minutes, and never returned to clients. Public endpoints expose only the integer `active_hikers_30m` count. Exact coordinates are shared **only** for explicit `trail_reports` and active `sos_alerts`.
3. **Two Lifecycles for Reports (Temporary Waze Alerts vs. Permanent Landmarks):**
   - **Permanent Landmarks (`expires_at = null`):** `spring` (Izvor), `viewpoint` (Belvedere), `shelter` (Refugiu). Never auto-expire; hikers passing within `<150 m` can update seasonal `condition_status` (`good` / `dry_or_closed`) or flag obvious spam (`spam_flags >= 5` hides the item).
   - **Temporary Waze Alerts (`expires_at != null`):** `bear` (`3h`), `deer` (`3h`), `shepherd_dogs` (`24h`), `ice_mud` (`48h`), `fallen_tree_terrain` (`14d`). Hikers within `<150 m` get a non-intrusive Waze prompt (*„Mai este acolo? Da / Nu”*): `confirm` extends `expires_at` by one full TTL window from `now`; `3` net `dismiss` votes mark `status = "resolved"`.
4. **Community SOS within 5 km + Off-Trail DEM A\* Rescue Routing:**
   - Triggering SOS creates an active `sos_alerts` record (`reason`: `lost` | `injury` | `exhaustion` | `other`, optional `message`, live `lat`/`lon`/`ele`, `trail_id`). UI prominently displays a `112 / Salvamont` emergency reminder.
   - Backend queries `trail_presence` (active in last 30 min) within `5,000 m` Haversine OR on the same `trail_id`, sending **Web Push (VAPID)** notifications (PWA iOS 16.4+ & Android) and **SSE Realtime** events (`/api/v1/live/stream`).
   - Tapping **„Vin să ajut”** creates/updates `sos_responders`: the requester sees live responder count and nearest ETA/distance, while the responder's navigation screen computes a live **DEM A\* off-trail/on-trail route** directly to the requester's coordinates.

---

## 2. Data Model (PocketBase Migration in `db/migrations/`)

1. **`trail_presence`** *(internal-only: all API rules `null`)*
   - `device_hash` (`text`, required, unique index)
   - `trail_id` (`relation -> trails`, optional)
   - `lat` (`number`, required), `lon` (`number`, required), `ele` (`number`, optional)
   - `in_navigation` (`bool`)
   - `last_seen` (`date`, indexed) — cleaned every 2 min by Go cron (`last_seen < now - 30m`).

2. **`trail_reports`**
   - `trail_id` (`relation -> trails`, optional, indexed)
   - `category` (`select`: `bear`, `shepherd_dogs`, `fallen_tree_terrain`, `ice_mud`, `deer`, `spring`, `viewpoint`, `shelter`)
   - `kind` (`select`: `hazard`, `wildlife_good`, `landmark_permanent`)
   - `is_permanent` (`bool`)
   - `condition_status` (`select`: `active`, `dry_or_closed`, `resolved`, `spam_hidden`)
   - `note` (`text`, max 160 chars, HTML-sanitized)
   - `lat` (`number`), `lon` (`number`), `ele` (`number`), `along_track_m` (`number`, optional)
   - `device_hash` (`text`, hidden), `author_actor` (`relation -> activitypub_actors`, optional)
   - `confirm_count` (`number`, default `1`), `dismiss_count` (`number`, default `0`), `spam_count` (`number`, default `0`)
   - `expires_at` (`date`, optional — `null` for permanent landmarks)

3. **`trail_report_votes`** *(internal-only)*
   - `report_id` (`relation -> trail_reports`, cascade delete)
   - `device_hash` (`text`)
   - `vote` (`select`: `confirm`, `dismiss`, `seasonal_dry`, `seasonal_ok`, `spam`)
   - Unique index on `(report_id, device_hash)`.

4. **`sos_alerts`**
   - `trail_id` (`relation -> trails`, optional)
   - `status` (`select`: `active`, `resolved`, `cancelled`)
   - `reason` (`select`: `lost`, `injury`, `exhaustion`, `other`)
   - `message` (`text`, max 200 chars)
   - `lat` (`number`), `lon` (`number`), `ele` (`number`)
   - `device_hash` (`text`, hidden), `requester_name` (`text`, max 40)
   - `responder_count` (`number`, default `0`)
   - `expires_at` (`date` — auto-expires after `6h` if not renewed/resolved)

5. **`sos_responders`** *(internal-only)*
   - `sos_id` (`relation -> sos_alerts`, cascade delete)
   - `device_hash` (`text`)
   - `lat` (`number`), `lon` (`number`), `ele` (`number`)
   - `distance_m` (`number`), `eta_sec` (`number`)
   - `status` (`select`: `coming`, `cancelled`)
   - `last_seen` (`date`) — unique index on `(sos_id, device_hash)`.

6. **`push_subscriptions`** *(internal-only)*
   - `device_hash` (`text`, indexed)
   - `endpoint` (`text`, unique index)
   - `p256dh` (`text`), `auth` (`text`)
   - `lat` (`number`), `lon` (`number`), `trail_id` (`text`)
   - `updated` (`autodate`)

---

## 3. API Contract (SvelteKit `/api/v1/live/*` -> PocketBase Internal `/live/*`)

All SvelteKit `/api/v1/live/*` endpoints read `X-Device-Token` (or generate/validate format), attach `X-Internal-Secret: POCKETBASE_PROXY_SECRET`, and proxy to PocketBase Go routes in `db/routes/trail_live.go`:

- `POST /api/v1/live/heartbeat` — Upserts `trail_presence` (rate-limited: 1 write / 20s per `device_hash`), updates `push_subscriptions` last location if present, and returns `{ activeHikers30m, nearbyReports, activeSosAlerts, myActiveSos }`.
- `GET /api/v1/live/trail/[id]/summary` — Public fast read returning `{ activeHikers30m, reports, activeSosAlerts }` for trail detail & cards.
- `POST /api/v1/live/reports` — Creates a `trail_reports` entry (rate-limited: max 5 / 10 min per `device_hash`; deduplicates same category within `40 m`).
- `POST /api/v1/live/reports/[id]/vote` — Casts/updates `confirm` | `dismiss` | `seasonal_dry` | `seasonal_ok` | `spam`.
- `POST /api/v1/live/sos` — Creates `sos_alerts`, resolves nearby `trail_presence` + `push_subscriptions` within `5,000 m` (or same `trail_id`), triggers Web Push fan-out + SSE broadcast.
- `PATCH /api/v1/live/sos/[id]` — Updates requester GPS coordinates or marks `resolved` / `cancelled` (verified via `device_hash`).
- `POST /api/v1/live/sos/[id]/respond` — Registers/updates `coming` or `cancelled` responder with live distance/ETA.
- `GET /api/v1/live/push/vapid-public-key` & `POST /api/v1/live/push/subscribe` — Registers browser PWA Web Push subscription.
- `GET /api/v1/live/stream?lat=...&lon=...&trailId=...` — Server-Sent Events (SSE) stream pushing instant `<1s` `sos_alert`, `sos_update`, and `report_change` events to open Web & Flutter clients.
