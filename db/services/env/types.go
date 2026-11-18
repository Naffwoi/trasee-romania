package env

import (
	"math"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/twpayne/go-polyline"

	"pocketbase/util"
)

const (
	RoLatMin = 43.4
	RoLatMax = 48.5
	RoLonMin = 20.0
	RoLonMax = 30.0
)

type EnvHazardDto struct {
	ID               string   `json:"id"`
	Source           string   `json:"source"`
	HazardType       string   `json:"hazardType"`
	Severity         string   `json:"severity"`
	Title            string   `json:"title"`
	Lat              float64  `json:"lat"`
	Lon              float64  `json:"lon"`
	RadiusM          float64  `json:"radiusM"`
	Confidence       string   `json:"confidence"`
	AffectedTrailIDs []string `json:"affectedTrailIds,omitempty"`
	DetectedAt       string   `json:"detectedAt"`
	ExpiresAt        string   `json:"expiresAt"`
}

func RecordToEnvHazardDto(rec *core.Record) EnvHazardDto {
	var trailIDs []string
	_ = rec.UnmarshalJSONField("affected_trail_ids", &trailIDs)
	return EnvHazardDto{
		ID:               rec.Id,
		Source:           rec.GetString("source"),
		HazardType:       rec.GetString("hazard_type"),
		Severity:         rec.GetString("severity"),
		Title:            rec.GetString("title"),
		Lat:              rec.GetFloat("lat"),
		Lon:              rec.GetFloat("lon"),
		RadiusM:          rec.GetFloat("radius_m"),
		Confidence:       rec.GetString("confidence"),
		AffectedTrailIDs: trailIDs,
		DetectedAt:       rec.GetDateTime("detected_at").Time().UTC().Format(time.RFC3339),
		ExpiresAt:        rec.GetDateTime("expires_at").Time().UTC().Format(time.RFC3339),
	}
}

type TrailCorridor struct {
	ID     string
	Coords [][]float64
	MinLat float64
	MaxLat float64
	MinLon float64
	MaxLon float64
}

func LoadPublicTrailCorridors(app core.App) ([]TrailCorridor, error) {
	records := []*core.Record{}
	err := app.RecordQuery("trails").
		AndWhere(dbx.NewExp("public = TRUE AND polyline != ''")).
		All(&records)
	if err != nil {
		return nil, err
	}
	out := make([]TrailCorridor, 0, len(records))
	for _, r := range records {
		coords, _, decErr := polyline.DecodeCoords([]byte(r.GetString("polyline")))
		if decErr != nil || len(coords) == 0 {
			continue
		}
		minLat, maxLat := coords[0][0], coords[0][0]
		minLon, maxLon := coords[0][1], coords[0][1]
		for _, c := range coords[1:] {
			minLat = math.Min(minLat, c[0])
			maxLat = math.Max(maxLat, c[0])
			minLon = math.Min(minLon, c[1])
			maxLon = math.Max(maxLon, c[1])
		}
		out = append(out, TrailCorridor{
			ID:     r.Id,
			Coords: coords,
			MinLat: minLat,
			MaxLat: maxLat,
			MinLon: minLon,
			MaxLon: maxLon,
		})
	}
	return out, nil
}

func DistanceToCorridorMeters(lat, lon float64, coords [][]float64) float64 {
	if len(coords) == 0 {
		return math.Inf(1)
	}
	if len(coords) == 1 {
		return util.HaversineDistanceMeters(lat, lon, coords[0][0], coords[0][1])
	}
	const metersPerDegLat = 111132.92
	metersPerDegLon := metersPerDegLat * math.Max(0.1, math.Cos(lat*math.Pi/180.0))
	minSq := math.Inf(1)
	for i := 0; i < len(coords)-1; i++ {
		ax := (coords[i][1] - lon) * metersPerDegLon
		ay := (coords[i][0] - lat) * metersPerDegLat
		bx := (coords[i+1][1] - lon) * metersPerDegLon
		by := (coords[i+1][0] - lat) * metersPerDegLat
		dx, dy := bx-ax, by-ay
		lenSq := dx*dx + dy*dy
		t := 0.0
		if lenSq > 1e-9 {
			t = math.Max(0, math.Min(1, -(ax*dx+ay*dy)/lenSq))
		}
		px, py := ax+t*dx, ay+t*dy
		if dSq := px*px + py*py; dSq < minSq {
			minSq = dSq
		}
	}
	return math.Sqrt(minSq)
}
