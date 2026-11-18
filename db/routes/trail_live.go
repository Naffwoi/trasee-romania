package routes

import (
	"errors"
	"html"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/microcosm-cc/bluemonday"
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
	"github.com/twpayne/go-polyline"

	"pocketbase/services/live"
	"pocketbase/util"
)

const (
	presenceWindow           = 30 * time.Minute
	livePresenceWindow       = 2 * time.Minute
	presenceAreaRadiusMeters = 2000.0
	reportDedupMeters        = 40.0
	sosDefaultTTL            = 6 * time.Hour
	unsetAlongTrackVal       = -1.0
)

type reportCategoryMeta struct {
	Kind        string
	IsPermanent bool
	TTL         time.Duration
}

var reportCategories = map[string]reportCategoryMeta{
	// Temporary Waze alerts (isPermanent: false)
	"bear":                {Kind: "hazard", IsPermanent: false, TTL: 3 * time.Hour},
	"deer":                {Kind: "wildlife_good", IsPermanent: false, TTL: 3 * time.Hour},
	"shepherd_dogs":       {Kind: "hazard", IsPermanent: false, TTL: 24 * time.Hour},
	"ice_mud":             {Kind: "hazard", IsPermanent: false, TTL: 48 * time.Hour},
	"fallen_tree_terrain": {Kind: "hazard", IsPermanent: false, TTL: 14 * 24 * time.Hour},
	// Permanent landmarks (isPermanent: true, expiresAt: null)
	"spring":    {Kind: "landmark_permanent", IsPermanent: true, TTL: 0},
	"viewpoint": {Kind: "landmark_permanent", IsPermanent: true, TTL: 0},
	"shelter":   {Kind: "landmark_permanent", IsPermanent: true, TTL: 0},
}

var allowedReportVotes = map[string]bool{
	"confirm":      true,
	"dismiss":      true,
	"seasonal_ok":  true,
	"seasonal_dry": true,
	"spam":         true,
}

var allowedSosReasons = map[string]bool{
	"lost":       true,
	"injury":     true,
	"exhaustion": true,
	"other":      true,
}

var allowedSosStatuses = map[string]bool{
	"active":    true,
	"resolved":  true,
	"cancelled": true,
}

var strictTextPolicy = bluemonday.StrictPolicy()

// TrailReportDto is the exact camelCase wire representation of a trail report
// or permanent landmark.
type TrailReportDto struct {
	ID              string   `json:"id"`
	TrailID         string   `json:"trailId"`
	Category        string   `json:"category"`
	Kind            string   `json:"kind"`
	IsPermanent     bool     `json:"isPermanent"`
	ConditionStatus string   `json:"conditionStatus"`
	Note            string   `json:"note"`
	Lat             float64  `json:"lat"`
	Lon             float64  `json:"lon"`
	Ele             float64  `json:"ele"`
	AlongTrackM     *float64 `json:"alongTrackM"`
	ConfirmCount    int      `json:"confirmCount"`
	DismissCount    int      `json:"dismissCount"`
	CreatedAt       string   `json:"createdAt"`
	LastConfirmedAt string   `json:"lastConfirmedAt"`
	ExpiresAt       *string  `json:"expiresAt"`
}

// SosAlertDto is the exact camelCase wire representation of an SOS alert.
type SosAlertDto struct {
	ID               string   `json:"id"`
	ClientSosID      string   `json:"clientSosId,omitempty"`
	TrailID          string   `json:"trailId"`
	Status           string   `json:"status"`
	Reason           string   `json:"reason"`
	Message          string   `json:"message"`
	RequesterName    string   `json:"requesterName"`
	Lat              float64  `json:"lat"`
	Lon              float64  `json:"lon"`
	Ele              float64  `json:"ele"`
	ResponderCount   int      `json:"responderCount"`
	NearestEtaSec    *int     `json:"nearestEtaSec"`
	NearestDistanceM *float64 `json:"nearestDistanceM"`
	IsMine           bool     `json:"isMine"`
	AmResponding     bool     `json:"amResponding"`
	CreatedAt        string   `json:"createdAt"`
	ExpiresAt        *string  `json:"expiresAt"`
}

// PushTargetDto represents a nearby Web Push subscription returned to the
// internal SvelteKit VAPID dispatcher on POST /live/sos.
type PushTargetDto struct {
	Endpoint  string  `json:"endpoint"`
	P256dh    string  `json:"p256dh"`
	Auth      string  `json:"auth"`
	DistanceM float64 `json:"distanceM"`
}

// TrailLiveHandler groups the internal `/live/*` endpoints with an injectable
// SSE hub and clock for deterministic unit tests.
type TrailLiveHandler struct {
	Hub *live.TrailLiveHub
	Now func() time.Time
}

// NewTrailLiveHandler creates a handler backed by hub (or live.DefaultHub() if nil).
func NewTrailLiveHandler(hub *live.TrailLiveHub) *TrailLiveHandler {
	if hub == nil {
		hub = live.DefaultHub()
	}
	return &TrailLiveHandler{
		Hub: hub,
		Now: func() time.Time { return time.Now().UTC() },
	}
}

func (h *TrailLiveHandler) nowUTC() time.Time {
	if h != nil && h.Now != nil {
		return h.Now().UTC()
	}
	return time.Now().UTC()
}

func (h *TrailLiveHandler) liveHub() *live.TrailLiveHub {
	if h != nil && h.Hub != nil {
		return h.Hub
	}
	return live.DefaultHub()
}

// RegisterTrailLiveRoutes wires all `/live/*` routes on se.Router.
func RegisterTrailLiveRoutes(se *core.ServeEvent, hub *live.TrailLiveHub) {
	handler := NewTrailLiveHandler(hub)
	group := se.Router.Group("/live")
	group.BindFunc(RequireLiveInternalProxy)

	group.POST("/heartbeat", handler.Heartbeat)
	group.DELETE("/heartbeat", handler.ClearHeartbeat)
	group.GET("/trail/{id}/summary", handler.TrailSummary)
	group.POST("/reports", handler.CreateReport)
	group.POST("/reports/{id}/vote", handler.VoteReport)
	group.POST("/sos", handler.CreateSos)
	group.POST("/sos/relay", handler.RelaySos)
	group.PATCH("/sos/{id}", handler.UpdateSos)
	group.POST("/sos/{id}/respond", handler.RespondSos)
	group.POST("/push/subscribe", handler.PushSubscribe)
	group.DELETE("/push/subscribe", handler.PushUnsubscribe)
	group.POST("/groups", handler.CreateGroup)
	group.GET("/groups/{code}", handler.GetGroup)
	group.POST("/groups/{code}/join", handler.JoinGroup)
	group.POST("/groups/{code}/ping", handler.PingGroup)
	group.POST("/groups/{code}/leave", handler.LeaveGroup)
	group.GET("/stream", handler.Stream)
}

func verifyLiveInternalSecret(e *core.RequestEvent) error {
	if err := util.VerifyInternalProxySecret(e.Request); err != nil {
		if errors.Is(err, util.ErrProxySecretNotConfigured) {
			return e.UnauthorizedError("POCKETBASE_PROXY_SECRET not configured", nil)
		}
		return e.UnauthorizedError("Invalid internal secret", nil)
	}
	return nil
}

// RequireLiveInternalProxy enforces X-Internal-Secret on the /live router group.
func RequireLiveInternalProxy(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	return e.Next()
}

func readDeviceHash(r *http.Request, allowQuery bool) string {
	val := strings.TrimSpace(r.Header.Get("X-Device-Hash"))
	if val == "" && allowQuery {
		val = strings.TrimSpace(r.URL.Query().Get("deviceHash"))
	}
	return val
}

func requireDeviceHash(e *core.RequestEvent) (string, error) {
	hash := readDeviceHash(e.Request, false)
	if hash == "" {
		return "", e.BadRequestError("Missing X-Device-Hash header", nil)
	}
	return hash, nil
}

func toPBDateTime(t time.Time) types.DateTime {
	dt, _ := types.ParseDateTime(t.UTC())
	return dt
}

func validateLatLon(lat, lon *float64) error {
	if lat == nil || lon == nil {
		return errors.New("lat and lon are required")
	}
	if math.IsNaN(*lat) || math.IsInf(*lat, 0) || *lat < -90 || *lat > 90 {
		return errors.New("invalid latitude")
	}
	if math.IsNaN(*lon) || math.IsInf(*lon, 0) || *lon < -180 || *lon > 180 {
		return errors.New("invalid longitude")
	}
	return nil
}

func sanitizePlainText(raw string, maxRunes int) string {
	stripped := html.UnescapeString(strictTextPolicy.Sanitize(raw))
	// Strip any residual angle brackets after entity unescaping so plain text
	// can never smuggle markup.
	stripped = strings.ReplaceAll(stripped, "<", "")
	stripped = strings.ReplaceAll(stripped, ">", "")
	stripped = strings.TrimSpace(stripped)
	if maxRunes <= 0 {
		return stripped
	}
	runes := []rune(stripped)
	if len(runes) > maxRunes {
		return strings.TrimSpace(string(runes[:maxRunes]))
	}
	return stripped
}

func toTrailReportDto(rec *core.Record) TrailReportDto {
	createdDT := rec.GetDateTime("created")
	createdStr := ""
	if !createdDT.IsZero() {
		createdStr = createdDT.Time().UTC().Format(time.RFC3339)
	} else {
		createdStr = time.Now().UTC().Format(time.RFC3339)
	}

	lastConfDT := rec.GetDateTime("last_confirmed_at")
	lastConfStr := createdStr
	if !lastConfDT.IsZero() {
		lastConfStr = lastConfDT.Time().UTC().Format(time.RFC3339)
	}

	isPermanent := rec.GetBool("is_permanent")
	if meta, ok := reportCategories[rec.GetString("category")]; ok && meta.IsPermanent {
		isPermanent = true
	}

	var expiresAt *string
	if !isPermanent {
		expDT := rec.GetDateTime("expires_at")
		if !expDT.IsZero() {
			s := expDT.Time().UTC().Format(time.RFC3339)
			expiresAt = &s
		}
	}

	var alongTrackPtr *float64
	alongVal := rec.GetFloat("along_track_m")
	if alongVal >= 0 {
		v := alongVal
		alongTrackPtr = &v
	}

	return TrailReportDto{
		ID:              rec.Id,
		TrailID:         rec.GetString("trail_id"),
		Category:        rec.GetString("category"),
		Kind:            rec.GetString("kind"),
		IsPermanent:     isPermanent,
		ConditionStatus: rec.GetString("condition_status"),
		Note:            rec.GetString("note"),
		Lat:             rec.GetFloat("lat"),
		Lon:             rec.GetFloat("lon"),
		Ele:             rec.GetFloat("ele"),
		AlongTrackM:     alongTrackPtr,
		ConfirmCount:    rec.GetInt("confirm_count"),
		DismissCount:    rec.GetInt("dismiss_count"),
		CreatedAt:       createdStr,
		LastConfirmedAt: lastConfStr,
		ExpiresAt:       expiresAt,
	}
}

func toSosAlertDto(rec *core.Record, callerDeviceHash string, respondingDevices map[string]bool) SosAlertDto {
	createdDT := rec.GetDateTime("created")
	createdStr := ""
	if !createdDT.IsZero() {
		createdStr = createdDT.Time().UTC().Format(time.RFC3339)
	} else {
		createdStr = time.Now().UTC().Format(time.RFC3339)
	}

	var expiresAt *string
	expDT := rec.GetDateTime("expires_at")
	if !expDT.IsZero() {
		s := expDT.Time().UTC().Format(time.RFC3339)
		expiresAt = &s
	}

	responderCount := rec.GetInt("responder_count")
	var nearestEtaPtr *int
	var nearestDistPtr *float64
	if responderCount > 0 {
		eta := rec.GetInt("nearest_eta_sec")
		dist := rec.GetFloat("nearest_distance_m")
		nearestEtaPtr = &eta
		nearestDistPtr = &dist
	}

	ownerHash := rec.GetString("device_hash")
	isMine := callerDeviceHash != "" && ownerHash != "" && callerDeviceHash == ownerHash
	amResponding := callerDeviceHash != "" && respondingDevices[callerDeviceHash]

	return SosAlertDto{
		ID:               rec.Id,
		ClientSosID:      rec.GetString("client_sos_id"),
		TrailID:          rec.GetString("trail_id"),
		Status:           rec.GetString("status"),
		Reason:           rec.GetString("reason"),
		Message:          rec.GetString("message"),
		RequesterName:    rec.GetString("requester_name"),
		Lat:              rec.GetFloat("lat"),
		Lon:              rec.GetFloat("lon"),
		Ele:              rec.GetFloat("ele"),
		ResponderCount:   responderCount,
		NearestEtaSec:    nearestEtaPtr,
		NearestDistanceM: nearestDistPtr,
		IsMine:           isMine,
		AmResponding:     amResponding,
		CreatedAt:        createdStr,
		ExpiresAt:        expiresAt,
	}
}

func distanceToCoordsCorridorMeters(lat, lon float64, coords [][]float64) float64 {
	if len(coords) == 0 {
		return math.Inf(1)
	}
	if len(coords) == 1 {
		return util.HaversineDistanceMeters(lat, lon, coords[0][0], coords[0][1])
	}

	const metersPerDegLat = 111132.92
	cosLat := math.Max(0.1, math.Cos(lat*math.Pi/180.0))
	metersPerDegLon := metersPerDegLat * cosLat

	minDistSq := math.Inf(1)
	for i := 0; i < len(coords)-1; i++ {
		ax := (coords[i][1] - lon) * metersPerDegLon
		ay := (coords[i][0] - lat) * metersPerDegLat
		bx := (coords[i+1][1] - lon) * metersPerDegLon
		by := (coords[i+1][0] - lat) * metersPerDegLat

		dx := bx - ax
		dy := by - ay
		segLenSq := dx*dx + dy*dy
		var t float64
		if segLenSq > 1e-9 {
			t = -(ax*dx + ay*dy) / segLenSq
			if t < 0 {
				t = 0
			} else if t > 1 {
				t = 1
			}
		}
		px := ax + t*dx
		py := ay + t*dy
		dSq := px*px + py*py
		if dSq < minDistSq {
			minDistSq = dSq
		}
	}
	return math.Sqrt(minDistSq)
}

func resolveTrailOrRefCorridor(app core.App, trailID string, refLat, refLon float64, hasRefCoords bool) [][]float64 {
	trailID = strings.TrimSpace(trailID)
	if trailID != "" {
		if trailRec, err := app.FindRecordById("trails", trailID); err == nil && trailRec != nil {
			if poly := strings.TrimSpace(trailRec.GetString("polyline")); poly != "" {
				if coords, _, decErr := polyline.DecodeCoords([]byte(poly)); decErr == nil && len(coords) > 0 {
					return coords
				}
			}
			tLat := trailRec.GetFloat("lat")
			tLon := trailRec.GetFloat("lon")
			if tLat != 0 || tLon != 0 {
				return [][]float64{{tLat, tLon}}
			}
		}
	}
	if hasRefCoords {
		return [][]float64{{refLat, refLon}}
	}
	return nil
}

// countActiveNearbyUsers counts OTHER distinct devices (`device_hash != callerDeviceHash`)
// that currently have the app open (`last_seen >= now - 2 min`) AND have live GPS location
// inside the 2 km corridor of the target trail / reference location.
func countActiveNearbyUsers(
	app core.App,
	trailID string,
	refLat, refLon float64,
	hasRefCoords bool,
	callerDeviceHash string,
	now time.Time,
) (int, error) {
	corridor := resolveTrailOrRefCorridor(app, trailID, refLat, refLon, hasRefCoords)
	if len(corridor) == 0 {
		return 0, nil
	}

	minLat, maxLat := corridor[0][0], corridor[0][0]
	minLon, maxLon := corridor[0][1], corridor[0][1]
	for _, c := range corridor[1:] {
		if c[0] < minLat {
			minLat = c[0]
		}
		if c[0] > maxLat {
			maxLat = c[0]
		}
		if c[1] < minLon {
			minLon = c[1]
		}
		if c[1] > maxLon {
			maxLon = c[1]
		}
	}
	// ~2 km margin with generous latitude/longitude buffer for fast SQL pre-filtering
	const latPad = 0.03
	const lonPad = 0.05

	cutoff := toPBDateTime(now.Add(-livePresenceWindow)).String()
	records, err := app.FindRecordsByFilter(
		"trail_presence",
		"last_seen >= {:cutoff} && lat >= {:minLat} && lat <= {:maxLat} && lon >= {:minLon} && lon <= {:maxLon}",
		"",
		500,
		0,
		dbx.Params{
			"cutoff": cutoff,
			"minLat": minLat - latPad,
			"maxLat": maxLat + latPad,
			"minLon": minLon - lonPad,
			"maxLon": maxLon + lonPad,
		},
	)
	if err != nil {
		return 0, err
	}

	seenDevices := make(map[string]bool)
	for _, rec := range records {
		dh := strings.TrimSpace(rec.GetString("device_hash"))
		if dh == "" || (callerDeviceHash != "" && dh == callerDeviceHash) || seenDevices[dh] {
			continue
		}
		pLat := rec.GetFloat("lat")
		pLon := rec.GetFloat("lon")
		if distanceToCoordsCorridorMeters(pLat, pLon, corridor) <= presenceAreaRadiusMeters {
			seenDevices[dh] = true
		}
	}

	return len(seenDevices), nil
}

func isReportVisibleAt(rec *core.Record, now time.Time) bool {
	status := rec.GetString("condition_status")
	if status != "active" && status != "dry_or_closed" {
		return false
	}
	if rec.GetBool("is_permanent") {
		return true
	}
	if meta, ok := reportCategories[rec.GetString("category")]; ok && meta.IsPermanent {
		return true
	}
	expDT := rec.GetDateTime("expires_at")
	if expDT.IsZero() {
		return true
	}
	return !expDT.Time().Before(now)
}

func loadActiveRespondersMap(app core.App, sosID string, now time.Time) (map[string]bool, error) {
	cutoff := toPBDateTime(now.Add(-presenceWindow)).String()
	responders, err := app.FindRecordsByFilter(
		"sos_responders",
		"sos_id = {:sosId} && status = 'coming' && last_seen >= {:cutoff}",
		"",
		0,
		0,
		dbx.Params{"sosId": sosID, "cutoff": cutoff},
	)
	if err != nil {
		return map[string]bool{}, err
	}
	out := make(map[string]bool, len(responders))
	for _, r := range responders {
		if dh := r.GetString("device_hash"); dh != "" {
			out[dh] = true
		}
	}
	return out, nil
}

func queryVisibleReports(app core.App, trailID string, lat, lon float64, hasCoords bool, now time.Time) ([]TrailReportDto, error) {
	records, err := app.FindRecordsByFilter(
		"trail_reports",
		"condition_status = 'active' || condition_status = 'dry_or_closed'",
		"-created",
		500,
		0,
		nil,
	)
	if err != nil {
		return nil, err
	}

	dtos := make([]TrailReportDto, 0)
	for _, rec := range records {
		if !isReportVisibleAt(rec, now) {
			continue
		}
		recTrail := rec.GetString("trail_id")
		matched := false
		if trailID != "" && recTrail == trailID {
			matched = true
		} else if hasCoords {
			if util.HaversineDistanceMeters(lat, lon, rec.GetFloat("lat"), rec.GetFloat("lon")) <= live.LiveRadiusMeters {
				matched = true
			}
		}
		if matched {
			dtos = append(dtos, toTrailReportDto(rec))
		}
	}
	return dtos, nil
}

func queryActiveSosAlerts(app core.App, trailID string, lat, lon float64, hasCoords bool, callerDeviceHash string, now time.Time) ([]SosAlertDto, error) {
	nowStr := toPBDateTime(now).String()
	records, err := app.FindRecordsByFilter(
		"sos_alerts",
		"status = 'active' && (expires_at = '' || expires_at >= {:now})",
		"-created",
		100,
		0,
		dbx.Params{"now": nowStr},
	)
	if err != nil {
		return nil, err
	}

	dtos := make([]SosAlertDto, 0)
	for _, rec := range records {
		recTrail := rec.GetString("trail_id")
		isOwner := callerDeviceHash != "" && rec.GetString("device_hash") == callerDeviceHash
		matched := isOwner
		if !matched && trailID != "" && recTrail == trailID {
			matched = true
		}
		if !matched && hasCoords {
			if util.HaversineDistanceMeters(lat, lon, rec.GetFloat("lat"), rec.GetFloat("lon")) <= live.LiveRadiusMeters {
				matched = true
			}
		}
		respMap, _ := loadActiveRespondersMap(app, rec.Id, now)
		if !matched && callerDeviceHash != "" && respMap[callerDeviceHash] {
			matched = true
		}
		if matched {
			dtos = append(dtos, toSosAlertDto(rec, callerDeviceHash, respMap))
		}
	}
	return dtos, nil
}

type heartbeatRequest struct {
	TrailID      string   `json:"trailId"`
	Lat          *float64 `json:"lat"`
	Lon          *float64 `json:"lon"`
	Ele          *float64 `json:"ele"`
	InNavigation *bool    `json:"inNavigation"`
}

// Heartbeat handles POST /live/heartbeat.
// Upserts trail_presence (never exposing raw presence coordinates), updates any
// push_subscriptions for this deviceHash, and returns { activeHikers30m, reports, sosAlerts }.
func (h *TrailLiveHandler) Heartbeat(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	var req heartbeatRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}
	if err := validateLatLon(req.Lat, req.Lon); err != nil {
		return e.BadRequestError(err.Error(), nil)
	}

	now := h.nowUTC()
	nowDT := toPBDateTime(now)
	trailID := strings.TrimSpace(req.TrailID)
	ele := 0.0
	if req.Ele != nil && !math.IsNaN(*req.Ele) && !math.IsInf(*req.Ele, 0) {
		ele = *req.Ele
	}
	inNav := false
	if req.InNavigation != nil {
		inNav = *req.InNavigation
	}

	presenceCol, err := e.App.FindCachedCollectionByNameOrId("trail_presence")
	if err != nil {
		return err
	}

	presenceRec, err := e.App.FindFirstRecordByData("trail_presence", "device_hash", deviceHash)
	if err != nil || presenceRec == nil {
		presenceRec = core.NewRecord(presenceCol)
		presenceRec.Set("device_hash", deviceHash)
	}
	presenceRec.Set("trail_id", trailID)
	presenceRec.Set("lat", *req.Lat)
	presenceRec.Set("lon", *req.Lon)
	presenceRec.Set("ele", ele)
	presenceRec.Set("in_navigation", inNav)
	presenceRec.Set("last_seen", nowDT)

	if err := e.App.Save(presenceRec); err != nil {
		return err
	}

	// Keep push_subscriptions location/trail fresh for 5 km SOS fan-out.
	if subs, subErr := e.App.FindRecordsByFilter(
		"push_subscriptions",
		"device_hash = {:deviceHash}",
		"",
		50,
		0,
		dbx.Params{"deviceHash": deviceHash},
	); subErr == nil {
		for _, sub := range subs {
			sub.Set("lat", *req.Lat)
			sub.Set("lon", *req.Lon)
			sub.Set("trail_id", trailID)
			_ = e.App.Save(sub)
		}
	}

	activeHikers, err := countActiveNearbyUsers(e.App, trailID, *req.Lat, *req.Lon, true, deviceHash, now)
	if err != nil {
		return err
	}

	reports, err := queryVisibleReports(e.App, trailID, *req.Lat, *req.Lon, true, now)
	if err != nil {
		return err
	}

	sosAlerts, err := queryActiveSosAlerts(e.App, trailID, *req.Lat, *req.Lon, true, deviceHash, now)
	if err != nil {
		return err
	}

	return e.JSON(http.StatusOK, map[string]any{
		"activeHikers30m": activeHikers,
		"reports":         reports,
		"sosAlerts":       sosAlerts,
	})
}

// ClearHeartbeat handles DELETE /live/heartbeat when a client closes or backgrounds
// the app so its active presence disappears immediately.
func (h *TrailLiveHandler) ClearHeartbeat(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}
	if rec, findErr := e.App.FindFirstRecordByData("trail_presence", "device_hash", deviceHash); findErr == nil && rec != nil {
		_ = e.App.Delete(rec)
	}
	return e.JSON(http.StatusOK, map[string]any{"ok": true})
}

// TrailSummary handles GET /live/trail/{id}/summary.
func (h *TrailLiveHandler) TrailSummary(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	trailID := strings.TrimSpace(e.Request.PathValue("id"))
	if trailID == "" {
		return e.BadRequestError("Missing trail id", nil)
	}
	callerDeviceHash := readDeviceHash(e.Request, false)
	now := h.nowUTC()

	var refLat, refLon float64
	hasRefCoords := false
	q := e.Request.URL.Query()
	latRaw := strings.TrimSpace(q.Get("lat"))
	lonRaw := strings.TrimSpace(q.Get("lon"))
	if latRaw != "" && lonRaw != "" {
		parsedLat, errLat := strconv.ParseFloat(latRaw, 64)
		parsedLon, errLon := strconv.ParseFloat(lonRaw, 64)
		if errLat == nil && errLon == nil && validateLatLon(&parsedLat, &parsedLon) == nil {
			refLat = parsedLat
			refLon = parsedLon
			hasRefCoords = true
		}
	}

	activeHikers, err := countActiveNearbyUsers(e.App, trailID, refLat, refLon, hasRefCoords, callerDeviceHash, now)
	if err != nil {
		return err
	}

	reports, err := queryVisibleReports(e.App, trailID, refLat, refLon, hasRefCoords, now)
	if err != nil {
		return err
	}

	sosAlerts, err := queryActiveSosAlerts(e.App, trailID, refLat, refLon, hasRefCoords, callerDeviceHash, now)
	if err != nil {
		return err
	}

	return e.JSON(http.StatusOK, map[string]any{
		"trailId":         trailID,
		"activeHikers30m": activeHikers,
		"reports":         reports,
		"sosAlerts":       sosAlerts,
	})
}

type createReportRequest struct {
	TrailID     string   `json:"trailId"`
	Category    string   `json:"category"`
	Note        string   `json:"note"`
	Lat         *float64 `json:"lat"`
	Lon         *float64 `json:"lon"`
	Ele         *float64 `json:"ele"`
	AlongTrackM *float64 `json:"alongTrackM"`
}

// CreateReport handles POST /live/reports.
// Deduplicates active/dry_or_closed reports of the same category within 40 m as
// a `confirm` vote; otherwise creates a new temporary or permanent report.
func (h *TrailLiveHandler) CreateReport(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}
	actorID := strings.TrimSpace(e.Request.Header.Get("X-Actor-Id"))

	var req createReportRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}

	category := strings.TrimSpace(req.Category)
	meta, ok := reportCategories[category]
	if !ok {
		return e.BadRequestError("Invalid report category", nil)
	}
	if err := validateLatLon(req.Lat, req.Lon); err != nil {
		return e.BadRequestError(err.Error(), nil)
	}

	now := h.nowUTC()
	cleanNote := sanitizePlainText(req.Note, 160)
	trailID := strings.TrimSpace(req.TrailID)

	// Deduplicate within 40 m if an active/dry_or_closed report of the same category exists.
	candidates, err := e.App.FindRecordsByFilter(
		"trail_reports",
		"category = {:category} && (condition_status = 'active' || condition_status = 'dry_or_closed')",
		"-created",
		200,
		0,
		dbx.Params{"category": category},
	)
	if err == nil {
		var closest *core.Record
		closestDist := reportDedupMeters + 1.0
		for _, cand := range candidates {
			if !isReportVisibleAt(cand, now) {
				continue
			}
			d := util.HaversineDistanceMeters(*req.Lat, *req.Lon, cand.GetFloat("lat"), cand.GetFloat("lon"))
			if d <= reportDedupMeters && d < closestDist {
				closest = cand
				closestDist = d
			}
		}
		if closest != nil {
			if closest.GetString("note") == "" && cleanNote != "" {
				closest.Set("note", cleanNote)
			}
			dto, voteErr := h.applyReportVote(e.App, closest, deviceHash, "confirm", now)
			if voteErr != nil {
				return voteErr
			}
			return e.JSON(http.StatusOK, map[string]any{"report": dto})
		}
	}

	reportsCol, err := e.App.FindCachedCollectionByNameOrId("trail_reports")
	if err != nil {
		return err
	}
	votesCol, err := e.App.FindCachedCollectionByNameOrId("trail_report_votes")
	if err != nil {
		return err
	}

	ele := 0.0
	if req.Ele != nil && !math.IsNaN(*req.Ele) && !math.IsInf(*req.Ele, 0) {
		ele = *req.Ele
	}
	alongTrack := unsetAlongTrackVal
	if req.AlongTrackM != nil && !math.IsNaN(*req.AlongTrackM) && !math.IsInf(*req.AlongTrackM, 0) && *req.AlongTrackM >= 0 {
		alongTrack = *req.AlongTrackM
	}

	nowDT := toPBDateTime(now)
	rec := core.NewRecord(reportsCol)
	rec.Set("trail_id", trailID)
	rec.Set("category", category)
	rec.Set("kind", meta.Kind)
	rec.Set("is_permanent", meta.IsPermanent)
	rec.Set("condition_status", "active")
	rec.Set("note", cleanNote)
	rec.Set("lat", *req.Lat)
	rec.Set("lon", *req.Lon)
	rec.Set("ele", ele)
	rec.Set("along_track_m", alongTrack)
	rec.Set("device_hash", deviceHash)
	rec.Set("author_actor", actorID)
	rec.Set("confirm_count", 1)
	rec.Set("dismiss_count", 0)
	rec.Set("spam_count", 0)
	rec.Set("last_confirmed_at", nowDT)
	if meta.IsPermanent {
		rec.Set("expires_at", "")
	} else {
		rec.Set("expires_at", toPBDateTime(now.Add(meta.TTL)))
	}

	if err := e.App.Save(rec); err != nil {
		return err
	}

	// Record the author's initial confirmation vote so subsequent votes recompute
	// totals accurately.
	voteRec := core.NewRecord(votesCol)
	voteRec.Set("report_id", rec.Id)
	voteRec.Set("device_hash", deviceHash)
	voteRec.Set("vote", "confirm")
	_ = e.App.Save(voteRec)

	dto := toTrailReportDto(rec)
	h.liveHub().BroadcastReportUpdate(live.GeoTarget{
		TrailID:   dto.TrailID,
		Lat:       dto.Lat,
		Lon:       dto.Lon,
		HasCoords: true,
	}, dto)

	return e.JSON(http.StatusOK, map[string]any{"report": dto})
}

type voteReportRequest struct {
	Vote string `json:"vote"`
}

// VoteReport handles POST /live/reports/{id}/vote.
func (h *TrailLiveHandler) VoteReport(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	reportID := strings.TrimSpace(e.Request.PathValue("id"))
	if reportID == "" {
		return e.BadRequestError("Missing report id", nil)
	}

	var req voteReportRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}
	vote := strings.TrimSpace(req.Vote)
	if !allowedReportVotes[vote] {
		return e.BadRequestError("Invalid vote type", nil)
	}

	reportRec, err := e.App.FindRecordById("trail_reports", reportID)
	if err != nil || reportRec == nil {
		return e.NotFoundError("Report not found", nil)
	}

	dto, err := h.applyReportVote(e.App, reportRec, deviceHash, vote, h.nowUTC())
	if err != nil {
		return err
	}

	return e.JSON(http.StatusOK, map[string]any{"report": dto})
}

func (h *TrailLiveHandler) applyReportVote(app core.App, reportRec *core.Record, deviceHash, vote string, now time.Time) (TrailReportDto, error) {
	votesCol, err := app.FindCachedCollectionByNameOrId("trail_report_votes")
	if err != nil {
		return TrailReportDto{}, err
	}

	existingVote, err := app.FindFirstRecordByFilter(
		"trail_report_votes",
		"report_id = {:reportId} && device_hash = {:deviceHash}",
		dbx.Params{"reportId": reportRec.Id, "deviceHash": deviceHash},
	)
	if err != nil || existingVote == nil {
		existingVote = core.NewRecord(votesCol)
		existingVote.Set("report_id", reportRec.Id)
		existingVote.Set("device_hash", deviceHash)
	}
	existingVote.Set("vote", vote)
	if err := app.Save(existingVote); err != nil {
		return TrailReportDto{}, err
	}

	allVotes, err := app.FindRecordsByFilter(
		"trail_report_votes",
		"report_id = {:reportId}",
		"",
		0,
		0,
		dbx.Params{"reportId": reportRec.Id},
	)
	if err != nil {
		return TrailReportDto{}, err
	}

	confirmCount := 0
	dismissCount := 0
	spamCount := 0
	for _, v := range allVotes {
		switch v.GetString("vote") {
		case "confirm", "seasonal_ok":
			confirmCount++
		case "dismiss":
			dismissCount++
		case "spam":
			spamCount++
		}
	}

	reportRec.Set("confirm_count", confirmCount)
	reportRec.Set("dismiss_count", dismissCount)
	reportRec.Set("spam_count", spamCount)

	category := reportRec.GetString("category")
	meta := reportCategories[category]
	isPermanent := reportRec.GetBool("is_permanent") || meta.IsPermanent
	nowDT := toPBDateTime(now)
	curStatus := reportRec.GetString("condition_status")

	switch vote {
	case "confirm":
		reportRec.Set("last_confirmed_at", nowDT)
		if isPermanent {
			reportRec.Set("expires_at", "")
		} else if meta.TTL > 0 {
			candidateExp := now.Add(meta.TTL)
			curExpDT := reportRec.GetDateTime("expires_at")
			if curExpDT.IsZero() || curExpDT.Time().Before(candidateExp) {
				reportRec.Set("expires_at", toPBDateTime(candidateExp))
			}
		}
	case "dismiss":
		if !isPermanent && curStatus != "spam_hidden" {
			if dismissCount >= 3 || dismissCount-confirmCount >= 2 {
				reportRec.Set("condition_status", "resolved")
			}
		}
	case "seasonal_dry":
		if isPermanent && curStatus != "spam_hidden" {
			reportRec.Set("condition_status", "dry_or_closed")
			reportRec.Set("last_confirmed_at", nowDT)
			reportRec.Set("expires_at", "")
		}
	case "seasonal_ok":
		if isPermanent && curStatus != "spam_hidden" {
			reportRec.Set("condition_status", "active")
			reportRec.Set("last_confirmed_at", nowDT)
			reportRec.Set("expires_at", "")
		}
	case "spam":
		if spamCount >= 5 {
			reportRec.Set("condition_status", "spam_hidden")
		}
	}

	// Re-check spam threshold regardless of last vote in case counts crossed >= 5.
	if spamCount >= 5 {
		reportRec.Set("condition_status", "spam_hidden")
	}

	if err := app.Save(reportRec); err != nil {
		return TrailReportDto{}, err
	}

	dto := toTrailReportDto(reportRec)
	h.liveHub().BroadcastReportUpdate(live.GeoTarget{
		TrailID:   dto.TrailID,
		Lat:       dto.Lat,
		Lon:       dto.Lon,
		HasCoords: true,
	}, dto)

	return dto, nil
}

type createSosRequest struct {
	ClientSosID    string   `json:"clientSosId"`
	SosClaimSecret string   `json:"sosClaimSecret"`
	TrailID        string   `json:"trailId"`
	Reason         string   `json:"reason"`
	Message        string   `json:"message"`
	RequesterName  string   `json:"requesterName"`
	Lat            *float64 `json:"lat"`
	Lon            *float64 `json:"lon"`
	Ele            *float64 `json:"ele"`
}

// CreateSos handles POST /live/sos.
// Creates an active SOS alert (expires_at = now + 6h), or seamlessly claims ownership
// of an already-relayed offline BLE SOS when valid `clientSosId` + `sosClaimSecret`
// are provided. Selects Web Push targets within 5,000 m Haversine OR matching trailId,
// broadcasts sos_update on SSE, and returns { sos, pushTargets }.
func (h *TrailLiveHandler) CreateSos(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	var req createSosRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}
	if err := validateLatLon(req.Lat, req.Lon); err != nil {
		return e.BadRequestError(err.Error(), nil)
	}

	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "other"
	}
	if !allowedSosReasons[reason] {
		return e.BadRequestError("Invalid SOS reason", nil)
	}

	var clientSosID, expectedClaimHash string
	hasClientSos := strings.TrimSpace(req.ClientSosID) != "" || strings.TrimSpace(req.SosClaimSecret) != ""
	if hasClientSos {
		cid, okCid := normalizeLowerHexFixed(req.ClientSosID, 16)
		if !okCid {
			return e.BadRequestError("Invalid clientSosId", nil)
		}
		claimHash, okSecret := computeSosClaimHashFromSecret(req.SosClaimSecret)
		if !okSecret {
			return e.BadRequestError("Invalid sosClaimSecret", nil)
		}
		clientSosID = cid
		expectedClaimHash = claimHash
	}

	ele := 0.0
	if req.Ele != nil && !math.IsNaN(*req.Ele) && !math.IsInf(*req.Ele, 0) {
		ele = *req.Ele
	}

	now := h.nowUTC()
	trailID := strings.TrimSpace(req.TrailID)
	cleanMessage := sanitizePlainText(req.Message, 200)
	cleanRequester := sanitizePlainText(req.RequesterName, 40)

	sosCol, err := e.App.FindCachedCollectionByNameOrId("sos_alerts")
	if err != nil {
		return err
	}

	if hasClientSos {
		var sosRec *core.Record
		var respondingDevices map[string]bool
		claimedExisting := false

		txErr := e.App.RunInTransaction(func(txApp core.App) error {
			existing, findErr := txApp.FindFirstRecordByFilter(
				"sos_alerts",
				"client_sos_id = {:cid}",
				dbx.Params{"cid": clientSosID},
			)
			if findErr == nil && existing != nil {
				if !verifySosClaimHashConstantTime(expectedClaimHash, existing.GetString("sos_claim_hash")) {
					return errSosRelayForbidden
				}
				existing.Set("device_hash", deviceHash)
				existing.Set("lat", *req.Lat)
				existing.Set("lon", *req.Lon)
				existing.Set("ele", ele)
				existing.Set("origin_lat", *req.Lat)
				existing.Set("origin_lon", *req.Lon)
				existing.Set("last_packet_epoch", now.Unix())
				if trailID != "" {
					existing.Set("trail_id", trailID)
				}
				if cleanMessage != "" {
					existing.Set("message", cleanMessage)
				}
				if cleanRequester != "" {
					existing.Set("requester_name", cleanRequester)
				}
				if existing.GetString("status") == "active" {
					existing.Set("expires_at", toPBDateTime(now.Add(sosDefaultTTL)))
				}

				var statsErr error
				respondingDevices, statsErr = recomputeSosResponderStats(txApp, existing, now)
				if statsErr != nil {
					return statsErr
				}
				if saveErr := txApp.Save(existing); saveErr != nil {
					return saveErr
				}
				sosRec = existing
				claimedExisting = true
				return nil
			}

			rec := core.NewRecord(sosCol)
			rec.Set("trail_id", trailID)
			rec.Set("status", "active")
			rec.Set("reason", reason)
			rec.Set("message", cleanMessage)
			rec.Set("requester_name", cleanRequester)
			rec.Set("lat", *req.Lat)
			rec.Set("lon", *req.Lon)
			rec.Set("ele", ele)
			rec.Set("origin_lat", *req.Lat)
			rec.Set("origin_lon", *req.Lon)
			rec.Set("device_hash", deviceHash)
			rec.Set("client_sos_id", clientSosID)
			rec.Set("sos_claim_hash", expectedClaimHash)
			rec.Set("last_packet_epoch", now.Unix())
			rec.Set("responder_count", 0)
			rec.Set("nearest_distance_m", 0)
			rec.Set("nearest_eta_sec", 0)
			rec.Set("expires_at", toPBDateTime(now.Add(sosDefaultTTL)))

			if saveErr := txApp.Save(rec); saveErr != nil {
				return saveErr
			}
			sosRec = rec
			respondingDevices = map[string]bool{}
			return nil
		})
		if txErr != nil {
			if errors.Is(txErr, errSosRelayForbidden) {
				return e.ForbiddenError("Invalid sosClaimSecret for existing SOS alert", nil)
			}
			return txErr
		}

		pushTargets := []PushTargetDto{}
		if !claimedExisting {
			pts, ptErr := selectSosPushTargets(e.App, deviceHash, trailID, *req.Lat, *req.Lon, now)
			if ptErr != nil {
				return ptErr
			}
			if len(pts) > 0 {
				pushTargets = pts
			}
		}

		h.broadcastSosRecord(sosRec, respondingDevices)
		dto := toSosAlertDto(sosRec, deviceHash, respondingDevices)
		return e.JSON(http.StatusOK, map[string]any{
			"sos":         dto,
			"pushTargets": pushTargets,
		})
	}

	sosRec := core.NewRecord(sosCol)
	sosRec.Set("trail_id", trailID)
	sosRec.Set("status", "active")
	sosRec.Set("reason", reason)
	sosRec.Set("message", cleanMessage)
	sosRec.Set("requester_name", cleanRequester)
	sosRec.Set("lat", *req.Lat)
	sosRec.Set("lon", *req.Lon)
	sosRec.Set("ele", ele)
	sosRec.Set("origin_lat", *req.Lat)
	sosRec.Set("origin_lon", *req.Lon)
	sosRec.Set("device_hash", deviceHash)
	sosRec.Set("responder_count", 0)
	sosRec.Set("nearest_distance_m", 0)
	sosRec.Set("nearest_eta_sec", 0)
	sosRec.Set("expires_at", toPBDateTime(now.Add(sosDefaultTTL)))

	if err := e.App.Save(sosRec); err != nil {
		return err
	}

	pushTargets, err := selectSosPushTargets(e.App, deviceHash, trailID, *req.Lat, *req.Lon, now)
	if err != nil {
		return err
	}

	respondingDevices := map[string]bool{}
	h.broadcastSosRecord(sosRec, respondingDevices)

	dto := toSosAlertDto(sosRec, deviceHash, respondingDevices)
	return e.JSON(http.StatusOK, map[string]any{
		"sos":         dto,
		"pushTargets": pushTargets,
	})
}

func selectSosPushTargets(app core.App, callerDeviceHash, sosTrailID string, sosLat, sosLon float64, now time.Time) ([]PushTargetDto, error) {
	cutoff := toPBDateTime(now.Add(-presenceWindow)).String()
	presenceRecords, _ := app.FindRecordsByFilter(
		"trail_presence",
		"last_seen >= {:cutoff}",
		"",
		0,
		0,
		dbx.Params{"cutoff": cutoff},
	)
	presenceByDevice := make(map[string]*core.Record, len(presenceRecords))
	for _, p := range presenceRecords {
		if dh := p.GetString("device_hash"); dh != "" && dh != callerDeviceHash {
			presenceByDevice[dh] = p
		}
	}

	subs, err := app.FindRecordsByFilter(
		"push_subscriptions",
		"device_hash != {:callerHash}",
		"",
		0,
		0,
		dbx.Params{"callerHash": callerDeviceHash},
	)
	if err != nil {
		return []PushTargetDto{}, nil
	}

	targets := make([]PushTargetDto, 0)
	seenEndpoints := make(map[string]bool)

	for _, sub := range subs {
		endpoint := strings.TrimSpace(sub.GetString("endpoint"))
		p256dh := strings.TrimSpace(sub.GetString("p256dh"))
		auth := strings.TrimSpace(sub.GetString("auth"))
		subDevice := sub.GetString("device_hash")

		if endpoint == "" || p256dh == "" || auth == "" || subDevice == callerDeviceHash || seenEndpoints[endpoint] {
			continue
		}

		matched := false
		bestDist := math.Inf(1)

		if pres, ok := presenceByDevice[subDevice]; ok {
			d := util.HaversineDistanceMeters(sosLat, sosLon, pres.GetFloat("lat"), pres.GetFloat("lon"))
			bestDist = d
			if d <= live.LiveRadiusMeters || (sosTrailID != "" && pres.GetString("trail_id") == sosTrailID) {
				matched = true
			}
		}

		subLat := sub.GetFloat("lat")
		subLon := sub.GetFloat("lon")
		if subLat != 0 || subLon != 0 {
			d := util.HaversineDistanceMeters(sosLat, sosLon, subLat, subLon)
			if math.IsInf(bestDist, 1) {
				bestDist = d
			}
			if d <= live.LiveRadiusMeters {
				matched = true
			}
		}

		if sosTrailID != "" && sub.GetString("trail_id") == sosTrailID {
			matched = true
		}

		if matched {
			seenEndpoints[endpoint] = true
			if math.IsInf(bestDist, 1) {
				bestDist = 0
			}
			targets = append(targets, PushTargetDto{
				Endpoint:  endpoint,
				P256dh:    p256dh,
				Auth:      auth,
				DistanceM: math.Round(bestDist),
			})
		}
	}

	return targets, nil
}

type updateSosRequest struct {
	Status         *string  `json:"status"`
	Lat            *float64 `json:"lat"`
	Lon            *float64 `json:"lon"`
	Ele            *float64 `json:"ele"`
	SosClaimSecret string   `json:"sosClaimSecret"`
}

// UpdateSos handles PATCH /live/sos/{id}.
// Verifies caller ownership (`sos.device_hash == X-Device-Hash` OR valid Lamport
// `sosClaimSecret` preimage), updates status and/or GPS coordinates, broadcasts
// sos_update, and returns { sos }.
func (h *TrailLiveHandler) UpdateSos(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	sosID := strings.TrimSpace(e.Request.PathValue("id"))
	if sosID == "" {
		return e.BadRequestError("Missing SOS id", nil)
	}

	sosRec, err := e.App.FindRecordById("sos_alerts", sosID)
	if (err != nil || sosRec == nil) && len(sosID) == 16 {
		if normCid, ok := normalizeLowerHexFixed(sosID, 16); ok {
			sosRec, err = e.App.FindFirstRecordByFilter(
				"sos_alerts",
				"client_sos_id = {:cid}",
				dbx.Params{"cid": normCid},
			)
		}
	}
	if err != nil || sosRec == nil {
		return e.NotFoundError("SOS alert not found", nil)
	}

	var req updateSosRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}

	ownerHash := sosRec.GetString("device_hash")
	authorizedByDevice := ownerHash != "" && ownerHash == deviceHash
	authorizedBySecret := false
	if strings.TrimSpace(req.SosClaimSecret) != "" {
		if computedHash, ok := computeSosClaimHashFromSecret(req.SosClaimSecret); ok &&
			verifySosClaimHashConstantTime(computedHash, sosRec.GetString("sos_claim_hash")) {
			authorizedBySecret = true
		}
	}
	if !authorizedByDevice && !authorizedBySecret {
		return e.ForbiddenError("Only the SOS requester may update this alert", nil)
	}
	if authorizedBySecret && ownerHash == "" {
		sosRec.Set("device_hash", deviceHash)
	}

	now := h.nowUTC()

	if req.Status != nil {
		st := strings.TrimSpace(*req.Status)
		if !allowedSosStatuses[st] {
			return e.BadRequestError("Invalid SOS status", nil)
		}
		sosRec.Set("status", st)
	}
	if req.Lat != nil {
		if math.IsNaN(*req.Lat) || math.IsInf(*req.Lat, 0) || *req.Lat < -90 || *req.Lat > 90 {
			return e.BadRequestError("invalid latitude", nil)
		}
		sosRec.Set("lat", *req.Lat)
		sosRec.Set("origin_lat", *req.Lat)
		sosRec.Set("last_packet_epoch", now.Unix())
	}
	if req.Lon != nil {
		if math.IsNaN(*req.Lon) || math.IsInf(*req.Lon, 0) || *req.Lon < -180 || *req.Lon > 180 {
			return e.BadRequestError("invalid longitude", nil)
		}
		sosRec.Set("lon", *req.Lon)
		sosRec.Set("origin_lon", *req.Lon)
		sosRec.Set("last_packet_epoch", now.Unix())
	}
	if req.Ele != nil && !math.IsNaN(*req.Ele) && !math.IsInf(*req.Ele, 0) {
		sosRec.Set("ele", *req.Ele)
	}

	respondingDevices, err := recomputeSosResponderStats(e.App, sosRec, now)
	if err != nil {
		return err
	}

	if err := e.App.Save(sosRec); err != nil {
		return err
	}

	h.broadcastSosRecord(sosRec, respondingDevices)
	dto := toSosAlertDto(sosRec, deviceHash, respondingDevices)
	return e.JSON(http.StatusOK, map[string]any{"sos": dto})
}

type respondSosRequest struct {
	Status    string   `json:"status"`
	Lat       *float64 `json:"lat"`
	Lon       *float64 `json:"lon"`
	Ele       *float64 `json:"ele"`
	DistanceM *float64 `json:"distanceM"`
	EtaSec    *int     `json:"etaSec"`
}

// RespondSos handles POST /live/sos/{id}/respond.
// Upserts sos_responders, recomputes responder_count, nearest_distance_m, and
// nearest_eta_sec on sos_alerts, broadcasts sos_update, and returns { sos }.
func (h *TrailLiveHandler) RespondSos(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	sosID := strings.TrimSpace(e.Request.PathValue("id"))
	if sosID == "" {
		return e.BadRequestError("Missing SOS id", nil)
	}

	sosRec, err := e.App.FindRecordById("sos_alerts", sosID)
	if (err != nil || sosRec == nil) && len(sosID) == 16 {
		if normCid, ok := normalizeLowerHexFixed(sosID, 16); ok {
			sosRec, err = e.App.FindFirstRecordByFilter(
				"sos_alerts",
				"client_sos_id = {:cid}",
				dbx.Params{"cid": normCid},
			)
		}
	}
	if err != nil || sosRec == nil {
		return e.NotFoundError("SOS alert not found", nil)
	}

	var req respondSosRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}

	status := strings.TrimSpace(req.Status)
	if status != "coming" && status != "cancelled" {
		return e.BadRequestError("Invalid responder status", nil)
	}

	lat, lon := 0.0, 0.0
	if status == "coming" || (req.Lat != nil && req.Lon != nil) {
		if err := validateLatLon(req.Lat, req.Lon); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		lat = *req.Lat
		lon = *req.Lon
	}

	ele := 0.0
	if req.Ele != nil && !math.IsNaN(*req.Ele) && !math.IsInf(*req.Ele, 0) {
		ele = *req.Ele
	}

	distM := 0.0
	if req.DistanceM != nil && !math.IsNaN(*req.DistanceM) && !math.IsInf(*req.DistanceM, 0) && *req.DistanceM > 0 {
		distM = *req.DistanceM
	} else if status == "coming" {
		distM = util.HaversineDistanceMeters(lat, lon, sosRec.GetFloat("lat"), sosRec.GetFloat("lon"))
	}

	etaSec := 0
	if req.EtaSec != nil && *req.EtaSec > 0 {
		etaSec = *req.EtaSec
	} else if status == "coming" {
		climb := math.Max(0, sosRec.GetFloat("ele")-ele)
		etaSec = int(math.Max(1, math.Round(distM/1.1+climb*6.0)))
	}

	respCol, err := e.App.FindCachedCollectionByNameOrId("sos_responders")
	if err != nil {
		return err
	}

	respRec, err := e.App.FindFirstRecordByFilter(
		"sos_responders",
		"sos_id = {:sosId} && device_hash = {:deviceHash}",
		dbx.Params{"sosId": sosRec.Id, "deviceHash": deviceHash},
	)
	if err != nil || respRec == nil {
		respRec = core.NewRecord(respCol)
		respRec.Set("sos_id", sosRec.Id)
		respRec.Set("device_hash", deviceHash)
	}
	now := h.nowUTC()
	respRec.Set("lat", lat)
	respRec.Set("lon", lon)
	respRec.Set("ele", ele)
	respRec.Set("distance_m", math.Round(distM))
	respRec.Set("eta_sec", etaSec)
	respRec.Set("status", status)
	respRec.Set("last_seen", toPBDateTime(now))

	if err := e.App.Save(respRec); err != nil {
		return err
	}

	respondingDevices, err := recomputeSosResponderStats(e.App, sosRec, now)
	if err != nil {
		return err
	}
	if err := e.App.Save(sosRec); err != nil {
		return err
	}

	h.broadcastSosRecord(sosRec, respondingDevices)
	dto := toSosAlertDto(sosRec, deviceHash, respondingDevices)
	return e.JSON(http.StatusOK, map[string]any{"sos": dto})
}

func recomputeSosResponderStats(app core.App, sosRec *core.Record, now time.Time) (map[string]bool, error) {
	cutoff := toPBDateTime(now.Add(-presenceWindow)).String()
	activeResponders, err := app.FindRecordsByFilter(
		"sos_responders",
		"sos_id = {:sosId} && status = 'coming' && last_seen >= {:cutoff}",
		"",
		0,
		0,
		dbx.Params{"sosId": sosRec.Id, "cutoff": cutoff},
	)
	if err != nil {
		return nil, err
	}

	respondingDevices := make(map[string]bool, len(activeResponders))
	if len(activeResponders) == 0 {
		sosRec.Set("responder_count", 0)
		sosRec.Set("nearest_distance_m", 0)
		sosRec.Set("nearest_eta_sec", 0)
		return respondingDevices, nil
	}

	nearestDist := math.Inf(1)
	nearestEta := math.MaxInt

	for _, r := range activeResponders {
		if dh := r.GetString("device_hash"); dh != "" {
			respondingDevices[dh] = true
		}
		d := r.GetFloat("distance_m")
		if d <= 0 {
			d = util.HaversineDistanceMeters(
				r.GetFloat("lat"),
				r.GetFloat("lon"),
				sosRec.GetFloat("lat"),
				sosRec.GetFloat("lon"),
			)
		}
		if d < nearestDist {
			nearestDist = d
		}
		eta := r.GetInt("eta_sec")
		if eta <= 0 {
			eta = int(math.Max(1, math.Round(d/1.1)))
		}
		if eta < nearestEta {
			nearestEta = eta
		}
	}

	if math.IsInf(nearestDist, 1) {
		nearestDist = 0
	}
	if nearestEta == math.MaxInt {
		nearestEta = 0
	}

	sosRec.Set("responder_count", len(activeResponders))
	sosRec.Set("nearest_distance_m", math.Round(nearestDist))
	sosRec.Set("nearest_eta_sec", nearestEta)
	return respondingDevices, nil
}

func (h *TrailLiveHandler) broadcastSosRecord(sosRec *core.Record, respondingDevices map[string]bool) {
	ownerHash := sosRec.GetString("device_hash")
	target := live.GeoTarget{
		TrailID:   sosRec.GetString("trail_id"),
		Lat:       sosRec.GetFloat("lat"),
		Lon:       sosRec.GetFloat("lon"),
		HasCoords: true,
	}
	h.liveHub().BroadcastSosUpdate(target, ownerHash, respondingDevices, func(subDeviceHash string) any {
		return toSosAlertDto(sosRec, subDeviceHash, respondingDevices)
	})
}

type pushSubscribeRequest struct {
	Endpoint string   `json:"endpoint"`
	P256dh   string   `json:"p256dh"`
	Auth     string   `json:"auth"`
	Lat      *float64 `json:"lat"`
	Lon      *float64 `json:"lon"`
	TrailID  string   `json:"trailId"`
	Keys     *struct {
		P256dh string `json:"p256dh"`
		Auth   string `json:"auth"`
	} `json:"keys"`
}

// PushSubscribe handles POST /live/push/subscribe.
func (h *TrailLiveHandler) PushSubscribe(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	var req pushSubscribeRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}

	endpoint := strings.TrimSpace(req.Endpoint)
	p256dh := strings.TrimSpace(req.P256dh)
	auth := strings.TrimSpace(req.Auth)
	if req.Keys != nil {
		if p256dh == "" {
			p256dh = strings.TrimSpace(req.Keys.P256dh)
		}
		if auth == "" {
			auth = strings.TrimSpace(req.Keys.Auth)
		}
	}
	if endpoint == "" || p256dh == "" || auth == "" {
		return e.BadRequestError("Missing push subscription endpoint or keys", nil)
	}

	subCol, err := e.App.FindCachedCollectionByNameOrId("push_subscriptions")
	if err != nil {
		return err
	}

	subRec, err := e.App.FindFirstRecordByData("push_subscriptions", "endpoint", endpoint)
	if err != nil || subRec == nil {
		subRec = core.NewRecord(subCol)
		subRec.Set("endpoint", endpoint)
	}
	subRec.Set("device_hash", deviceHash)
	subRec.Set("p256dh", p256dh)
	subRec.Set("auth", auth)

	if req.Lat != nil && req.Lon != nil && validateLatLon(req.Lat, req.Lon) == nil {
		subRec.Set("lat", *req.Lat)
		subRec.Set("lon", *req.Lon)
	}
	if trailID := strings.TrimSpace(req.TrailID); trailID != "" {
		subRec.Set("trail_id", trailID)
	}

	if err := e.App.Save(subRec); err != nil {
		return err
	}

	return e.JSON(http.StatusOK, map[string]any{"ok": true})
}

type pushUnsubscribeRequest struct {
	Endpoint string `json:"endpoint"`
}

// PushUnsubscribe handles DELETE /live/push/subscribe.
// Deletes by unique endpoint without requiring matching device_hash so stale
// 404/410 cleanup during background SOS fan-out succeeds cleanly.
func (h *TrailLiveHandler) PushUnsubscribe(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}

	var req pushUnsubscribeRequest
	_ = e.BindBody(&req)
	endpoint := strings.TrimSpace(req.Endpoint)
	if endpoint == "" {
		endpoint = strings.TrimSpace(e.Request.URL.Query().Get("endpoint"))
	}
	if endpoint == "" {
		return e.BadRequestError("Missing endpoint", nil)
	}

	if subRec, err := e.App.FindFirstRecordByData("push_subscriptions", "endpoint", endpoint); err == nil && subRec != nil {
		if err := e.App.Delete(subRec); err != nil {
			return err
		}
	}

	return e.JSON(http.StatusOK, map[string]any{"ok": true})
}

// Stream handles GET /live/stream?lat=...&lon=...&trailId=...
func (h *TrailLiveHandler) Stream(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}

	q := e.Request.URL.Query()
	trailID := strings.TrimSpace(q.Get("trailId"))
	deviceHash := readDeviceHash(e.Request, true)

	var lat, lon float64
	hasCoords := false
	latRaw := strings.TrimSpace(q.Get("lat"))
	lonRaw := strings.TrimSpace(q.Get("lon"))
	if latRaw != "" && lonRaw != "" {
		parsedLat, errLat := strconv.ParseFloat(latRaw, 64)
		parsedLon, errLon := strconv.ParseFloat(lonRaw, 64)
		if errLat != nil || errLon != nil || validateLatLon(&parsedLat, &parsedLon) != nil {
			return e.BadRequestError("Invalid lat/lon query parameters", nil)
		}
		lat = parsedLat
		lon = parsedLon
		hasCoords = true
	}

	groupCode := ""
	if rawGroup := strings.TrimSpace(q.Get("groupCode")); rawGroup != "" {
		if normCode, ok := normalizeAndValidateGroupCode(rawGroup); ok {
			groupCode = normCode
		}
	}

	sub, unsubscribe := h.liveHub().SubscribeWithGroup(lat, lon, hasCoords, trailID, deviceHash, groupCode)
	defer unsubscribe()

	return h.liveHub().ServeSSE(e.Response, e.Request, sub)
}

// RunTrailLiveGC cleans stale 30-minute presence rows and resolves expired
// temporary trail_reports and sos_alerts. Permanent landmarks (is_permanent=true,
// expires_at="") are never expired.
func RunTrailLiveGC(app core.App, hub *live.TrailLiveHub, now time.Time) error {
	now = now.UTC()
	cutoffPresence := toPBDateTime(now.Add(-presenceWindow)).String()
	nowStr := toPBDateTime(now).String()

	// 1. Purge trail_presence rows older than 30 minutes.
	if _, err := app.DB().NewQuery(
		"DELETE FROM trail_presence WHERE last_seen = '' OR last_seen < {:cutoff}",
	).Bind(dbx.Params{"cutoff": cutoffPresence}).Execute(); err != nil {
		return err
	}

	// 2. Mark expired temporary trail_reports as resolved (never touch permanent landmarks).
	expiredReports, err := app.FindRecordsByFilter(
		"trail_reports",
		"is_permanent = false && (condition_status = 'active' || condition_status = 'dry_or_closed') && expires_at != '' && expires_at < {:now}",
		"",
		0,
		0,
		dbx.Params{"now": nowStr},
	)
	if err != nil {
		return err
	}
	for _, rep := range expiredReports {
		if meta, ok := reportCategories[rep.GetString("category")]; ok && meta.IsPermanent {
			continue
		}
		rep.Set("condition_status", "resolved")
		if err := app.Save(rep); err != nil {
			return err
		}
		if hub != nil {
			dto := toTrailReportDto(rep)
			hub.BroadcastReportUpdate(live.GeoTarget{
				TrailID:   dto.TrailID,
				Lat:       dto.Lat,
				Lon:       dto.Lon,
				HasCoords: true,
			}, dto)
		}
	}

	// 3. Mark expired active sos_alerts as resolved.
	expiredSos, err := app.FindRecordsByFilter(
		"sos_alerts",
		"status = 'active' && expires_at != '' && expires_at < {:now}",
		"",
		0,
		0,
		dbx.Params{"now": nowStr},
	)
	if err != nil {
		return err
	}
	for _, sosRec := range expiredSos {
		sosRec.Set("status", "resolved")
		if err := app.Save(sosRec); err != nil {
			return err
		}
		if hub != nil {
			respMap, _ := loadActiveRespondersMap(app, sosRec.Id, now)
			ownerHash := sosRec.GetString("device_hash")
			target := live.GeoTarget{
				TrailID:   sosRec.GetString("trail_id"),
				Lat:       sosRec.GetFloat("lat"),
				Lon:       sosRec.GetFloat("lon"),
				HasCoords: true,
			}
			hub.BroadcastSosUpdate(target, ownerHash, respMap, func(subDeviceHash string) any {
				return toSosAlertDto(sosRec, subDeviceHash, respMap)
			})
		}
	}

	// 4. Clean up expired trail_groups (< now) and stale trail_group_members (< now - 2h).
	if err := cleanTrailGroupsGC(app, now); err != nil {
		return err
	}

	return nil
}
