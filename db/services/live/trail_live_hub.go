package live

import (
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"pocketbase/util"
)

const (
	// LiveRadiusMeters is the maximum Haversine distance for geo-scoped live
	// updates (reports and SOS alerts).
	LiveRadiusMeters = 5000.0

	// KeepaliveInterval is the SSE comment heartbeat interval.
	KeepaliveInterval = 20 * time.Second

	subscriberBufferSize = 32
)

// Subscriber represents one active SSE client connected to /live/stream.
type Subscriber struct {
	ID         uint64
	Lat        float64
	Lon        float64
	HasCoords  bool
	TrailID    string
	DeviceHash string
	Ch         chan string
}

// GeoTarget describes the geographic / trail scope of an outgoing event.
type GeoTarget struct {
	TrailID   string
	Lat       float64
	Lon       float64
	HasCoords bool
}

// TrailLiveHub manages connected SSE subscribers and dispatches geo-filtered
// and trail-filtered live events.
type TrailLiveHub struct {
	mu                sync.RWMutex
	nextID            atomic.Uint64
	subs              map[uint64]*Subscriber
	keepaliveInterval time.Duration
}

var defaultHub = NewTrailLiveHub()

// DefaultHub returns the process-wide SSE hub used by PocketBase routes and cron.
func DefaultHub() *TrailLiveHub {
	return defaultHub
}

// NewTrailLiveHub creates an isolated SSE broker instance.
func NewTrailLiveHub() *TrailLiveHub {
	return &TrailLiveHub{
		subs:              make(map[uint64]*Subscriber),
		keepaliveInterval: KeepaliveInterval,
	}
}

// SetKeepaliveInterval overrides the keepalive interval (primarily for tests).
func (h *TrailLiveHub) SetKeepaliveInterval(d time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if d > 0 {
		h.keepaliveInterval = d
	}
}

// Subscribe registers a new SSE subscriber and returns it alongside an
// unsubscribe cleanup function.
func (h *TrailLiveHub) Subscribe(lat, lon float64, hasCoords bool, trailID, deviceHash string) (*Subscriber, func()) {
	id := h.nextID.Add(1)
	sub := &Subscriber{
		ID:         id,
		Lat:        lat,
		Lon:        lon,
		HasCoords:  hasCoords,
		TrailID:    trailID,
		DeviceHash: deviceHash,
		Ch:         make(chan string, subscriberBufferSize),
	}

	h.mu.Lock()
	h.subs[id] = sub
	h.mu.Unlock()

	var once sync.Once
	unsubscribe := func() {
		once.Do(func() {
			h.mu.Lock()
			delete(h.subs, id)
			h.mu.Unlock()
		})
	}
	return sub, unsubscribe
}

// SubscriberCount returns the current number of active SSE subscribers.
func (h *TrailLiveHub) SubscriberCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs)
}

func matchesSubscriber(sub *Subscriber, target GeoTarget) bool {
	if target.TrailID != "" && sub.TrailID != "" && sub.TrailID == target.TrailID {
		return true
	}
	if target.HasCoords && sub.HasCoords {
		if util.HaversineDistanceMeters(sub.Lat, sub.Lon, target.Lat, target.Lon) <= LiveRadiusMeters {
			return true
		}
	}
	return false
}

// formatSSEEvent builds an SSE event frame whose JSON data carries both the
// nested wrapper key (e.g. {"type":"report_update","report":{...}}) AND top-level
// DTO fields so clients parsing either shape succeed seamlessly.
func formatSSEEvent(eventName, nestedKey string, dto any) (string, error) {
	rawDto, err := json.Marshal(dto)
	if err != nil {
		return "", err
	}

	envelope := map[string]any{}
	_ = json.Unmarshal(rawDto, &envelope)

	var nestedVal any
	_ = json.Unmarshal(rawDto, &nestedVal)

	payload := make(map[string]any, len(envelope)+2)
	maps.Copy(payload, envelope)
	payload["type"] = eventName
	payload[nestedKey] = nestedVal

	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("event: %s\ndata: %s\n\n", eventName, encoded), nil
}

// BroadcastReportUpdate sends a `report_update` SSE event to all subscribers
// matching target.TrailID or within 5,000 m Haversine.
func (h *TrailLiveHub) BroadcastReportUpdate(target GeoTarget, reportDto any) {
	if h == nil {
		return
	}
	frame, err := formatSSEEvent("report_update", "report", reportDto)
	if err != nil {
		return
	}

	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, sub := range h.subs {
		if !matchesSubscriber(sub, target) {
			continue
		}
		select {
		case sub.Ch <- frame:
		default:
			// Drop oldest queued event if slow client buffer is full so fresh state wins.
			select {
			case <-sub.Ch:
			default:
			}
			select {
			case sub.Ch <- frame:
			default:
			}
		}
	}
}

// BroadcastSosUpdate sends a `sos_update` SSE event to all subscribers matching
// target.TrailID, within 5,000 m Haversine, or matching the SOS owner/responders.
// buildDtoForDevice produces a per-subscriber DTO so `isMine` and `amResponding`
// are accurate for every connected client.
func (h *TrailLiveHub) BroadcastSosUpdate(
	target GeoTarget,
	ownerDeviceHash string,
	respondingDevices map[string]bool,
	buildDtoForDevice func(subscriberDeviceHash string) any,
) {
	if h == nil || buildDtoForDevice == nil {
		return
	}

	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, sub := range h.subs {
		isOwner := sub.DeviceHash != "" && sub.DeviceHash == ownerDeviceHash
		isResponder := sub.DeviceHash != "" && respondingDevices[sub.DeviceHash]
		if !isOwner && !isResponder && !matchesSubscriber(sub, target) {
			continue
		}

		dto := buildDtoForDevice(sub.DeviceHash)
		frame, err := formatSSEEvent("sos_update", "sos", dto)
		if err != nil {
			continue
		}

		select {
		case sub.Ch <- frame:
		default:
			select {
			case <-sub.Ch:
			default:
			}
			select {
			case sub.Ch <- frame:
			default:
			}
		}
	}
}

// ServeSSE streams SSE frames and periodic `: keepalive\n\n` comments until the
// request context ends or writing fails.
func (h *TrailLiveHub) ServeSSE(w http.ResponseWriter, r *http.Request, sub *Subscriber) error {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	flusher, _ := w.(http.Flusher)
	if _, err := fmt.Fprint(w, ": connected\n\n"); err != nil {
		return nil
	}
	if flusher != nil {
		flusher.Flush()
	}

	h.mu.RLock()
	interval := h.keepaliveInterval
	h.mu.RUnlock()
	if interval <= 0 {
		interval = KeepaliveInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return nil
		case frame := <-sub.Ch:
			if _, err := fmt.Fprint(w, frame); err != nil {
				return nil
			}
			if flusher != nil {
				flusher.Flush()
			}
		case <-ticker.C:
			if _, err := fmt.Fprint(w, ": keepalive\n\n"); err != nil {
				return nil
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
	}
}
