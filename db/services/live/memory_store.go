package live

import (
	"container/list"
	"math"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"pocketbase/util"
)

const (
	numMemoryShards = 32

	LiveMovingPresenceWindow     = 2 * time.Minute
	LiveStationaryPresenceWindow = 10 * time.Minute
	PresenceRetentionWindow      = 30 * time.Minute
	PresenceCorridorRadiusMeters = 2000.0
	PushCoarseDriftMeters        = 1000.0
	DefaultCorridorLRUCapacity   = 512
)

func shardIndex(key string) uint32 {
	var h uint32 = 2166136261
	for i := 0; i < len(key); i++ {
		h ^= uint32(key[i])
		h *= 16777619
	}
	return h & (numMemoryShards - 1)
}

// PresenceEntry holds ephemeral live GPS telemetry for one hiker device in RAM.
type PresenceEntry struct {
	DeviceHash   string    `json:"deviceHash"`
	TrailID      string    `json:"trailId"`
	Lat          float64   `json:"lat"`
	Lon          float64   `json:"lon"`
	Ele          float64   `json:"ele"`
	InNavigation bool      `json:"inNavigation"`
	Stationary   bool      `json:"stationary"`
	CellKey      uint32    `json:"cellKey"`
	LastSeen     time.Time `json:"lastSeen"`
}

func (p PresenceEntry) isActivelyHikingAt(now time.Time) bool {
	window := LiveMovingPresenceWindow
	if p.Stationary {
		window = LiveStationaryPresenceWindow
	}
	return !p.LastSeen.Before(now.Add(-window))
}

type presenceShard struct {
	mu      sync.RWMutex
	entries map[string]*PresenceEntry
}

// CachedGroup stores the durable group metadata mirrored in RAM alongside last SQLite TTL flush time.
type CachedGroup struct {
	RecordID        string    `json:"recordId"`
	Code            string    `json:"code"`
	TrailID         string    `json:"trailId"`
	OwnerDeviceHash string    `json:"ownerDeviceHash"`
	ExpiresAt       time.Time `json:"expiresAt"`
	LastDBSyncAt    time.Time `json:"lastDbSyncAt"`
}

// CachedGroupMember stores 5s group member telemetry purely in RAM (backed by 60s disk snapshot).
type CachedGroupMember struct {
	DeviceHash   string    `json:"deviceHash"`
	MemberID     string    `json:"memberId"`
	DisplayName  string    `json:"displayName"`
	ColorHex     string    `json:"colorHex"`
	Lat          float64   `json:"lat"`
	Lon          float64   `json:"lon"`
	Ele          float64   `json:"ele"`
	Accuracy     float64   `json:"accuracy"`
	Heading      *float64  `json:"heading,omitempty"`
	Speed        *float64  `json:"speed,omitempty"`
	AlongTrackM  *float64  `json:"alongTrackM,omitempty"`
	InNavigation bool      `json:"inNavigation"`
	Stationary   bool      `json:"stationary"`
	CreatedAt    time.Time `json:"createdAt"`
	LastSeen     time.Time `json:"lastSeen"`
}

type groupBucket struct {
	meta    CachedGroup
	members map[string]*CachedGroupMember // keyed by DeviceHash
}

type groupShard struct {
	mu     sync.RWMutex
	groups map[string]*groupBucket // keyed by normalized GroupCode
}

// CachedReport mirrors active/dry_or_closed trail_reports in a RAM spatial index.
type CachedReport struct {
	ID              string
	TrailID         string
	Category        string
	Kind            string
	IsPermanent     bool
	ConditionStatus string
	Note            string
	Lat             float64
	Lon             float64
	Ele             float64
	AlongTrackM     float64
	DeviceHash      string
	AuthorActor     string
	ConfirmCount    int
	DismissCount    int
	SpamCount       int
	CreatedAt       time.Time
	LastConfirmedAt time.Time
	ExpiresAt       time.Time // zero when permanent
	CellKey         uint32
}

func (r *CachedReport) IsVisibleAt(now time.Time) bool {
	if r.ConditionStatus != "active" && r.ConditionStatus != "dry_or_closed" {
		return false
	}
	if r.IsPermanent || r.ExpiresAt.IsZero() {
		return true
	}
	return !r.ExpiresAt.Before(now)
}

// CachedSosResponder holds responder telemetry in RAM.
type CachedSosResponder struct {
	RecordID   string    `json:"recordId"`
	SosID      string    `json:"sosId"`
	DeviceHash string    `json:"deviceHash"`
	Lat        float64   `json:"lat"`
	Lon        float64   `json:"lon"`
	Ele        float64   `json:"ele"`
	DistanceM  float64   `json:"distanceM"`
	EtaSec     int       `json:"etaSec"`
	Status     string    `json:"status"`
	LastSeen   time.Time `json:"lastSeen"`
}

// CachedSosAlert mirrors active SOS alerts in RAM for 0-SQL heartbeats.
type CachedSosAlert struct {
	ID               string
	ClientSosID      string
	TrailID          string
	Status           string
	Reason           string
	Message          string
	RequesterName    string
	Lat              float64
	Lon              float64
	Ele              float64
	OriginLat        float64
	OriginLon        float64
	DeviceHash       string
	SosClaimHash     string
	LastPacketEpoch  int64
	RelayedByHash    string
	ResponderCount   int
	NearestDistanceM float64
	NearestEtaSec    int
	CreatedAt        time.Time
	ExpiresAt        time.Time
}

// PushSubEntry mirrors Web Push subscriptions in RAM with coarse-drift dirty tracking.
type PushSubEntry struct {
	ID         string
	DeviceHash string
	Endpoint   string
	P256dh     string
	Auth       string
	Lat        float64
	Lon        float64
	TrailID    string
	SavedLat   float64
	SavedLon   float64
	SavedTrail string
	Dirty      bool
}

// PushMatchTarget is a geo-matched push subscription ready for VAPID dispatch.
type PushMatchTarget struct {
	Endpoint  string
	P256dh    string
	Auth      string
	DistanceM float64
}

type corridorEntry struct {
	trailID string
	coords  [][2]float64
}

// LiveMemoryStore unifies lock-striped ephemeral GPS presence, group telemetry,
// spatial report/SOS read projections, push subscriptions, and trail corridor LRU.
type LiveMemoryStore struct {
	hydrated atomic.Bool
	initMu   sync.Mutex

	presence [numMemoryShards]presenceShard
	gridMu   sync.RWMutex
	grid     map[uint32]map[string]struct{} // cellKey -> set of deviceHash

	groups [numMemoryShards]groupShard

	reportsMu      sync.RWMutex
	reportsByID    map[string]*CachedReport
	reportsByTrail map[string]map[string]struct{}
	reportsByCell  map[uint32]map[string]struct{}

	sosMu      sync.RWMutex
	sosByID    map[string]*CachedSosAlert
	responders map[string]map[string]*CachedSosResponder // sosID -> deviceHash -> responder

	pushMu       sync.RWMutex
	pushByEndpt  map[string]*PushSubEntry
	pushByDevice map[string]map[string]*PushSubEntry // deviceHash -> endpoint -> entry

	corridorMu  sync.Mutex
	corridorCap int
	corridorLRU *list.List
	corridorMap map[string]*list.Element
}

var defaultMemoryStore = NewLiveMemoryStore()

// DefaultMemoryStore returns the singleton in-memory store shared by PocketBase live routes & cron.
func DefaultMemoryStore() *LiveMemoryStore {
	return defaultMemoryStore
}

// NewLiveMemoryStore constructs an isolated in-memory spatial store.
func NewLiveMemoryStore() *LiveMemoryStore {
	s := &LiveMemoryStore{
		grid:           make(map[uint32]map[string]struct{}),
		reportsByID:    make(map[string]*CachedReport),
		reportsByTrail: make(map[string]map[string]struct{}),
		reportsByCell:  make(map[uint32]map[string]struct{}),
		sosByID:        make(map[string]*CachedSosAlert),
		responders:     make(map[string]map[string]*CachedSosResponder),
		pushByEndpt:    make(map[string]*PushSubEntry),
		pushByDevice:   make(map[string]map[string]*PushSubEntry),
		corridorCap:    DefaultCorridorLRUCapacity,
		corridorLRU:    list.New(),
		corridorMap:    make(map[string]*list.Element),
	}
	for i := 0; i < numMemoryShards; i++ {
		s.presence[i].entries = make(map[string]*PresenceEntry)
		s.groups[i].groups = make(map[string]*groupBucket)
	}
	return s
}

// EnsureHydrated executes loader at most once for this store instance.
func (s *LiveMemoryStore) EnsureHydrated(loader func(*LiveMemoryStore) error) error {
	if s.hydrated.Load() {
		return nil
	}
	s.initMu.Lock()
	defer s.initMu.Unlock()
	if s.hydrated.Load() {
		return nil
	}
	if loader != nil {
		if err := loader(s); err != nil {
			return err
		}
	}
	s.hydrated.Store(true)
	return nil
}

// UpsertPresence inserts or updates a hiker's live GPS fix, mutating the global spatial grid
// ONLY when the hiker crosses a 500m cell boundary.
func (s *LiveMemoryStore) UpsertPresence(in PresenceEntry) {
	dh := strings.TrimSpace(in.DeviceHash)
	if dh == "" {
		return
	}
	newCell := GridCellKey(in.Lat, in.Lon)
	in.DeviceHash = dh
	in.CellKey = newCell

	sh := &s.presence[shardIndex(dh)]
	sh.mu.Lock()
	prev, existed := sh.entries[dh]
	var prevCell uint32
	if existed {
		prevCell = prev.CellKey
		*prev = in
	} else {
		cp := in
		sh.entries[dh] = &cp
	}
	sh.mu.Unlock()

	if !existed || prevCell != newCell {
		s.gridMu.Lock()
		if existed && prevCell != newCell {
			if bucket, ok := s.grid[prevCell]; ok {
				delete(bucket, dh)
				if len(bucket) == 0 {
					delete(s.grid, prevCell)
				}
			}
		}
		bucket, ok := s.grid[newCell]
		if !ok {
			bucket = make(map[string]struct{}, 4)
			s.grid[newCell] = bucket
		}
		bucket[dh] = struct{}{}
		s.gridMu.Unlock()
	}
}

// DeletePresence immediately removes a hiker's presence entry (e.g. DELETE /live/heartbeat).
func (s *LiveMemoryStore) DeletePresence(deviceHash string) {
	dh := strings.TrimSpace(deviceHash)
	if dh == "" {
		return
	}
	sh := &s.presence[shardIndex(dh)]
	sh.mu.Lock()
	prev, existed := sh.entries[dh]
	var prevCell uint32
	if existed {
		prevCell = prev.CellKey
		delete(sh.entries, dh)
	}
	sh.mu.Unlock()

	if existed {
		s.gridMu.Lock()
		if bucket, ok := s.grid[prevCell]; ok {
			delete(bucket, dh)
			if len(bucket) == 0 {
				delete(s.grid, prevCell)
			}
		}
		s.gridMu.Unlock()
	}
}

// GetPresence retrieves a copy of a hiker's presence entry if present and within retentionWindow.
func (s *LiveMemoryStore) GetPresence(deviceHash string, retentionWindow time.Duration, now time.Time) (PresenceEntry, bool) {
	dh := strings.TrimSpace(deviceHash)
	if dh == "" {
		return PresenceEntry{}, false
	}
	sh := &s.presence[shardIndex(dh)]
	sh.mu.RLock()
	entry, ok := sh.entries[dh]
	var cp PresenceEntry
	if ok {
		cp = *entry
	}
	sh.mu.RUnlock()
	if !ok || cp.LastSeen.Before(now.Add(-retentionWindow)) {
		return PresenceEntry{}, false
	}
	return cp, true
}

// PresenceCount returns the total number of retained presence entries across all 32 shards.
func (s *LiveMemoryStore) PresenceCount() int {
	total := 0
	for i := 0; i < numMemoryShards; i++ {
		s.presence[i].mu.RLock()
		total += len(s.presence[i].entries)
		s.presence[i].mu.RUnlock()
	}
	return total
}

// SweepStalePresence purges presence entries older than PresenceRetentionWindow (30m).
func (s *LiveMemoryStore) SweepStalePresence(now time.Time) int {
	cutoff := now.Add(-PresenceRetentionWindow)
	type deadItem struct {
		dh   string
		cell uint32
	}
	var removed []deadItem

	for i := 0; i < numMemoryShards; i++ {
		sh := &s.presence[i]
		sh.mu.Lock()
		for dh, entry := range sh.entries {
			if entry.LastSeen.Before(cutoff) {
				removed = append(removed, deadItem{dh: dh, cell: entry.CellKey})
				delete(sh.entries, dh)
			}
		}
		sh.mu.Unlock()
	}

	if len(removed) > 0 {
		s.gridMu.Lock()
		for _, item := range removed {
			if bucket, ok := s.grid[item.cell]; ok {
				delete(bucket, item.dh)
				if len(bucket) == 0 {
					delete(s.grid, item.cell)
				}
			}
		}
		s.gridMu.Unlock()
	}
	return len(removed)
}

// CountActiveNearbyUsers counts distinct OTHER devices actively hiking (2m moving / 10m stationary)
// within 2,000 m of corridor using the 500m spatial grid.
func (s *LiveMemoryStore) CountActiveNearbyUsers(corridor [][2]float64, callerDeviceHash string, now time.Time) int {
	if len(corridor) == 0 {
		return 0
	}
	minLat, maxLat := corridor[0][0], corridor[0][0]
	minLon, maxLon := corridor[0][1], corridor[0][1]
	for _, c := range corridor[1:] {
		if c[0] < minLat {
			minLat = c[0]
		}
		if c[0] > maxLat {
			maxLat = c[0]
		}
		if c[1] < minLon {
			minLon = c[1]
		}
		if c[1] > maxLon {
			maxLon = c[1]
		}
	}

	cells := GridCellsForBBox(minLat, maxLat, minLon, maxLon, PresenceCorridorRadiusMeters+250.0)
	candidates := make([]string, 0, 16)

	s.gridMu.RLock()
	for _, ck := range cells {
		for dh := range s.grid[ck] {
			if dh != "" && dh != callerDeviceHash {
				candidates = append(candidates, dh)
			}
		}
	}
	s.gridMu.RUnlock()

	if len(candidates) == 0 {
		return 0
	}

	seen := make(map[string]struct{}, len(candidates))
	matched := 0
	for _, dh := range candidates {
		if _, dup := seen[dh]; dup {
			continue
		}
		seen[dh] = struct{}{}

		sh := &s.presence[shardIndex(dh)]
		sh.mu.RLock()
		entry, ok := sh.entries[dh]
		var cp PresenceEntry
		if ok {
			cp = *entry
		}
		sh.mu.RUnlock()

		if !ok || !cp.isActivelyHikingAt(now) {
			continue
		}
		if DistanceToCorridorMeters(cp.Lat, cp.Lon, corridor) <= PresenceCorridorRadiusMeters {
			matched++
		}
	}
	return matched
}

// GetTrailCorridor looks up cached decoded trail coordinates from the bounded LRU.
func (s *LiveMemoryStore) GetTrailCorridor(trailID string) ([][2]float64, bool) {
	s.corridorMu.Lock()
	defer s.corridorMu.Unlock()
	if elem, ok := s.corridorMap[trailID]; ok {
		s.corridorLRU.MoveToFront(elem)
		return elem.Value.(corridorEntry).coords, true
	}
	return nil, false
}

// PutTrailCorridor caches decoded trail coordinates in the bounded 512-trail LRU.
func (s *LiveMemoryStore) PutTrailCorridor(trailID string, coords [][2]float64) {
	if trailID == "" || len(coords) == 0 {
		return
	}
	s.corridorMu.Lock()
	defer s.corridorMu.Unlock()
	if elem, ok := s.corridorMap[trailID]; ok {
		s.corridorLRU.MoveToFront(elem)
		elem.Value = corridorEntry{trailID: trailID, coords: coords}
		return
	}
	elem := s.corridorLRU.PushFront(corridorEntry{trailID: trailID, coords: coords})
	s.corridorMap[trailID] = elem
	if s.corridorLRU.Len() > s.corridorCap {
		oldest := s.corridorLRU.Back()
		if oldest != nil {
			s.corridorLRU.Remove(oldest)
			delete(s.corridorMap, oldest.Value.(corridorEntry).trailID)
		}
	}
}

// InvalidateTrailCorridor evicts a trail's cached polyline when the trail record is updated or deleted.
func (s *LiveMemoryStore) InvalidateTrailCorridor(trailID string) {
	if trailID == "" {
		return
	}
	s.corridorMu.Lock()
	defer s.corridorMu.Unlock()
	if elem, ok := s.corridorMap[trailID]; ok {
		s.corridorLRU.Remove(elem)
		delete(s.corridorMap, trailID)
	}
}

// UpsertGroup registers or updates group session metadata in RAM.
func (s *LiveMemoryStore) UpsertGroup(g CachedGroup) {
	code := strings.ToUpper(strings.TrimSpace(g.Code))
	if code == "" {
		return
	}
	g.Code = code
	sh := &s.groups[shardIndex(code)]
	sh.mu.Lock()
	bucket, ok := sh.groups[code]
	if !ok {
		bucket = &groupBucket{
			meta:    g,
			members: make(map[string]*CachedGroupMember, 4),
		}
		sh.groups[code] = bucket
	} else {
		bucket.meta = g
	}
	sh.mu.Unlock()
}

// GetActiveGroup returns the cached group metadata if not expired at now.
func (s *LiveMemoryStore) GetActiveGroup(code string, now time.Time) (CachedGroup, bool) {
	norm := strings.ToUpper(strings.TrimSpace(code))
	if norm == "" {
		return CachedGroup{}, false
	}
	sh := &s.groups[shardIndex(norm)]
	sh.mu.RLock()
	bucket, ok := sh.groups[norm]
	var meta CachedGroup
	if ok {
		meta = bucket.meta
	}
	sh.mu.RUnlock()
	if !ok || (!meta.ExpiresAt.IsZero() && meta.ExpiresAt.Before(now)) {
		return CachedGroup{}, false
	}
	return meta, true
}

// DeleteGroup removes a group and all of its members from RAM.
func (s *LiveMemoryStore) DeleteGroup(code string) {
	norm := strings.ToUpper(strings.TrimSpace(code))
	if norm == "" {
		return
	}
	sh := &s.groups[shardIndex(norm)]
	sh.mu.Lock()
	delete(sh.groups, norm)
	sh.mu.Unlock()
}

// TouchGroupTTL extends the in-memory group ExpiresAt and reports whether SQLite also needs a lazy write
// based on the SQL-persisted expiry (LastDBSyncAt + ttl), so frequent 5s pings never starve hourly DB syncs.
func (s *LiveMemoryStore) TouchGroupTTL(code string, newExpiresAt time.Time, dbRefreshThreshold time.Duration, now time.Time) (CachedGroup, bool) {
	norm := strings.ToUpper(strings.TrimSpace(code))
	sh := &s.groups[shardIndex(norm)]
	sh.mu.Lock()
	defer sh.mu.Unlock()
	bucket, ok := sh.groups[norm]
	if !ok {
		return CachedGroup{}, false
	}
	ttl := newExpiresAt.Sub(now)
	sqlExpiresAt := bucket.meta.ExpiresAt
	if !bucket.meta.LastDBSyncAt.IsZero() && ttl > 0 {
		sqlExpiresAt = bucket.meta.LastDBSyncAt.Add(ttl)
	}
	needsDBWrite := bucket.meta.LastDBSyncAt.IsZero() || sqlExpiresAt.Sub(now) < dbRefreshThreshold
	bucket.meta.ExpiresAt = newExpiresAt
	if needsDBWrite {
		bucket.meta.LastDBSyncAt = now
	}
	return bucket.meta, needsDBWrite
}

// UpsertGroupMember updates or inserts a group member's 5s telemetry in RAM.
func (s *LiveMemoryStore) UpsertGroupMember(code string, m CachedGroupMember) CachedGroupMember {
	norm := strings.ToUpper(strings.TrimSpace(code))
	dh := strings.TrimSpace(m.DeviceHash)
	if norm == "" || dh == "" {
		return m
	}
	sh := &s.groups[shardIndex(norm)]
	sh.mu.Lock()
	defer sh.mu.Unlock()

	bucket, ok := sh.groups[norm]
	if !ok {
		bucket = &groupBucket{
			meta:    CachedGroup{Code: norm, ExpiresAt: m.LastSeen.Add(12 * time.Hour)},
			members: make(map[string]*CachedGroupMember, 4),
		}
		sh.groups[norm] = bucket
	}
	existing, exists := bucket.members[dh]
	if exists {
		m.CreatedAt = existing.CreatedAt
		if strings.TrimSpace(m.DisplayName) == "" {
			m.DisplayName = existing.DisplayName
		}
		*existing = m
		return *existing
	}
	if m.CreatedAt.IsZero() {
		m.CreatedAt = m.LastSeen
	}
	cp := m
	bucket.members[dh] = &cp
	return cp
}

// GetGroupMember returns one member in a group if present.
func (s *LiveMemoryStore) GetGroupMember(code, deviceHash string) (CachedGroupMember, bool) {
	norm := strings.ToUpper(strings.TrimSpace(code))
	dh := strings.TrimSpace(deviceHash)
	sh := &s.groups[shardIndex(norm)]
	sh.mu.RLock()
	defer sh.mu.RUnlock()
	bucket, ok := sh.groups[norm]
	if !ok {
		return CachedGroupMember{}, false
	}
	m, ok := bucket.members[dh]
	if !ok {
		return CachedGroupMember{}, false
	}
	return *m, true
}

// RemoveGroupMember deletes a single member from a group in RAM.
func (s *LiveMemoryStore) RemoveGroupMember(code, deviceHash string) bool {
	norm := strings.ToUpper(strings.TrimSpace(code))
	dh := strings.TrimSpace(deviceHash)
	sh := &s.groups[shardIndex(norm)]
	sh.mu.Lock()
	defer sh.mu.Unlock()
	bucket, ok := sh.groups[norm]
	if !ok {
		return false
	}
	if _, exists := bucket.members[dh]; !exists {
		return false
	}
	delete(bucket.members, dh)
	return true
}

// ListActiveGroupMembers returns members with LastSeen >= now - activeWindow ordered by CreatedAt ASC.
func (s *LiveMemoryStore) ListActiveGroupMembers(code string, activeWindow time.Duration, now time.Time) []CachedGroupMember {
	norm := strings.ToUpper(strings.TrimSpace(code))
	cutoff := now.Add(-activeWindow)
	sh := &s.groups[shardIndex(norm)]
	sh.mu.RLock()
	bucket, ok := sh.groups[norm]
	if !ok {
		sh.mu.RUnlock()
		return nil
	}
	out := make([]CachedGroupMember, 0, len(bucket.members))
	for _, m := range bucket.members {
		if !m.LastSeen.Before(cutoff) {
			out = append(out, *m)
		}
	}
	sh.mu.RUnlock()

	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].MemberID < out[j].MemberID
		}
		return out[i].CreatedAt.Before(out[j].CreatedAt)
	})
	return out
}

// GroupMemberCount returns total retained (including idle <2h) members for a group code.
func (s *LiveMemoryStore) GroupMemberCount(code string) int {
	norm := strings.ToUpper(strings.TrimSpace(code))
	sh := &s.groups[shardIndex(norm)]
	sh.mu.RLock()
	defer sh.mu.RUnlock()
	if bucket, ok := sh.groups[norm]; ok {
		return len(bucket.members)
	}
	return 0
}

// SweepGroupsGC purges expired groups and members stale beyond memberStaleWindow (2h).
func (s *LiveMemoryStore) SweepGroupsGC(memberStaleWindow time.Duration, now time.Time) {
	memberCutoff := now.Add(-memberStaleWindow)
	for i := 0; i < numMemoryShards; i++ {
		sh := &s.groups[i]
		sh.mu.Lock()
		for code, bucket := range sh.groups {
			if !bucket.meta.ExpiresAt.IsZero() && bucket.meta.ExpiresAt.Before(now) {
				delete(sh.groups, code)
				continue
			}
			for dh, m := range bucket.members {
				if m.LastSeen.IsZero() || m.LastSeen.Before(memberCutoff) {
					delete(bucket.members, dh)
				}
			}
		}
		sh.mu.Unlock()
	}
}

// UpsertReport indexes an active/dry_or_closed report by ID, TrailID, and 500m spatial cell.
func (s *LiveMemoryStore) UpsertReport(rep CachedReport) {
	if rep.ID == "" {
		return
	}
	if rep.ConditionStatus != "active" && rep.ConditionStatus != "dry_or_closed" {
		s.RemoveReport(rep.ID)
		return
	}
	rep.CellKey = GridCellKey(rep.Lat, rep.Lon)

	s.reportsMu.Lock()
	defer s.reportsMu.Unlock()

	if prev, ok := s.reportsByID[rep.ID]; ok {
		if prev.TrailID != "" && prev.TrailID != rep.TrailID {
			if tset, ok := s.reportsByTrail[prev.TrailID]; ok {
				delete(tset, rep.ID)
			}
		}
		if prev.CellKey != rep.CellKey {
			if cset, ok := s.reportsByCell[prev.CellKey]; ok {
				delete(cset, rep.ID)
			}
		}
	}

	cp := rep
	s.reportsByID[rep.ID] = &cp
	if rep.TrailID != "" {
		tset, ok := s.reportsByTrail[rep.TrailID]
		if !ok {
			tset = make(map[string]struct{}, 4)
			s.reportsByTrail[rep.TrailID] = tset
		}
		tset[rep.ID] = struct{}{}
	}
	cset, ok := s.reportsByCell[rep.CellKey]
	if !ok {
		cset = make(map[string]struct{}, 4)
		s.reportsByCell[rep.CellKey] = cset
	}
	cset[rep.ID] = struct{}{}
}

// RemoveReport removes a resolved or spam_hidden report from the live spatial index.
func (s *LiveMemoryStore) RemoveReport(reportID string) {
	s.reportsMu.Lock()
	defer s.reportsMu.Unlock()
	prev, ok := s.reportsByID[reportID]
	if !ok {
		return
	}
	delete(s.reportsByID, reportID)
	if prev.TrailID != "" {
		if tset, ok := s.reportsByTrail[prev.TrailID]; ok {
			delete(tset, reportID)
			if len(tset) == 0 {
				delete(s.reportsByTrail, prev.TrailID)
			}
		}
	}
	if cset, ok := s.reportsByCell[prev.CellKey]; ok {
		delete(cset, reportID)
		if len(cset) == 0 {
			delete(s.reportsByCell, prev.CellKey)
		}
	}
}

// QueryVisibleReports returns all visible reports matching trailID OR within 5,000m of (lat, lon),
// sorted newest-first without any global 500-row truncation bug.
func (s *LiveMemoryStore) QueryVisibleReports(trailID string, lat, lon float64, hasCoords bool, now time.Time) []CachedReport {
	var cells []uint32
	if hasCoords {
		cells = GridCellsForRadius(lat, lon, LiveRadiusMeters+300.0)
	}

	s.reportsMu.RLock()
	seen := make(map[string]struct{}, 16)
	out := make([]CachedReport, 0, 16)

	if trailID != "" {
		for id := range s.reportsByTrail[trailID] {
			if rep, ok := s.reportsByID[id]; ok && rep.IsVisibleAt(now) {
				seen[id] = struct{}{}
				out = append(out, *rep)
			}
		}
	}
	if hasCoords {
		for _, ck := range cells {
			for id := range s.reportsByCell[ck] {
				if _, dup := seen[id]; dup {
					continue
				}
				rep, ok := s.reportsByID[id]
				if !ok || !rep.IsVisibleAt(now) {
					continue
				}
				if util.HaversineDistanceMeters(lat, lon, rep.Lat, rep.Lon) <= LiveRadiusMeters {
					seen[id] = struct{}{}
					out = append(out, *rep)
				}
			}
		}
	}
	s.reportsMu.RUnlock()

	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].ID > out[j].ID
		}
		return out[i].CreatedAt.After(out[j].CreatedAt)
	})
	return out
}

// FindNearbyDuplicateReport finds the closest visible report of the same category within maxMeters.
func (s *LiveMemoryStore) FindNearbyDuplicateReport(category string, lat, lon, maxMeters float64, now time.Time) (CachedReport, bool) {
	cells := GridCellsForRadius(lat, lon, maxMeters+200.0)
	bestDist := maxMeters + 1.0
	var best CachedReport
	found := false

	s.reportsMu.RLock()
	for _, ck := range cells {
		for id := range s.reportsByCell[ck] {
			rep, ok := s.reportsByID[id]
			if !ok || rep.Category != category || !rep.IsVisibleAt(now) {
				continue
			}
			d := util.HaversineDistanceMeters(lat, lon, rep.Lat, rep.Lon)
			if d <= maxMeters && d < bestDist {
				bestDist = d
				best = *rep
				found = true
			}
		}
	}
	s.reportsMu.RUnlock()
	return best, found
}

// UpsertSos caches or removes an SOS alert depending on whether its status is active.
func (s *LiveMemoryStore) UpsertSos(alert CachedSosAlert) {
	if alert.ID == "" {
		return
	}
	s.sosMu.Lock()
	defer s.sosMu.Unlock()
	if alert.Status != "active" {
		delete(s.sosByID, alert.ID)
		delete(s.responders, alert.ID)
		return
	}
	cp := alert
	s.sosByID[alert.ID] = &cp
}

// UpsertSosResponder updates a responder's status/ETA in RAM.
func (s *LiveMemoryStore) UpsertSosResponder(r CachedSosResponder) {
	if r.SosID == "" || r.DeviceHash == "" {
		return
	}
	s.sosMu.Lock()
	defer s.sosMu.Unlock()
	rmap, ok := s.responders[r.SosID]
	if !ok {
		rmap = make(map[string]*CachedSosResponder, 4)
		s.responders[r.SosID] = rmap
	}
	cp := r
	rmap[r.DeviceHash] = &cp
}

// ActiveRespondersMap returns the active 'coming' responder deviceHashes within 30m for sosID.
func (s *LiveMemoryStore) ActiveRespondersMap(sosID string, now time.Time) map[string]bool {
	cutoff := now.Add(-PresenceRetentionWindow)
	s.sosMu.RLock()
	defer s.sosMu.RUnlock()
	rmap := s.responders[sosID]
	out := make(map[string]bool, len(rmap))
	for dh, r := range rmap {
		if r.Status == "coming" && !r.LastSeen.Before(cutoff) {
			out[dh] = true
		}
	}
	return out
}

// QueryActiveSos queries active non-expired SOS alerts matching caller, trailID, 5km radius, or responder role.
func (s *LiveMemoryStore) QueryActiveSos(trailID string, lat, lon float64, hasCoords bool, callerDeviceHash string, now time.Time) ([]CachedSosAlert, map[string]map[string]bool) {
	cutoff := now.Add(-PresenceRetentionWindow)
	s.sosMu.RLock()
	alerts := make([]CachedSosAlert, 0, len(s.sosByID))
	respBySos := make(map[string]map[string]bool, len(s.sosByID))

	for _, rec := range s.sosByID {
		if rec.Status != "active" || (!rec.ExpiresAt.IsZero() && rec.ExpiresAt.Before(now)) {
			continue
		}
		rmap := s.responders[rec.ID]
		activeResp := make(map[string]bool, len(rmap))
		for dh, r := range rmap {
			if r.Status == "coming" && !r.LastSeen.Before(cutoff) {
				activeResp[dh] = true
			}
		}

		matched := callerDeviceHash != "" && (rec.DeviceHash == callerDeviceHash || activeResp[callerDeviceHash])
		if !matched && trailID != "" && rec.TrailID == trailID {
			matched = true
		}
		if !matched && hasCoords && util.HaversineDistanceMeters(lat, lon, rec.Lat, rec.Lon) <= LiveRadiusMeters {
			matched = true
		}
		if matched {
			alerts = append(alerts, *rec)
			respBySos[rec.ID] = activeResp
		}
	}
	s.sosMu.RUnlock()

	sort.Slice(alerts, func(i, j int) bool {
		if alerts[i].CreatedAt.Equal(alerts[j].CreatedAt) {
			return alerts[i].ID > alerts[j].ID
		}
		return alerts[i].CreatedAt.After(alerts[j].CreatedAt)
	})
	return alerts, respBySos
}

// UpsertPushSub registers or updates a Web Push subscription in RAM.
func (s *LiveMemoryStore) UpsertPushSub(sub PushSubEntry, markSaved bool) {
	ep := strings.TrimSpace(sub.Endpoint)
	if ep == "" {
		return
	}
	sub.Endpoint = ep
	if markSaved || (!sub.Dirty && sub.SavedLat == 0 && sub.SavedLon == 0 && sub.SavedTrail == "") {
		sub.SavedLat = sub.Lat
		sub.SavedLon = sub.Lon
		sub.SavedTrail = sub.TrailID
		sub.Dirty = false
	}

	s.pushMu.Lock()
	defer s.pushMu.Unlock()

	if prev, ok := s.pushByEndpt[ep]; ok && prev.DeviceHash != sub.DeviceHash {
		if dmap, ok := s.pushByDevice[prev.DeviceHash]; ok {
			delete(dmap, ep)
		}
	}
	cp := sub
	s.pushByEndpt[ep] = &cp
	if sub.DeviceHash != "" {
		dmap, ok := s.pushByDevice[sub.DeviceHash]
		if !ok {
			dmap = make(map[string]*PushSubEntry, 1)
			s.pushByDevice[sub.DeviceHash] = dmap
		}
		dmap[ep] = &cp
	}
}

// DeletePushSub removes a Web Push subscription by endpoint from RAM.
func (s *LiveMemoryStore) DeletePushSub(endpoint string) {
	ep := strings.TrimSpace(endpoint)
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	prev, ok := s.pushByEndpt[ep]
	if !ok {
		return
	}
	delete(s.pushByEndpt, ep)
	if dmap, ok := s.pushByDevice[prev.DeviceHash]; ok {
		delete(dmap, ep)
		if len(dmap) == 0 {
			delete(s.pushByDevice, prev.DeviceHash)
		}
	}
}

// TouchPushLocation updates live coordinates in RAM and marks Dirty ONLY on >= 1,000m drift or trail change.
func (s *LiveMemoryStore) TouchPushLocation(deviceHash string, lat, lon float64, trailID string) {
	if deviceHash == "" {
		return
	}
	s.pushMu.RLock()
	_, exists := s.pushByDevice[deviceHash]
	s.pushMu.RUnlock()
	if !exists {
		return
	}

	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	for _, sub := range s.pushByDevice[deviceHash] {
		sub.Lat = lat
		sub.Lon = lon
		sub.TrailID = trailID
		if !sub.Dirty {
			if sub.SavedTrail != trailID ||
				(sub.SavedLat == 0 && sub.SavedLon == 0) ||
				util.HaversineDistanceMeters(sub.SavedLat, sub.SavedLon, lat, lon) >= PushCoarseDriftMeters {
				sub.Dirty = true
			}
		}
	}
}

// DrainDirtyPushSubs atomically snapshots and clears dirty flags for periodic batched SQLite persistence.
func (s *LiveMemoryStore) DrainDirtyPushSubs() []PushSubEntry {
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	var out []PushSubEntry
	for _, sub := range s.pushByEndpt {
		if sub.Dirty && sub.ID != "" {
			sub.SavedLat = sub.Lat
			sub.SavedLon = sub.Lon
			sub.SavedTrail = sub.TrailID
			sub.Dirty = false
			out = append(out, *sub)
		}
	}
	return out
}

// SelectSosPushTargets matches nearby Web Push endpoints within 5km or on sosTrailID in RAM with 0 SQL queries.
func (s *LiveMemoryStore) SelectSosPushTargets(callerDeviceHash, sosTrailID string, sosLat, sosLon float64, now time.Time) []PushMatchTarget {
	s.pushMu.RLock()
	subs := make([]PushSubEntry, 0, len(s.pushByEndpt))
	for _, sub := range s.pushByEndpt {
		if sub.DeviceHash != callerDeviceHash && sub.Endpoint != "" && sub.P256dh != "" && sub.Auth != "" {
			subs = append(subs, *sub)
		}
	}
	s.pushMu.RUnlock()

	targets := make([]PushMatchTarget, 0)
	seenEndpoints := make(map[string]struct{})
	for _, sub := range subs {
		if _, dup := seenEndpoints[sub.Endpoint]; dup {
			continue
		}
		matched := false
		bestDist := math.Inf(1)

		if pres, ok := s.GetPresence(sub.DeviceHash, PresenceRetentionWindow, now); ok {
			d := util.HaversineDistanceMeters(sosLat, sosLon, pres.Lat, pres.Lon)
			bestDist = d
			if d <= LiveRadiusMeters || (sosTrailID != "" && pres.TrailID == sosTrailID) {
				matched = true
			}
		}
		if sub.Lat != 0 || sub.Lon != 0 {
			d := util.HaversineDistanceMeters(sosLat, sosLon, sub.Lat, sub.Lon)
			if math.IsInf(bestDist, 1) {
				bestDist = d
			}
			if d <= LiveRadiusMeters {
				matched = true
			}
		}
		if sosTrailID != "" && sub.TrailID == sosTrailID {
			matched = true
		}

		if matched {
			seenEndpoints[sub.Endpoint] = struct{}{}
			if math.IsInf(bestDist, 1) {
				bestDist = 0
			}
			targets = append(targets, PushMatchTarget{
				Endpoint:  sub.Endpoint,
				P256dh:    sub.P256dh,
				Auth:      sub.Auth,
				DistanceM: math.Round(bestDist),
			})
		}
	}
	return targets
}
