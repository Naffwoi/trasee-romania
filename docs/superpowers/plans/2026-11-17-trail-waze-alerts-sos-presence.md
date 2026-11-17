# Trail Live Community (Waze Alerts, Permanent Landmarks, SOS Rescue & 30m Presence) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (or `/swarm`) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build real-time Waze-style trail alerts + permanent hiker landmarks, 5 km nearby SOS rescue notifications with DEM A\* routing to the person in distress, and an anonymous 30-minute active trail hiker counter across PocketBase Go (`db/`), SvelteKit Web/PWA (`web/`), and Native Flutter (`app/`).

**Spec:** `docs/superpowers/specs/2026-11-17-trail-waze-alerts-sos-presence-design.md`

---

### Task 1: PocketBase Migrations, Internal Go Routes, Cron GC & SSE Hub (`db/`)
- Create `db/migrations/1792000000_created_trail_live_community.go` (`trail_presence`, `trail_reports`, `trail_report_votes`, `sos_alerts`, `sos_responders`, `push_subscriptions`).
- Create `db/services/live/trail_live_hub.go` (in-memory geo/trail SSE pub/sub broker).
- Create `db/routes/trail_live.go` + `db/routes/trail_live_test.go` (protected by `util.VerifyInternalProxySecret`, Haversine `<= 5000m` SOS fan-out, permanent vs temporary report lifecycles, 3-vote dismiss resolution, 5-vote spam hide).
- Register `/live/*` routes and `*/2 * * * *` cleanup cron in `db/main.go`.

### Task 2: SvelteKit `/api/v1/live/*` Proxy, HMAC Device Auth & VAPID Web Push (`web/`)
- Add `web-push` + `@types/web-push` to `web/package.json`.
- Add `"/api/v1/live"` to `publicRoutes` in `web/src/lib/util/authorization_util.ts`.
- Create `web/src/lib/server/live/device_identity.ts` (`HMAC-SHA256(POCKETBASE_PROXY_SECRET, X-Device-Token)` + per-device sliding-window rate limiter) and `vapid_push.ts` (auto-persisted VAPID keypair + RFC 8291 push dispatch).
- Create `/api/v1/live/{heartbeat,reports,reports/[id]/vote,trail/[id]/summary,sos,sos/[id],sos/[id]/respond,push/vapid-public-key,push/subscribe,stream}/+server.ts`.
- Create `web/src/service-worker.ts` handling `push` and `notificationclick` for iOS 16.4+ Standalone PWA & Android Chrome.

### Task 3: Web & PWA UI — Waze Sheet, Elevation/Map Pins, SOS DEM Rescue & 30m Badge (`web/`)
- Create `web/src/lib/live/live_client.ts` + components `waze_report_sheet.svelte`, `waze_nearby_prompt.svelte`, `sos_modal_and_banner.svelte`, `active_hikers_badge.svelte`.
- Integrate report markers onto MapLibre & `live_elevation_sheet.svelte`.
- Wire responder rescue mode in `web/src/routes/map/trail/[handle]/[id]/navigate/+page.svelte` using `computeOffTrailReroute` targeting the requester's live `(lat, lon, ele)`.

### Task 4: Native Flutter Parity & LocationPuck Compass Cone Fix (`app/`)
- Fix invisible compass cone on `NavigationScreen` (`app/lib/routes/navigation_screen.dart` + `app/lib/components/map/location_marker_layer.dart`): increase `_LocationMarkerLayer` marker/puck from `size: 44` to `size: 96, dotSize: 20` (previously `dotSize: 20` occluded the inner `60%` of the `22px` radial gradient, leaving only `alpha <= 0.18` over dark-mode tiles), boost cone gradient alpha (`0.68 -> 0.30 -> 0.0`), subtract `_mapBearing` when `!_headingUp`, and fall back to GPS `pos.heading` in `_onFix` when moving if `RotationSensor` hasn't emitted.
- Ensure every `confirm` ("OK / Still there") vote on temporary Waze reports extends `expires_at = max(expires_at, now + categoryTTL)` and updates `last_confirmed_at = now` + `confirm_count` across backend, Web, and Flutter UI.
- Create `app/lib/models/live/*`, `app/lib/services/trail_live_service.dart` (ObjectBox token persistence, 60s heartbeat, SSE stream, `flutter_local_notifications` high-priority SOS alerts), and widgets `waze_report_sheet.dart`, `waze_nearby_prompt.dart`, `sos_banner_and_dialog.dart`, `active_hikers_badge.dart`.
- Integrate into `navigation_screen.dart` (with `OffTrailRouter` rescue target routing) and trail details screen + `app_ro.arb` / `app_en.arb`.

### Task 5: End-to-End Multi-User Verification (`db/`, `web/`, `app/`)
- Run `go test ./...`, `vitest`, and multi-context Playwright test `web/tests/playwright/components/trail-waze-sos-live.spec.ts` verifying 2-hiker 30m counter, permanent spring vs temporary bear alert, and 5 km SOS dispatch + DEM rescue route.

### Task 6: Production Deploy & Mobile Package Refresh
- Deploy `db` + `web` to `vps-pub`, push `main` to trigger GitHub Actions (`App CI`, `Android APK Build`, `iOS IPA Build`), and refresh `/var/www/maps.skillfy.ro/downloads/` on `trasee.skillfy.ro`.
