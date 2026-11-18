package routes

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"pocketbase/services/live"
)

func testComputeClaimHash(t *testing.T, secretHex32 string) string {
	t.Helper()
	secretBytes, err := hex.DecodeString(strings.ToLower(strings.TrimSpace(secretHex32)))
	if err != nil || len(secretBytes) != 16 {
		t.Fatalf("invalid test secretHex32 %q: len=%d err=%v", secretHex32, len(secretBytes), err)
	}
	sum := sha256.Sum256(append([]byte("trasee-sos-claim-v1:"), secretBytes...))
	return hex.EncodeToString(sum[:8])
}

func TestTrailLiveSosRelaySchemaAndPartialUniqueIndex(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	sosCol, err := app.FindCollectionByNameOrId("sos_alerts")
	if err != nil {
		t.Fatalf("sos_alerts collection missing: %v", err)
	}

	if f := sosCol.Fields.GetByName("client_sos_id"); f == nil {
		t.Fatal("sos_alerts.client_sos_id field missing")
	}
	if f := sosCol.Fields.GetByName("sos_claim_hash"); f == nil || !f.GetHidden() {
		t.Fatal("sos_alerts.sos_claim_hash must exist and be hidden")
	}
	if f := sosCol.Fields.GetByName("last_packet_epoch"); f == nil {
		t.Fatal("sos_alerts.last_packet_epoch field missing")
	}
	if f := sosCol.Fields.GetByName("relayed_by_hash"); f == nil || !f.GetHidden() {
		t.Fatal("sos_alerts.relayed_by_hash must exist and be hidden")
	}

	idxDef := sosCol.GetIndex("idx_sos_alerts_client_sos_id")
	if idxDef == "" || !strings.Contains(strings.ToUpper(idxDef), "UNIQUE") || !strings.Contains(idxDef, "client_sos_id != ''") {
		t.Fatalf("expected partial unique index idx_sos_alerts_client_sos_id with WHERE client_sos_id != '', got %q", idxDef)
	}

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	// Legacy online SOS rows have client_sos_id = "" — multiple rows must NEVER collide on the partial unique index!
	for i := 1; i <= 2; i++ {
		st, raw := invokeLiveHandler(t, app, handler.CreateSos, liveCallOptions{
			method:     http.MethodPost,
			target:     "/live/sos",
			body:       fmt.Sprintf(`{"trailId":"trail-legacy","reason":"lost","lat":45.40%d,"lon":25.54%d}`, i, i),
			secret:     testLiveSecret,
			deviceHash: fmt.Sprintf("legacy-dev-%d", i),
		})
		if st != http.StatusOK {
			t.Fatalf("legacy CreateSos #%d failed with status=%d body=%s", i, st, raw)
		}
	}

	// Non-empty duplicate client_sos_id at DB level must be rejected by partial unique index!
	rec1 := core.NewRecord(sosCol)
	rec1.Set("status", "active")
	rec1.Set("reason", "injury")
	rec1.Set("lat", 45.44)
	rec1.Set("lon", 25.45)
	rec1.Set("client_sos_id", "a1b2c3d4e5f60718")
	if err := app.Save(rec1); err != nil {
		t.Fatalf("save first non-empty client_sos_id failed: %v", err)
	}

	rec2 := core.NewRecord(sosCol)
	rec2.Set("status", "active")
	rec2.Set("reason", "injury")
	rec2.Set("lat", 45.44)
	rec2.Set("lon", 25.45)
	rec2.Set("client_sos_id", "a1b2c3d4e5f60718")
	if err := app.Save(rec2); err == nil {
		t.Fatal("expected duplicate non-empty client_sos_id to fail unique index constraint")
	}

	// Auth checks on POST /live/sos/relay
	st, _ := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/sos/relay",
		body:       `{"clientSosId":"0123456789abcdef","sosClaimHash":"fedcba9876543210","lat":45.44,"lon":25.45}`,
		deviceHash: "mule-1",
	})
	if st != http.StatusUnauthorized {
		t.Fatalf("RelaySos missing X-Internal-Secret status = %d, want 401", st)
	}

	st, _ = invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body:   `{"clientSosId":"0123456789abcdef","sosClaimHash":"fedcba9876543210","lat":45.44,"lon":25.45}`,
		secret: testLiveSecret,
	})
	if st != http.StatusBadRequest {
		t.Fatalf("RelaySos missing X-Device-Hash status = %d, want 400", st)
	}
}

func TestTrailLiveSosRelayMultiMuleDedupDriftAndClamping(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	curTime := time.Date(2026, 11, 18, 13, 0, 0, 0, time.UTC)
	handler.Now = func() time.Time { return curTime }

	clientSosID := "8f7e6d5c4b3a2910"
	sosClaimSecret := "000102030405060708090a0b0c0d0e0f"
	sosClaimHash := testComputeClaimHash(t, sosClaimSecret)

	// Register push subscriptions for Mule B, a nearby hiker (~1.1 km), and a distant user (~125 km).
	for _, sub := range []struct {
		dev  string
		body string
	}{
		{"dev-mule-b", `{"endpoint":"https://push.example/mule-b","p256dh":"k-b","auth":"a-b","lat":45.4450,"lon":25.4560,"trailId":"trail-omu"}`},
		{"dev-near", `{"endpoint":"https://push.example/near","p256dh":"k-near","auth":"a-near","lat":45.4350,"lon":25.4560,"trailId":"trail-other"}`},
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
			t.Fatalf("PushSubscribe(%s) status = %d: %s", sub.dev, st, raw)
		}
	}

	subMuleB, unsubMuleB := hub.Subscribe(45.4450, 25.4560, true, "trail-omu", "dev-mule-b")
	defer unsubMuleB()
	subNear, unsubNear := hub.Subscribe(45.4350, 25.4560, true, "trail-other", "dev-near")
	defer unsubNear()
	subFar, unsubFar := hub.Subscribe(44.4268, 26.1025, true, "trail-bucharest", "dev-far")
	defer unsubFar()

	epochB := curTime.Unix() - 300 // SOS originated 5 minutes ago offline

	// 1. Mule B uploads relayed SOS alert first -> created: true, isMine: false for Mule B, pushTargets excludes Mule B!
	st, rawB := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","message":"<b>Fractură</b> sub Omu","requesterName":"Elena","lat":45.4450,"lon":25.4560,"ele":2480,"packetEpochSec":%d,"hopCount":2}`,
			strings.ToUpper(clientSosID), strings.ToUpper(sosClaimHash), epochB,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-b",
	})
	if st != http.StatusOK {
		t.Fatalf("Mule B RelaySos status = %d: %s", st, rawB)
	}
	if strings.Contains(string(rawB), "dev-mule-b") || strings.Contains(string(rawB), sosClaimHash) {
		t.Fatalf("PRIVACY VIOLATION: RelaySos leaked hidden fields: %s", rawB)
	}

	var respB struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
		Created     bool            `json:"created"`
	}
	if err := json.Unmarshal(rawB, &respB); err != nil {
		t.Fatalf("unmarshal Mule B response: %v", err)
	}
	if !respB.Created {
		t.Fatalf("expected created=true for first Mule B, got false")
	}
	if respB.Sos.IsMine {
		t.Fatalf("Mule B must NEVER become owner (expected isMine=false, got true)")
	}
	if respB.Sos.ClientSosID != clientSosID || respB.Sos.Message != "Fractură sub Omu" || respB.Sos.Status != "active" {
		t.Fatalf("unexpected relayed SOS DTO: %+v", respB.Sos)
	}
	if len(respB.PushTargets) != 1 || respB.PushTargets[0].Endpoint != "https://push.example/near" {
		t.Fatalf("expected only dev-near pushTarget (excluding dev-mule-b and dev-far), got %+v", respB.PushTargets)
	}

	// Verify DB row has empty device_hash and hidden audit fields populated.
	dbRec, err := app.FindRecordById("sos_alerts", respB.Sos.ID)
	if err != nil {
		t.Fatal(err)
	}
	if dbRec.GetString("device_hash") != "" {
		t.Fatalf("expected unclaimed relayed sos_alerts.device_hash == \"\", got %q", dbRec.GetString("device_hash"))
	}
	if dbRec.GetString("relayed_by_hash") != "dev-mule-b" {
		t.Fatalf("expected relayed_by_hash == dev-mule-b, got %q", dbRec.GetString("relayed_by_hash"))
	}

	// Verify SSE frames: both Mule B and Near subscriber see isMine:false, Far subscriber gets nothing!
	for name, ch := range map[string]<-chan []byte{"muleB": subMuleB.Ch, "near": subNear.Ch} {
		select {
		case rawFrame := <-ch:
			frame := string(rawFrame)
			if !strings.Contains(frame, `"isMine":false`) || !strings.Contains(frame, fmt.Sprintf(`"clientSosId":%q`, clientSosID)) {
				t.Fatalf("SSE frame for %s expected isMine:false and clientSosId, got %s", name, frame)
			}
		default:
			t.Fatalf("expected %s SSE subscriber to receive sos_update", name)
		}
	}
	select {
	case frame := <-subFar.Ch:
		t.Fatalf("far subscriber must not receive sos_update, got %s", string(frame))
	default:
	}

	// 2. Mule C uploads the SAME packet (equal/older packetEpochSec) -> created: false, pushTargets: [], no duplicate row!
	st, rawC := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","lat":45.4460,"lon":25.4570,"ele":2475,"packetEpochSec":%d,"hopCount":3}`,
			clientSosID, sosClaimHash, epochB,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-c",
	})
	if st != http.StatusOK {
		t.Fatalf("Mule C RelaySos status = %d: %s", st, rawC)
	}
	if !strings.Contains(string(rawC), `"pushTargets":[]`) {
		t.Fatalf("expected empty JSON array pushTargets:[], got %s", rawC)
	}
	var respC struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
		Created     bool            `json:"created"`
	}
	_ = json.Unmarshal(rawC, &respC)
	if respC.Created || len(respC.PushTargets) != 0 || respC.Sos.ID != respB.Sos.ID || respC.Sos.IsMine {
		t.Fatalf("unexpected Mule C dedup response: %+v", respC)
	}
	if respC.Sos.Lat != 45.4450 || respC.Sos.Lon != 25.4560 {
		t.Fatalf("equal packetEpochSec must not overwrite coords, got (%v, %v)", respC.Sos.Lat, respC.Sos.Lon)
	}

	// 3. Mule D uploads a NEWER packet from victim moving ~300 m downhill, with skewed future epoch (now + 600s -> clamped to now + 120s)!
	skewedEpochD := curTime.Unix() + 600
	st, rawD := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","lat":45.4430,"lon":25.4550,"ele":2410,"packetEpochSec":%d,"hopCount":1}`,
			clientSosID, sosClaimHash, skewedEpochD,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-d",
	})
	if st != http.StatusOK {
		t.Fatalf("Mule D RelaySos status = %d: %s", st, rawD)
	}
	var respD struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
		Created     bool            `json:"created"`
	}
	_ = json.Unmarshal(rawD, &respD)
	if respD.Created || len(respD.PushTargets) != 0 || respD.Sos.Lat != 45.4430 || respD.Sos.Lon != 25.4550 || respD.Sos.Ele != 2410 {
		t.Fatalf("expected Mule D newer epoch within 10km to update coords without pushTargets, got %+v", respD)
	}

	dbRecAfterD, _ := app.FindRecordById("sos_alerts", respB.Sos.ID)
	wantClampedEpoch := curTime.Unix() + 120
	if int64(dbRecAfterD.GetFloat("last_packet_epoch")) != wantClampedEpoch {
		t.Fatalf("expected last_packet_epoch clamped to now+120s (%d), got %v", wantClampedEpoch, dbRecAfterD.GetFloat("last_packet_epoch"))
	}

	totalCount, err := app.CountRecords("sos_alerts")
	if err != nil || totalCount != 1 {
		t.Fatalf("expected exactly 1 sos_alerts row after 3 mules (B, C, D), got %d (err=%v)", totalCount, err)
	}

	// Drain subNear SSE update from Mule D's coordinate refresh.
	select {
	case rawFrameD := <-subNear.Ch:
		frameD := string(rawFrameD)
		if !strings.Contains(frameD, "45.443") {
			t.Fatalf("expected SSE update with Mule D coords, got %s", frameD)
		}
	default:
		t.Fatal("expected SSE sos_update when Mule D updated coordinates")
	}

	// 3b. Cumulative multi-hop drift check: moving 7 km north is <= 10 km from origin (45.4450 -> 45.5080, ~7.0 km),
	// then attempting another 5 km north (45.5530, ~12.0 km from origin, though only 5 km from previous update) MUST be rejected!
	curTime = curTime.Add(3 * time.Minute)
	st, raw7km := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","lat":45.5080,"lon":25.4560,"ele":2300,"packetEpochSec":%d}`,
			clientSosID, sosClaimHash, curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-7km",
	})
	if st != http.StatusOK {
		t.Fatalf("7km RelaySos status = %d: %s", st, raw7km)
	}
	// Drain SSE frame from 7km update.
	select {
	case <-subNear.Ch:
	default:
	}

	curTime = curTime.Add(1 * time.Minute)
	st, raw12km := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","lat":45.5530,"lon":25.4560,"ele":2200,"packetEpochSec":%d}`,
			clientSosID, sosClaimHash, curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-12km",
	})
	if st != http.StatusOK {
		t.Fatalf("12km cumulative drift RelaySos status = %d: %s", st, raw12km)
	}
	var resp12km struct {
		Sos SosAlertDto `json:"sos"`
	}
	_ = json.Unmarshal(raw12km, &resp12km)
	if resp12km.Sos.Lat != 45.5080 {
		t.Fatalf("cumulative >10km drift from original coordinates must be rejected, got lat=%v (want 45.5080)", resp12km.Sos.Lat)
	}

	// 4. Advance clock +5m so a new packet has epoch > clampedEpoch, but coords are > 10,000m away (~125 km in Bucharest) -> must NOT teleport pin!
	curTime = curTime.Add(5 * time.Minute)
	st, rawTeleport := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","lat":44.4268,"lon":26.1025,"ele":85,"packetEpochSec":%d}`,
			clientSosID, sosClaimHash, curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-rogue-mule",
	})
	if st != http.StatusOK {
		t.Fatalf("drift-clamped RelaySos status = %d: %s", st, rawTeleport)
	}
	var respTeleport struct {
		Sos SosAlertDto `json:"sos"`
	}
	_ = json.Unmarshal(rawTeleport, &respTeleport)
	if respTeleport.Sos.Lat != 45.5080 || respTeleport.Sos.Lon != 25.4560 {
		t.Fatalf("coords >10km from origin must be rejected, got (%v, %v)", respTeleport.Sos.Lat, respTeleport.Sos.Lon)
	}

	// 5. Spoofed sosClaimHash for existing clientSosId -> 403 Forbidden!
	st, _ = invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":"deadbeefcafebabe","trailId":"trail-omu","reason":"injury","lat":45.4435,"lon":25.4555,"packetEpochSec":%d}`,
			clientSosID, curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-spoof-hash",
	})
	if st != http.StatusForbidden {
		t.Fatalf("mismatched sosClaimHash status = %d, want 403", st)
	}
}

func TestTrailLiveSosRelayResolutionPreimageVerification(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	curTime := time.Date(2026, 11, 18, 15, 0, 0, 0, time.UTC)
	handler.Now = func() time.Time { return curTime }

	clientSosID := "1122334455667788"
	validSecret := "aabbccddeeff00112233445566778899"
	wrongSecret := "ffeeddccbbaa99887766554433221100"
	claimHash := testComputeClaimHash(t, validSecret)

	// Mule B uploads active SOS alert.
	st, rawCreate := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-fagaras","reason":"exhaustion","lat":45.5990,"lon":24.7360,"ele":2500,"packetEpochSec":%d}`,
			clientSosID, claimHash, curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-b",
	})
	if st != http.StatusOK {
		t.Fatalf("setup RelaySos status = %d: %s", st, rawCreate)
	}

	subNear, unsubNear := hub.Subscribe(45.6000, 24.7370, true, "trail-fagaras", "dev-hiker-fagaras")
	defer unsubNear()

	// 1. Rogue resolution with MISSING sosClaimSecret -> 403 Forbidden!
	st, _ = invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/sos/relay",
		body:       fmt.Sprintf(`{"clientSosId":%q,"sosClaimHash":%q,"status":"resolved"}`, clientSosID, claimHash),
		secret:     testLiveSecret,
		deviceHash: "dev-rogue-1",
	})
	if st != http.StatusForbidden {
		t.Fatalf("missing sosClaimSecret resolve status = %d, want 403", st)
	}

	// 2. Rogue resolution with WRONG 32-hex sosClaimSecret -> 403 Forbidden!
	st, _ = invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/sos/relay",
		body:       fmt.Sprintf(`{"clientSosId":%q,"status":"resolved","sosClaimSecret":%q}`, clientSosID, wrongSecret),
		secret:     testLiveSecret,
		deviceHash: "dev-rogue-2",
	})
	if st != http.StatusForbidden {
		t.Fatalf("wrong sosClaimSecret resolve status = %d, want 403", st)
	}

	// 3. Rogue resolution attempting to pass public 16-hex sosClaimHash as secret -> 403 Forbidden!
	st, _ = invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/sos/relay",
		body:       fmt.Sprintf(`{"clientSosId":%q,"status":"resolved","sosClaimSecret":%q}`, clientSosID, claimHash),
		secret:     testLiveSecret,
		deviceHash: "dev-rogue-3",
	})
	if st != http.StatusForbidden {
		t.Fatalf("public claimHash used as secret status = %d, want 403", st)
	}

	// Confirm no SSE resolution leaked and DB record is still active!
	select {
	case unexpected := <-subNear.Ch:
		t.Fatalf("rogue resolution must not broadcast SSE, got %s", string(unexpected))
	default:
	}

	// 4. Valid preimage sosClaimSecret resolves cleanly (even without lat/lon or sosClaimHash in PKT_SOS_RESOLVED) and broadcasts SSE!
	curTime = curTime.Add(10 * time.Minute)
	st, rawRes := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"status":"resolved","sosClaimSecret":%q,"packetEpochSec":%d}`,
			clientSosID, strings.ToUpper(validSecret), curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-good-mule",
	})
	if st != http.StatusOK {
		t.Fatalf("valid sosClaimSecret resolve status = %d: %s", st, rawRes)
	}

	var resWrap struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
		Created     bool            `json:"created"`
	}
	if err := json.Unmarshal(rawRes, &resWrap); err != nil {
		t.Fatal(err)
	}
	if resWrap.Created || len(resWrap.PushTargets) != 0 || resWrap.Sos.Status != "resolved" {
		t.Fatalf("unexpected resolved response: %+v", resWrap)
	}

	select {
	case rawSSE := <-subNear.Ch:
		sseFrame := string(rawSSE)
		if !strings.Contains(sseFrame, "event: sos_update\n") || !strings.Contains(sseFrame, `"status":"resolved"`) {
			t.Fatalf("expected SSE sos_update with status:resolved, got %s", sseFrame)
		}
	default:
		t.Fatal("expected SSE sos_update on valid relayed resolution")
	}
}

func TestTrailLiveSosVictim4GRecoveryClaimAndUpdateSos(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	curTime := time.Date(2026, 11, 18, 16, 0, 0, 0, time.UTC)
	handler.Now = func() time.Time { return curTime }

	// Subscribe a nearby push endpoint to confirm Victim's 4G claim does NOT re-spam Web Push.
	_, _ = invokeLiveHandler(t, app, handler.PushSubscribe, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/push/subscribe",
		body:       `{"endpoint":"https://push.example/rescuer","p256dh":"k-r","auth":"a-r","lat":45.4400,"lon":25.4560,"trailId":"trail-omu"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-rescuer-1",
	})

	// --- Scenario A: Mule relays first -> Rescuer responds -> Victim regains 4G and calls CreateSos ---
	clientSosA := "aaaa1111bbbb2222"
	secretA := "102030405060708090a0b0c0d0e0f001"
	hashA := testComputeClaimHash(t, secretA)

	st, rawRelayA := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"injury","message":"Offline SOS","requesterName":"Mihai","lat":45.4450,"lon":25.4560,"ele":2480,"packetEpochSec":%d}`,
			clientSosA, hashA, curTime.Unix()-120,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-1",
	})
	if st != http.StatusOK {
		t.Fatalf("RelaySos A status = %d: %s", st, rawRelayA)
	}
	var relayRespA struct {
		Sos SosAlertDto `json:"sos"`
	}
	_ = json.Unmarshal(rawRelayA, &relayRespA)
	sosIDA := relayRespA.Sos.ID

	// Rescuer taps "Vin să ajut" before Victim has 4G!
	curTime = curTime.Add(2 * time.Minute)
	st, _ = invokeLiveHandler(t, app, handler.RespondSos, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/sos/" + sosIDA + "/respond",
		body:       `{"status":"coming","lat":45.4400,"lon":25.4560,"ele":2400,"distanceM":620,"etaSec":480}`,
		secret:     testLiveSecret,
		deviceHash: "dev-rescuer-1",
		pathValues: map[string]string{"id": sosIDA},
	})
	if st != http.StatusOK {
		t.Fatalf("RespondSos status = %d", st)
	}

	// Impersonator tries to claim via CreateSos with wrong secret -> 403 Forbidden!
	st, _ = invokeLiveHandler(t, app, handler.CreateSos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimSecret":"ffffffffffffffffffffffffffffffff","trailId":"trail-omu","reason":"injury","lat":45.4450,"lon":25.4560}`,
			clientSosA,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-impersonator",
	})
	if st != http.StatusForbidden {
		t.Fatalf("impersonator CreateSos claim status = %d, want 403", st)
	}

	subVictim, unsubVictim := hub.Subscribe(45.4451, 25.4561, true, "trail-omu", "dev-victim-a")
	defer unsubVictim()

	// Victim A regains 4G and calls CreateSos with valid clientSosId + sosClaimSecret!
	curTime = curTime.Add(1 * time.Minute)
	st, rawClaimA := invokeLiveHandler(t, app, handler.CreateSos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimSecret":%q,"trailId":"trail-omu","reason":"injury","message":"Offline SOS","requesterName":"Mihai","lat":45.4451,"lon":25.4561,"ele":2482}`,
			clientSosA, secretA,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-victim-a",
	})
	if st != http.StatusOK {
		t.Fatalf("Victim A CreateSos claim status = %d: %s", st, rawClaimA)
	}

	var claimRespA struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
	}
	if err := json.Unmarshal(rawClaimA, &claimRespA); err != nil {
		t.Fatal(err)
	}
	if claimRespA.Sos.ID != sosIDA {
		t.Fatalf("expected Victim A to claim existing SOS row %s, got new id %s", sosIDA, claimRespA.Sos.ID)
	}
	if !claimRespA.Sos.IsMine {
		t.Fatalf("expected claimed SOS to have isMine=true for Victim A")
	}
	if claimRespA.Sos.ResponderCount != 1 || claimRespA.Sos.NearestEtaSec == nil || *claimRespA.Sos.NearestEtaSec == 0 {
		t.Fatalf("expected claimed SOS to preserve responderCount=1 and nearestEtaSec, got %+v", claimRespA.Sos)
	}
	if len(claimRespA.PushTargets) != 0 {
		t.Fatalf("expected 0 duplicate pushTargets on claim, got %+v", claimRespA.PushTargets)
	}

	select {
	case rawVictimSSE := <-subVictim.Ch:
		victimSSE := string(rawVictimSSE)
		if !strings.Contains(victimSSE, `"isMine":true`) {
			t.Fatalf("expected Victim SSE frame to have isMine:true after ownership claim, got %s", victimSSE)
		}
	default:
		t.Fatal("expected Victim SSE subscriber to receive sos_update on claim")
	}

	// --- Scenario B: Unclaimed Relayed SOS -> Victim calls PATCH /live/sos/{id} with sosClaimSecret ---
	clientSosB := "cccc3333dddd4444"
	secretB := "99887766554433221100ffeeddccbbaa"
	hashB := testComputeClaimHash(t, secretB)

	st, rawRelayB := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"lost","lat":45.4460,"lon":25.4570,"packetEpochSec":%d}`,
			clientSosB, hashB, curTime.Unix(),
		),
		secret:     testLiveSecret,
		deviceHash: "dev-mule-2",
	})
	if st != http.StatusOK {
		t.Fatalf("RelaySos B status = %d: %s", st, rawRelayB)
	}
	var relayRespB struct {
		Sos SosAlertDto `json:"sos"`
	}
	_ = json.Unmarshal(rawRelayB, &relayRespB)
	sosIDB := relayRespB.Sos.ID

	// PATCH without secret on unclaimed SOS -> 403 Forbidden
	st, _ = invokeLiveHandler(t, app, handler.UpdateSos, liveCallOptions{
		method:     http.MethodPatch,
		target:     "/live/sos/" + sosIDB,
		body:       `{"status":"resolved"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-victim-b",
		pathValues: map[string]string{"id": sosIDB},
	})
	if st != http.StatusForbidden {
		t.Fatalf("PATCH unclaimed SOS without secret status = %d, want 403", st)
	}

	// PATCH with valid sosClaimSecret -> 200 OK, binds ownership & resolves!
	st, rawPatchB := invokeLiveHandler(t, app, handler.UpdateSos, liveCallOptions{
		method:     http.MethodPatch,
		target:     "/live/sos/" + sosIDB,
		body:       fmt.Sprintf(`{"status":"resolved","sosClaimSecret":%q}`, secretB),
		secret:     testLiveSecret,
		deviceHash: "dev-victim-b",
		pathValues: map[string]string{"id": sosIDB},
	})
	if st != http.StatusOK {
		t.Fatalf("PATCH with valid sosClaimSecret status = %d: %s", st, rawPatchB)
	}
	var patchRespB struct {
		Sos SosAlertDto `json:"sos"`
	}
	_ = json.Unmarshal(rawPatchB, &patchRespB)
	if !patchRespB.Sos.IsMine || patchRespB.Sos.Status != "resolved" {
		t.Fatalf("expected isMine=true and status=resolved after secret-authenticated PATCH, got %+v", patchRespB.Sos)
	}

	// --- Scenario C: Victim creates online FIRST with clientSosId + sosClaimSecret, then Mule relays later ---
	clientSosC := "eeee5555ffff6666"
	secretC := "abcdef0123456789abcdef0123456789"
	hashC := testComputeClaimHash(t, secretC)

	st, rawCreateC := invokeLiveHandler(t, app, handler.CreateSos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimSecret":%q,"trailId":"trail-omu","reason":"other","lat":45.4420,"lon":25.4550,"ele":2400}`,
			clientSosC, secretC,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-victim-c",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateSos C status = %d: %s", st, rawCreateC)
	}
	var createRespC struct {
		Sos         SosAlertDto     `json:"sos"`
		PushTargets []PushTargetDto `json:"pushTargets"`
	}
	_ = json.Unmarshal(rawCreateC, &createRespC)
	if !createRespC.Sos.IsMine || createRespC.Sos.ClientSosID != clientSosC || len(createRespC.PushTargets) != 1 {
		t.Fatalf("expected online CreateSos with clientSosId to dispatch pushTargets, got %+v", createRespC)
	}

	// Mule later flushes BLE packet for clientSosC -> deduplicates cleanly while keeping Victim C as owner!
	st, rawLateMule := invokeLiveHandler(t, app, handler.RelaySos, liveCallOptions{
		method: http.MethodPost,
		target: "/live/sos/relay",
		body: fmt.Sprintf(
			`{"clientSosId":%q,"sosClaimHash":%q,"trailId":"trail-omu","reason":"other","lat":45.4420,"lon":25.4550,"packetEpochSec":%d}`,
			clientSosC, hashC, curTime.Unix()-30,
		),
		secret:     testLiveSecret,
		deviceHash: "dev-late-mule",
	})
	if st != http.StatusOK {
		t.Fatalf("late Mule RelaySos status = %d: %s", st, rawLateMule)
	}
	var lateMuleResp struct {
		Sos     SosAlertDto `json:"sos"`
		Created bool        `json:"created"`
	}
	_ = json.Unmarshal(rawLateMule, &lateMuleResp)
	if lateMuleResp.Created || lateMuleResp.Sos.IsMine || lateMuleResp.Sos.ID != createRespC.Sos.ID {
		t.Fatalf("expected late Mule to deduplicate against Victim C's online SOS, got %+v", lateMuleResp)
	}
	recC, _ := app.FindRecordById("sos_alerts", createRespC.Sos.ID)
	if recC.GetString("device_hash") != "dev-victim-c" {
		t.Fatalf("late Mule must not clobber existing owner device_hash, got %q", recC.GetString("device_hash"))
	}
}

func TestTrailLiveCreateGroupWithPreferredCodeOfflineSyncAndRouterMux(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	t0 := time.Date(2026, 11, 18, 11, 0, 0, 0, time.UTC)
	curTime := t0
	handler.Now = func() time.Time { return curTime }

	// 1. Invalid preferredCode (contains disallowed '0', '1', 'I', 'O' or wrong length) -> 400 Bad Request
	for _, bad := range []string{"OI10AB", "ABC", "ABCDEFG", "123456"} {
		st, _ := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
			method:     http.MethodPost,
			target:     "/live/groups",
			body:       fmt.Sprintf(`{"trailId":"trail-retezat","preferredCode":%q,"displayName":"Ana"}`, bad),
			secret:     testLiveSecret,
			deviceHash: "dev-groupmate-1",
		})
		if st != http.StatusBadRequest {
			t.Fatalf("CreateGroup(preferredCode=%q) status = %d, want 400", bad, st)
		}
	}

	// 2. First offline groupmate regains 4G and syncs offline group with preferredCode "k7m4p2" (normalized "K7M4P2").
	st, raw1 := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-retezat","preferredCode":"k7m4p2","displayName":"Ana","lat":45.3600,"lon":22.8700,"ele":2100,"accuracy":6}`,
		secret:     testLiveSecret,
		deviceHash: "dev-groupmate-1",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateGroup #1 with preferredCode status = %d: %s", st, raw1)
	}
	var sess1 GroupSessionDto
	if err := json.Unmarshal(raw1, &sess1); err != nil {
		t.Fatal(err)
	}
	if sess1.Code != "K7M4P2" || len(sess1.Members) != 1 || sess1.Members[0].DisplayName != "Ana" {
		t.Fatalf("expected group K7M4P2 with Ana, got %+v", sess1)
	}

	// 3. Second offline groupmate regains 4G 4 seconds later and also calls POST /live/groups with preferredCode "K7M4P2"!
	// Must join/upsert into the SAME active group without collision!
	curTime = t0.Add(4 * time.Second)
	st, raw2 := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-retezat","preferredCode":"K7M4P2","displayName":"Bogdan","lat":45.3605,"lon":22.8705,"ele":2105,"accuracy":5}`,
		secret:     testLiveSecret,
		deviceHash: "dev-groupmate-2",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateGroup #2 with existing active preferredCode status = %d: %s", st, raw2)
	}
	var sess2 GroupSessionDto
	if err := json.Unmarshal(raw2, &sess2); err != nil {
		t.Fatal(err)
	}
	wantMember2 := expectedDerivedMemberID("K7M4P2", "dev-groupmate-2")
	if sess2.Code != "K7M4P2" || sess2.SelfMemberID != wantMember2 || len(sess2.Members) != 2 {
		t.Fatalf("expected merged 2-member group K7M4P2 for Bogdan, got %+v", sess2)
	}

	// 3b. After 13h (> 12h TTL, before cron GC runs), an expired group with code K7M4P2 is cleanly replaced by a fresh group!
	curTime = t0.Add(13 * time.Hour)
	st, rawReused := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-piatra","preferredCode":"K7M4P2","displayName":"Cristina"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-groupmate-3",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateGroup replacing expired preferredCode status = %d: %s", st, rawReused)
	}
	var sessReused GroupSessionDto
	_ = json.Unmarshal(rawReused, &sessReused)
	if sessReused.Code != "K7M4P2" || sessReused.TrailID != "trail-piatra" || len(sessReused.Members) != 1 {
		t.Fatalf("expected fresh 1-member group K7M4P2 after expiry, got %+v", sessReused)
	}

	// 4. Verify real HTTP router mux wires POST /live/sos/relay!
	r, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("NewRouter: %v", err)
	}
	RegisterTrailLiveRoutes(&core.ServeEvent{App: app, Router: r}, hub)
	mux, err := r.BuildMux()
	if err != nil {
		t.Fatalf("BuildMux: %v", err)
	}

	secretMux := "0102030405060708090a0b0c0d0e0f10"
	hashMux := testComputeClaimHash(t, secretMux)
	req := httptest.NewRequest(
		http.MethodPost,
		"/live/sos/relay",
		strings.NewReader(fmt.Sprintf(`{"clientSosId":"9999888877776666","sosClaimHash":%q,"trailId":"trail-mux","reason":"lost","lat":45.40,"lon":25.50}`, hashMux)),
	)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Secret", testLiveSecret)
	req.Header.Set("X-Device-Hash", "dev-mux-mule")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("mux POST /live/sos/relay status = %d, body = %s", rec.Code, rec.Body.String())
	}
}
