package live

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestPublishGroupEventIsolation(t *testing.T) {
	hub := NewTrailLiveHub()

	subGroupA1, unsubA1 := hub.SubscribeWithGroup(45.40, 25.50, true, "trail-1", "dev-1", "abc234")
	defer unsubA1()
	subGroupA2, unsubA2 := hub.SubscribeWithGroup(45.41, 25.51, true, "trail-1", "dev-2", "ABC234")
	defer unsubA2()
	subPublicSameSpot, unsubPub := hub.Subscribe(45.40, 25.50, true, "trail-1", "dev-3")
	defer unsubPub()
	subOtherGroup, unsubOther := hub.SubscribeWithGroup(45.40, 25.50, true, "trail-1", "dev-4", "XYZ789")
	defer unsubOther()

	hub.PublishGroupEvent("abc234", "group_member_update", map[string]any{
		"type":      "group_member_update",
		"groupCode": "ABC234",
		"member": map[string]any{
			"memberId": "a1b2c3d4e5f6",
			"lat":      45.40123,
			"lon":      25.50456,
			"isSelf":   false,
		},
	})

	for idx, sub := range []*Subscriber{subGroupA1, subGroupA2} {
		select {
		case rawFrame := <-sub.Ch:
			frame := string(rawFrame)
			if !strings.HasPrefix(frame, "id: ") || !strings.Contains(frame, "\nevent: group_member_update\ndata: ") || !strings.HasSuffix(frame, "\n\n") {
				t.Fatalf("subscriber %d got malformed SSE frame: %q", idx, frame)
			}
			if !strings.Contains(frame, `"memberId":"a1b2c3d4e5f6"`) {
				t.Fatalf("subscriber %d missing payload: %q", idx, frame)
			}
		default:
			t.Fatalf("subscriber %d with matching GroupCode did not receive event", idx)
		}
	}

	select {
	case leaked := <-subPublicSameSpot.Ch:
		t.Fatalf("subscriber with empty GroupCode received group event: %q", string(leaked))
	default:
	}

	select {
	case leaked := <-subOtherGroup.Ch:
		t.Fatalf("subscriber with different GroupCode received group event: %q", string(leaked))
	default:
	}

	hub.PublishGroupEvent("", "group_member_update", map[string]any{"lat": 1})
	select {
	case leaked := <-subPublicSameSpot.Ch:
		t.Fatalf("empty groupCode broadcast leaked to public subscriber: %q", string(leaked))
	default:
	}
}

func TestUpdateSubscriberLocationRebucketsLiveStreamWithoutReconnect(t *testing.T) {
	hub := NewTrailLiveHub()

	// Subscriber starts in Bucharest (44.4268, 26.1025), 125 km away from Omu Peak.
	sub, unsub := hub.Subscribe(44.4268, 26.1025, true, "", "dev-walker")
	defer unsub()

	// Hiker walks onto Omu Peak (45.4450, 25.4560) and sends a heartbeat updating location in-place.
	hub.UpdateSubscriberLocation("dev-walker", 45.4450, 25.4560, "trail-omu")

	hub.BroadcastReportUpdate(GeoTarget{
		TrailID:   "other-trail",
		Lat:       45.4460,
		Lon:       25.4560,
		HasCoords: true,
	}, map[string]any{"id": "rep-omu-1", "category": "bear"})

	select {
	case rawFrame := <-sub.Ch:
		frame := string(rawFrame)
		if !strings.Contains(frame, `"report":{"category":"bear","id":"rep-omu-1"}`) {
			t.Fatalf("unexpected single-envelope report frame: %s", frame)
		}
	default:
		t.Fatal("expected subscriber with updated in-place coordinates to receive Omu report")
	}
}

func TestLastEventIDReplayIsolationAndOverflowResync(t *testing.T) {
	hub := NewTrailLiveHub()

	// Emit seq 1 (Group A), seq 2 (Group B - must NOT leak!), seq 3 (SOS near Group A).
	hub.PublishGroupEvent("GRP234", "group_member_update", map[string]any{"memberId": "m-a1"})
	hub.PublishGroupEvent("OTHER9", "group_member_update", map[string]any{"memberId": "m-secret"})
	hub.BroadcastSosUpdate(
		GeoTarget{TrailID: "trail-a", Lat: 45.44, Lon: 25.45, HasCoords: true},
		"dev-victim",
		map[string]bool{"dev-resp": true},
		func(dh string) any {
			return map[string]any{
				"id":           "sos-1",
				"isMine":       dh == "dev-victim",
				"amResponding": dh == "dev-resp",
			}
		},
	)

	// Reconnect dev-victim subscribed to GRP234 with Last-Event-ID: 0 -> gets seq 1 and seq 3 (with isMine:true), NEVER seq 2!
	sub, unsub := hub.SubscribeWithGroup(45.44, 25.45, true, "trail-a", "dev-victim", "GRP234")
	defer unsub()

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest("GET", "/live/stream?groupCode=GRP234", nil).WithContext(ctx)
	req.Header.Set("Last-Event-ID", "0")
	rec := httptest.NewRecorder()

	done := make(chan error, 1)
	go func() {
		done <- hub.ServeSSE(rec, req, sub)
	}()
	time.Sleep(15 * time.Millisecond)
	cancel()
	<-done

	body := rec.Body.String()
	if !strings.Contains(body, "id: 1\nevent: group_member_update\ndata: {\"memberId\":\"m-a1\"}") {
		t.Fatalf("expected replay of seq 1 group event, got %q", body)
	}
	if strings.Contains(body, "m-secret") {
		t.Fatalf("replay leaked another group's event: %q", body)
	}
	if !strings.Contains(body, "id: 3\nevent: sos_update\n") || !strings.Contains(body, `"isMine":true`) {
		t.Fatalf("expected replay of seq 3 SOS event with personalized isMine:true, got %q", body)
	}

	// Overflow > 512 events -> emits resync_required when reconnecting from Last-Event-ID: 1.
	for i := 0; i < ReplayRingCapacity+10; i++ {
		hub.PublishGroupEvent("GRP234", "group_member_update", map[string]any{"seq": i})
	}
	sub2, unsub2 := hub.SubscribeWithGroup(45.44, 25.45, true, "trail-a", "dev-victim", "GRP234")
	defer unsub2()
	ctx2, cancel2 := context.WithCancel(context.Background())
	req2 := httptest.NewRequest("GET", "/live/stream?groupCode=GRP234&lastEventId=1", nil).WithContext(ctx2)
	rec2 := httptest.NewRecorder()
	done2 := make(chan error, 1)
	go func() {
		done2 <- hub.ServeSSE(rec2, req2, sub2)
	}()
	time.Sleep(15 * time.Millisecond)
	cancel2()
	<-done2

	if !strings.Contains(rec2.Body.String(), "event: resync_required\ndata: {\"type\":\"resync_required\"}\n\n") {
		t.Fatalf("expected resync_required when gap exceeds 512 ring buffer, got %q", rec2.Body.String())
	}
}

func BenchmarkBroadcastSosUpdate500Subscribers(b *testing.B) {
	hub := NewTrailLiveHub()
	for i := 0; i < 500; i++ {
		_, _ = hub.Subscribe(45.4450, 25.4560, true, "trail-omu", "dev-bystander")
	}
	target := GeoTarget{TrailID: "trail-omu", Lat: 45.4450, Lon: 25.4560, HasCoords: true}
	resp := map[string]bool{"dev-resp-1": true}

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hub.BroadcastSosUpdate(target, "dev-owner", resp, func(dh string) any {
			return struct {
				ID           string `json:"id"`
				Status       string `json:"status"`
				IsMine       bool   `json:"isMine"`
				AmResponding bool   `json:"amResponding"`
			}{
				ID:           "sos-bench",
				Status:       "active",
				IsMine:       dh == "dev-owner",
				AmResponding: resp[dh],
			}
		})
	}
}
