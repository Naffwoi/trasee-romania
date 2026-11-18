package env

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"time"
)

type MountainWeatherDto struct {
	ElevationM        float64 `json:"elevationM"`
	TemperatureC      float64 `json:"temperatureC"`
	ApparentTempC     float64 `json:"apparentTempC"`
	WeatherCode       int     `json:"weatherCode"`
	WindSpeed10mKmh   float64 `json:"windSpeed10mKmh"`
	WindGustsKmh      float64 `json:"windGustsKmh"`
	RidgeWindPeakKmh  float64 `json:"ridgeWindPeakKmh"`
	RidgeWindSeverity string  `json:"ridgeWindSeverity"` // "none" | "warning" | "danger"
	FreezingLevelM    float64 `json:"freezingLevelM"`
	FreezingOnTrail   bool    `json:"freezingOnTrail"`
	SnowDepthCm       float64 `json:"snowDepthCm"`
	MaxCapeJkg        float64 `json:"maxCapeJkg"`
	ThunderstormRisk  bool    `json:"thunderstormRisk"`
	Attribution       string  `json:"attribution"`
}

type GorgeFloodDto struct {
	BaselineMedianM3s float64 `json:"baselineMedianM3s"`
	BaselineP90M3s    float64 `json:"baselineP90M3s"`
	ForecastPeakM3s   float64 `json:"forecastPeakM3s"`
	RatioToMedian     float64 `json:"ratioToMedian"`
	Warning           bool    `json:"warning"`
	Severity          string  `json:"severity"` // "none" | "warning" | "danger"
	Attribution       string  `json:"attribution"`
}

type cachedEntry[T any] struct {
	val       T
	expiresAt time.Time
}

type EnvironmentService struct {
	client      *http.Client
	forecastURL string
	floodURL    string
	mu          sync.Mutex
	weatherMemo map[string]cachedEntry[*MountainWeatherDto]
	floodMemo   map[string]cachedEntry[*GorgeFloodDto]
}

func NewEnvironmentService(client *http.Client, forecastURL, floodURL string) *EnvironmentService {
	if client == nil {
		client = &http.Client{Timeout: 8 * time.Second}
	}
	if forecastURL == "" {
		if strings.TrimSpace(os.Getenv("OPEN_METEO_API_KEY")) != "" {
			forecastURL = "https://customer-api.open-meteo.com/v1/forecast"
		} else {
			forecastURL = "https://api.open-meteo.com/v1/forecast"
		}
	}
	if floodURL == "" {
		floodURL = "https://flood-api.open-meteo.com/v1/flood"
	}
	return &EnvironmentService{
		client:      client,
		forecastURL: forecastURL,
		floodURL:    floodURL,
		weatherMemo: map[string]cachedEntry[*MountainWeatherDto]{},
		floodMemo:   map[string]cachedEntry[*GorgeFloodDto]{},
	}
}

var DefaultEnvironmentService = NewEnvironmentService(nil, "", "")

func (s *EnvironmentService) FetchMountainWeather(ctx context.Context, lat, lon, maxEleM float64) (*MountainWeatherDto, error) {
	eleParam := math.Max(200, math.Round(maxEleM/100.0)*100.0)
	cacheKey := fmt.Sprintf("%.2f:%.2f:%.0f", math.Round(lat*20)/20, math.Round(lon*20)/20, eleParam)

	s.mu.Lock()
	if hit, ok := s.weatherMemo[cacheKey]; ok && time.Now().Before(hit.expiresAt) {
		s.mu.Unlock()
		return hit.val, nil
	}
	s.mu.Unlock()

	u := fmt.Sprintf(
		"%s?latitude=%.4f&longitude=%.4f&elevation=%.0f&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_gusts_10m,snow_depth&hourly=wind_speed_800hPa,wind_speed_700hPa,freezing_level_height,cape&forecast_days=1&timezone=Europe%%2FBucharest",
		s.forecastURL, lat, lon, eleParam,
	)
	if key := strings.TrimSpace(os.Getenv("OPEN_METEO_API_KEY")); key != "" {
		u += "&apikey=" + key
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("open-meteo status %d", resp.StatusCode)
	}

	var raw struct {
		Elevation float64 `json:"elevation"`
		Current   struct {
			Temp       float64 `json:"temperature_2m"`
			Apparent   float64 `json:"apparent_temperature"`
			Code       int     `json:"weather_code"`
			Wind10m    float64 `json:"wind_speed_10m"`
			Gusts10m   float64 `json:"wind_gusts_10m"`
			SnowDepthM float64 `json:"snow_depth"`
		} `json:"current"`
		Hourly struct {
			Wind800  []float64 `json:"wind_speed_800hPa"`
			Wind700  []float64 `json:"wind_speed_700hPa"`
			Freezing []float64 `json:"freezing_level_height"`
			Cape     []float64 `json:"cape"`
		} `json:"hourly"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}

	ridgePeak := raw.Current.Gusts10m
	upperSeries := raw.Hourly.Wind800
	if eleParam >= 2100 && len(raw.Hourly.Wind700) > 0 {
		upperSeries = raw.Hourly.Wind700
	}
	for _, w := range upperSeries {
		if w > ridgePeak {
			ridgePeak = w
		}
	}
	windSeverity := "none"
	if ridgePeak >= 85.0 {
		windSeverity = "danger"
	} else if ridgePeak >= 60.0 {
		windSeverity = "warning"
	}

	minFreezing := 9999.0
	for _, fz := range raw.Hourly.Freezing {
		if fz > 0 && fz < minFreezing {
			minFreezing = fz
		}
	}
	if minFreezing == 9999.0 {
		minFreezing = 0
	}

	maxCape := 0.0
	for _, c := range raw.Hourly.Cape {
		if c > maxCape {
			maxCape = c
		}
	}

	dto := &MountainWeatherDto{
		ElevationM:        raw.Elevation,
		TemperatureC:      raw.Current.Temp,
		ApparentTempC:     raw.Current.Apparent,
		WeatherCode:       raw.Current.Code,
		WindSpeed10mKmh:   raw.Current.Wind10m,
		WindGustsKmh:      raw.Current.Gusts10m,
		RidgeWindPeakKmh:  math.Round(ridgePeak*10) / 10,
		RidgeWindSeverity: windSeverity,
		FreezingLevelM:    minFreezing,
		FreezingOnTrail:   (minFreezing > 0 && minFreezing <= eleParam+150) || raw.Current.Temp <= 0.5,
		SnowDepthCm:       math.Round(raw.Current.SnowDepthM * 100),
		MaxCapeJkg:        maxCape,
		ThunderstormRisk:  maxCape >= 800 || raw.Current.Code == 95 || raw.Current.Code == 96 || raw.Current.Code == 99,
		Attribution:       "Weather data by Open-Meteo.com (CC BY 4.0)",
	}

	s.mu.Lock()
	s.weatherMemo[cacheKey] = cachedEntry[*MountainWeatherDto]{val: dto, expiresAt: time.Now().Add(30 * time.Minute)}
	s.mu.Unlock()
	return dto, nil
}

func (s *EnvironmentService) FetchGorgeFloodRisk(ctx context.Context, lat, lon float64) (*GorgeFloodDto, error) {
	cacheKey := fmt.Sprintf("%.2f:%.2f", math.Round(lat*20)/20, math.Round(lon*20)/20)
	s.mu.Lock()
	if hit, ok := s.floodMemo[cacheKey]; ok && time.Now().Before(hit.expiresAt) {
		s.mu.Unlock()
		return hit.val, nil
	}
	s.mu.Unlock()

	u := fmt.Sprintf(
		"%s?latitude=%.4f&longitude=%.4f&daily=river_discharge,river_discharge_max&past_days=92&forecast_days=3",
		s.floodURL, lat, lon,
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("glofas status %d", resp.StatusCode)
	}

	var raw struct {
		Daily struct {
			Discharge []float64 `json:"river_discharge"`
			Max       []float64 `json:"river_discharge_max"`
		} `json:"daily"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}
	total := len(raw.Daily.Discharge)
	if total < 10 {
		return nil, fmt.Errorf("insufficient glofas series")
	}
	histEnd := total - 3
	if histEnd < 5 {
		histEnd = total / 2
	}
	hist := slices.Clone(raw.Daily.Discharge[:histEnd])
	slices.Sort(hist)
	median := hist[len(hist)/2]
	p90 := hist[int(float64(len(hist)-1)*0.90)]

	forecastPeak := 0.0
	for i := histEnd; i < len(raw.Daily.Max); i++ {
		if raw.Daily.Max[i] > forecastPeak {
			forecastPeak = raw.Daily.Max[i]
		}
	}
	ratio := 1.0
	if median > 0.05 {
		ratio = math.Round((forecastPeak/median)*100) / 100
	}
	severity := "none"
	if forecastPeak >= math.Max(10.0, 4.0*median) && forecastPeak > p90 {
		severity = "danger"
	} else if forecastPeak >= math.Max(5.0, 2.5*median) && forecastPeak > p90 {
		severity = "warning"
	}

	dto := &GorgeFloodDto{
		BaselineMedianM3s: math.Round(median*100) / 100,
		BaselineP90M3s:    math.Round(p90*100) / 100,
		ForecastPeakM3s:   math.Round(forecastPeak*100) / 100,
		RatioToMedian:     ratio,
		Warning:           severity != "none",
		Severity:          severity,
		Attribution:       "Copernicus GloFAS via Open-Meteo (CC BY 4.0)",
	}
	s.mu.Lock()
	s.floodMemo[cacheKey] = cachedEntry[*GorgeFloodDto]{val: dto, expiresAt: time.Now().Add(3 * time.Hour)}
	s.mu.Unlock()
	return dto, nil
}
