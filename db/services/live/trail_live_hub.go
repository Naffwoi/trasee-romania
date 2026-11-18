package live

import (
	"encoding/json"
	"maps"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"pocketbase/util"
)

const (
	// LiveRadiusMeters is the maximum Haversine distance for geo-scoped live updates.
	LiveRadiusMeters = 5000.0

	// KeepaliveInterval is the SSE comment heartbeat interval.
	KeepaliveInterval = 20 * time.Second

	// ReplayRingCapacity is the number of recent SSE events retained for Last-Event-ID recovery.
	ReplayRingCapacity = 512

	subscriberBufferSize = 32
)

var (
	connectedBytes = []byte(": connected\n\n")
	keepaliveBytes = []byte(": keepalive\n\n")
	resyncBytes    = []byte("event: resync_required\ndata: {\"type\":\"resync_required\"}\n\n")
)

type replayKind uint8

const (
	replayGroup replayKind = iota + 1
	replayReport
	replaySos
)

type replaySlot struct {
	seq         uint64
	kind        replayKind
	groupCode   string
	target      GeoTarget
	ownerHash   string
	responders  map[string]bool
	sharedFrame []byte
	buildSosDto func(subscriberDeviceHash string) any
}

// Subscriber represents one active SSE client connected to /live/stream.
type Subscriber struct {
	ID         uint64
	Lat        float64
	Lon        float64
	HasCoords  bool
	CellKey    uint32
	TrailID    string
	DeviceHash string
	GroupCode  string
	Ch         chan []byte
}

// GeoTarget describes the geographic / trail scope of an outgoing event.
type GeoTarget struct {
	TrailID   string
	Lat       float64
	Lon       float64
	HasCoords bool
}

// TrailLiveHub manages connected SSE subscribers with O(1) group/trail/cell indexes
// and a 512-slot circular Last-Event-ID replay buffer.
type TrailLiveHub struct {
	mu                sync.RWMutex
	nextID            atomic.Uint64
	nextSeq           atomic.Uint64
	subs              map[uint64]*Subscriber
	byGroup           map[string]map[uint64]*Subscriber
	byTrail           map[string]map[uint64]*Subscriber
	byCell            map[uint32]map[uint64]*Subscriber
	byDevice          map[string]map[uint64]*Subscriber
	ring              [ReplayRingCapacity]replaySlot
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
		byGroup:           make(map[string]map[uint64]*Subscriber),
		byTrail:           make(map[string]map[uint64]*Subscriber),
		byCell:            make(map[uint32]map[uint64]*Subscriber),
		byDevice:          make(map[string]map[uint64]*Subscriber),
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

// Subscribe registers a new SSE subscriber without a private group channel.
func (h *TrailLiveHub) Subscribe(lat, lon float64, hasCoords bool, trailID, deviceHash string) (*Subscriber, func()) {
	return h.SubscribeWithGroup(lat, lon, hasCoords, trailID, deviceHash, "")
}

// SubscribeWithGroup registers a new SSE subscriber indexed by group, trail, spatial cell, and deviceHash.
func (h *TrailLiveHub) SubscribeWithGroup(lat, lon float64, hasCoords bool, trailID, deviceHash, groupCode string) (*Subscriber, func()) {
	id := h.nextID.Add(1)
	var cellKey uint32
	if hasCoords {
		cellKey = GridCellKey(lat, lon)
	}
	sub := &Subscriber{
		ID:         id,
		Lat:        lat,
		Lon:        lon,
		HasCoords:  hasCoords,
		CellKey:    cellKey,
		TrailID:    strings.TrimSpace(trailID),
		DeviceHash: strings.TrimSpace(deviceHash),
		GroupCode:  strings.ToUpper(strings.TrimSpace(groupCode)),
		Ch:         make(chan []byte, subscriberBufferSize),
	}

	h.mu.Lock()
	h.subs[id] = sub
	h.indexSubscriberLocked(sub)
	h.mu.Unlock()

	var once sync.Once
	unsubscribe := func() {
		once.Do(func() {
			h.mu.Lock()
			h.unindexSubscriberLocked(sub)
			delete(h.subs, id)
			h.mu.Unlock()
		})
	}
	return sub, unsubscribe
}

func (h *TrailLiveHub) indexSubscriberLocked(sub *Subscriber) {
	if sub.GroupCode != "" {
		m := h.byGroup[sub.GroupCode]
		if m == nil {
			m = make(map[uint64]*Subscriber, 4)
			h.byGroup[sub.GroupCode] = m
		}
		m[sub.ID] = sub
	}
	if sub.TrailID != "" {
		m := h.byTrail[sub.TrailID]
		if m == nil {
			m = make(map[uint64]*Subscriber, 4)
			h.byTrail[sub.TrailID] = m
		}
		m[sub.ID] = sub
	}
	if sub.HasCoords {
		m := h.byCell[sub.CellKey]
		if m == nil {
			m = make(map[uint64]*Subscriber, 4)
			h.byCell[sub.CellKey] = m
		}
		m[sub.ID] = sub
	}
	if sub.DeviceHash != "" {
		m := h.byDevice[sub.DeviceHash]
		if m == nil {
			m = make(map[uint64]*Subscriber, 2)
			h.byDevice[sub.DeviceHash] = m
		}
		m[sub.ID] = sub
	}
}

func (h *TrailLiveHub) unindexSubscriberLocked(sub *Subscriber) {
	if sub.GroupCode != "" {
		if m, ok := h.byGroup[sub.GroupCode]; ok {
			delete(m, sub.ID)
			if len(m) == 0 {
				delete(h.byGroup, sub.GroupCode)
			}
		}
	}
	if sub.TrailID != "" {
		if m, ok := h.byTrail[sub.TrailID]; ok {
			delete(m, sub.ID)
			if len(m) == 0 {
				delete(h.byTrail, sub.TrailID)
			}
		}
	}
	if sub.HasCoords {
		if m, ok := h.byCell[sub.CellKey]; ok {
			delete(m, sub.ID)
			if len(m) == 0 {
				delete(h.byCell, sub.CellKey)
			}
		}
	}
	if sub.DeviceHash != "" {
		if m, ok := h.byDevice[sub.DeviceHash]; ok {
			delete(m, sub.ID)
			if len(m) == 0 {
				delete(h.byDevice, sub.DeviceHash)
			}
		}
	}
}

// UpdateSubscriberLocation updates live coordinates and trail scope in-place for all open SSE connections
// belonging to deviceHash so hikers walking >5km never lose geo-scoped alerts or reconnect EventSource.
func (h *TrailLiveHub) UpdateSubscriberLocation(deviceHash string, lat, lon float64, trailID string) {
	if h == nil {
		return
	}
	dh := strings.TrimSpace(deviceHash)
	if dh == "" {
		return
	}
	newCell := GridCellKey(lat, lon)
	cleanTrail := strings.TrimSpace(trailID)

	h.mu.RLock()
	hasSubs := len(h.byDevice[dh]) > 0
	h.mu.RUnlock()
	if !hasSubs {
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	for _, sub := range h.byDevice[dh] {
		needReindexCell := !sub.HasCoords || sub.CellKey != newCell
		needReindexTrail := cleanTrail != "" && sub.TrailID != cleanTrail

		if needReindexCell && sub.HasCoords {
			if m, ok := h.byCell[sub.CellKey]; ok {
				delete(m, sub.ID)
				if len(m) == 0 {
					delete(h.byCell, sub.CellKey)
				}
			}
		}
		if needReindexTrail && sub.TrailID != "" {
			if m, ok := h.byTrail[sub.TrailID]; ok {
				delete(m, sub.ID)
				if len(m) == 0 {
					delete(h.byTrail, sub.TrailID)
				}
			}
		}

		sub.Lat = lat
		sub.Lon = lon
		sub.HasCoords = true
		sub.CellKey = newCell
		if cleanTrail != "" {
			sub.TrailID = cleanTrail
		}

		if needReindexCell {
			m := h.byCell[newCell]
			if m == nil {
				m = make(map[uint64]*Subscriber, 4)
				h.byCell[newCell] = m
			}
			m[sub.ID] = sub
		}
		if needReindexTrail {
			m := h.byTrail[sub.TrailID]
			if m == nil {
				m = make(map[uint64]*Subscriber, 4)
				h.byTrail[sub.TrailID] = m
			}
			m[sub.ID] = sub
		}
	}
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

// buildEnvelopeFrame serializes dto ONCE and byte-splices the single-envelope SSE []byte frame with zero json.Unmarshal calls.
func buildEnvelopeFrame(seq uint64, eventName, nestedKey string, dto any) ([]byte, error) {
	rawDto, err := json.Marshal(dto)
	if err != nil {
		return nil, err
	}
	var seqBuf [20]byte
	seqBytes := strconv.AppendUint(seqBuf[:0], seq, 10)

	// Layout: "id: <seq>\nevent: <eventName>\ndata: {\"type\":\"<eventName>\",\"<nestedKey>\":<rawDto>}\n\n"
	totalLen := 4 + len(seqBytes) + 8 + len(eventName) + 16 + len(eventName) + 3 + len(nestedKey) + 2 + len(rawDto) + 3
	buf := make([]byte, 0, totalLen)
	buf = append(buf, "id: "...)
	buf = append(buf, seqBytes...)
	buf = append(buf, "\nevent: "...)
	buf = append(buf, eventName...)
	buf = append(buf, "\ndata: {\"type\":\""...)
	buf = append(buf, eventName...)
	buf = append(buf, "\",\""...)
	buf = append(buf, nestedKey...)
	buf = append(buf, "\":"...)
	buf = append(buf, rawDto...)
	buf = append(buf, "}\n\n"...)

	return buf, nil
}

func buildDirectFrame(seq uint64, eventName string, payload any) ([]byte, error) {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var seqBuf [20]byte
	seqBytes := strconv.AppendUint(seqBuf[:0], seq, 10)

	// Layout: "id: <seq>\nevent: <eventName>\ndata: <encoded>\n\n"
	totalLen := 4 + len(seqBytes) + 8 + len(eventName) + 7 + len(encoded) + 2
	buf := make([]byte, 0, totalLen)
	buf = append(buf, "id: "...)
	buf = append(buf, seqBytes...)
	buf = append(buf, "\nevent: "...)
	buf = append(buf, eventName...)
	buf = append(buf, "\ndata: "...)
	buf = append(buf, encoded...)
	buf = append(buf, "\n\n"...)

	return buf, nil
}

func pushNonBlocking(ch chan []byte, frame []byte) {
	select {
	case ch <- frame:
	default:
		select {
		case <-ch:
		default:
		}
		select {
		case ch <- frame:
		default:
		}
	}
}

func (h *TrailLiveHub) storeReplayLocked(slot replaySlot) {
	h.ring[slot.seq%ReplayRingCapacity] = slot
}

func (h *TrailLiveHub) collectGeoCandidatesLocked(target GeoTarget, cells []uint32) []*Subscriber {
	seen := make(map[uint64]struct{}, 16)
	out := make([]*Subscriber, 0, 16)

	if target.TrailID != "" {
		for id, sub := range h.byTrail[target.TrailID] {
			seen[id] = struct{}{}
			out = append(out, sub)
		}
	}
	if target.HasCoords {
		for _, ck := range cells {
			for id, sub := range h.byCell[ck] {
				if _, dup := seen[id]; dup {
					continue
				}
				if util.HaversineDistanceMeters(sub.Lat, sub.Lon, target.Lat, target.Lon) <= LiveRadiusMeters {
					seen[id] = struct{}{}
					out = append(out, sub)
				}
			}
		}
	}
	return out
}

// BroadcastReportUpdate sends a single-envelope `report_update` SSE event in O(k_local) via trail + 500m cell indexes.
func (h *TrailLiveHub) BroadcastReportUpdate(target GeoTarget, reportDto any) {
	if h == nil {
		return
	}
	seq := h.nextSeq.Add(1)
	frame, err := buildEnvelopeFrame(seq, "report_update", "report", reportDto)
	if err != nil {
		return
	}
	var cells []uint32
	if target.HasCoords {
		cells = GridCellsForRadius(target.Lat, target.Lon, LiveRadiusMeters+300.0)
	}

	h.mu.Lock()
	h.storeReplayLocked(replaySlot{
		seq:         seq,
		kind:        replayReport,
		target:      target,
		sharedFrame: frame,
	})
	targets := h.collectGeoCandidatesLocked(target, cells)
	h.mu.Unlock()

	for _, sub := range targets {
		pushNonBlocking(sub.Ch, frame)
	}
}

// BroadcastSosUpdate pre-builds ONE shared []byte frame for bystanders (isMine:false, amResponding:false) outside lock,
// and dispatches custom frames ONLY to the SOS owner and active responders.
func (h *TrailLiveHub) BroadcastSosUpdate(
	target GeoTarget,
	ownerDeviceHash string,
	respondingDevices map[string]bool,
	buildDtoForDevice func(subscriberDeviceHash string) any,
) {
	if h == nil || buildDtoForDevice == nil {
		return
	}
	seq := h.nextSeq.Add(1)

	bystanderFrame, err := buildEnvelopeFrame(seq, "sos_update", "sos", buildDtoForDevice(""))
	if err != nil {
		return
	}
	var ownerFrame []byte
	if ownerDeviceHash != "" {
		ownerFrame, _ = buildEnvelopeFrame(seq, "sos_update", "sos", buildDtoForDevice(ownerDeviceHash))
	}
	respFrames := make(map[string][]byte, len(respondingDevices))
	for dh := range respondingDevices {
		if dh != "" && dh != ownerDeviceHash {
			if rf, rfErr := buildEnvelopeFrame(seq, "sos_update", "sos", buildDtoForDevice(dh)); rfErr == nil {
				respFrames[dh] = rf
			}
		}
	}

	var cells []uint32
	if target.HasCoords {
		cells = GridCellsForRadius(target.Lat, target.Lon, LiveRadiusMeters+300.0)
	}
	respClone := maps.Clone(respondingDevices)

	type delivery struct {
		ch    chan []byte
		frame []byte
	}
	deliveries := make([]delivery, 0, 16)
	deliveredIDs := make(map[uint64]struct{}, 16)

	h.mu.Lock()
	h.storeReplayLocked(replaySlot{
		seq:         seq,
		kind:        replaySos,
		target:      target,
		ownerHash:   ownerDeviceHash,
		responders:  respClone,
		sharedFrame: bystanderFrame,
		buildSosDto: buildDtoForDevice,
	})

	if ownerDeviceHash != "" && len(ownerFrame) > 0 {
		for id, sub := range h.byDevice[ownerDeviceHash] {
			deliveredIDs[id] = struct{}{}
			deliveries = append(deliveries, delivery{ch: sub.Ch, frame: ownerFrame})
		}
	}
	for dh, rf := range respFrames {
		for id, sub := range h.byDevice[dh] {
			if _, dup := deliveredIDs[id]; dup {
				continue
			}
			deliveredIDs[id] = struct{}{}
			deliveries = append(deliveries, delivery{ch: sub.Ch, frame: rf})
		}
	}
	for _, sub := range h.collectGeoCandidatesLocked(target, cells) {
		if _, dup := deliveredIDs[sub.ID]; dup {
			continue
		}
		deliveredIDs[sub.ID] = struct{}{}
		deliveries = append(deliveries, delivery{ch: sub.Ch, frame: bystanderFrame})
	}
	h.mu.Unlock()

	for _, d := range deliveries {
		pushNonBlocking(d.ch, d.frame)
	}
}

// PublishGroupEvent dispatches strictly to O(G) subscribers of groupCode via h.byGroup.
func (h *TrailLiveHub) PublishGroupEvent(groupCode, eventName string, payload any) {
	if h == nil {
		return
	}
	normalizedCode := strings.ToUpper(strings.TrimSpace(groupCode))
	cleanEvent := strings.TrimSpace(eventName)
	if normalizedCode == "" || cleanEvent == "" {
		return
	}

	seq := h.nextSeq.Add(1)
	frame, err := buildDirectFrame(seq, cleanEvent, payload)
	if err != nil {
		return
	}

	h.mu.Lock()
	h.storeReplayLocked(replaySlot{
		seq:         seq,
		kind:        replayGroup,
		groupCode:   normalizedCode,
		sharedFrame: frame,
	})
	groupMap := h.byGroup[normalizedCode]
	chans := make([]chan []byte, 0, len(groupMap))
	for _, sub := range groupMap {
		chans = append(chans, sub.Ch)
	}
	h.mu.Unlock()

	for _, ch := range chans {
		pushNonBlocking(ch, frame)
	}
}

func parseLastEventID(r *http.Request) (uint64, bool) {
	raw := strings.TrimSpace(r.Header.Get("Last-Event-ID"))
	if raw == "" {
		raw = strings.TrimSpace(r.URL.Query().Get("lastEventId"))
	}
	if raw == "" {
		return 0, false
	}
	v, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func (h *TrailLiveHub) replayMissedFrames(sub *Subscriber, lastSeq uint64) [][]byte {
	head := h.nextSeq.Load()
	if head == 0 || lastSeq >= head {
		return nil
	}
	if head-lastSeq > ReplayRingCapacity {
		return [][]byte{resyncBytes}
	}

	h.mu.RLock()
	slots := make([]replaySlot, 0, head-lastSeq)
	for seq := lastSeq + 1; seq <= head; seq++ {
		slot := h.ring[seq%ReplayRingCapacity]
		if slot.seq == seq {
			slots = append(slots, slot)
		}
	}
	h.mu.RUnlock()

	var frames [][]byte
	for _, slot := range slots {
		switch slot.kind {
		case replayGroup:
			if sub.GroupCode != "" && sub.GroupCode == slot.groupCode {
				frames = append(frames, slot.sharedFrame)
			}
		case replayReport:
			if matchesSubscriber(sub, slot.target) {
				frames = append(frames, slot.sharedFrame)
			}
		case replaySos:
			isOwner := sub.DeviceHash != "" && sub.DeviceHash == slot.ownerHash
			isResp := sub.DeviceHash != "" && slot.responders[sub.DeviceHash]
			if !isOwner && !isResp && !matchesSubscriber(sub, slot.target) {
				continue
			}
			if (isOwner || isResp) && slot.buildSosDto != nil {
				if custom, err := buildEnvelopeFrame(slot.seq, "sos_update", "sos", slot.buildSosDto(sub.DeviceHash)); err == nil {
					frames = append(frames, custom)
					continue
				}
			}
			frames = append(frames, slot.sharedFrame)
		}
	}
	return frames
}

// ServeSSE streams Last-Event-ID replays, live SSE []byte frames, and 20s keepalives with zero heap copies.
func (h *TrailLiveHub) ServeSSE(w http.ResponseWriter, r *http.Request, sub *Subscriber) error {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	flusher, _ := w.(http.Flusher)
	if _, err := w.Write(connectedBytes); err != nil {
		return nil
	}

	if lastSeq, hasLast := parseLastEventID(r); hasLast {
		for _, missed := range h.replayMissedFrames(sub, lastSeq) {
			if _, err := w.Write(missed); err != nil {
				return nil
			}
		}
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
			if _, err := w.Write(frame); err != nil {
				return nil
			}
			if flusher != nil {
				flusher.Flush()
			}
		case <-ticker.C:
			if _, err := w.Write(keepaliveBytes); err != nil {
				return nil
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
	}
}
