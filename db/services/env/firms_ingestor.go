package env

import (
	"context"
	"encoding/csv"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"

	"pocketbase/util"
)

var DefaultKeylessFirmsURLs = []string{
	"https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-20-viirs-c2/csv/J1_VIIRS_C2_Europe_24h.csv",
	"https://firms.modaps.eosdis.nasa.gov/data/active_fire/noaa-21-viirs-c2/csv/J2_VIIRS_C2_Europe_24h.csv",
	"https://firms.modaps.eosdis.nasa.gov/data/active_fire/modis-c6.1/csv/MODIS_C6_1_Europe_24h.csv",
}

func ResolveFirmsFeedURLs() []string {
	if key := strings.TrimSpace(os.Getenv("FIRMS_MAP_KEY")); key != "" {
		return []string{
			fmt.Sprintf("https://firms.modaps.eosdis.nasa.gov/api/area/csv/%s/VIIRS_NOAA20_NRT/20.0,43.4,30.0,48.5/2", key),
			fmt.Sprintf("https://firms.modaps.eosdis.nasa.gov/api/area/csv/%s/VIIRS_NOAA21_NRT/20.0,43.4,30.0,48.5/2", key),
		}
	}
	return DefaultKeylessFirmsURLs
}

type firmsDetection struct {
	Lat        float64
	Lon        float64
	Confidence string
	FRP        float64
	DetectedAt time.Time
}

func isReliableFirmsConfidence(raw string) bool {
	c := strings.ToLower(strings.TrimSpace(raw))
	if c == "high" || c == "nominal" || c == "h" || c == "n" {
		return true
	}
	if n, err := strconv.Atoi(c); err == nil {
		return n >= 50
	}
	return false
}

func csvField(row []string, idx map[string]int, col string) string {
	pos, ok := idx[col]
	if !ok || pos < 0 || pos >= len(row) {
		return ""
	}
	return row[pos]
}

func fetchFirmsFeedCSV(ctx context.Context, client *http.Client, feedURL string, now time.Time, cluster *[]firmsDetection) bool {
	req, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if reqErr != nil {
		return false
	}
	resp, doErr := client.Do(req)
	if doErr != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}

	reader := csv.NewReader(io.LimitReader(resp.Body, 16*1024*1024))
	header, hErr := reader.Read()
	if hErr != nil {
		return false
	}
	idx := map[string]int{}
	for i, colName := range header {
		idx[strings.ToLower(strings.TrimSpace(colName))] = i
	}
	for {
		row, rErr := reader.Read()
		if rErr != nil {
			break
		}
		lat, err1 := strconv.ParseFloat(csvField(row, idx, "latitude"), 64)
		lon, err2 := strconv.ParseFloat(csvField(row, idx, "longitude"), 64)
		if err1 != nil || err2 != nil || lat < RoLatMin || lat > RoLatMax || lon < RoLonMin || lon > RoLonMax {
			continue
		}
		conf := csvField(row, idx, "confidence")
		if !isReliableFirmsConfidence(conf) {
			continue
		}
		frp, _ := strconv.ParseFloat(csvField(row, idx, "frp"), 64)
		acqDate := strings.TrimSpace(csvField(row, idx, "acq_date"))
		acqTime := fmt.Sprintf("%04s", strings.TrimSpace(csvField(row, idx, "acq_time")))
		detTime, tErr := time.Parse("2006-01-02 1504", acqDate+" "+acqTime)
		if tErr != nil {
			detTime = now.UTC()
		}

		duplicate := false
		for _, existing := range *cluster {
			if util.HaversineDistanceMeters(lat, lon, existing.Lat, existing.Lon) <= 500.0 {
				duplicate = true
				break
			}
		}
		if !duplicate {
			*cluster = append(*cluster, firmsDetection{
				Lat: lat, Lon: lon, Confidence: conf, FRP: frp, DetectedAt: detTime.UTC(),
			})
		}
	}
	return true
}

func SyncFirmsActiveFires(
	ctx context.Context,
	app core.App,
	client *http.Client,
	feedURLs []string,
	now time.Time,
) (int, error) {
	return SyncFirmsActiveFiresWithBroadcast(ctx, app, client, feedURLs, now, nil)
}

func SyncFirmsActiveFiresWithBroadcast(
	ctx context.Context,
	app core.App,
	client *http.Client,
	feedURLs []string,
	now time.Time,
	onHazard func(EnvHazardDto),
) (int, error) {
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	explicitFeeds := len(feedURLs) > 0
	if !explicitFeeds {
		feedURLs = ResolveFirmsFeedURLs()
	}

	corridors, err := LoadPublicTrailCorridors(app)
	if err != nil {
		return 0, err
	}
	hazardsCol, err := app.FindCollectionByNameOrId("env_hazards")
	if err != nil {
		return 0, err
	}

	var cluster []firmsDetection
	successFeeds := 0
	for _, feedURL := range feedURLs {
		if fetchFirmsFeedCSV(ctx, client, feedURL, now, &cluster) {
			successFeeds++
		}
	}
	// If FIRMS_MAP_KEY was set and all keyed requests failed, fall back to open 24h CSVs.
	if !explicitFeeds && successFeeds == 0 && strings.TrimSpace(os.Getenv("FIRMS_MAP_KEY")) != "" {
		for _, feedURL := range DefaultKeylessFirmsURLs {
			fetchFirmsFeedCSV(ctx, client, feedURL, now, &cluster)
		}
	}

	savedCount := 0
	for _, det := range cluster {
		affected := []string{}
		minDist := 999999.0
		for _, tr := range corridors {
			if det.Lat < tr.MinLat-0.03 || det.Lat > tr.MaxLat+0.03 || det.Lon < tr.MinLon-0.04 || det.Lon > tr.MaxLon+0.04 {
				continue
			}
			d := DistanceToCorridorMeters(det.Lat, det.Lon, tr.Coords)
			if d <= 2500.0 {
				affected = append(affected, tr.ID)
				if d < minDist {
					minDist = d
				}
			}
		}

		severity := "warning"
		if minDist <= 800.0 {
			severity = "danger"
		}
		extKey := fmt.Sprintf("firms:%s:%.3f:%.3f", det.DetectedAt.Format("2006-01-02"), det.Lat, det.Lon)
		rec, findErr := app.FindFirstRecordByData("env_hazards", "external_key", extKey)
		if findErr != nil || rec == nil {
			rec = core.NewRecord(hazardsCol)
			rec.Set("external_key", extKey)
		}
		detDT, _ := types.ParseDateTime(det.DetectedAt)
		expDT, _ := types.ParseDateTime(now.UTC().Add(36 * time.Hour))
		rec.Set("source", "nasa_firms")
		rec.Set("hazard_type", "wildfire")
		rec.Set("severity", severity)
		rec.Set("title", "Focar termic activ detectat din satelit (NASA FIRMS)")
		rec.Set("lat", det.Lat)
		rec.Set("lon", det.Lon)
		rec.Set("radius_m", 1000)
		rec.Set("confidence", det.Confidence)
		rec.Set("frp_mw", det.FRP)
		rec.Set("affected_trail_ids", affected)
		rec.Set("detected_at", detDT)
		rec.Set("expires_at", expDT)
		if err := app.Save(rec); err == nil {
			savedCount++
			if onHazard != nil {
				onHazard(RecordToEnvHazardDto(rec))
			}
		}
	}
	return savedCount, nil
}
