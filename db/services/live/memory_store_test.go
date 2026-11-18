package live

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestGridCellKeyAndNeighborhoodSearch(t *testing.T) {
	omuLat, omuLon := 45.4450, 25.4560
	centerKey := GridCellKey(omuLat, omuLon)
	if centerKey == 0 {
		t.Fatal("expected non-zero cell key for Omu Peak")
	}

	// Same spot within ~50m stays in same or adjacent 500m cell and MUST be covered by 2km radius cells.
	cells2km := GridCellsForRadius(omuLat, omuLon, 2000.0)
	nearKey := GridCellKey(45.4580, 25.4560) // ~1.44 km north
	found := false
	for _, ck := range cells2km {
		if ck == nearKey {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected 1.44km point cell %d to be inside 2km neighborhood (%d cells)", nearKey, len(cells2km))
	}
}

func TestLiveMemoryStorePresenceCorridorAndStationaryWindow(t *testing.T) {
	store := NewLiveMemoryStore()
	t0 := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)

	corridor := [][2]float64{
		{45.4080, 25.5420},
		{45.4300, 25.4900},
	}
	store.PutTrailCorridor("trail-bucegi", corridor)

	// Hiker A (caller), Hiker B (moving, on corridor), Hiker C (stationary=true at cabana), Hiker D (15km away).
	store.UpsertPresence(PresenceEntry{
		DeviceHash:   "hiker-a",
		TrailID:      "trail-bucegi",
		Lat:          45.4090,
		Lon:          25.5400,
		Ele:          1980,
		InNavigation: true,
		Stationary:   false,
		LastSeen:     t0,
	})
	store.UpsertPresence(PresenceEntry{
		DeviceHash:   "hiker-b",
		TrailID:      "trail-bucegi",
		Lat:          45.4150,
		Lon:          25.5250,
		Ele:          2025,
		InNavigation: true,
		Stationary:   false,
		LastSeen:     t0,
	})
	store.UpsertPresence(PresenceEntry{
		DeviceHash:   "hiker-cabana",
		TrailID:      "trail-bucegi",
		Lat:          45.4120,
		Lon:          25.5300,
		Ele:          2000,
		InNavigation: true,
		Stationary:   true,
		LastSeen:     t0,
	})
	store.UpsertPresence(PresenceEntry{
		DeviceHash: "hiker-far",
		TrailID:    "trail-fagaras",
		Lat:        45.6000,
		Lon:        24.6000,
		LastSeen:   t0,
	})

	if got := store.CountActiveNearbyUsers(corridor, "hiker-a", t0); got != 2 {
		t.Fatalf("at t0 CountActiveNearbyUsers = %d, want 2 (hiker-b + hiker-cabana)", got)
	}

	// At t0 + 8m: moving hiker-b (> 2m window) expires from live count,
	// while stationary hiker-cabana (<= 10m stationary window, 2x 300s keepalive) stays active!
	t8m := t0.Add(8 * time.Minute)
	if got := store.CountActiveNearbyUsers(corridor, "hiker-a", t8m); got != 1 {
		t.Fatalf("at t0+8m CountActiveNearbyUsers = %d, want 1 (stationary hiker-cabana still within 10m window)", got)
	}

	// At t0 + 11m: stationary hiker also expires if no 5m keepalive arrived.
	t11m := t0.Add(11 * time.Minute)
	if got := store.CountActiveNearbyUsers(corridor, "hiker-a", t11m); got != 0 {
		t.Fatalf("at t0+11m CountActiveNearbyUsers = %d, want 0", got)
	}
}

func TestReportSpatialIndexDoesNotTruncateBeyond500PermanentLandmarks(t *testing.T) {
	store := NewLiveMemoryStore()
	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)

	// Insert oldest permanent spring right at Bucegi (45.4100, 25.5400).
	store.UpsertReport(CachedReport{
		ID:              "spring-oldest",
		TrailID:         "trail-bucegi",
		Category:        "spring",
		Kind:            "landmark_permanent",
		IsPermanent:     true,
		ConditionStatus: "active",
		Note:            "Izvorul vechi",
		Lat:             45.4100,
		Lon:             25.5400,
		AlongTrackM:     -1,
		ConfirmCount:    4,
		CreatedAt:       now.Add(-30 * 24 * time.Hour),
		LastConfirmedAt: now.Add(-2 * 24 * time.Hour),
	})

	// Insert 650 newer permanent springs far away in Retezat (45.35, 22.88) — previously LIMIT 500 hid spring-oldest!
	for i := 0; i < 650; i++ {
		store.UpsertReport(CachedReport{
			ID:              fmt.Sprintf("spring-retezat-%03d", i),
			TrailID:         "trail-retezat",
			Category:        "spring",
			Kind:            "landmark_permanent",
			IsPermanent:     true,
			ConditionStatus: "active",
			Lat:             45.3500 + float64(i)*0.0001,
			Lon:             22.8800,
			AlongTrackM:     -1,
			ConfirmCount:    1,
			CreatedAt:       now.Add(-time.Duration(650-i) * time.Minute),
			LastConfirmedAt: now.Add(-time.Duration(650-i) * time.Minute),
		})
	}

	got := store.QueryVisibleReports("other-trail", 45.4105, 25.5402, true, now)
	if len(got) != 1 || got[0].ID != "spring-oldest" {
		t.Fatalf("expected spatial index to return spring-oldest despite 650 newer distant landmarks, got %d items", len(got))
	}
}

func TestPushSubCoarseDriftAndSnapshotRoundTrip(t *testing.T) {
	store := NewLiveMemoryStore()
	t0 := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)

	store.UpsertPushSub(PushSubEntry{
		ID:         "rec-push-1",
		DeviceHash: "dev-push-1",
		Endpoint:   "https://push.example/sub1",
		P256dh:     "p256-key",
		Auth:       "auth-key",
		Lat:        45.4000,
		Lon:        25.5000,
		TrailID:    "trail-1",
	}, false)

	// Moving only 80m on same trail MUST NOT mark SQLite row dirty.
	store.TouchPushLocation("dev-push-1", 45.4005, 25.5000, "trail-1")
	if dirty := store.DrainDirtyPushSubs(); len(dirty) != 0 {
		t.Fatalf("expected 0 dirty push subs for 55m move, got %d", len(dirty))
	}

	// Moving ~2.2km north MUST mark SQLite row dirty once.
	store.TouchPushLocation("dev-push-1", 45.4200, 25.5000, "trail-1")
	dirty := store.DrainDirtyPushSubs()
	if len(dirty) != 1 || dirty[0].ID != "rec-push-1" {
		t.Fatalf("expected 1 dirty push sub after 2.2km move, got %+v", dirty)
	}

	// Group + Presence + SOS responder snapshot round-trip.
	store.UpsertGroup(CachedGroup{
		RecordID:        "grp-rec-1",
		Code:            "ABC234",
		TrailID:         "trail-1",
		OwnerDeviceHash: "dev-host",
		ExpiresAt:       t0.Add(12 * time.Hour),
		LastDBSyncAt:    t0,
	})
	heading := 180.0
	store.UpsertGroupMember("ABC234", CachedGroupMember{
		DeviceHash:   "dev-host",
		MemberID:     "112233445566",
		DisplayName:  "Andrei",
		ColorHex:     "#242734",
		Lat:          45.4200,
		Lon:          25.5000,
		Ele:          2100,
		Accuracy:     6.5,
		Heading:      &heading,
		InNavigation: true,
		Stationary:   true,
		CreatedAt:    t0,
		LastSeen:     t0,
	})

	snapPath := filepath.Join(t.TempDir(), "live_state.snap")
	if err := store.SaveSnapshot(snapPath, t0); err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}

	restored := NewLiveMemoryStore()
	if err := restored.LoadSnapshot(snapPath, 10*time.Minute, t0.Add(30*time.Second)); err != nil {
		t.Fatalf("LoadSnapshot: %v", err)
	}
	members := restored.ListActiveGroupMembers("ABC234", 10*time.Minute, t0.Add(30*time.Second))
	if len(members) != 1 || members[0].DisplayName != "Andrei" || !members[0].Stationary {
		t.Fatalf("restored group members mismatch: %+v", members)
	}
}

func TestLiveMemoryStoreConcurrentContention(t *testing.T) {
	store := NewLiveMemoryStore()
	now := time.Now().UTC()
	var wg sync.WaitGroup
	for g := 0; g < 16; g++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				dh := fmt.Sprintf("dev-%d-%d", worker, i%25)
				store.UpsertPresence(PresenceEntry{
					DeviceHash: dh,
					TrailID:    "trail-stress",
					Lat:        45.30 + float64(i%40)*0.002,
					Lon:        25.40 + float64(worker)*0.002,
					LastSeen:   now,
				})
				_ = store.CountActiveNearbyUsers([][2]float64{{45.32, 25.42}, {45.35, 25.45}}, dh, now)
			}
		}(g)
	}
	wg.Wait()
}
