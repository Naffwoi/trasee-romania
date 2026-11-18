package main

import (
	"path/filepath"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
	_ "modernc.org/sqlite"

	"pocketbase/routes"
	"pocketbase/services/live"
)

const (
	liveSnapshotFilename = "live_state.snap"
	liveSnapshotInterval = 60 * time.Second
	liveSnapshotMaxAge   = 15 * time.Minute
)

// optimizedDBConnect configures modernc.org/sqlite for a 512 MiB container:
// - 128 MiB OS-shared mmap_size avoids duplicate user-space read copies across connections
// - cache_size(-4000) (~4 MiB/conn) × DataMaxOpenConns(16) caps private page cache at <= 64 MiB (down from 3,840 MiB)
// - journal_size_limit(67108864) bounds WAL disk footprint to 64 MiB.
func optimizedDBConnect(dbPath string) (*dbx.DB, error) {
	const pragmas = "?_pragma=busy_timeout(10000)" +
		"&_pragma=journal_mode(WAL)" +
		"&_pragma=journal_size_limit(67108864)" +
		"&_pragma=synchronous(NORMAL)" +
		"&_pragma=mmap_size(134217728)" +
		"&_pragma=cache_size(-4000)" +
		"&_pragma=temp_store(MEMORY)" +
		"&_pragma=foreign_keys(ON)"

	return dbx.Open("sqlite", dbPath+pragmas)
}

func newPocketBaseConfig() pocketbase.Config {
	return pocketbase.Config{
		DBConnect:        optimizedDBConnect,
		DataMaxOpenConns: 16,
		DataMaxIdleConns: 4,
		AuxMaxOpenConns:  4,
		AuxMaxIdleConns:  2,
	}
}

func liveSnapshotPath(dataDir string) string {
	return filepath.Join(dataDir, liveSnapshotFilename)
}

func startLiveMemoryLifecycle(app core.App, store *live.LiveMemoryStore) func() {
	snapPath := liveSnapshotPath(app.DataDir())
	now := time.Now().UTC()

	if err := routes.HydrateLiveMemoryStore(app, store); err != nil {
		app.Logger().Warn("failed to hydrate LiveMemoryStore from SQLite", "error", err)
	}
	if err := store.LoadSnapshot(snapPath, liveSnapshotMaxAge, now); err != nil {
		app.Logger().Warn("failed to load live state snapshot on startup", "error", err)
	}

	stopCh := make(chan struct{})
	go func() {
		ticker := time.NewTicker(liveSnapshotInterval)
		defer ticker.Stop()
		for {
			select {
			case <-stopCh:
				return
			case t := <-ticker.C:
				if err := store.SaveSnapshot(snapPath, t.UTC()); err != nil {
					app.Logger().Warn("periodic live snapshot failed", "error", err)
				}
			}
		}
	}()

	var stopOnce sync.Once
	return func() {
		stopOnce.Do(func() {
			close(stopCh)
		})
		if err := store.SaveSnapshot(snapPath, time.Now().UTC()); err != nil {
			app.Logger().Warn("shutdown live snapshot failed", "error", err)
		}
	}
}

func runSQLitePlannerOptimize(app core.App) {
	if _, err := app.ConcurrentDB().NewQuery("PRAGMA optimize").Execute(); err != nil {
		app.Logger().Warn("PRAGMA optimize failed", "error", err)
	}
}
