package env_test

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
	"github.com/twpayne/go-polyline"

	_ "pocketbase/migrations"
	"pocketbase/services/env"
)

func seedTestTrail(t *testing.T, app core.App, coords [][]float64) *core.Record {
	t.Helper()
	actorsCol, _ := app.FindCollectionByNameOrId("activitypub_actors")
	actor := core.NewRecord(actorsCol)
	actor.Set("username", "tester")
	actor.Set("preferred_username", "tester")
	actor.Set("is_local", true)
	actor.Set("iri", "https://example.com/actors/tester")
	actor.Set("inbox", "https://example.com/actors/tester/inbox")
	actor.Set("public_key", "pem")
	if err := app.UnsafeWithoutHooks().Save(actor); err != nil {
		t.Fatalf("save actor: %v", err)
	}

	trailsCol, _ := app.FindCollectionByNameOrId("trails")
	tr := core.NewRecord(trailsCol)
	tr.Set("name", "Traseu Făgăraș Test")
	tr.Set("author", actor.Id)
	tr.Set("public", true)
	tr.Set("lat", coords[0][0])
	tr.Set("lon", coords[0][1])
	tr.Set("polyline", string(polyline.EncodeCoords(coords)))
	if err := app.UnsafeWithoutHooks().Save(tr); err != nil {
		t.Fatalf("save trail: %v", err)
	}
	return tr
}

func TestFirmsIngestorFiltersRomaniaConfidenceAndMatchesTrail(t *testing.T) {
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("new test app: %v", err)
	}
	defer app.Cleanup()

	trail := seedTestTrail(t, app, [][]float64{
		{45.6000, 24.6100},
		{45.6050, 24.6200},
	})

	csvPayload := "latitude,longitude,bright_ti4,scan,track,acq_date,acq_time,satellite,confidence,version,bright_ti5,frp,daynight\n" +
		"45.6020,24.6150,335.4,0.4,0.4,2026-11-18,1015,N20,high,2.0NRT,290.1,14.2,D\n" +
		"45.6022,24.6152,334.0,0.4,0.4,2026-11-18,1016,N21,high,2.0NRT,289.0,12.1,D\n" + // <500m dedup
		"45.6025,24.6155,312.0,0.4,0.4,2026-11-18,1015,N20,low,2.0NRT,285.0,2.1,D\n" +
		"52.1561,10.4047,330.0,0.4,0.4,2026-11-18,0900,N21,nominal,2.0NRT,280.0,5.0,D\n"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(csvPayload))
	}))
	defer srv.Close()

	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	count, err := env.SyncFirmsActiveFires(context.Background(), app, srv.Client(), []string{srv.URL}, now)
	if err != nil {
		t.Fatalf("SyncFirmsActiveFires error: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected 1 persisted wildfire hazard (with <500m dedup), got %d", count)
	}

	records, err := app.FindRecordsByFilter("env_hazards", "source = 'nasa_firms'", "", 10, 0, nil)
	if err != nil || len(records) != 1 {
		t.Fatalf("expected 1 env_hazards record, got %d (%v)", len(records), err)
	}
	if records[0].GetString("severity") != "danger" {
		t.Fatalf("expected severity=danger within 800m of trail, got %s", records[0].GetString("severity"))
	}
	var trailIDs []string
	_ = records[0].UnmarshalJSONField("affected_trail_ids", &trailIDs)
	if len(trailIDs) != 1 || trailIDs[0] != trail.Id {
		t.Fatalf("expected affected_trail_ids=[%s], got %v", trail.Id, trailIDs)
	}
}

func TestGladDisturbancePixelDecodeAndTileScan(t *testing.T) {
	dt, high, ok := env.DecodeGladDistAlertPixel(8, 100, 245, 255)
	if !ok || !high {
		t.Fatalf("expected valid high-confidence alert")
	}
	if dt.Format("2006-01-02") != "2026-11-10" {
		t.Fatalf("expected 2026-11-10, got %s", dt.Format("2006-01-02"))
	}

	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("new test app: %v", err)
	}
	defer app.Cleanup()

	lat, lon := 45.6000, 24.6100
	trail := seedTestTrail(t, app, [][]float64{
		{lat, lon},
		{lat + 0.0005, lon + 0.0005},
	})

	n := 4096.0
	xf := (lon + 180.0) / 360.0 * n
	latRad := lat * math.Pi / 180.0
	yf := (1.0 - math.Asinh(math.Tan(latRad))/math.Pi) / 2.0 * n
	px := int((xf - math.Floor(xf)) * 256.0)
	py := int((yf - math.Floor(yf)) * 256.0)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		img := image.NewNRGBA(image.Rect(0, 0, 256, 256))
		img.SetNRGBA(px, py, color.NRGBA{R: 8, G: 100, B: 245, A: 255})
		img.SetNRGBA(px+1, py, color.NRGBA{R: 8, G: 100, B: 245, A: 255})
		var buf bytes.Buffer
		_ = png.Encode(&buf, img)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(buf.Bytes())
	}))
	defer srv.Close()

	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	created, err := env.ScanDisturbanceTiles(context.Background(), app, srv.Client(), srv.URL+"/{z}/{x}/{y}.png", now)
	if err != nil {
		t.Fatalf("ScanDisturbanceTiles error: %v", err)
	}
	if created != 1 {
		t.Fatalf("expected 1 disturbance hazard, got %d", created)
	}
	records, _ := app.FindRecordsByFilter("env_hazards", "source = 'gfw_dist_alert'", "", 10, 0, nil)
	if len(records) != 1 {
		t.Fatalf("expected 1 gfw_dist_alert record, got %d", len(records))
	}
	var ids []string
	_ = records[0].UnmarshalJSONField("affected_trail_ids", &ids)
	if len(ids) != 1 || ids[0] != trail.Id {
		t.Fatalf("expected trail %s affected, got %v", trail.Id, ids)
	}
}
