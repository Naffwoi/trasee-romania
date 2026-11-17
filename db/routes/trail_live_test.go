package routes

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/router"

	"pocketbase/services/live"
)

const testLiveSecret = "test-live-proxy-secret-32-chars!!"

type liveCallOptions struct {
	method     string
	target     string
	body       string
	secret     string
	deviceHash string
	actorID    string
	pathValues map[string]string
}

func invokeLiveHandler(
	t *testing.T,
	app core.App,
	fn func(*core.RequestEvent) error,
	opts liveCallOptions,
) (int, []byte) {
	t.Helper()

	var bodyReader *strings.Reader
	if opts.body != "" {
		bodyReader = strings.NewReader(opts.body)
	} else {
		bodyReader = strings.NewReader("")
	}

	req := httptest.NewRequest(opts.method, opts.target, bodyReader)
	if opts.body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if opts.secret != "" {
		req.Header.Set("X-Internal-Secret", opts.secret)
	}
	if opts.deviceHash != "" {
		req.Header.Set("X-Device-Hash", opts.deviceHash)
	}
	if opts.actorID != "" {
		req.Header.Set("X-Actor-Id", opts.actorID)
	}
	for k, v := range opts.pathValues {
		req.SetPathValue(k, v)
	}

	rec := httptest.NewRecorder()
	ev := &core.RequestEvent{App: app}
	ev.Request = req
	ev.Response = rec

	if err := fn(ev); err != nil {
		var apiErr *router.ApiError
		if errors.As(err, &apiErr) {
			raw, _ := json.Marshal(map[string]any{"message": apiErr.Message})
			return apiErr.Status, raw
		}
		t.Fatalf("unexpected non-API error from handler %s %s: %v", opts.method, opts.target, err)
	}

	return rec.Code, rec.Body.Bytes()
}

func TestTrailLiveInternalSecretProtectionAndCollectionRules(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	// Verify all 6 collections exist and have strictly null API rules.
	expectedCollections := []string{
		"trail_presence",
		"trail_reports",
		"trail_report_votes",
		"sos_alerts",
		"sos_responders",
		"push_subscriptions",
	}
	for _, name := range expectedCollections {
		col, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			t.Fatalf("collection %q missing from migrated schema: %v", name, err)
		}
		if col.ListRule != nil || col.ViewRule != nil || col.CreateRule != nil || col.UpdateRule != nil || col.DeleteRule != nil {
			t.Fatalf("collection %q must have all API rules nil, got list=%v view=%v create=%v update=%v delete=%v",
				name, col.ListRule, col.ViewRule, col.CreateRule, col.UpdateRule, col.DeleteRule)
		}
	}

	handler := NewTrailLiveHandler(live.NewTrailLiveHub())

	// Missing X-Internal-Secret -> 401
	status, _ := invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/heartbeat",
		body:       `{"trailId":"trail-1","lat":45.4,"lon":25.5}`,
		deviceHash: "dev-1",
	})
	if status != http.StatusUnauthorized {
		t.Fatalf("missing secret status = %d, want 401", status)
	}

	// Wrong X-Internal-Secret -> 401
	status, _ = invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/heartbeat",
		body:       `{"trailId":"trail-1","lat":45.4,"lon":25.5}`,
		secret:     "wrong-secret",
		deviceHash: "dev-1",
	})
	if status != http.StatusUnauthorized {
		t.Fatalf("wrong secret status = %d, want 401", status)
	}

	// Missing X-Device-Hash on mutating endpoint -> 400
	status, _ = invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
		method: http.MethodPost,
		target: "/live/heartbeat",
		body:   `{"trailId":"trail-1","lat":45.4,"lon":25.5}`,
		secret: testLiveSecret,
	})
	if status != http.StatusBadRequest {
		t.Fatalf("missing X-Device-Hash status = %d, want 400", status)
	}
}

func TestTrailLivePresenceCountingPrivacyAndGC(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	curTime := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	handler.Now = func() time.Time { return curTime }

	// 3 distinct hikers on trail-bucegi, 1 hiker on trail-piatra-craiului.
	for _, h := range []struct {
		device string
		trail  string
		body   string
	}{
		{"hiker-a", "trail-bucegi", `{"trailId":"trail-bucegi","lat":45.408123,"lon":25.541987,"ele":2025,"inNavigation":true}`},
		{"hiker-b", "trail-bucegi", `{"trailId":"trail-bucegi","lat":45.412345,"lon":25.545678,"ele":2110,"inNavigation":true}`},
		{"hiker-c", "trail-bucegi", `{"trailId":"trail-bucegi","lat":45.419876,"lon":25.549111,"ele":2205,"inNavigation":false}`},
		{"hiker-d", "trail-craiului", `{"trailId":"trail-craiului","lat":45.529999,"lon":25.221111,"ele":1800,"inNavigation":true}`},
	} {
		status, raw := invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
			method:     http.MethodPost,
			target:     "/live/heartbeat",
			body:       h.body,
			secret:     testLiveSecret,
			deviceHash: h.device,
		})
		if status != http.StatusOK {
			t.Fatalf("heartbeat(%s) status = %d, body = %s", h.device, status, raw)
		}
	}

	// Repeat heartbeat from hiker-a (upsert by device_hash, must NOT double-count)
	status, hbRaw := invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/heartbeat",
		body:       `{"trailId":"trail-bucegi","lat":45.408555,"lon":25.542222,"ele":2030,"inNavigation":true}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-a",
	})
	if status != http.StatusOK {
		t.Fatalf("repeat heartbeat status = %d", status)
	}

	// Privacy assertion: raw hiker coordinates must NEVER appear in heartbeat or summary responses!
	for _, secretCoord := range []string{"45.408123", "45.408555", "45.412345", "25.545678", "45.419876"} {
		if strings.Contains(string(hbRaw), secretCoord) {
			t.Fatalf("PRIVACY VIOLATION: heartbeat response leaked presence coordinate %s: %s", secretCoord, hbRaw)
		}
	}

	var hbResp struct {
		ActiveHikers30m int              `json:"activeHikers30m"`
		Reports         []TrailReportDto `json:"reports"`
		SosAlerts       []SosAlertDto    `json:"sosAlerts"`
	}
	if err := json.Unmarshal(hbRaw, &hbResp); err != nil {
		t.Fatalf("unmarshal heartbeat: %v", err)
	}
	if hbResp.ActiveHikers30m != 3 {
		t.Fatalf("activeHikers30m = %d, want 3", hbResp.ActiveHikers30m)
	}

	// GET /live/trail/{id}/summary without deviceHash works and never leaks coordinates
	status, sumRaw := invokeLiveHandler(t, app, handler.TrailSummary, liveCallOptions{
		method:     http.MethodGet,
		target:     "/live/trail/trail-bucegi/summary",
		secret:     testLiveSecret,
		pathValues: map[string]string{"id": "trail-bucegi"},
	})
	if status != http.StatusOK {
		t.Fatalf("summary status = %d, body = %s", status, sumRaw)
	}
	for _, secretCoord := range []string{"45.408555", "45.412345", "45.419876"} {
		if strings.Contains(string(sumRaw), secretCoord) {
			t.Fatalf("PRIVACY VIOLATION: summary leaked presence coordinate %s: %s", secretCoord, sumRaw)
		}
	}

	// Advance clock by 31 minutes: only hiker-a refreshes presence.
	curTime = curTime.Add(31 * time.Minute)
	status, hbAfterRaw := invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/heartbeat",
		body:       `{"trailId":"trail-bucegi","lat":45.409000,"lon":25.543000}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-a",
	})
	if status != http.StatusOK {
		t.Fatalf("heartbeat after 31m status = %d", status)
	}
	if err := json.Unmarshal(hbAfterRaw, &hbResp); err != nil {
		t.Fatal(err)
	}
	if hbResp.ActiveHikers30m != 1 {
		t.Fatalf("activeHikers30m after 31m = %d, want 1", hbResp.ActiveHikers30m)
	}

	// Run Cron GC: stale presence rows (hiker-b, hiker-c, hiker-d) must be deleted, leaving only hiker-a.
	if err := RunTrailLiveGC(app, hub, curTime); err != nil {
		t.Fatalf("RunTrailLiveGC: %v", err)
	}
	remainingPresence, err := app.CountRecords("trail_presence")
	if err != nil {
		t.Fatal(err)
	}
	if remainingPresence != 1 {
		t.Fatalf("remaining trail_presence rows after GC = %d, want 1", remainingPresence)
	}
}

func TestTrailLivePermanentLandmarksVsTemporaryHazards(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	t0 := time.Date(2026, 11, 17, 9, 0, 0, 0, time.UTC)
	curTime := t0
	handler.Now = func() time.Time { return curTime }

	// 1. Create permanent `spring` landmark (also testing HTML tag stripping on note).
	status, springRaw := invokeLiveHandler(t, app, handler.CreateReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports",
		body:       `{"trailId":"trail-bucegi","category":"spring","note":"<script>evil()</script>Izvor cu apă rece","lat":45.4100,"lon":25.5400,"ele":1950,"alongTrackM":840}`,
		secret:     testLiveSecret,
		deviceHash: "author-spring",
	})
	if status != http.StatusOK {
		t.Fatalf("create spring status = %d, body = %s", status, springRaw)
	}
	if !strings.Contains(string(springRaw), `"expiresAt":null`) {
		t.Fatalf("permanent spring must serialize expiresAt:null, got %s", springRaw)
	}

	var springWrap struct {
		Report TrailReportDto `json:"report"`
	}
	if err := json.Unmarshal(springRaw, &springWrap); err != nil {
		t.Fatal(err)
	}
	spring := springWrap.Report
	if !spring.IsPermanent || spring.Kind != "landmark_permanent" || spring.ExpiresAt != nil {
		t.Fatalf("unexpected permanent spring fields: %+v", spring)
	}
	if strings.Contains(spring.Note, "<script>") || spring.Note != "Izvor cu apă rece" {
		t.Fatalf("HTML sanitization failed on note: %q", spring.Note)
	}

	// Seasonal toggle: seasonal_dry -> dry_or_closed, seasonal_ok -> active, never sets expiresAt!
	curTime = t0.Add(20 * time.Minute)
	status, dryRaw := invokeLiveHandler(t, app, handler.VoteReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports/" + spring.ID + "/vote",
		body:       `{"vote":"seasonal_dry"}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-2",
		pathValues: map[string]string{"id": spring.ID},
	})
	if status != http.StatusOK {
		t.Fatalf("seasonal_dry status = %d: %s", status, dryRaw)
	}
	_ = json.Unmarshal(dryRaw, &springWrap)
	if springWrap.Report.ConditionStatus != "dry_or_closed" || springWrap.Report.ExpiresAt != nil {
		t.Fatalf("expected dry_or_closed with nil expiresAt, got %+v", springWrap.Report)
	}

	curTime = t0.Add(40 * time.Minute)
	status, okRaw := invokeLiveHandler(t, app, handler.VoteReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports/" + spring.ID + "/vote",
		body:       `{"vote":"seasonal_ok"}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-3",
		pathValues: map[string]string{"id": spring.ID},
	})
	if status != http.StatusOK {
		t.Fatalf("seasonal_ok status = %d: %s", status, okRaw)
	}
	_ = json.Unmarshal(okRaw, &springWrap)
	if springWrap.Report.ConditionStatus != "active" || springWrap.Report.ExpiresAt != nil {
		t.Fatalf("expected active with nil expiresAt, got %+v", springWrap.Report)
	}

	// 2. Create temporary `bear` hazard (3h TTL).
	curTime = t0
	status, bearRaw := invokeLiveHandler(t, app, handler.CreateReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports",
		body:       `{"trailId":"trail-bucegi","category":"bear","note":"Urs văzut lângă potecă","lat":45.4200,"lon":25.5500,"ele":2010,"alongTrackM":2150}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-1",
	})
	if status != http.StatusOK {
		t.Fatalf("create bear status = %d: %s", status, bearRaw)
	}
	var bearWrap struct {
		Report TrailReportDto `json:"report"`
	}
	_ = json.Unmarshal(bearRaw, &bearWrap)
	bear := bearWrap.Report
	if bear.IsPermanent || bear.Kind != "hazard" || bear.ExpiresAt == nil {
		t.Fatalf("unexpected temporary bear fields: %+v", bear)
	}
	initialExp, err := time.Parse(time.RFC3339, *bear.ExpiresAt)
	if err != nil {
		t.Fatalf("parse bear expiresAt: %v", err)
	}
	wantInitialExp := t0.Add(3 * time.Hour)
	if !initialExp.Equal(wantInitialExp) {
		t.Fatalf("initial bear expiresAt = %v, want %v", initialExp, wantInitialExp)
	}

	// Deduplication within 40m (~12m offset) at t0 + 1h acts as a `confirm` vote and extends expiresAt to t0 + 4h!
	curTime = t0.Add(1 * time.Hour)
	status, dedupRaw := invokeLiveHandler(t, app, handler.CreateReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports",
		body:       `{"trailId":"trail-bucegi","category":"bear","lat":45.4201,"lon":25.5500}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-2",
	})
	if status != http.StatusOK {
		t.Fatalf("dedup bear status = %d", status)
	}
	_ = json.Unmarshal(dedupRaw, &bearWrap)
	if bearWrap.Report.ID != bear.ID || bearWrap.Report.ConfirmCount != 2 {
		t.Fatalf("expected deduplicated report %s with confirmCount=2, got %+v", bear.ID, bearWrap.Report)
	}
	dedupExp, _ := time.Parse(time.RFC3339, *bearWrap.Report.ExpiresAt)
	if !dedupExp.Equal(t0.Add(4 * time.Hour)) {
		t.Fatalf("dedup extended expiresAt = %v, want %v", dedupExp, t0.Add(4*time.Hour))
	}

	// Explicit `confirm` vote at t0 + 2h extends expiresAt to t0 + 5h!
	curTime = t0.Add(2 * time.Hour)
	status, confRaw := invokeLiveHandler(t, app, handler.VoteReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports/" + bear.ID + "/vote",
		body:       `{"vote":"confirm"}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-3",
		pathValues: map[string]string{"id": bear.ID},
	})
	if status != http.StatusOK {
		t.Fatalf("confirm vote status = %d", status)
	}
	_ = json.Unmarshal(confRaw, &bearWrap)
	confExp, _ := time.Parse(time.RFC3339, *bearWrap.Report.ExpiresAt)
	if !confExp.Equal(t0.Add(5*time.Hour)) || bearWrap.Report.ConfirmCount != 3 {
		t.Fatalf("confirm vote result = %+v (exp=%v, want %v)", bearWrap.Report, confExp, t0.Add(5*time.Hour))
	}

	// 3 `dismiss` votes resolve a temporary hazard!
	for i, voter := range []string{"dismisser-1", "dismisser-2", "dismisser-3"} {
		status, disRaw := invokeLiveHandler(t, app, handler.VoteReport, liveCallOptions{
			method:     http.MethodPost,
			target:     "/live/reports/" + bear.ID + "/vote",
			body:       `{"vote":"dismiss"}`,
			secret:     testLiveSecret,
			deviceHash: voter,
			pathValues: map[string]string{"id": bear.ID},
		})
		if status != http.StatusOK {
			t.Fatalf("dismiss #%d status = %d", i+1, status)
		}
		_ = json.Unmarshal(disRaw, &bearWrap)
	}
	if bearWrap.Report.DismissCount != 3 || bearWrap.Report.ConditionStatus != "resolved" {
		t.Fatalf("expected 3 dismiss votes to resolve bear report, got %+v", bearWrap.Report)
	}

	// Create another temporary `deer` (3h TTL) to verify Cron GC expiration while permanent `spring` survives!
	curTime = t0.Add(2 * time.Hour)
	_, deerRaw := invokeLiveHandler(t, app, handler.CreateReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports",
		body:       `{"trailId":"trail-bucegi","category":"deer","lat":45.4250,"lon":25.5550}`,
		secret:     testLiveSecret,
		deviceHash: "hiker-deer",
	})
	var deerWrap struct {
		Report TrailReportDto `json:"report"`
	}
	_ = json.Unmarshal(deerRaw, &deerWrap)

	// Advance past deer expiry (t0 + 6h > t0 + 5h) and run Cron GC:
	// deer must become `resolved`, while permanent `spring` survives active!
	curTime = t0.Add(6 * time.Hour)
	if err := RunTrailLiveGC(app, hub, curTime); err != nil {
		t.Fatalf("RunTrailLiveGC: %v", err)
	}

	deerRec, err := app.FindRecordById("trail_reports", deerWrap.Report.ID)
	if err != nil {
		t.Fatal(err)
	}
	if deerRec.GetString("condition_status") != "resolved" {
		t.Fatalf("expired deer status = %q, want resolved", deerRec.GetString("condition_status"))
	}

	springRec, err := app.FindRecordById("trail_reports", spring.ID)
	if err != nil {
		t.Fatal(err)
	}
	if springRec.GetString("condition_status") != "active" {
		t.Fatalf("permanent spring must survive GC untouched, got status=%q", springRec.GetString("condition_status"))
	}
}

func TestTrailLiveSosPushTargetsRespondersAndSSE(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	curTime := time.Date(2026, 11, 17, 14, 0, 0, 0, time.UTC)
	handler.Now = func() time.Time { return curTime }

	// SOS center: Omu Peak area (45.4450, 25.4560)
	// Near subscriber (~1.1 km south): (45.4350, 25.4560)
	// Presence-updated subscriber: initially subscribed in Bucharest (44.4268, 26.1025, ~125 km away),
	//   then walked within ~2.2 km (45.4250, 25.4560) via heartbeat!
	// Far subscriber (~125 km away in Bucharest, different trail): (44.4268, 26.1025)

	for _, sub := range []struct {
		dev  string
		body string
	}{
		{"dev-victim", `{"endpoint":"https://push.example/victim","p256dh":"k-victim","auth":"a-victim","lat":45.4450,"lon":25.4560,"trailId":"trail-omu"}`},
		{"dev-near", `{"endpoint":"https://push.example/near","p256dh":"k-near","auth":"a-near","lat":45.4350,"lon":25.4560,"trailId":"trail-other"}`},
		{"dev-presence", `{"endpoint":"https://push.example/presence","p256dh":"k-pres","auth":"a-pres","lat":44.4268,"lon":26.1025,"trailId":"trail-bucharest"}`},
		{"dev-far", `{"endpoint":"https://push.example/far","p256dh":"k-far","auth":"a-far","lat":44.4268,"lon":26.1025,"trailId":"trail-bucharest"}`},
	} {
		st, raw := invokeLiveHandler(t, app, handler.PushSubscribe, liveCallOptions{
			method:     http.MethodPost,
			target:     "/live/push/subscribe",
			body:       sub.body,
			secret:     testLiveSecret,
			deviceHash: sub.dev,
		})
		if st != http.StatusOK {
			t.Fatalf("push subscribe(%s) status = %d: %s", sub.dev, st, raw)
		}
	}

	// dev-presence sends a trail presence heartbeat 2.2 km from Omu Peak.
	st, _ := invokeLiveHandler(t, app, handler.Heartbeat, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/heartbeat",
		body:       `{"trailId":"trail-omu","lat":45.4250,"lon":25.4560,"ele":2300,"inNavigation":true}`,
		secret:     testLiveSecret,
		deviceHash: "dev-presence",
	})
	if st != http.StatusOK {
		t.Fatalf("dev-presence heartbeat status = %d", st)
	}

	// Connect SSE subscribers: victim, near hiker (~1.1 km), and far hiker (~125 km).
	subVictim, unsubVictim := hub.Subscribe(45.4450, 25.4560, true, "trail-omu", "dev-victim")
	defer unsubVictim()
	subNear, unsubNear := hub.Subscribe(45.4350, 25.4560, true, "trail-other", "dev-near")
	defer unsubNear()
	subFar, unsubFar := hub.Subscribe(44.4268, 26.1025, true, "trail-bucharest", "dev-far")
	defer unsubFar()

	// Trigger SOS from dev-victim!
	st, sosRaw := invokeLiveHandler(t, app, handler.CreateSos, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/sos",
		body:       `{"trailId":"trail-omu","reason":"injury","message":"Entorsă la gleznă sub Vârful Omu","requesterName":"Andrei","lat":45.4450,"lon":25.4560,"ele":2480}`,
		secret:     testLiveSecret,
		deviceHash: "dev-victim",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateSos status = %d: %s", st, sosRaw)
	}

	var createSosResp struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
	}
	if err := json.Unmarshal(sosRaw, &createSosResp); err != nil {
		t.Fatal(err)
	}
	if !createSosResp.Sos.IsMine || createSosResp.Sos.Status != "active" || createSosResp.Sos.ResponderCount != 0 {
		t.Fatalf("unexpected created SOS DTO: %+v", createSosResp.Sos)
	}

	// PushTargets must include ONLY near (~1112m) and presence (~2224m), NOT victim or far!
	gotEndpoints := map[string]float64{}
	for _, pt := range createSosResp.PushTargets {
		gotEndpoints[pt.Endpoint] = pt.DistanceM
	}
	if len(gotEndpoints) != 2 {
		t.Fatalf("expected exactly 2 pushTargets within 5 km, got %d: %+v", len(gotEndpoints), createSosResp.PushTargets)
	}
	if _, ok := gotEndpoints["https://push.example/near"]; !ok {
		t.Fatalf("missing near pushTarget: %+v", gotEndpoints)
	}
	if _, ok := gotEndpoints["https://push.example/presence"]; !ok {
		t.Fatalf("missing presence-matched pushTarget: %+v", gotEndpoints)
	}
	if _, ok := gotEndpoints["https://push.example/victim"]; ok {
		t.Fatalf("caller's own push subscription must be excluded!")
	}
	if _, ok := gotEndpoints["https://push.example/far"]; ok {
		t.Fatalf("25km+ push subscription must be excluded!")
	}

	// Verify SSE broadcasts: victim gets isMine=true, near gets isMine=false, far gets nothing!
	select {
	case victimFrame := <-subVictim.Ch:
		if !strings.Contains(victimFrame, "event: sos_update\n") || !strings.Contains(victimFrame, `"isMine":true`) {
			t.Fatalf("victim SSE frame expected isMine:true, got %s", victimFrame)
		}
	default:
		t.Fatal("expected victim SSE subscriber to receive sos_update")
	}

	select {
	case nearFrame := <-subNear.Ch:
		if !strings.Contains(nearFrame, "event: sos_update\n") || !strings.Contains(nearFrame, `"isMine":false`) {
			t.Fatalf("near SSE frame expected isMine:false, got %s", nearFrame)
		}
	default:
		t.Fatal("expected near 5km SSE subscriber to receive sos_update")
	}

	select {
	case farFrame := <-subFar.Ch:
		t.Fatalf("far subscriber outside 5km must NOT receive sos_update, got %s", farFrame)
	default:
	}

	sosID := createSosResp.Sos.ID

	// Responder 1 ("dev-presence", 2200m, ETA 1800s) and Responder 2 ("dev-near", 1110m, ETA 920s) tap "coming"!
	for _, r := range []struct {
		dev  string
		body string
	}{
		{"dev-presence", `{"status":"coming","lat":45.4250,"lon":25.4560,"ele":2300,"distanceM":2200,"etaSec":1800}`},
		{"dev-near", `{"status":"coming","lat":45.4350,"lon":25.4560,"ele":2390,"distanceM":1110,"etaSec":920}`},
	} {
		st, raw := invokeLiveHandler(t, app, handler.RespondSos, liveCallOptions{
			method:     http.MethodPost,
			target:     "/live/sos/" + sosID + "/respond",
			body:       r.body,
			secret:     testLiveSecret,
			deviceHash: r.dev,
			pathValues: map[string]string{"id": sosID},
		})
		if st != http.StatusOK {
			t.Fatalf("RespondSos(%s) status = %d: %s", r.dev, st, raw)
		}
	}

	// Check summary / responder metrics: responderCount == 2, nearestDistanceM == 1110, nearestEtaSec == 920
	st, sumRaw := invokeLiveHandler(t, app, handler.TrailSummary, liveCallOptions{
		method:     http.MethodGet,
		target:     "/live/trail/trail-omu/summary",
		secret:     testLiveSecret,
		deviceHash: "dev-near",
		pathValues: map[string]string{"id": "trail-omu"},
	})
	if st != http.StatusOK {
		t.Fatalf("summary status = %d", st)
	}
	var sumResp struct {
		SosAlerts []SosAlertDto `json:"sosAlerts"`
	}
	_ = json.Unmarshal(sumRaw, &sumResp)
	if len(sumResp.SosAlerts) != 1 {
		t.Fatalf("expected 1 active SOS on trail-omu, got %d", len(sumResp.SosAlerts))
	}
	gotSos := sumResp.SosAlerts[0]
	if gotSos.ResponderCount != 2 || gotSos.NearestDistanceM == nil || *gotSos.NearestDistanceM != 1110 || gotSos.NearestEtaSec == nil || *gotSos.NearestEtaSec != 920 || !gotSos.AmResponding {
		t.Fatalf("unexpected responder stats on SOS: %+v", gotSos)
	}

	// Non-owner PATCH /live/sos/{id} must return 403 Forbidden; owner PATCH resolves cleanly.
	st, _ = invokeLiveHandler(t, app, handler.UpdateSos, liveCallOptions{
		method:     http.MethodPatch,
		target:     "/live/sos/" + sosID,
		body:       `{"status":"resolved"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-near",
		pathValues: map[string]string{"id": sosID},
	})
	if st != http.StatusForbidden {
		t.Fatalf("non-owner PATCH SOS status = %d, want 403", st)
	}

	st, _ = invokeLiveHandler(t, app, handler.UpdateSos, liveCallOptions{
		method:     http.MethodPatch,
		target:     "/live/sos/" + sosID,
		body:       `{"status":"resolved"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-victim",
		pathValues: map[string]string{"id": sosID},
	})
	if st != http.StatusOK {
		t.Fatalf("owner PATCH SOS status = %d, want 200", st)
	}

	// Background stale endpoint cleanup (DELETE /live/push/subscribe called with SOS sender's deviceHash)
	st, _ = invokeLiveHandler(t, app, handler.PushUnsubscribe, liveCallOptions{
		method:     http.MethodDelete,
		target:     "/live/push/subscribe",
		body:       `{"endpoint":"https://push.example/far"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-victim",
	})
	if st != http.StatusOK {
		t.Fatalf("PushUnsubscribe status = %d, want 200", st)
	}
	if _, err := app.FindFirstRecordByData("push_subscriptions", "endpoint", "https://push.example/far"); err == nil {
		t.Fatal("expected stale push subscription endpoint to be deleted")
	}

	// Verify GET /live/stream HTTP streaming + keepalive comment
	hub.SetKeepaliveInterval(15 * time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/live/stream?lat=45.4450&lon=25.4560&trailId=trail-omu", nil).WithContext(ctx)
	req.Header.Set("X-Internal-Secret", testLiveSecret)
	rec := httptest.NewRecorder()
	ev := &core.RequestEvent{App: app}
	ev.Request = req
	ev.Response = rec

	done := make(chan error, 1)
	go func() {
		done <- handler.Stream(ev)
	}()

	time.Sleep(40 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Stream returned error: %v", err)
	}
	streamOut := rec.Body.String()
	if !strings.Contains(streamOut, ": keepalive\n\n") {
		t.Fatalf("expected SSE keepalive comment in stream output, got %q", streamOut)
	}
}
