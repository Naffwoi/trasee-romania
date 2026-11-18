package main

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"pocketbase/services/live"
)

func TestOptimizedDBConnectPragmas(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "test_data.db")
	db, err := optimizedDBConnect(dbPath)
	if err != nil {
		t.Fatalf("optimizedDBConnect: %v", err)
	}
	defer db.Close()

	var journalMode string
	if err := db.NewQuery("PRAGMA journal_mode").Row(&journalMode); err != nil {
		t.Fatalf("PRAGMA journal_mode: %v", err)
	}
	if !strings.EqualFold(journalMode, "wal") {
		t.Fatalf("journal_mode = %q, want wal", journalMode)
	}

	var cacheSize int64
	if err := db.NewQuery("PRAGMA cache_size").Row(&cacheSize); err != nil {
		t.Fatalf("PRAGMA cache_size: %v", err)
	}
	if cacheSize != -4000 {
		t.Fatalf("cache_size = %d, want -4000 (~4 MiB per connection)", cacheSize)
	}

	var mmapSize int64
	if err := db.NewQuery("PRAGMA mmap_size").Row(&mmapSize); err != nil {
		t.Fatalf("PRAGMA mmap_size: %v", err)
	}
	// On platforms supporting mmap, SQLite reports 134217728 (128 MiB).
	if mmapSize < 0 {
		t.Fatalf("unexpected negative mmap_size: %d", mmapSize)
	}

	cfg := newPocketBaseConfig()
	if cfg.DataMaxOpenConns != 16 || cfg.DataMaxIdleConns != 4 || cfg.AuxMaxOpenConns != 4 {
		t.Fatalf("unexpected pool bounds: %+v", cfg)
	}
}

func TestLiveSnapshotPathAndPersistCycle(t *testing.T) {
	dir := t.TempDir()
	store := live.NewLiveMemoryStore()
	now := time.Now().UTC()
	store.UpsertPresence(live.PresenceEntry{
		DeviceHash: "dev-snap-1",
		TrailID:    "trail-1",
		Lat:        45.44,
		Lon:        25.45,
		LastSeen:   now,
	})

	snapFile := liveSnapshotPath(dir)
	if err := store.SaveSnapshot(snapFile, now); err != nil {
		t.Fatalf("SaveSnapshot: %v", err)
	}

	reloaded := live.NewLiveMemoryStore()
	if err := reloaded.LoadSnapshot(snapFile, liveSnapshotMaxAge, now.Add(10*time.Second)); err != nil {
		t.Fatalf("LoadSnapshot: %v", err)
	}
	if reloaded.PresenceCount() != 1 {
		t.Fatalf("expected 1 restored presence entry, got %d", reloaded.PresenceCount())
	}
}
