package routes

import (
	"errors"
	"math"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"pocketbase/services/env"
	"pocketbase/util"
)

func (h *TrailLiveHandler) envService() *env.EnvironmentService {
	if h != nil && h.EnvService != nil {
		return h.EnvService
	}
	return env.DefaultEnvironmentService
}

func (h *TrailLiveHandler) streetService() *env.StreetPreviewService {
	if h != nil && h.StreetService != nil {
		return h.StreetService
	}
	return env.DefaultStreetPreviewService
}

func QueryActiveEnvHazards(
	app core.App,
	trailID string,
	lat, lon float64,
	hasCoords bool,
	radiusM float64,
	now time.Time,
) []env.EnvHazardDto {
	if _, colErr := app.FindCachedCollectionByNameOrId("env_hazards"); colErr != nil {
		return []env.EnvHazardDto{}
	}
	nowStr := toPBDateTime(now).String()
	records, err := app.FindRecordsByFilter(
		"env_hazards",
		"expires_at = '' || expires_at >= {:now}",
		"-detected_at",
		200,
		0,
		dbx.Params{"now": nowStr},
	)
	if err != nil {
		return []env.EnvHazardDto{}
	}
	if radiusM <= 0 {
		radiusM = 5000.0
	}
	trailID = strings.TrimSpace(trailID)
	out := make([]env.EnvHazardDto, 0, len(records))
	for _, rec := range records {
		dto := env.RecordToEnvHazardDto(rec)
		if trailID == "" && !hasCoords {
			out = append(out, dto)
			continue
		}
		matched := false
		if trailID != "" && slices.Contains(dto.AffectedTrailIDs, trailID) {
			matched = true
		}
		if !matched && hasCoords {
			if util.HaversineDistanceMeters(lat, lon, dto.Lat, dto.Lon) <= radiusM {
				matched = true
			}
		}
		if matched {
			out = append(out, dto)
		}
	}
	return out
}

// TrailEnvironment handles GET /live/trail/{id}/environment and /api/v1/live/trail/{id}/environment.
func (h *TrailLiveHandler) TrailEnvironment(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	trailID := strings.TrimSpace(e.Request.PathValue("id"))
	trailRec, err := e.App.FindRecordById("trails", trailID)
	if err != nil || trailRec == nil {
		return e.NotFoundError("Trail not found", nil)
	}
	lat := trailRec.GetFloat("lat")
	lon := trailRec.GetFloat("lon")
	maxEle := math.Max(400, trailRec.GetFloat("elevation_gain")+600)
	if qEle, errEle := strconv.ParseFloat(e.Request.URL.Query().Get("maxEle"), 64); errEle == nil && qEle > 0 {
		maxEle = qEle
	}

	svc := h.envService()
	weather, _ := svc.FetchMountainWeather(e.Request.Context(), lat, lon, maxEle)
	var flood *env.GorgeFloodDto
	if trailRec.GetBool("is_water_gorge") {
		flood, _ = svc.FetchGorgeFloodRisk(e.Request.Context(), lat, lon)
	}
	hazards := QueryActiveEnvHazards(e.App, trailID, 0, 0, false, 0, h.nowUTC())

	return e.JSON(http.StatusOK, map[string]any{
		"weather":    weather,
		"gorgeFlood": flood,
		"hazards":    hazards,
	})
}

// StreetPreview handles GET /live/street-preview and /api/v1/live/street-preview.
func (h *TrailLiveHandler) StreetPreview(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	lat, err1 := strconv.ParseFloat(e.Request.URL.Query().Get("lat"), 64)
	lon, err2 := strconv.ParseFloat(e.Request.URL.Query().Get("lon"), 64)
	if err1 != nil || err2 != nil || validateLatLon(&lat, &lon) != nil {
		return e.BadRequestError("Invalid lat/lon", nil)
	}
	photos, _ := h.streetService().FetchNearby(e.Request.Context(), lat, lon)
	if photos == nil {
		photos = []env.StreetPhotoDto{}
	}
	return e.JSON(http.StatusOK, map[string]any{"photos": photos})
}

// EnvHazardsSummary handles GET /live/env-hazards and /api/v1/live/env-hazards.
func (h *TrailLiveHandler) EnvHazardsSummary(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	q := e.Request.URL.Query()
	trailID := strings.TrimSpace(q.Get("trailId"))
	var lat, lon float64
	hasCoords := false
	if latRaw, lonRaw := strings.TrimSpace(q.Get("lat")), strings.TrimSpace(q.Get("lon")); latRaw != "" && lonRaw != "" {
		parsedLat, err1 := strconv.ParseFloat(latRaw, 64)
		parsedLon, err2 := strconv.ParseFloat(lonRaw, 64)
		if err1 != nil || err2 != nil || validateLatLon(&parsedLat, &parsedLon) != nil {
			return e.BadRequestError("Invalid lat/lon", nil)
		}
		lat, lon = parsedLat, parsedLon
		hasCoords = true
	}
	radiusM := 5000.0
	if rRaw := strings.TrimSpace(q.Get("radiusM")); rRaw != "" {
		if rVal, rErr := strconv.ParseFloat(rRaw, 64); rErr == nil && rVal > 0 && rVal <= 50000 {
			radiusM = rVal
		}
	}

	hazards := QueryActiveEnvHazards(e.App, trailID, lat, lon, hasCoords, radiusM, h.nowUTC())
	return e.JSON(http.StatusOK, map[string]any{
		"hazards": hazards,
		"count":   len(hazards),
	})
}

// AncpiProxyHandler exposes ANCPI orthophoto probe/status and safe WMS/XYZ tile proxy.
type AncpiProxyHandler struct {
	Service *env.AncpiService
}

func NewAncpiProxyHandler(doer util.HTTPDoer, templateURL string) *AncpiProxyHandler {
	if doer == nil && templateURL == "" {
		return &AncpiProxyHandler{Service: env.DefaultAncpiService}
	}
	return &AncpiProxyHandler{Service: env.NewAncpiService(doer, templateURL)}
}

func (a *AncpiProxyHandler) service() *env.AncpiService {
	if a != nil && a.Service != nil {
		return a.Service
	}
	return env.DefaultAncpiService
}

func (a *AncpiProxyHandler) Status(e *core.RequestEvent) error {
	avail := a.service().ProbeAvailable(e.Request.Context())
	e.Response.Header().Set("Cache-Control", "public, max-age=300")
	return e.JSON(http.StatusOK, map[string]any{
		"ancpiOrthoAvailable": avail,
	})
}

func (a *AncpiProxyHandler) ProxyTile(e *core.RequestEvent) error {
	q := e.Request.URL.Query()
	if probe := strings.ToLower(strings.TrimSpace(q.Get("probe"))); probe == "1" || probe == "true" {
		return a.Status(e)
	}

	zRaw := strings.TrimSpace(e.Request.PathValue("z"))
	xRaw := strings.TrimSpace(e.Request.PathValue("x"))
	yRaw := strings.TrimSpace(e.Request.PathValue("y"))
	if zRaw == "" {
		zRaw = strings.TrimSpace(q.Get("z"))
		xRaw = strings.TrimSpace(q.Get("x"))
		yRaw = strings.TrimSpace(q.Get("y"))
	}
	var body []byte
	var ct string
	var status int
	var err error

	if bboxRaw := strings.TrimSpace(q.Get("bbox")); bboxRaw != "" && zRaw == "" {
		parts := strings.Split(bboxRaw, ",")
		if len(parts) != 4 {
			return e.BadRequestError("Invalid bbox parameter", nil)
		}
		var coords [4]float64
		for i, p := range parts {
			v, pErr := strconv.ParseFloat(strings.TrimSpace(p), 64)
			if pErr != nil {
				return e.BadRequestError("Invalid bbox parameter", nil)
			}
			coords[i] = v
		}
		body, ct, status, err = a.service().FetchBbox(e.Request.Context(), coords[0], coords[1], coords[2], coords[3])
	} else {
		z, errZ := strconv.Atoi(zRaw)
		x, errX := strconv.Atoi(xRaw)
		y, errY := strconv.Atoi(yRaw)
		if errZ != nil || errX != nil || errY != nil {
			return e.BadRequestError("Invalid tile coordinates", nil)
		}
		body, ct, status, err = a.service().FetchTile(e.Request.Context(), z, x, y)
	}
	if err != nil {
		switch {
		case errors.Is(err, env.ErrAncpiNotConfigured):
			return e.JSON(http.StatusNotFound, map[string]any{
				"message":             "ancpi_ortho_not_configured",
				"ancpiOrthoAvailable": false,
			})
		case errors.Is(err, env.ErrAncpiInvalidTile), errors.Is(err, env.ErrAncpiInvalidURL):
			return e.BadRequestError(err.Error(), nil)
		default:
			if status < 400 {
				status = http.StatusBadGateway
			}
			return e.JSON(status, map[string]any{"message": "ancpi_upstream_error"})
		}
	}

	e.Response.Header().Set("Content-Type", ct)
	e.Response.Header().Set("Cache-Control", "public, max-age=86400")
	e.Response.Header().Set("X-Content-Type-Options", "nosniff")
	e.Response.WriteHeader(http.StatusOK)
	_, _ = e.Response.Write(body)
	return nil
}

// RegisterMapEnvRoutes mounts public /api/v1/map/ancpi-wms endpoints on se.Router.
func RegisterMapEnvRoutes(se *core.ServeEvent) {
	registerMapEnvRoutesWithAncpi(se, NewAncpiProxyHandler(nil, ""))
}

func registerMapEnvRoutesWithAncpi(se *core.ServeEvent, ancpi *AncpiProxyHandler) {
	se.Router.GET("/api/v1/map/ancpi-wms", ancpi.ProxyTile)
	se.Router.GET("/api/v1/map/ancpi-wms/status", ancpi.Status)
	se.Router.GET("/api/v1/map/ancpi-wms/{z}/{x}/{y}", ancpi.ProxyTile)
}
