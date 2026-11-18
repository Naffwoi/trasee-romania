package routes

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

const (
	// Unambiguous 32-character uppercase alphabet (excludes 0, O, 1, I).
	groupCodeAlphabet        = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	groupCodeLength          = 6
	groupDefaultTTL          = 12 * time.Hour
	groupActiveMemberWindow  = 10 * time.Minute
	groupStaleMemberGCWindow = 2 * time.Hour
	groupDefaultDisplayName  = "Drumeț"
	unsetGroupOptionalFloat  = -1.0
)

// Calm slate / forest / teal / indigo palette for deterministic group avatars.
var groupMemberPalette = []string{
	"#242734",
	"#0f766e",
	"#3730a3",
	"#0369a1",
	"#4d7c0f",
	"#6d28d9",
}

// GroupMemberDto is the exact camelCase wire representation of an active member
// in a live hiking group. Never exposes device_hash.
type GroupMemberDto struct {
	MemberID     string   `json:"memberId"`
	DisplayName  string   `json:"displayName"`
	ColorHex     string   `json:"colorHex"`
	Lat          float64  `json:"lat"`
	Lon          float64  `json:"lon"`
	Ele          float64  `json:"ele"`
	Accuracy     float64  `json:"accuracy"`
	Heading      *float64 `json:"heading"`
	Speed        *float64 `json:"speed"`
	AlongTrackM  *float64 `json:"alongTrackM"`
	InNavigation bool     `json:"inNavigation"`
	IsSelf       bool     `json:"isSelf"`
	UpdatedAt    string   `json:"updatedAt"`
}

// GroupSessionDto is the camelCase wire representation of a live hiking group
// session returned by create, get, join, and ping endpoints.
type GroupSessionDto struct {
	Code         string           `json:"code"`
	TrailID      string           `json:"trailId"`
	ExpiresAt    string           `json:"expiresAt"`
	SelfMemberID string           `json:"selfMemberId"`
	Members      []GroupMemberDto `json:"members"`
}

// GroupMemberLeftDto is the SSE payload broadcast on `event: group_member_left`.
type GroupMemberLeftDto struct {
	GroupCode string `json:"groupCode"`
	MemberID  string `json:"memberId"`
}

func deriveGroupMemberID(code, deviceHash string) string {
	sum := sha256.Sum256([]byte("group-member:" + code + ":" + deviceHash))
	return hex.EncodeToString(sum[:])[:12]
}

func deriveGroupMemberColor(code, deviceHash string) string {
	sum := sha256.Sum256([]byte("group-member:" + code + ":" + deviceHash))
	idx := int(binary.BigEndian.Uint32(sum[:4])) % len(groupMemberPalette)
	return groupMemberPalette[idx]
}

func normalizeAndValidateGroupCode(raw string) (string, bool) {
	code := strings.ToUpper(strings.TrimSpace(raw))
	if len(code) != groupCodeLength {
		return "", false
	}
	for i := 0; i < len(code); i++ {
		if strings.IndexByte(groupCodeAlphabet, code[i]) < 0 {
			return "", false
		}
	}
	return code, true
}

func generateUniqueGroupCode(app core.App) (string, error) {
	buf := make([]byte, groupCodeLength)
	out := make([]byte, groupCodeLength)

	for attempt := 0; attempt < 16; attempt++ {
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		for i, b := range buf {
			// len(groupCodeAlphabet) == 32, so b & 31 has zero modulo bias.
			out[i] = groupCodeAlphabet[int(b)&31]
		}
		code := string(out)
		if existing, err := app.FindFirstRecordByData("trail_groups", "code", code); err != nil || existing == nil {
			return code, nil
		}
	}
	return "", errors.New("failed to generate unique group code")
}

func findActiveGroupByCode(app core.App, code string, now time.Time) (*core.Record, error) {
	rec, err := app.FindFirstRecordByData("trail_groups", "code", code)
	if err != nil || rec == nil {
		return nil, nil
	}
	expDT := rec.GetDateTime("expires_at")
	if !expDT.IsZero() && expDT.Time().Before(now) {
		return nil, nil
	}
	return rec, nil
}

func bindOptionalGroupBody(e *core.RequestEvent, dst any) error {
	if e.Request == nil || e.Request.Body == nil {
		return nil
	}
	raw, err := io.ReadAll(io.LimitReader(e.Request.Body, 64*1024))
	if err != nil {
		return e.BadRequestError("Failed to read request body", err)
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return nil
	}
	if err := json.Unmarshal(trimmed, dst); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}
	return nil
}

type groupMemberUpsertInput struct {
	DisplayName            string
	Lat                    *float64
	Lon                    *float64
	Ele                    *float64
	Accuracy               *float64
	Heading                *float64
	Speed                  *float64
	AlongTrackM            *float64
	InNavigation           *bool
	ReplaceOptionalMetrics bool
}

func upsertGroupMember(
	app core.App,
	code string,
	deviceHash string,
	in groupMemberUpsertInput,
	now time.Time,
) (*core.Record, error) {
	membersCol, err := app.FindCachedCollectionByNameOrId("trail_group_members")
	if err != nil {
		return nil, err
	}

	rec, findErr := app.FindFirstRecordByFilter(
		"trail_group_members",
		"group_code = {:code} && device_hash = {:deviceHash}",
		dbx.Params{"code": code, "deviceHash": deviceHash},
	)
	isNew := findErr != nil || rec == nil
	if isNew {
		rec = core.NewRecord(membersCol)
		rec.Set("group_code", code)
		rec.Set("device_hash", deviceHash)
		rec.Set("heading", unsetGroupOptionalFloat)
		rec.Set("speed", unsetGroupOptionalFloat)
		rec.Set("along_track_m", unsetGroupOptionalFloat)
	}

	rec.Set("member_id", deriveGroupMemberID(code, deviceHash))
	rec.Set("color_hex", deriveGroupMemberColor(code, deviceHash))

	cleanName := sanitizePlainText(in.DisplayName, 24)
	if cleanName != "" {
		rec.Set("display_name", cleanName)
	} else if strings.TrimSpace(rec.GetString("display_name")) == "" {
		rec.Set("display_name", groupDefaultDisplayName)
	}

	if in.Lat != nil && in.Lon != nil {
		rec.Set("lat", *in.Lat)
		rec.Set("lon", *in.Lon)
	}
	if in.Ele != nil && !math.IsNaN(*in.Ele) && !math.IsInf(*in.Ele, 0) {
		rec.Set("ele", *in.Ele)
	}
	if in.Accuracy != nil && !math.IsNaN(*in.Accuracy) && !math.IsInf(*in.Accuracy, 0) && *in.Accuracy >= 0 {
		rec.Set("accuracy", *in.Accuracy)
	}

	setOptionalMetric := func(field string, val *float64) {
		if val != nil && !math.IsNaN(*val) && !math.IsInf(*val, 0) && *val >= 0 {
			rec.Set(field, *val)
		} else if in.ReplaceOptionalMetrics || isNew {
			rec.Set(field, unsetGroupOptionalFloat)
		}
	}
	setOptionalMetric("heading", in.Heading)
	setOptionalMetric("speed", in.Speed)
	setOptionalMetric("along_track_m", in.AlongTrackM)

	if in.InNavigation != nil {
		rec.Set("in_navigation", *in.InNavigation)
	}
	rec.Set("last_seen", toPBDateTime(now))

	if err := app.Save(rec); err != nil {
		return nil, err
	}
	return rec, nil
}

func toGroupMemberDto(rec *core.Record, callerDeviceHash string, fallbackNow time.Time) GroupMemberDto {
	var headingPtr *float64
	if h := rec.GetFloat("heading"); h >= 0 {
		v := h
		headingPtr = &v
	}

	var speedPtr *float64
	if s := rec.GetFloat("speed"); s >= 0 {
		v := s
		speedPtr = &v
	}

	var alongPtr *float64
	if a := rec.GetFloat("along_track_m"); a >= 0 {
		v := a
		alongPtr = &v
	}

	updatedStr := fallbackNow.UTC().Format(time.RFC3339)
	if lastSeenDT := rec.GetDateTime("last_seen"); !lastSeenDT.IsZero() {
		updatedStr = lastSeenDT.Time().UTC().Format(time.RFC3339)
	} else if updDT := rec.GetDateTime("updated"); !updDT.IsZero() {
		updatedStr = updDT.Time().UTC().Format(time.RFC3339)
	}

	code := rec.GetString("group_code")
	recDeviceHash := rec.GetString("device_hash")
	memberID := strings.TrimSpace(rec.GetString("member_id"))
	if memberID == "" && code != "" && recDeviceHash != "" {
		memberID = deriveGroupMemberID(code, recDeviceHash)
	}
	colorHex := strings.TrimSpace(rec.GetString("color_hex"))
	if colorHex == "" && code != "" && recDeviceHash != "" {
		colorHex = deriveGroupMemberColor(code, recDeviceHash)
	}
	if colorHex == "" {
		colorHex = groupMemberPalette[0]
	}

	displayName := strings.TrimSpace(rec.GetString("display_name"))
	if displayName == "" {
		displayName = groupDefaultDisplayName
	}

	isSelf := callerDeviceHash != "" && recDeviceHash != "" && callerDeviceHash == recDeviceHash

	return GroupMemberDto{
		MemberID:     memberID,
		DisplayName:  displayName,
		ColorHex:     colorHex,
		Lat:          rec.GetFloat("lat"),
		Lon:          rec.GetFloat("lon"),
		Ele:          rec.GetFloat("ele"),
		Accuracy:     rec.GetFloat("accuracy"),
		Heading:      headingPtr,
		Speed:        speedPtr,
		AlongTrackM:  alongPtr,
		InNavigation: rec.GetBool("in_navigation"),
		IsSelf:       isSelf,
		UpdatedAt:    updatedStr,
	}
}

func buildGroupSessionDto(
	app core.App,
	groupRec *core.Record,
	callerDeviceHash string,
	now time.Time,
) (GroupSessionDto, error) {
	code := groupRec.GetString("code")
	cutoff := toPBDateTime(now.Add(-groupActiveMemberWindow)).String()

	records, err := app.FindRecordsByFilter(
		"trail_group_members",
		"group_code = {:code} && last_seen >= {:cutoff}",
		"+created",
		100,
		0,
		dbx.Params{"code": code, "cutoff": cutoff},
	)
	if err != nil {
		return GroupSessionDto{}, err
	}

	members := make([]GroupMemberDto, 0, len(records))
	for _, rec := range records {
		members = append(members, toGroupMemberDto(rec, callerDeviceHash, now))
	}

	expiresStr := now.Add(groupDefaultTTL).UTC().Format(time.RFC3339)
	if expDT := groupRec.GetDateTime("expires_at"); !expDT.IsZero() {
		expiresStr = expDT.Time().UTC().Format(time.RFC3339)
	}

	selfMemberID := ""
	if callerDeviceHash != "" {
		selfMemberID = deriveGroupMemberID(code, callerDeviceHash)
	}

	return GroupSessionDto{
		Code:         code,
		TrailID:      groupRec.GetString("trail_id"),
		ExpiresAt:    expiresStr,
		SelfMemberID: selfMemberID,
		Members:      members,
	}, nil
}

type createGroupRequest struct {
	TrailID       string   `json:"trailId"`
	PreferredCode string   `json:"preferredCode"`
	DisplayName   string   `json:"displayName"`
	Lat           *float64 `json:"lat"`
	Lon           *float64 `json:"lon"`
	Ele           *float64 `json:"ele"`
	Accuracy      *float64 `json:"accuracy"`
	Heading       *float64 `json:"heading"`
	Speed         *float64 `json:"speed"`
	AlongTrackM   *float64 `json:"alongTrackM"`
	InNavigation  *bool    `json:"inNavigation"`
}

// CreateGroup handles POST /live/groups.
// Supports optional `preferredCode` (`^[A-HJ-NP-Z2-9]{6}$`) so hiking groups
// formed offline over BLE sync to the exact same 6-character code on 4G return
// (merging members seamlessly if a groupmate already synced seconds earlier).
func (h *TrailLiveHandler) CreateGroup(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	var req createGroupRequest
	if err := bindOptionalGroupBody(e, &req); err != nil {
		return err
	}
	if req.Lat != nil || req.Lon != nil {
		if err := validateLatLon(req.Lat, req.Lon); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
	}

	groupsCol, err := e.App.FindCachedCollectionByNameOrId("trail_groups")
	if err != nil {
		return err
	}

	now := h.nowUTC()
	memberInput := groupMemberUpsertInput{
		DisplayName:            req.DisplayName,
		Lat:                    req.Lat,
		Lon:                    req.Lon,
		Ele:                    req.Ele,
		Accuracy:               req.Accuracy,
		Heading:                req.Heading,
		Speed:                  req.Speed,
		AlongTrackM:            req.AlongTrackM,
		InNavigation:           req.InNavigation,
		ReplaceOptionalMetrics: true,
	}

	if strings.TrimSpace(req.PreferredCode) != "" {
		prefCode, ok := normalizeAndValidateGroupCode(req.PreferredCode)
		if !ok {
			return e.BadRequestError("Invalid preferredCode", nil)
		}

		var groupRec *core.Record
		if err := e.App.RunInTransaction(func(txApp core.App) error {
			existing, findErr := txApp.FindFirstRecordByData("trail_groups", "code", prefCode)
			if findErr == nil && existing != nil {
				expDT := existing.GetDateTime("expires_at")
				if !expDT.IsZero() && expDT.Time().Before(now) {
					_, _ = txApp.DB().NewQuery(
						"DELETE FROM trail_group_members WHERE group_code = {:code}",
					).Bind(dbx.Params{"code": prefCode}).Execute()
					if delErr := txApp.Delete(existing); delErr != nil {
						return delErr
					}
					existing = nil
				}
			}

			if existing != nil {
				groupRec = existing
				groupRec.Set("expires_at", toPBDateTime(now.Add(groupDefaultTTL)))
				if groupRec.GetString("trail_id") == "" && strings.TrimSpace(req.TrailID) != "" {
					groupRec.Set("trail_id", strings.TrimSpace(req.TrailID))
				}
				if saveErr := txApp.Save(groupRec); saveErr != nil {
					return saveErr
				}
				memberInput.ReplaceOptionalMetrics = false
			} else {
				groupRec = core.NewRecord(groupsCol)
				groupRec.Set("code", prefCode)
				groupRec.Set("trail_id", strings.TrimSpace(req.TrailID))
				groupRec.Set("owner_device_hash", deviceHash)
				groupRec.Set("expires_at", toPBDateTime(now.Add(groupDefaultTTL)))
				if saveErr := txApp.Save(groupRec); saveErr != nil {
					return saveErr
				}
			}

			_, upErr := upsertGroupMember(txApp, prefCode, deviceHash, memberInput, now)
			return upErr
		}); err != nil {
			return err
		}

		session, err := buildGroupSessionDto(e.App, groupRec, deviceHash, now)
		if err != nil {
			return err
		}
		return e.JSON(http.StatusOK, session)
	}

	code, err := generateUniqueGroupCode(e.App)
	if err != nil {
		return err
	}

	groupRec := core.NewRecord(groupsCol)
	groupRec.Set("code", code)
	groupRec.Set("trail_id", strings.TrimSpace(req.TrailID))
	groupRec.Set("owner_device_hash", deviceHash)
	groupRec.Set("expires_at", toPBDateTime(now.Add(groupDefaultTTL)))

	if err := e.App.Save(groupRec); err != nil {
		return err
	}

	if _, err := upsertGroupMember(e.App, code, deviceHash, memberInput, now); err != nil {
		return err
	}

	session, err := buildGroupSessionDto(e.App, groupRec, deviceHash, now)
	if err != nil {
		return err
	}
	return e.JSON(http.StatusOK, session)
}

// GetGroup handles GET /live/groups/{code}.
func (h *TrailLiveHandler) GetGroup(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}

	code, ok := normalizeAndValidateGroupCode(e.Request.PathValue("code"))
	if !ok {
		return e.BadRequestError("Invalid group code", nil)
	}

	now := h.nowUTC()
	groupRec, err := findActiveGroupByCode(e.App, code, now)
	if err != nil {
		return err
	}
	if groupRec == nil {
		return e.NotFoundError("Group not found or expired", nil)
	}

	callerDeviceHash := readDeviceHash(e.Request, false)
	session, err := buildGroupSessionDto(e.App, groupRec, callerDeviceHash, now)
	if err != nil {
		return err
	}
	return e.JSON(http.StatusOK, session)
}

type joinGroupRequest struct {
	DisplayName  string   `json:"displayName"`
	Lat          *float64 `json:"lat"`
	Lon          *float64 `json:"lon"`
	Ele          *float64 `json:"ele"`
	Accuracy     *float64 `json:"accuracy"`
	Heading      *float64 `json:"heading"`
	Speed        *float64 `json:"speed"`
	AlongTrackM  *float64 `json:"alongTrackM"`
	InNavigation *bool    `json:"inNavigation"`
}

// JoinGroup handles POST /live/groups/{code}/join.
func (h *TrailLiveHandler) JoinGroup(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	code, ok := normalizeAndValidateGroupCode(e.Request.PathValue("code"))
	if !ok {
		return e.BadRequestError("Invalid group code", nil)
	}

	var req joinGroupRequest
	if err := bindOptionalGroupBody(e, &req); err != nil {
		return err
	}
	if req.Lat != nil || req.Lon != nil {
		if err := validateLatLon(req.Lat, req.Lon); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
	}

	now := h.nowUTC()
	groupRec, err := findActiveGroupByCode(e.App, code, now)
	if err != nil {
		return err
	}
	if groupRec == nil {
		return e.NotFoundError("Group not found or expired", nil)
	}

	groupRec.Set("expires_at", toPBDateTime(now.Add(groupDefaultTTL)))
	if err := e.App.Save(groupRec); err != nil {
		return err
	}

	if _, err := upsertGroupMember(e.App, code, deviceHash, groupMemberUpsertInput{
		DisplayName:            req.DisplayName,
		Lat:                    req.Lat,
		Lon:                    req.Lon,
		Ele:                    req.Ele,
		Accuracy:               req.Accuracy,
		Heading:                req.Heading,
		Speed:                  req.Speed,
		AlongTrackM:            req.AlongTrackM,
		InNavigation:           req.InNavigation,
		ReplaceOptionalMetrics: false,
	}, now); err != nil {
		return err
	}

	session, err := buildGroupSessionDto(e.App, groupRec, deviceHash, now)
	if err != nil {
		return err
	}
	return e.JSON(http.StatusOK, session)
}

type pingGroupRequest struct {
	DisplayName  string   `json:"displayName"`
	Lat          *float64 `json:"lat"`
	Lon          *float64 `json:"lon"`
	Ele          *float64 `json:"ele"`
	Accuracy     *float64 `json:"accuracy"`
	Heading      *float64 `json:"heading"`
	Speed        *float64 `json:"speed"`
	AlongTrackM  *float64 `json:"alongTrackM"`
	InNavigation *bool    `json:"inNavigation"`
}

// PingGroup handles POST /live/groups/{code}/ping.
// Updates member coordinates & telemetry, refreshes group expires_at (now + 12h),
// and broadcasts `event: group_member_update` strictly to subscribers of `{code}`.
func (h *TrailLiveHandler) PingGroup(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	code, ok := normalizeAndValidateGroupCode(e.Request.PathValue("code"))
	if !ok {
		return e.BadRequestError("Invalid group code", nil)
	}

	var req pingGroupRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}
	if err := validateLatLon(req.Lat, req.Lon); err != nil {
		return e.BadRequestError(err.Error(), nil)
	}

	now := h.nowUTC()
	groupRec, err := findActiveGroupByCode(e.App, code, now)
	if err != nil {
		return err
	}
	if groupRec == nil {
		return e.NotFoundError("Group not found or expired", nil)
	}

	groupRec.Set("expires_at", toPBDateTime(now.Add(groupDefaultTTL)))
	if err := e.App.Save(groupRec); err != nil {
		return err
	}

	memberRec, err := upsertGroupMember(e.App, code, deviceHash, groupMemberUpsertInput{
		DisplayName:            req.DisplayName,
		Lat:                    req.Lat,
		Lon:                    req.Lon,
		Ele:                    req.Ele,
		Accuracy:               req.Accuracy,
		Heading:                req.Heading,
		Speed:                  req.Speed,
		AlongTrackM:            req.AlongTrackM,
		InNavigation:           req.InNavigation,
		ReplaceOptionalMetrics: true,
	}, now)
	if err != nil {
		return err
	}

	// Outgoing SSE payload ALWAYS has isSelf: false so remote peers never mistake
	// a teammate's broadcast for their own marker.
	broadcastDto := toGroupMemberDto(memberRec, "", now)
	h.liveHub().PublishGroupEvent(code, "group_member_update", broadcastDto)

	session, err := buildGroupSessionDto(e.App, groupRec, deviceHash, now)
	if err != nil {
		return err
	}
	return e.JSON(http.StatusOK, session)
}

// LeaveGroup handles POST /live/groups/{code}/leave.
// Deletes the caller's member row and broadcasts `event: group_member_left`.
func (h *TrailLiveHandler) LeaveGroup(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	deviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	code, ok := normalizeAndValidateGroupCode(e.Request.PathValue("code"))
	if !ok {
		return e.BadRequestError("Invalid group code", nil)
	}

	selfMemberID := deriveGroupMemberID(code, deviceHash)

	if rec, findErr := e.App.FindFirstRecordByFilter(
		"trail_group_members",
		"group_code = {:code} && device_hash = {:deviceHash}",
		dbx.Params{"code": code, "deviceHash": deviceHash},
	); findErr == nil && rec != nil {
		if err := e.App.Delete(rec); err != nil {
			return err
		}
	}

	h.liveHub().PublishGroupEvent(code, "group_member_left", GroupMemberLeftDto{
		GroupCode: code,
		MemberID:  selfMemberID,
	})

	return e.JSON(http.StatusOK, map[string]any{
		"ok":        true,
		"groupCode": code,
		"memberId":  selfMemberID,
	})
}

func cleanTrailGroupsGC(app core.App, now time.Time) error {
	nowStr := toPBDateTime(now).String()
	staleMemberCutoff := toPBDateTime(now.Add(-groupStaleMemberGCWindow)).String()

	if _, err := app.FindCachedCollectionByNameOrId("trail_groups"); err == nil {
		if _, err := app.DB().NewQuery(
			"DELETE FROM trail_groups WHERE expires_at = '' OR expires_at < {:now}",
		).Bind(dbx.Params{"now": nowStr}).Execute(); err != nil {
			return err
		}
	}

	if _, err := app.FindCachedCollectionByNameOrId("trail_group_members"); err == nil {
		if _, err := app.DB().NewQuery(
			"DELETE FROM trail_group_members WHERE last_seen = '' OR last_seen < {:cutoff} OR group_code NOT IN (SELECT code FROM trail_groups)",
		).Bind(dbx.Params{"cutoff": staleMemberCutoff}).Execute(); err != nil {
			return err
		}
	}

	return nil
}
