package env_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"pocketbase/services/env"
)

func TestMountainWeatherAndGorgeFloodWarnings(t *testing.T) {
	forecastCalls := 0
	floodCalls := 0
	forecastMux := http.NewServeMux()
	forecastMux.HandleFunc("/v1/forecast", func(w http.ResponseWriter, r *http.Request) {
		forecastCalls++
		_ = json.NewEncoder(w).Encode(map[string]any{
			"elevation": 2505.0,
			"current": map[string]any{
				"temperature_2m":       -2.4,
				"apparent_temperature": -8.1,
				"weather_code":         95,
				"wind_speed_10m":       38.0,
				"wind_gusts_10m":       68.0,
				"snow_depth":           0.42,
			},
			"hourly": map[string]any{
				"wind_speed_800hPa":     []float64{45.0, 52.0},
				"wind_speed_700hPa":     []float64{74.0, 88.0},
				"freezing_level_height": []float64{2200.0, 2150.0},
				"cape":                  []float64{950.0, 400.0},
			},
		})
	})
	forecastMux.HandleFunc("/v1/flood", func(w http.ResponseWriter, r *http.Request) {
		floodCalls++
		if r.URL.Query().Get("past_days") != "92" {
			t.Errorf("expected past_days=92 for climatological baseline, got %q", r.URL.Query().Get("past_days"))
		}
		dis := make([]float64, 95)
		maxes := make([]float64, 95)
		for i := 0; i < 92; i++ {
			dis[i] = 1.2
			maxes[i] = 1.4
		}
		dis[92], dis[93], dis[94] = 3.5, 6.2, 5.0
		maxes[92], maxes[93], maxes[94] = 4.1, 7.8, 6.4
		_ = json.NewEncoder(w).Encode(map[string]any{
			"daily": map[string]any{
				"river_discharge":     dis,
				"river_discharge_max": maxes,
			},
		})
	})
	srv := httptest.NewServer(forecastMux)
	defer srv.Close()

	svc := env.NewEnvironmentService(srv.Client(), srv.URL+"/v1/forecast", srv.URL+"/v1/flood")
	weather, err := svc.FetchMountainWeather(context.Background(), 45.4458, 25.4563, 2505)
	if err != nil {
		t.Fatalf("FetchMountainWeather failed: %v", err)
	}
	if weather.RidgeWindSeverity != "danger" {
		t.Fatalf("expected ridge wind danger at 88 km/h, got %s", weather.RidgeWindSeverity)
	}
	if !weather.ThunderstormRisk || !weather.FreezingOnTrail {
		t.Fatalf("expected thunderstorm and freezing warnings: %+v", weather)
	}

	// Second call hits 30m cache
	_, err = svc.FetchMountainWeather(context.Background(), 45.4458, 25.4563, 2505)
	if err != nil || forecastCalls != 1 {
		t.Fatalf("expected cached weather response (calls=%d, err=%v)", forecastCalls, err)
	}

	flood, err := svc.FetchGorgeFloodRisk(context.Background(), 44.8912, 21.7825)
	if err != nil {
		t.Fatalf("FetchGorgeFloodRisk failed: %v", err)
	}
	if !flood.Warning || flood.ForecastPeakM3s < 7.5 || flood.BaselineMedianM3s > 1.5 {
		t.Fatalf("expected gorge flood warning vs 92d baseline, got %+v", flood)
	}
	_, err = svc.FetchGorgeFloodRisk(context.Background(), 44.8912, 21.7825)
	if err != nil || floodCalls != 1 {
		t.Fatalf("expected cached flood response (calls=%d, err=%v)", floodCalls, err)
	}
}

func TestStreetPreviewKartaViewPrimaryAndMapillaryFallback(t *testing.T) {
	kvCalls := 0
	mlyCalls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/2.0/photo/" {
			kvCalls++
			if r.URL.Query().Get("lat") == "45.412500" {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"result": map[string]any{
						"data": []map[string]any{
							{
								"id":           722188,
								"lat":          "45.412871",
								"lng":          "25.534592",
								"heading":      "181.57",
								"shotDate":     "2023-07-17 13:08:48.000",
								"imageLthUrl":  "https://cdn.kartaview.org/sample_lth.jpg",
								"imageProcUrl": "https://cdn.kartaview.org/sample_proc.jpg",
							},
							{
								"id":           722189,
								"lat":          "45.412600",
								"lng":          "25.535900",
								"heading":      "90.0",
								"shotDate":     "2023-07-17 13:09:00.000",
								"imageLthUrl":  "https://cdn.kartaview.org/sample2_lth.jpg",
								"imageProcUrl": "https://cdn.kartaview.org/sample2_proc.jpg",
							},
						},
					},
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"data": []any{}}})
			return
		}
		if r.URL.Path == "/images" {
			mlyCalls++
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": []map[string]any{
					{
						"id":             "mly-1",
						"compass_angle":  215.4,
						"captured_at":    1718000000000,
						"thumb_1024_url": "https://scontent.mapillary.com/mly1.jpg",
						"geometry": map[string]any{
							"coordinates": []float64{25.3182, 45.5528},
						},
					},
				},
			})
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	svc := env.NewStreetPreviewService(srv.Client(), srv.URL+"/2.0/photo/", srv.URL+"/images", "MLY|test")

	res1, err := svc.FetchNearby(context.Background(), 45.4125, 25.5361)
	if err != nil || len(res1) != 2 || mlyCalls != 0 {
		t.Fatalf("expected 2 KartaView photos & 0 Mapillary calls, got len=%d mlyCalls=%d err=%v", len(res1), mlyCalls, err)
	}
	if res1[0].Provider != "kartaview" {
		t.Fatalf("expected provider=kartaview, got %s", fmt.Sprint(res1[0].Provider))
	}

	// Second call hits 24h cache
	_, err = svc.FetchNearby(context.Background(), 45.4125, 25.5361)
	if err != nil || kvCalls != 1 {
		t.Fatalf("expected cached KartaView result (kvCalls=%d, err=%v)", kvCalls, err)
	}

	res2, err := svc.FetchNearby(context.Background(), 45.5528, 25.3182)
	if err != nil || len(res2) != 1 || mlyCalls != 1 {
		t.Fatalf("expected 1 Mapillary fallback photo, got len=%d mlyCalls=%d err=%v", len(res2), mlyCalls, err)
	}
}
