package routes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"pocketbase/services/env"
	"pocketbase/services/live"
)

func TestPublicAndInternalEnvRoutesAndAncpiWms(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	// Seed an actor, a gorge trail, and an active env_hazard
	actorsCol, _ := app.FindCollectionByNameOrId("activitypub_actors")
	actor := core.NewRecord(actorsCol)
	actor.Set("username", "ro-env")
	actor.Set("preferred_username", "ro-env")
	actor.Set("is_local", true)
	actor.Set("iri", "https://example.com/actors/ro-env")
	actor.Set("inbox", "https://example.com/actors/ro-env/inbox")
	actor.Set("public_key", "pem")
	if err := app.UnsafeWithoutHooks().Save(actor); err != nil {
		t.Fatal(err)
	}

	trailsCol, _ := app.FindCollectionByNameOrId("trails")
	trail := core.NewRecord(trailsCol)
	trail.Set("name", "Cheile Nerei Test")
	trail.Set("author", actor.Id)
	trail.Set("public", true)
	trail.Set("lat", 44.8912)
	trail.Set("lon", 21.7825)
	trail.Set("elevation_gain", 450)
	trail.Set("is_water_gorge", true)
	if err := app.UnsafeWithoutHooks().Save(trail); err != nil {
		t.Fatal(err)
	}

	hazardsCol, _ := app.FindCollectionByNameOrId("env_hazards")
	haz := core.NewRecord(hazardsCol)
	detDT, _ := types.ParseDateTime(time.Now().UTC().Add(-1 * time.Hour))
	expDT, _ := types.ParseDateTime(time.Now().UTC().Add(24 * time.Hour))
	haz.Set("external_key", "firms:test:1")
	haz.Set("source", "nasa_firms")
	haz.Set("hazard_type", "wildfire")
	haz.Set("severity", "danger")
	haz.Set("title", "Focar activ test")
	haz.Set("lat", 44.8915)
	haz.Set("lon", 21.7830)
	haz.Set("radius_m", 1000)
	haz.Set("confidence", "high")
	haz.Set("affected_trail_ids", []string{trail.Id})
	haz.Set("detected_at", detDT)
	haz.Set("expires_at", expDT)
	if err := app.Save(haz); err != nil {
		t.Fatal(err)
	}

	// Mock external services (weather/flood/street/ancpi)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/forecast":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"elevation": 1050.0,
				"current": map[string]any{
					"temperature_2m": 12.0, "apparent_temperature": 11.0,
					"weather_code": 1, "wind_speed_10m": 15.0, "wind_gusts_10m": 25.0, "snow_depth": 0.0,
				},
				"hourly": map[string]any{
					"wind_speed_800hPa": []float64{30.0}, "wind_speed_700hPa": []float64{40.0},
					"freezing_level_height": []float64{2800.0}, "cape": []float64{100.0},
				},
			})
		case r.URL.Path == "/v1/flood":
			dis := make([]float64, 95)
			maxes := make([]float64, 95)
			for i := 0; i < 95; i++ {
				dis[i] = 2.0
				maxes[i] = 2.2
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"daily": map[string]any{"river_discharge": dis, "river_discharge_max": maxes},
			})
		case r.URL.Path == "/2.0/photo/":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"result": map[string]any{
					"data": []map[string]any{{
						"id": 101, "lat": "44.8912", "lng": "21.7825", "heading": "45",
						"shotDate": "2024-05-01 10:00:00", "imageLthUrl": "https://cdn.example/kv_lth.jpg",
						"imageProcUrl": "https://cdn.example/kv_proc.jpg",
					}},
				},
			})
		case strings.HasPrefix(r.URL.Path, "/wms"):
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()

	pbRouter, err := apis.NewRouter(app)
	if err != nil {
		t.Fatal(err)
	}
	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)
	handler.EnvService = env.NewEnvironmentService(upstream.Client(), upstream.URL+"/v1/forecast", upstream.URL+"/v1/flood")
	handler.StreetService = env.NewStreetPreviewService(upstream.Client(), upstream.URL+"/2.0/photo/", "", "")
	registerTrailLiveRouterGroups(pbRouter, handler)

	ancpi := NewAncpiProxyHandler(upstream.Client(), upstream.URL+"/wms?BBOX={bbox-epsg-3857}&Z={z}&X={x}&Y={y}")
	se := &core.ServeEvent{App: app, Router: pbRouter}
	registerMapEnvRoutesWithAncpi(se, ancpi)

	mux, err := pbRouter.BuildMux()
	if err != nil {
		t.Fatal(err)
	}

	// 1. Public & internal /trail/{id}/environment
	for _, path := range []string{
		"/api/v1/live/trail/" + trail.Id + "/environment",
		"/live/trail/" + trail.Id + "/environment",
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if strings.HasPrefix(path, "/live/") {
			req.Header.Set("X-Internal-Secret", testLiveSecret)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s = %d: %s", path, rec.Code, rec.Body.String())
		}
		var body struct {
			Weather    *env.MountainWeatherDto `json:"weather"`
			GorgeFlood *env.GorgeFloodDto      `json:"gorgeFlood"`
			Hazards    []env.EnvHazardDto      `json:"hazards"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if body.Weather == nil || body.GorgeFlood == nil || len(body.Hazards) != 1 {
			t.Fatalf("unexpected environment payload from %s: %+v", path, body)
		}
	}

	// 2. Public & internal /street-preview
	for _, path := range []string{
		"/api/v1/live/street-preview?lat=44.8912&lon=21.7825",
		"/live/street-preview?lat=44.8912&lon=21.7825",
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if strings.HasPrefix(path, "/live/") {
			req.Header.Set("X-Internal-Secret", testLiveSecret)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s = %d: %s", path, rec.Code, rec.Body.String())
		}
		var body struct {
			Photos []env.StreetPhotoDto `json:"photos"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &body)
		if len(body.Photos) != 1 || body.Photos[0].Provider != "kartaview" {
			t.Fatalf("unexpected street-preview payload from %s: %+v", path, body)
		}
	}

	// 3. Public & internal /env-hazards summary
	for _, path := range []string{
		"/api/v1/live/env-hazards?trailId=" + trail.Id,
		"/live/env-hazards?trailId=" + trail.Id,
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if strings.HasPrefix(path, "/live/") {
			req.Header.Set("X-Internal-Secret", testLiveSecret)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s = %d: %s", path, rec.Code, rec.Body.String())
		}
		var body struct {
			Hazards []env.EnvHazardDto `json:"hazards"`
			Count   int                `json:"count"`
		}
		_ = json.Unmarshal(rec.Body.Bytes(), &body)
		if body.Count != 1 || len(body.Hazards) != 1 {
			t.Fatalf("unexpected env-hazards summary from %s: %+v", path, body)
		}
	}

	// 4. SSE env_hazard_alert broadcast
	sub, unsub := hub.Subscribe(44.8912, 21.7825, true, trail.Id, "dev-sse-1")
	defer unsub()
	hub.BroadcastEnvHazardUpdate(live.GeoTarget{
		TrailID:   trail.Id,
		Lat:       44.8915,
		Lon:       21.7830,
		HasCoords: true,
	}, env.EnvHazardDto{ID: haz.Id, HazardType: "wildfire", Severity: "danger"})
	select {
	case raw := <-sub.Ch:
		if !strings.Contains(string(raw), "event: env_hazard_alert\n") {
			t.Fatalf("expected env_hazard_alert SSE event, got %s", string(raw))
		}
	default:
		t.Fatal("expected SSE subscriber to receive env_hazard_alert")
	}

	// 5. ANCPI WMS proxy + ancpiOrthoAvailable probe
	statusReq := httptest.NewRequest(http.MethodGet, "/api/v1/map/ancpi-wms/status", nil)
	statusRec := httptest.NewRecorder()
	mux.ServeHTTP(statusRec, statusReq)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("GET ancpi-wms/status = %d: %s", statusRec.Code, statusRec.Body.String())
	}
	var stBody map[string]bool
	_ = json.Unmarshal(statusRec.Body.Bytes(), &stBody)
	if !stBody["ancpiOrthoAvailable"] {
		t.Fatalf("expected ancpiOrthoAvailable=true, got %v", stBody)
	}

	wmsReq := httptest.NewRequest(http.MethodGet, "/api/v1/map/ancpi-wms?z=12&x=2338&y=1471", nil)
	wmsRec := httptest.NewRecorder()
	mux.ServeHTTP(wmsRec, wmsReq)
	if wmsRec.Code != http.StatusOK || wmsRec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("GET ancpi-wms tile = %d ct=%q", wmsRec.Code, wmsRec.Header().Get("Content-Type"))
	}

	// Invalid coords rejected
	badWms := httptest.NewRequest(http.MethodGet, "/api/v1/map/ancpi-wms?z=99&x=0&y=0", nil)
	badRec := httptest.NewRecorder()
	mux.ServeHTTP(badRec, badWms)
	if badRec.Code != http.StatusBadRequest {
		t.Fatalf("invalid z=99 status = %d, want 400", badRec.Code)
	}
}
