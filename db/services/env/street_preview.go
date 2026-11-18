package env

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"pocketbase/util"
)

type StreetPhotoDto struct {
	ID          string  `json:"id"`
	Provider    string  `json:"provider"` // "kartaview" | "mapillary"
	ThumbUrl    string  `json:"thumbUrl"`
	FullUrl     string  `json:"fullUrl"`
	Lat         float64 `json:"lat"`
	Lon         float64 `json:"lon"`
	Heading     float64 `json:"heading"`
	CapturedAt  string  `json:"capturedAt"`
	DistanceM   float64 `json:"distanceM"`
	Attribution string  `json:"attribution"`
}

type StreetPreviewService struct {
	client         *http.Client
	kartaViewURL   string
	mapillaryURL   string
	mapillaryToken string
	mu             sync.Mutex
	memo           map[string]cachedEntry[[]StreetPhotoDto]
}

func resolveMapillaryEnvToken() string {
	if tok := strings.TrimSpace(os.Getenv("MAPILLARY_ACCESS_TOKEN")); tok != "" {
		return tok
	}
	return strings.TrimSpace(os.Getenv("MAPILLARY_CLIENT_TOKEN"))
}

func NewStreetPreviewService(client *http.Client, kvURL, mlyURL, mlyToken string) *StreetPreviewService {
	if client == nil {
		client = &http.Client{Timeout: 8 * time.Second}
	}
	if kvURL == "" {
		kvURL = "https://api.kartaview.org/2.0/photo/"
	}
	if mlyURL == "" {
		mlyURL = "https://graph.mapillary.com/images"
	}
	return &StreetPreviewService{
		client:         client,
		kartaViewURL:   kvURL,
		mapillaryURL:   mlyURL,
		mapillaryToken: strings.TrimSpace(mlyToken),
		memo:           map[string]cachedEntry[[]StreetPhotoDto]{},
	}
}

var DefaultStreetPreviewService = NewStreetPreviewService(nil, "", "", resolveMapillaryEnvToken())

func (s *StreetPreviewService) FetchNearby(ctx context.Context, lat, lon float64) ([]StreetPhotoDto, error) {
	cacheKey := fmt.Sprintf("%.4f:%.4f", lat, lon)
	s.mu.Lock()
	if hit, ok := s.memo[cacheKey]; ok && time.Now().Before(hit.expiresAt) {
		s.mu.Unlock()
		return hit.val, nil
	}
	s.mu.Unlock()

	photos := s.fetchKartaView(ctx, lat, lon)
	token := s.mapillaryToken
	if token == "" {
		token = resolveMapillaryEnvToken()
	}
	if len(photos) < 2 && token != "" {
		photos = append(photos, s.fetchMapillary(ctx, lat, lon, token)...)
	}

	slices.SortFunc(photos, func(a, b StreetPhotoDto) int {
		if a.DistanceM < b.DistanceM {
			return -1
		}
		if a.DistanceM > b.DistanceM {
			return 1
		}
		return 0
	})
	if len(photos) > 8 {
		photos = photos[:8]
	}

	s.mu.Lock()
	s.memo[cacheKey] = cachedEntry[[]StreetPhotoDto]{val: photos, expiresAt: time.Now().Add(24 * time.Hour)}
	s.mu.Unlock()
	return photos, nil
}

func parseFlexFloat(v any) float64 {
	switch val := v.(type) {
	case float64:
		return val
	case string:
		f, _ := strconv.ParseFloat(strings.TrimSpace(val), 64)
		return f
	default:
		return 0
	}
}

func (s *StreetPreviewService) fetchKartaView(ctx context.Context, lat, lon float64) []StreetPhotoDto {
	u := fmt.Sprintf("%s?lat=%.6f&lng=%.6f&radius=400&itemsPerPage=8", s.kartaViewURL, lat, lon)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var raw struct {
		Result struct {
			Data []map[string]any `json:"data"`
		} `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil
	}
	out := make([]StreetPhotoDto, 0, len(raw.Result.Data))
	for _, item := range raw.Result.Data {
		pLat := parseFlexFloat(item["lat"])
		pLon := parseFlexFloat(item["lng"])
		thumb, _ := item["imageLthUrl"].(string)
		full, _ := item["imageProcUrl"].(string)
		if thumb == "" {
			thumb, _ = item["fileurlLTh"].(string)
		}
		if full == "" {
			full = thumb
		}
		if thumb == "" || (pLat == 0 && pLon == 0) {
			continue
		}
		shotDate, _ := item["shotDate"].(string)
		if len(shotDate) >= 10 {
			shotDate = shotDate[:10]
		}
		out = append(out, StreetPhotoDto{
			ID:          fmt.Sprintf("kv-%v", item["id"]),
			Provider:    "kartaview",
			ThumbUrl:    thumb,
			FullUrl:     full,
			Lat:         pLat,
			Lon:         pLon,
			Heading:     parseFlexFloat(item["heading"]),
			CapturedAt:  shotDate,
			DistanceM:   math.Round(util.HaversineDistanceMeters(lat, lon, pLat, pLon)),
			Attribution: "© KartaView contributors (CC BY-SA 4.0)",
		})
	}
	return out
}

func (s *StreetPreviewService) fetchMapillary(ctx context.Context, lat, lon float64, token string) []StreetPhotoDto {
	// Mapillary API v4 strictly enforces bbox < 0.01 degrees square; ±0.0035 is 0.007 deg (~770m).
	const d = 0.0035
	u := fmt.Sprintf(
		"%s?bbox=%.6f,%.6f,%.6f,%.6f&fields=id,geometry,compass_angle,captured_at,thumb_1024_url&limit=6",
		s.mapillaryURL, lon-d, lat-d, lon+d, lat+d,
	)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "OAuth "+token)
	resp, err := s.client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var raw struct {
		Data []struct {
			ID           string  `json:"id"`
			CompassAngle float64 `json:"compass_angle"`
			CapturedAt   int64   `json:"captured_at"`
			Thumb1024    string  `json:"thumb_1024_url"`
			Geometry     struct {
				Coordinates []float64 `json:"coordinates"`
			} `json:"geometry"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil
	}
	out := make([]StreetPhotoDto, 0, len(raw.Data))
	for _, it := range raw.Data {
		if it.Thumb1024 == "" || len(it.Geometry.Coordinates) < 2 {
			continue
		}
		pLon, pLat := it.Geometry.Coordinates[0], it.Geometry.Coordinates[1]
		capStr := ""
		if it.CapturedAt > 0 {
			capStr = time.UnixMilli(it.CapturedAt).UTC().Format("2006-01-02")
		}
		out = append(out, StreetPhotoDto{
			ID:          "mly-" + it.ID,
			Provider:    "mapillary",
			ThumbUrl:    it.Thumb1024,
			FullUrl:     it.Thumb1024,
			Lat:         pLat,
			Lon:         pLon,
			Heading:     it.CompassAngle,
			CapturedAt:  capStr,
			DistanceM:   math.Round(util.HaversineDistanceMeters(lat, lon, pLat, pLon)),
			Attribution: "© Mapillary contributors (CC BY-SA 4.0)",
		})
	}
	return out
}
