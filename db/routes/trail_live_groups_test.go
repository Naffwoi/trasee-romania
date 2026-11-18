package routes

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"pocketbase/services/live"
)

const expectedGroupAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var expectedGroupPalette = []string{
	"#242734",
	"#0f766e",
	"#3730a3",
	"#0369a1",
	"#4d7c0f",
	"#6d28d9",
}

func expectedDerivedMemberID(code, deviceHash string) string {
	sum := sha256.Sum256([]byte("group-member:" + code + ":" + deviceHash))
	return hex.EncodeToString(sum[:])[:12]
}

func TestTrailLiveGroupsCollectionSchemaAndAuth(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	for _, name := range []string{"trail_groups", "trail_group_members"} {
		col, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			t.Fatalf("collection %q missing from migrated schema: %v", name, err)
		}
		if col.ListRule != nil || col.ViewRule != nil || col.CreateRule != nil || col.UpdateRule != nil || col.DeleteRule != nil {
			t.Fatalf("collection %q must have all API rules nil, got list=%v view=%v create=%v update=%v delete=%v",
				name, col.ListRule, col.ViewRule, col.CreateRule, col.UpdateRule, col.DeleteRule)
		}
	}

	groupsCol, _ := app.FindCollectionByNameOrId("trail_groups")
	if f := groupsCol.Fields.GetByName("owner_device_hash"); f == nil || !f.GetHidden() {
		t.Fatalf("trail_groups.owner_device_hash must exist and be hidden")
	}
	membersCol, _ := app.FindCollectionByNameOrId("trail_group_members")
	if f := membersCol.Fields.GetByName("device_hash"); f == nil || !f.GetHidden() {
		t.Fatalf("trail_group_members.device_hash must exist and be hidden")
	}

	handler := NewTrailLiveHandler(live.NewTrailLiveHub())

	// Missing X-Internal-Secret -> 401
	st, _ := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-bucegi","displayName":"Andrei"}`,
		deviceHash: "dev-secret-1",
	})
	if st != http.StatusUnauthorized {
		t.Fatalf("CreateGroup missing secret status = %d, want 401", st)
	}

	// Missing X-Device-Hash -> 400
	st, _ = invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method: http.MethodPost,
		target: "/live/groups",
		body:   `{"trailId":"trail-bucegi","displayName":"Andrei"}`,
		secret: testLiveSecret,
	})
	if st != http.StatusBadRequest {
		t.Fatalf("CreateGroup missing device hash status = %d, want 400", st)
	}

	// Invalid group code (ambiguous 0/O/1/I or wrong length) -> 400
	for _, badCode := range []string{"OI10AB", "ABC", "ABCDEFG"} {
		st, _ = invokeLiveHandler(t, app, handler.GetGroup, liveCallOptions{
			method:     http.MethodGet,
			target:     "/live/groups/" + badCode,
			secret:     testLiveSecret,
			deviceHash: "dev-secret-1",
			pathValues: map[string]string{"code": badCode},
		})
		if st != http.StatusBadRequest {
			t.Fatalf("GetGroup(%q) status = %d, want 400", badCode, st)
		}
	}

	// Valid code format that does not exist -> 404
	st, _ = invokeLiveHandler(t, app, handler.GetGroup, liveCallOptions{
		method:     http.MethodGet,
		target:     "/live/groups/ZZZZ99",
		secret:     testLiveSecret,
		deviceHash: "dev-secret-1",
		pathValues: map[string]string{"code": "ZZZZ99"},
	})
	if st != http.StatusNotFound {
		t.Fatalf("GetGroup(ZZZZ99) status = %d, want 404", st)
	}
}

func TestTrailLiveGroupsLifecyclePrivacyAndPrivateSSE(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	t0 := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	curTime := t0
	handler.Now = func() time.Time { return curTime }

	creatorHash := "secret-device-hash-creator-999111"
	joinerHash := "secret-device-hash-joiner-888222"

	// 1. POST /live/groups creates a 6-char unambiguous code, upserts creator, and never leaks device_hash.
	st, createRaw := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-bucegi","displayName":"<b>Andrei</b>","lat":45.4080,"lon":25.5420,"ele":2010,"accuracy":12.5,"inNavigation":true}`,
		secret:     testLiveSecret,
		deviceHash: creatorHash,
	})
	if st != http.StatusOK {
		t.Fatalf("CreateGroup status = %d, body = %s", st, createRaw)
	}
	if strings.Contains(string(createRaw), creatorHash) {
		t.Fatalf("PRIVACY VIOLATION: CreateGroup leaked creator device_hash: %s", createRaw)
	}

	var created GroupSessionDto
	if err := json.Unmarshal(createRaw, &created); err != nil {
		t.Fatalf("unmarshal CreateGroup response: %v", err)
	}
	if len(created.Code) != 6 {
		t.Fatalf("group code length = %d (%q), want 6", len(created.Code), created.Code)
	}
	for i := 0; i < len(created.Code); i++ {
		if strings.IndexByte(expectedGroupAlphabet, created.Code[i]) < 0 {
			t.Fatalf("group code %q contains disallowed char %q", created.Code, created.Code[i])
		}
	}
	wantCreatorMemberID := expectedDerivedMemberID(created.Code, creatorHash)
	if created.SelfMemberID != wantCreatorMemberID {
		t.Fatalf("selfMemberId = %q, want %q", created.SelfMemberID, wantCreatorMemberID)
	}
	if created.TrailID != "trail-bucegi" {
		t.Fatalf("trailId = %q, want trail-bucegi", created.TrailID)
	}
	expTime, err := time.Parse(time.RFC3339, created.ExpiresAt)
	if err != nil || !expTime.Equal(t0.Add(12*time.Hour)) {
		t.Fatalf("expiresAt = %q, want %v", created.ExpiresAt, t0.Add(12*time.Hour))
	}
	if len(created.Members) != 1 {
		t.Fatalf("expected 1 member on creation, got %d", len(created.Members))
	}
	if created.Members[0].MemberID != wantCreatorMemberID || !created.Members[0].IsSelf || created.Members[0].DisplayName != "Andrei" {
		t.Fatalf("unexpected creator member DTO: %+v", created.Members[0])
	}
	if !slices.Contains(expectedGroupPalette, created.Members[0].ColorHex) {
		t.Fatalf("creator colorHex %q not in expected palette %v", created.Members[0].ColorHex, expectedGroupPalette)
	}

	code := created.Code

	// 2. Second device joins via POST /live/groups/{code}/join (testing case-insensitive path normalization too).
	curTime = t0.Add(1 * time.Minute)
	st, joinRaw := invokeLiveHandler(t, app, handler.JoinGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups/" + strings.ToLower(code) + "/join",
		body:       `{"displayName":"<script>x()</script>Diana"}`,
		secret:     testLiveSecret,
		deviceHash: joinerHash,
		pathValues: map[string]string{"code": strings.ToLower(code)},
	})
	if st != http.StatusOK {
		t.Fatalf("JoinGroup status = %d, body = %s", st, joinRaw)
	}
	if strings.Contains(string(joinRaw), creatorHash) || strings.Contains(string(joinRaw), joinerHash) {
		t.Fatalf("PRIVACY VIOLATION: JoinGroup leaked device_hash: %s", joinRaw)
	}

	var joined GroupSessionDto
	if err := json.Unmarshal(joinRaw, &joined); err != nil {
		t.Fatalf("unmarshal JoinGroup: %v", err)
	}
	wantJoinerMemberID := expectedDerivedMemberID(code, joinerHash)
	if joined.SelfMemberID != wantJoinerMemberID || len(joined.Members) != 2 {
		t.Fatalf("unexpected JoinGroup session: %+v", joined)
	}

	// Verify GET /live/groups/{code} from creator's perspective: creator has isSelf=true, joiner has isSelf=false, deterministic colors.
	st, getRaw := invokeLiveHandler(t, app, handler.GetGroup, liveCallOptions{
		method:     http.MethodGet,
		target:     "/live/groups/" + code,
		secret:     testLiveSecret,
		deviceHash: creatorHash,
		pathValues: map[string]string{"code": code},
	})
	if st != http.StatusOK {
		t.Fatalf("GetGroup status = %d, body = %s", st, getRaw)
	}
	if strings.Contains(string(getRaw), creatorHash) || strings.Contains(string(getRaw), joinerHash) {
		t.Fatalf("PRIVACY VIOLATION: GetGroup leaked device_hash: %s", getRaw)
	}

	var fetched GroupSessionDto
	if err := json.Unmarshal(getRaw, &fetched); err != nil {
		t.Fatalf("unmarshal GetGroup: %v", err)
	}
	if len(fetched.Members) != 2 {
		t.Fatalf("GetGroup members = %d, want 2", len(fetched.Members))
	}
	for _, m := range fetched.Members {
		if !slices.Contains(expectedGroupPalette, m.ColorHex) {
			t.Fatalf("member %s colorHex %q not in palette", m.MemberID, m.ColorHex)
		}
		if m.MemberID == wantCreatorMemberID && !m.IsSelf {
			t.Fatalf("expected creator isSelf=true in GetGroup")
		}
		if m.MemberID == wantJoinerMemberID {
			if m.IsSelf {
				t.Fatalf("expected joiner isSelf=false when queried by creator")
			}
			if m.DisplayName != "Diana" {
				t.Fatalf("expected sanitized displayName Diana, got %q", m.DisplayName)
			}
		}
	}

	// 3. Connect SSE subscribers:
	// - subGroup: subscribed via HTTP Stream with ?groupCode={code}
	// - subNoGroup: subscribed on the EXACT same trail & coords WITHOUT groupCode (must NEVER get group coords!)
	// - subOtherGroup: subscribed with a DIFFERENT groupCode (must NEVER get group coords!)
	subNoGroup, unsubNoGroup := hub.Subscribe(45.4080, 25.5420, true, "trail-bucegi", "stranger-device")
	defer unsubNoGroup()
	subOtherGroup, unsubOtherGroup := hub.SubscribeWithGroup(45.4080, 25.5420, true, "trail-bucegi", "other-group-dev", "WWWW88")
	defer unsubOtherGroup()

	hub.SetKeepaliveInterval(5 * time.Second)
	streamCtx, cancelStream := context.WithCancel(context.Background())
	defer cancelStream()
	streamReq := httptest.NewRequest(
		http.MethodGet,
		"/live/stream?lat=45.4080&lon=25.5420&trailId=trail-bucegi&groupCode="+strings.ToLower(code),
		nil,
	).WithContext(streamCtx)
	streamReq.Header.Set("X-Internal-Secret", testLiveSecret)
	streamReq.Header.Set("X-Device-Hash", creatorHash)
	streamRec := httptest.NewRecorder()
	streamEv := &core.RequestEvent{App: app}
	streamEv.Request = streamReq
	streamEv.Response = streamRec

	streamDone := make(chan error, 1)
	go func() {
		streamDone <- handler.Stream(streamEv)
	}()

	// Wait briefly for Stream goroutine to register subscriber on hub.
	deadline := time.Now().Add(500 * time.Millisecond)
	for hub.SubscriberCount() < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if hub.SubscriberCount() != 3 {
		t.Fatalf("expected 3 active SSE subscribers, got %d", hub.SubscriberCount())
	}

	// Also register a direct channel subscriber for deterministic frame inspection.
	subGroupDirect, unsubGroupDirect := hub.SubscribeWithGroup(45.4080, 25.5420, true, "trail-bucegi", creatorHash, code)
	defer unsubGroupDirect()

	// 4. Joiner calls POST /live/groups/{code}/ping at t0 + 5m:
	// Updates all telemetry fields, refreshes group expires_at to curTime + 12h, and broadcasts group_member_update (isSelf: false).
	curTime = t0.Add(5 * time.Minute)
	pingBody := `{"lat":45.409123,"lon":25.543456,"ele":2042.5,"accuracy":5.5,"heading":135.0,"speed":1.25,"alongTrackM":640.5,"inNavigation":true}`
	st, pingRaw := invokeLiveHandler(t, app, handler.PingGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups/" + code + "/ping",
		body:       pingBody,
		secret:     testLiveSecret,
		deviceHash: joinerHash,
		pathValues: map[string]string{"code": code},
	})
	if st != http.StatusOK {
		t.Fatalf("PingGroup status = %d, body = %s", st, pingRaw)
	}
	if strings.Contains(string(pingRaw), creatorHash) || strings.Contains(string(pingRaw), joinerHash) {
		t.Fatalf("PRIVACY VIOLATION: PingGroup leaked device_hash: %s", pingRaw)
	}

	var pingSession GroupSessionDto
	if err := json.Unmarshal(pingRaw, &pingSession); err != nil {
		t.Fatalf("unmarshal PingGroup: %v", err)
	}
	refreshedExp, err := time.Parse(time.RFC3339, pingSession.ExpiresAt)
	if err != nil || !refreshedExp.Equal(curTime.Add(12*time.Hour)) {
		t.Fatalf("expected PingGroup to refresh expiresAt to %v, got %q", curTime.Add(12*time.Hour), pingSession.ExpiresAt)
	}

	// Verify lazy 1h DB write reduction: at +5m (4m after JoinGroup at +1m, remaining 11h56m >= 11h threshold),
	// PingGroup leaves SQLite untouched (`t0 + 1m + 12h`), while RAM session already reports `curTime + 12h`.
	groupRecAfterPing, err := app.FindFirstRecordByData("trail_groups", "code", code)
	if err != nil {
		t.Fatal(err)
	}
	wantLazyDBExp := t0.Add(1*time.Minute + 12*time.Hour)
	if !groupRecAfterPing.GetDateTime("expires_at").Time().Equal(wantLazyDBExp) {
		t.Fatalf("expected lazy DB trail_groups.expires_at to stay %v within 1h window, got %v", wantLazyDBExp, groupRecAfterPing.GetDateTime("expires_at").Time())
	}

	// Verify SSE frame on subGroupDirect: exact wire keys & isSelf == false & no device_hash.
	var sseUpdateFrame string
	select {
	case rawUpdate := <-subGroupDirect.Ch:
		sseUpdateFrame = string(rawUpdate)
	default:
		t.Fatal("expected group SSE subscriber to receive group_member_update")
	}
	if !strings.HasPrefix(sseUpdateFrame, "id: ") || !strings.Contains(sseUpdateFrame, "\nevent: group_member_update\ndata: ") {
		t.Fatalf("unexpected SSE frame prefix: %q", sseUpdateFrame)
	}
	if strings.Contains(sseUpdateFrame, joinerHash) || strings.Contains(sseUpdateFrame, "device_hash") || strings.Contains(sseUpdateFrame, "deviceHash") {
		t.Fatalf("PRIVACY VIOLATION in SSE frame: %s", sseUpdateFrame)
	}

	_, dataPart, _ := strings.Cut(sseUpdateFrame, "\ndata: ")
	dataJSON := strings.TrimSpace(dataPart)
	var envelopeMap map[string]any
	if err := json.Unmarshal([]byte(dataJSON), &envelopeMap); err != nil {
		t.Fatalf("unmarshal SSE JSON map: %v", err)
	}
	if envelopeMap["type"] != "group_member_update" || envelopeMap["groupCode"] != code {
		t.Fatalf("unexpected group_member_update envelope metadata: %s", dataJSON)
	}
	rawWireMap, ok := envelopeMap["member"].(map[string]any)
	if !ok {
		t.Fatalf("missing member object in group_member_update envelope: %s", dataJSON)
	}
	requiredKeys := []string{
		"memberId", "displayName", "colorHex",
		"lat", "lon", "ele", "accuracy",
		"heading", "speed", "alongTrackM",
		"inNavigation", "stationary", "isSelf", "updatedAt",
	}
	for _, k := range requiredKeys {
		if _, exists := rawWireMap[k]; !exists {
			t.Fatalf("missing required wire key %q in GroupMemberDto JSON: %s", k, dataJSON)
		}
	}

	var sseWrap struct {
		Member GroupMemberDto `json:"member"`
	}
	if err := json.Unmarshal([]byte(dataJSON), &sseWrap); err != nil {
		t.Fatalf("unmarshal GroupMemberDto: %v", err)
	}
	sseMember := sseWrap.Member
	if sseMember.MemberID != wantJoinerMemberID || sseMember.IsSelf {
		t.Fatalf("SSE GroupMemberDto expected memberId=%s and isSelf=false, got %+v", wantJoinerMemberID, sseMember)
	}
	if sseMember.Lat != 45.409123 || sseMember.Lon != 25.543456 || sseMember.Ele != 2042.5 || sseMember.Accuracy != 5.5 {
		t.Fatalf("SSE GroupMemberDto coords mismatch: %+v", sseMember)
	}
	if sseMember.Heading == nil || *sseMember.Heading != 135.0 ||
		sseMember.Speed == nil || *sseMember.Speed != 1.25 ||
		sseMember.AlongTrackM == nil || *sseMember.AlongTrackM != 640.5 ||
		!sseMember.InNavigation {
		t.Fatalf("SSE GroupMemberDto optional telemetry mismatch: %+v", sseMember)
	}
	if sseMember.UpdatedAt != curTime.Format(time.RFC3339) {
		t.Fatalf("SSE GroupMemberDto updatedAt = %q, want %q", sseMember.UpdatedAt, curTime.Format(time.RFC3339))
	}

	// Verify subscribers WITHOUT matching groupCode NEVER received private group coordinates!
	select {
	case leaked := <-subNoGroup.Ch:
		t.Fatalf("PRIVACY VIOLATION: subscriber without groupCode received frame: %s", string(leaked))
	default:
	}
	select {
	case leaked := <-subOtherGroup.Ch:
		t.Fatalf("PRIVACY VIOLATION: subscriber with different groupCode received frame: %s", string(leaked))
	default:
	}

	// 5. Verify 10-minute active window: at t0 + 12m, creator (last_seen at t0) is >10m old, while joiner (last_seen at t0+5m) is 7m old!
	curTime = t0.Add(12 * time.Minute)
	st, get12mRaw := invokeLiveHandler(t, app, handler.GetGroup, liveCallOptions{
		method:     http.MethodGet,
		target:     "/live/groups/" + code,
		secret:     testLiveSecret,
		deviceHash: joinerHash,
		pathValues: map[string]string{"code": code},
	})
	if st != http.StatusOK {
		t.Fatalf("GetGroup at +12m status = %d", st)
	}
	var session12m GroupSessionDto
	_ = json.Unmarshal(get12mRaw, &session12m)
	if len(session12m.Members) != 1 || session12m.Members[0].MemberID != wantJoinerMemberID || !session12m.Members[0].IsSelf {
		t.Fatalf("expected only active joiner within 10m window, got %+v", session12m.Members)
	}

	// 6. POST /live/groups/{code}/leave deletes caller's member row and broadcasts group_member_left.
	st, leaveRaw := invokeLiveHandler(t, app, handler.LeaveGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups/" + code + "/leave",
		secret:     testLiveSecret,
		deviceHash: joinerHash,
		pathValues: map[string]string{"code": code},
	})
	if st != http.StatusOK {
		t.Fatalf("LeaveGroup status = %d, body = %s", st, leaveRaw)
	}

	select {
	case rawLeft := <-subGroupDirect.Ch:
		leftFrame := string(rawLeft)
		if !strings.HasPrefix(leftFrame, "id: ") || !strings.Contains(leftFrame, "\nevent: group_member_left\ndata: ") {
			t.Fatalf("unexpected leave SSE frame: %q", leftFrame)
		}
		_, leftDataPart, _ := strings.Cut(leftFrame, "\ndata: ")
		leftData := strings.TrimSpace(leftDataPart)
		var leftPayload struct {
			Type      string `json:"type"`
			GroupCode string `json:"groupCode"`
			MemberID  string `json:"memberId"`
		}
		if err := json.Unmarshal([]byte(leftData), &leftPayload); err != nil {
			t.Fatalf("unmarshal group_member_left: %v", err)
		}
		if leftPayload.Type != "group_member_left" || leftPayload.GroupCode != code || leftPayload.MemberID != wantJoinerMemberID {
			t.Fatalf("unexpected group_member_left payload: %+v", leftPayload)
		}
	default:
		t.Fatal("expected group SSE subscriber to receive group_member_left")
	}

	// Confirm joiner was deleted from RAM GroupStore, and 0 rows were written to SQLite trail_group_members.
	if _, exists := handler.memoryStore().GetGroupMember(code, joinerHash); exists {
		t.Fatal("expected joiner entry removed from RAM GroupStore on leave")
	}
	if dbMemberRows, _ := app.CountRecords("trail_group_members"); dbMemberRows != 0 {
		t.Fatalf("expected 0 SQLite trail_group_members rows on RAM hot path, got %d", dbMemberRows)
	}

	// Advance past 1h threshold (t0 + 1h05m) and verify ?ack=1 compact response + lazy SQLite expires_at refresh!
	curTime = t0.Add(65 * time.Minute)
	stAck, rawAck := invokeLiveHandler(t, app, handler.PingGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups/" + code + "/ping?ack=1",
		body:       `{"lat":45.412,"lon":25.512,"accuracy":5,"stationary":true}`,
		secret:     testLiveSecret,
		deviceHash: creatorHash,
		pathValues: map[string]string{"code": code},
	})
	if stAck != http.StatusOK {
		t.Fatalf("PingGroup ?ack=1 status = %d: %s", stAck, rawAck)
	}
	var ackMap map[string]any
	if err := json.Unmarshal(rawAck, &ackMap); err != nil {
		t.Fatal(err)
	}
	if ackMap["ok"] != true || ackMap["code"] != code || ackMap["selfMemberId"] != deriveGroupMemberID(code, creatorHash) {
		t.Fatalf("unexpected ?ack=1 payload: %s", rawAck)
	}
	groupRecAfter1h, _ := app.FindFirstRecordByData("trail_groups", "code", code)
	if !groupRecAfter1h.GetDateTime("expires_at").Time().Equal(curTime.Add(12 * time.Hour)) {
		t.Fatalf("expected lazy DB expires_at refresh after >1h elapsed, got %v", groupRecAfter1h.GetDateTime("expires_at").Time())
	}

	// Close HTTP stream and confirm HTTP Stream output received both SSE events too!
	time.Sleep(15 * time.Millisecond)
	cancelStream()
	if err := <-streamDone; err != nil {
		t.Fatalf("HTTP Stream returned error: %v", err)
	}
	httpStreamBody := streamRec.Body.String()
	if !strings.Contains(httpStreamBody, "event: group_member_update\n") || !strings.Contains(httpStreamBody, "event: group_member_left\n") {
		t.Fatalf("expected HTTP /live/stream?groupCode=%s to stream both update and left events, got %q", code, httpStreamBody)
	}
}

func TestTrailLiveGroupsGarbageCollection(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)

	t0 := time.Date(2026, 11, 18, 8, 0, 0, 0, time.UTC)
	curTime := t0
	handler.Now = func() time.Time { return curTime }

	// Group A created at t0 (expires at t0 + 12h).
	st, rawA := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-a","displayName":"HostA","lat":45.40,"lon":25.50}`,
		secret:     testLiveSecret,
		deviceHash: "dev-host-a",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateGroup A status = %d: %s", st, rawA)
	}
	var groupA GroupSessionDto
	_ = json.Unmarshal(rawA, &groupA)

	// Member A2 joins Group A at t0 + 1h50m.
	curTime = t0.Add(110 * time.Minute)
	st, _ = invokeLiveHandler(t, app, handler.JoinGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups/" + groupA.Code + "/join",
		body:       `{"displayName":"FreshA2"}`,
		secret:     testLiveSecret,
		deviceHash: "dev-fresh-a2",
		pathValues: map[string]string{"code": groupA.Code},
	})
	if st != http.StatusOK {
		t.Fatalf("JoinGroup A2 status = %d", st)
	}

	// At t0 + 2h05m:
	// - dev-host-a has last_seen = t0 (< now - 2h) -> must be cleaned by GC!
	// - dev-fresh-a2 has last_seen = t0 + 1h50m (>= now - 2h, only 15m old) -> must survive GC!
	// - Group A expires_at is t0 + 13h50m (>= now) -> must survive GC!
	curTime = t0.Add(125 * time.Minute)
	if err := RunTrailLiveGC(app, hub, curTime); err != nil {
		t.Fatalf("RunTrailLiveGC at +2h05m: %v", err)
	}

	if handler.memoryStore().GroupMemberCount(groupA.Code) != 1 {
		t.Fatalf("expected 1 member in RAM GroupStore after 2h GC, got %d", handler.memoryStore().GroupMemberCount(groupA.Code))
	}
	if _, ok := handler.memoryStore().GetGroupMember(groupA.Code, "dev-fresh-a2"); !ok {
		t.Fatal("expected dev-fresh-a2 to survive 2h member GC in RAM GroupStore")
	}

	// Create Group B at t0 + 13h so it is fresh while Group A expires (t0 + 13h50m < t0 + 15h).
	curTime = t0.Add(13 * time.Hour)
	st, rawB := invokeLiveHandler(t, app, handler.CreateGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups",
		body:       `{"trailId":"trail-b","displayName":"HostB","lat":45.50,"lon":25.60}`,
		secret:     testLiveSecret,
		deviceHash: "dev-host-b",
	})
	if st != http.StatusOK {
		t.Fatalf("CreateGroup B status = %d", st)
	}
	var groupB GroupSessionDto
	_ = json.Unmarshal(rawB, &groupB)

	// Keep HostB fresh at t0 + 14h30m, then run GC at t0 + 15h:
	// Group A (expires_at = t0 + 13h50m < t0 + 15h) must be purged, while Group B survives!
	curTime = t0.Add(14*time.Hour + 30*time.Minute)
	_, _ = invokeLiveHandler(t, app, handler.PingGroup, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/groups/" + groupB.Code + "/ping",
		body:       `{"lat":45.51,"lon":25.61,"accuracy":8}`,
		secret:     testLiveSecret,
		deviceHash: "dev-host-b",
		pathValues: map[string]string{"code": groupB.Code},
	})

	curTime = t0.Add(15 * time.Hour)
	if err := RunTrailLiveGC(app, hub, curTime); err != nil {
		t.Fatalf("RunTrailLiveGC at +15h: %v", err)
	}

	if _, err := app.FindFirstRecordByData("trail_groups", "code", groupA.Code); err == nil {
		t.Fatalf("expected expired Group A (%s) to be deleted by RunTrailLiveGC", groupA.Code)
	}
	if _, err := app.FindFirstRecordByData("trail_groups", "code", groupB.Code); err != nil {
		t.Fatalf("expected active Group B (%s) to survive RunTrailLiveGC: %v", groupB.Code, err)
	}
}

func TestTrailLiveGroupsRegisteredRouterAndZeroOptionalMetrics(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	hub := live.NewTrailLiveHub()
	r, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("NewRouter: %v", err)
	}
	RegisterTrailLiveRoutes(&core.ServeEvent{App: app, Router: r}, hub)
	mux, err := r.BuildMux()
	if err != nil {
		t.Fatalf("BuildMux: %v", err)
	}

	doReq := func(method, path, body, devHash string) (int, []byte) {
		var rdr *strings.Reader
		if body != "" {
			rdr = strings.NewReader(body)
		} else {
			rdr = strings.NewReader("")
		}
		req := httptest.NewRequest(method, path, rdr)
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		req.Header.Set("X-Internal-Secret", testLiveSecret)
		if devHash != "" {
			req.Header.Set("X-Device-Hash", devHash)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code, rec.Body.Bytes()
	}

	// 1. POST /live/groups via real HTTP mux (without optional metrics -> heading/speed/alongTrackM must be null).
	st, createRaw := doReq(http.MethodPost, "/live/groups", `{"trailId":"trail-mux","displayName":"Radu"}`, "dev-mux-1")
	if st != http.StatusOK {
		t.Fatalf("mux POST /live/groups status = %d: %s", st, createRaw)
	}
	var session GroupSessionDto
	if err := json.Unmarshal(createRaw, &session); err != nil {
		t.Fatal(err)
	}
	if len(session.Members) != 1 ||
		session.Members[0].Heading != nil ||
		session.Members[0].Speed != nil ||
		session.Members[0].AlongTrackM != nil {
		t.Fatalf("expected nil optional metrics on initial group create, got %+v", session.Members[0])
	}

	// 2. POST /live/groups/{code}/ping with exact 0.0 heading (North), 0.0 speed, 0.0 alongTrackM -> must serialize as 0, not null!
	st, pingRaw := doReq(
		http.MethodPost,
		"/live/groups/"+session.Code+"/ping",
		`{"lat":45.44,"lon":25.55,"ele":1400,"accuracy":4.2,"heading":0,"speed":0,"alongTrackM":0,"inNavigation":true}`,
		"dev-mux-1",
	)
	if st != http.StatusOK {
		t.Fatalf("mux POST /live/groups/%s/ping status = %d: %s", session.Code, st, pingRaw)
	}
	if err := json.Unmarshal(pingRaw, &session); err != nil {
		t.Fatal(err)
	}
	m := session.Members[0]
	if m.Heading == nil || *m.Heading != 0 || m.Speed == nil || *m.Speed != 0 || m.AlongTrackM == nil || *m.AlongTrackM != 0 {
		t.Fatalf("expected 0.0 optional metrics to be preserved as non-nil 0.0, got %+v", m)
	}

	// 3. POST /live/groups/{code}/join -> GET /live/groups/{code} -> POST /live/groups/{code}/leave via real HTTP mux.
	st, _ = doReq(http.MethodPost, "/live/groups/"+session.Code+"/join", `{"displayName":"Ioana"}`, "dev-mux-2")
	if st != http.StatusOK {
		t.Fatalf("mux join status = %d", st)
	}
	st, getRaw := doReq(http.MethodGet, "/live/groups/"+session.Code, "", "dev-mux-2")
	if st != http.StatusOK {
		t.Fatalf("mux get status = %d", st)
	}
	_ = json.Unmarshal(getRaw, &session)
	if len(session.Members) != 2 {
		t.Fatalf("mux expected 2 members, got %d", len(session.Members))
	}

	st, _ = doReq(http.MethodPost, "/live/groups/"+session.Code+"/leave", "", "dev-mux-2")
	if st != http.StatusOK {
		t.Fatalf("mux leave status = %d", st)
	}
	st, getAfterLeave := doReq(http.MethodGet, "/live/groups/"+session.Code, "", "dev-mux-1")
	if st != http.StatusOK {
		t.Fatalf("mux get after leave status = %d", st)
	}
	_ = json.Unmarshal(getAfterLeave, &session)
	if len(session.Members) != 1 {
		t.Fatalf("mux expected 1 member after leave, got %d", len(session.Members))
	}
}
