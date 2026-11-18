package env_test

import (
	"context"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"pocketbase/services/env"
)

func TestXyzToEpsg3857Bbox(t *testing.T) {
	minX, minY, maxX, maxY := env.XyzToEpsg3857Bbox(0, 0, 0)
	if math.Round(minX) != -20037508 || math.Round(maxX) != 20037508 {
		t.Fatalf("unexpected z=0 X bounds: %v, %v", minX, maxX)
	}
	if maxY <= minY {
		t.Fatalf("expected maxY > minY: %v, %v", minY, maxY)
	}
}

func TestAncpiServiceProbeCacheAndGuards(t *testing.T) {
	// Unconfigured template -> false & ErrAncpiNotConfigured
	unconfigured := env.NewAncpiService(http.DefaultClient, "")
	if unconfigured.ProbeAvailable(context.Background()) {
		t.Fatal("expected ProbeAvailable=false when template is empty")
	}
	if _, _, _, err := unconfigured.FetchTile(context.Background(), 12, 2338, 1471); !errors.Is(err, env.ErrAncpiNotConfigured) {
		t.Fatalf("expected ErrAncpiNotConfigured, got %v", err)
	}

	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		if r.URL.Query().Get("badmime") == "1" {
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte("<html>error</html>"))
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte{0xFF, 0xD8, 0xFF, 0xD9})
	}))
	defer srv.Close()

	svc := env.NewAncpiService(srv.Client(), srv.URL+"/wms?bbox={bbox-epsg-3857}&z={z}&x={x}&y={y}")
	if !svc.ProbeAvailable(context.Background()) {
		t.Fatal("expected ProbeAvailable=true")
	}
	if !svc.ProbeAvailable(context.Background()) {
		t.Fatal("expected cached ProbeAvailable=true")
	}
	if hits.Load() != 1 {
		t.Fatalf("expected ProbeAvailable cached (1 upstream hit), got %d", hits.Load())
	}

	body, ct, status, err := svc.FetchTile(context.Background(), 12, 2338, 1471)
	if err != nil || status != http.StatusOK || ct != "image/jpeg" || len(body) != 4 {
		t.Fatalf("FetchTile failed: status=%d ct=%q len=%d err=%v", status, ct, len(body), err)
	}

	badMimeSvc := env.NewAncpiService(srv.Client(), srv.URL+"/wms?badmime=1&z={z}&x={x}&y={y}")
	if _, _, _, err := badMimeSvc.FetchTile(context.Background(), 12, 2338, 1471); !errors.Is(err, env.ErrAncpiInvalidMime) {
		t.Fatalf("expected ErrAncpiInvalidMime, got %v", err)
	}
}
