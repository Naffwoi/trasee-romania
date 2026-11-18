package env

import (
	"context"
	"fmt"
	"image"
	_ "image/png"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

const DefaultGfwEncodedTileTemplate = "https://tiles.globalforestwatch.org/umd_glad_dist_alerts/latest/dynamic/{z}/{x}/{y}.png?render_type=encoded&tree_cover_density_threshold=30&tree_cover_height_threshold=5"

var gladEpoch = time.Date(2020, 12, 31, 0, 0, 0, 0, time.UTC)

// DecodeGladDistAlertPixel decodes a GFW umd_glad_dist_alerts encoded RGBA pixel:
// days_since_2020_12_31 = R*255 + G; confidence = floor(B/100) where 2 = high, 1 = low.
func DecodeGladDistAlertPixel(r, g, b, a uint8) (time.Time, bool, bool) {
	if a == 0 || (r == 0 && g == 0) {
		return time.Time{}, false, false
	}
	days := int(r)*255 + int(g)
	if days <= 0 || days > 10000 {
		return time.Time{}, false, false
	}
	conf := int(b) / 100
	return gladEpoch.AddDate(0, 0, days), conf >= 2, true
}

type z12TileKey struct {
	X int
	Y int
}

func latLonToZ12Pixel(lat, lon float64) (tileX, tileY, px, py int) {
	const n = 4096.0
	xf := (lon + 180.0) / 360.0 * n
	latRad := lat * math.Pi / 180.0
	yf := (1.0 - math.Asinh(math.Tan(latRad))/math.Pi) / 2.0 * n
	tileX = int(math.Floor(xf))
	tileY = int(math.Floor(yf))
	px = int(math.Max(0, math.Min(255, (xf-float64(tileX))*256.0)))
	py = int(math.Max(0, math.Min(255, (yf-float64(tileY))*256.0)))
	return
}

func ScanDisturbanceTiles(
	ctx context.Context,
	app core.App,
	client *http.Client,
	tileTemplate string,
	now time.Time,
) (int, error) {
	return ScanDisturbanceTilesWithBroadcast(ctx, app, client, tileTemplate, now, nil)
}

func ScanDisturbanceTilesWithBroadcast(
	ctx context.Context,
	app core.App,
	client *http.Client,
	tileTemplate string,
	now time.Time,
	onHazard func(EnvHazardDto),
) (int, error) {
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	if strings.TrimSpace(tileTemplate) == "" {
		tileTemplate = DefaultGfwEncodedTileTemplate
	}

	corridors, err := LoadPublicTrailCorridors(app)
	if err != nil {
		return 0, err
	}
	hazardsCol, err := app.FindCollectionByNameOrId("env_hazards")
	if err != nil {
		return 0, err
	}

	tileCache := map[z12TileKey]image.Image{}
	fetchTile := func(tx, ty int) image.Image {
		key := z12TileKey{X: tx, Y: ty}
		if cached, ok := tileCache[key]; ok {
			return cached
		}
		u := strings.NewReplacer(
			"{z}", "12",
			"{x}", fmt.Sprintf("%d", tx),
			"{y}", fmt.Sprintf("%d", ty),
		).Replace(tileTemplate)
		// IMPORTANT: GFW tile server returns 405 on HEAD; always use GET.
		req, reqErr := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if reqErr != nil {
			tileCache[key] = nil
			return nil
		}
		resp, doErr := client.Do(req)
		if doErr != nil {
			tileCache[key] = nil
			return nil
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			tileCache[key] = nil
			return nil
		}
		img, _, decErr := image.Decode(resp.Body)
		if decErr != nil {
			tileCache[key] = nil
			return nil
		}
		tileCache[key] = img
		return img
	}

	minAlertDate := now.UTC().AddDate(0, 0, -120)
	createdCount := 0

	for _, tr := range corridors {
		for _, pt := range tr.Coords {
			lat, lon := pt[0], pt[1]
			tx, ty, px, py := latLonToZ12Pixel(lat, lon)
			img := fetchTile(tx, ty)
			if img == nil {
				continue
			}
			bounds := img.Bounds()
			scaleX := bounds.Dx() / 256
			if scaleX < 1 {
				scaleX = 1
			}
			highNeighbors := 0
			var latestAlert time.Time
			for dy := -1; dy <= 1; dy++ {
				for dx := -1; dx <= 1; dx++ {
					ix := bounds.Min.X + (px+dx)*scaleX
					iy := bounds.Min.Y + (py+dy)*scaleX
					if ix < bounds.Min.X || ix >= bounds.Max.X || iy < bounds.Min.Y || iy >= bounds.Max.Y {
						continue
					}
					r16, g16, b16, a16 := img.At(ix, iy).RGBA()
					dt, high, ok := DecodeGladDistAlertPixel(uint8(r16>>8), uint8(g16>>8), uint8(b16>>8), uint8(a16>>8))
					if ok && high && !dt.Before(minAlertDate) {
						highNeighbors++
						if dt.After(latestAlert) {
							latestAlert = dt
						}
					}
				}
			}
			if highNeighbors >= 2 {
				extKey := fmt.Sprintf("gfw:12/%d/%d:%d:%d", tx, ty, px/4, py/4)
				rec, findErr := app.FindFirstRecordByData("env_hazards", "external_key", extKey)
				existingTrails := []string{}
				if findErr == nil && rec != nil {
					_ = rec.UnmarshalJSONField("affected_trail_ids", &existingTrails)
				} else {
					rec = core.NewRecord(hazardsCol)
					rec.Set("external_key", extKey)
				}
				found := false
				for _, id := range existingTrails {
					if id == tr.ID {
						found = true
						break
					}
				}
				if !found {
					existingTrails = append(existingTrails, tr.ID)
				}
				detDT, _ := types.ParseDateTime(latestAlert)
				expDT, _ := types.ParseDateTime(now.UTC().Add(90 * 24 * time.Hour))
				rec.Set("source", "gfw_dist_alert")
				rec.Set("hazard_type", "forest_disturbance")
				rec.Set("severity", "warning")
				rec.Set("title", "Doborâtură de vânt / exploatare forestieră recentă pe traseu (satelit)")
				rec.Set("lat", lat)
				rec.Set("lon", lon)
				rec.Set("radius_m", 90)
				rec.Set("confidence", "high")
				rec.Set("affected_trail_ids", existingTrails)
				rec.Set("detected_at", detDT)
				rec.Set("expires_at", expDT)
				if err := app.Save(rec); err == nil {
					createdCount++
					if onHazard != nil {
						onHazard(RecordToEnvHazardDto(rec))
					}
				}
				break
			}
		}
	}
	return createdCount, nil
}
