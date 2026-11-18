package live

import (
	"strings"
	"testing"
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
		"memberId": "a1b2c3d4e5f6",
		"lat":      45.40123,
		"lon":      25.50456,
		"isSelf":   false,
	})

	for idx, sub := range []*Subscriber{subGroupA1, subGroupA2} {
		select {
		case frame := <-sub.Ch:
			if !strings.HasPrefix(frame, "event: group_member_update\ndata: ") || !strings.HasSuffix(frame, "\n\n") {
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
		t.Fatalf("subscriber with empty GroupCode received group event: %q", leaked)
	default:
	}

	select {
	case leaked := <-subOtherGroup.Ch:
		t.Fatalf("subscriber with different GroupCode received group event: %q", leaked)
	default:
	}

	// Empty groupCode must never broadcast anything.
	hub.PublishGroupEvent("", "group_member_update", map[string]any{"lat": 1})
	select {
	case leaked := <-subPublicSameSpot.Ch:
		t.Fatalf("empty groupCode broadcast leaked to public subscriber: %q", leaked)
	default:
	}
}
