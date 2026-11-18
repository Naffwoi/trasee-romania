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

	"pocketbase/services/live"
)

const (
	// Unambiguous 32-character uppercase alphabet (excludes 0, O, 1, I).
	groupCodeAlphabet        = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	groupCodeLength          = 6
	groupDefaultTTL          = 12 * time.Hour
	groupDBRefreshThreshold  = 11 * time.Hour
	groupActiveMemberWindow  = 10 * time.Minute
	groupStaleMemberGCWindow = 2 * time.Hour
	groupDefaultDisplayName  = "Drumeț"
)

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
	Stationary   bool     `json:"stationary"`
	IsSelf       bool     `json:"isSelf"`
	UpdatedAt    string   `json:"updatedAt"`
}

// GroupSessionDto is the camelCase wire representation of a live hiking group session.
type GroupSessionDto struct {
	Code         string           `json:"code"`
	TrailID      string           `json:"trailId"`
	ExpiresAt    string           `json:"expiresAt"`
	SelfMemberID string           `json:"selfMemberId"`
	Members      []GroupMemberDto `json:"members"`
}

// GroupMemberUpdateEventDto is the single-envelope SSE payload broadcast on `event: group_member_update`.
type GroupMemberUpdateEventDto struct {
	Type      string         `json:"type"`
	GroupCode string         `json:"groupCode"`
	Member    GroupMemberDto `json:"member"`
}

// GroupMemberLeftDto is the SSE payload broadcast on `event: group_member_left`.
type GroupMemberLeftDto struct {
	Type      string `json:"type"`
	GroupCode string `json:"groupCode"`
	MemberID  string `json:"memberId"`
}

func deriveGroupMemberIDAndColor(code, deviceHash string) (string, string) {
	sum := sha256.Sum256([]byte("group-member:" + code + ":" + deviceHash))
	memberID := hex.EncodeToString(sum[:])[:12]
	colorHex := groupMemberPalette[int(binary.BigEndian.Uint32(sum[:4]))%len(groupMemberPalette)]
	return memberID, colorHex
}

func deriveGroupMemberID(code, deviceHash string) string {
	id, _ := deriveGroupMemberIDAndColor(code, deviceHash)
	return id
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

func generateUniqueGroupCode(app core.App, store *live.LiveMemoryStore, now time.Time) (string, error) {
	buf := make([]byte, groupCodeLength)
	out := make([]byte, groupCodeLength)

	for attempt := 0; attempt < 16; attempt++ {
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		for i, b := range buf {
			out[i] = groupCodeAlphabet[int(b)&31]
		}
		code := string(out)
		if _, inMem := store.GetActiveGroup(code, now); inMem {
			continue
		}
		if existing, err := app.FindFirstRecordByData("trail_groups", "code", code); err != nil || existing == nil {
			return code, nil
		}
	}
	return "", errors.New("failed to generate unique group code")
}

func resolveActiveGroupCached(app core.App, store *live.LiveMemoryStore, code string, now time.Time) (live.CachedGroup, bool) {
	if meta, ok := store.GetActiveGroup(code, now); ok {
		return meta, true
	}
	rec, err := app.FindFirstRecordByData("trail_groups", "code", code)
	if err != nil || rec == nil {
		return live.CachedGroup{}, false
	}
	expDT := rec.GetDateTime("expires_at")
	if !expDT.IsZero() && expDT.Time().Before(now) {
		return live.CachedGroup{}, false
	}
	meta := live.CachedGroup{
		RecordID:        rec.Id,
		Code:            code,
		TrailID:         rec.GetString("trail_id"),
		OwnerDeviceHash: rec.GetString("owner_device_hash"),
		ExpiresAt:       expDT.Time().UTC(),
		LastDBSyncAt:    now,
	}
	store.UpsertGroup(meta)
	return meta, true
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
	Stationary             *bool
	ReplaceOptionalMetrics bool
}

func sanitizeOptionalFloatPtr(v *float64) *float64 {
	if v != nil && !math.IsNaN(*v) && !math.IsInf(*v, 0) && *v >= 0 {
		cp := *v
		return &cp
	}
	return nil
}

func upsertGroupMemberInStore(
	store *live.LiveMemoryStore,
	code string,
	deviceHash string,
	in groupMemberUpsertInput,
	now time.Time,
) live.CachedGroupMember {
	prev, existed := store.GetGroupMember(code, deviceHash)
	memberID, colorHex := deriveGroupMemberIDAndColor(code, deviceHash)

	cleanName := sanitizePlainText(in.DisplayName, 24)
	if cleanName == "" {
		if existed && strings.TrimSpace(prev.DisplayName) != "" {
			cleanName = prev.DisplayName
		} else {
			cleanName = groupDefaultDisplayName
		}
	}

	lat, lon := prev.Lat, prev.Lon
	if in.Lat != nil && in.Lon != nil {
		lat = *in.Lat
		lon = *in.Lon
	}
	ele := prev.Ele
	if in.Ele != nil && !math.IsNaN(*in.Ele) && !math.IsInf(*in.Ele, 0) {
		ele = *in.Ele
	}
	acc := prev.Accuracy
	if in.Accuracy != nil && !math.IsNaN(*in.Accuracy) && !math.IsInf(*in.Accuracy, 0) && *in.Accuracy >= 0 {
		acc = *in.Accuracy
	}

	pickOptional := func(incoming, existing *float64) *float64 {
		if clean := sanitizeOptionalFloatPtr(incoming); clean != nil {
			return clean
		}
		if in.ReplaceOptionalMetrics || !existed {
			return nil
		}
		return existing
	}

	inNav := prev.InNavigation
	if in.InNavigation != nil {
		inNav = *in.InNavigation
	}
	stationary := prev.Stationary
	if in.Stationary != nil {
		stationary = *in.Stationary
	}

	return store.UpsertGroupMember(code, live.CachedGroupMember{
		DeviceHash:   deviceHash,
		MemberID:     memberID,
		DisplayName:  cleanName,
		ColorHex:     colorHex,
		Lat:          lat,
		Lon:          lon,
		Ele:          ele,
		Accuracy:     acc,
		Heading:      pickOptional(in.Heading, prev.Heading),
		Speed:        pickOptional(in.Speed, prev.Speed),
		AlongTrackM:  pickOptional(in.AlongTrackM, prev.AlongTrackM),
		InNavigation: inNav,
		Stationary:   stationary,
		CreatedAt:    prev.CreatedAt,
		LastSeen:     now,
	})
}

func cachedMemberToDto(m live.CachedGroupMember, callerDeviceHash string, fallbackNow time.Time) GroupMemberDto {
	updatedStr := fallbackNow.UTC().Format(time.RFC3339)
	if !m.LastSeen.IsZero() {
		updatedStr = m.LastSeen.UTC().Format(time.RFC3339)
	}
	displayName := strings.TrimSpace(m.DisplayName)
	if displayName == "" {
		displayName = groupDefaultDisplayName
	}
	colorHex := m.ColorHex
	if colorHex == "" {
		colorHex = groupMemberPalette[0]
	}
	return GroupMemberDto{
		MemberID:     m.MemberID,
		DisplayName:  displayName,
		ColorHex:     colorHex,
		Lat:          m.Lat,
		Lon:          m.Lon,
		Ele:          m.Ele,
		Accuracy:     m.Accuracy,
		Heading:      m.Heading,
		Speed:        m.Speed,
		AlongTrackM:  m.AlongTrackM,
		InNavigation: m.InNavigation,
		Stationary:   m.Stationary,
		IsSelf:       callerDeviceHash != "" && m.DeviceHash == callerDeviceHash,
		UpdatedAt:    updatedStr,
	}
}

func buildGroupSessionDtoFromStore(
	store *live.LiveMemoryStore,
	meta live.CachedGroup,
	callerDeviceHash string,
	now time.Time,
) GroupSessionDto {
	rawMembers := store.ListActiveGroupMembers(meta.Code, groupActiveMemberWindow, now)
	members := make([]GroupMemberDto, len(rawMembers))
	for i, m := range rawMembers {
		members[i] = cachedMemberToDto(m, callerDeviceHash, now)
	}
	expiresStr := now.Add(groupDefaultTTL).UTC().Format(time.RFC3339)
	if !meta.ExpiresAt.IsZero() {
		expiresStr = meta.ExpiresAt.UTC().Format(time.RFC3339)
	}
	selfMemberID := ""
	if callerDeviceHash != "" {
		selfMemberID = deriveGroupMemberID(meta.Code, callerDeviceHash)
	}
	return GroupSessionDto{
		Code:         meta.Code,
		TrailID:      meta.TrailID,
		ExpiresAt:    expiresStr,
		SelfMemberID: selfMemberID,
		Members:      members,
	}
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
	Stationary    *bool    `json:"stationary"`
}

// CreateGroup handles POST /live/groups (persisting group header in SQLite and member telemetry in RAM).
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
	store := h.readyStore(e.App)
	newExp := now.Add(groupDefaultTTL)
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
		Stationary:             req.Stationary,
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
					store.DeleteGroup(prefCode)
					if delErr := txApp.Delete(existing); delErr != nil {
						return delErr
					}
					existing = nil
				}
			}

			if existing != nil {
				groupRec = existing
				groupRec.Set("expires_at", toPBDateTime(newExp))
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
				groupRec.Set("expires_at", toPBDateTime(newExp))
				if saveErr := txApp.Save(groupRec); saveErr != nil {
					return saveErr
				}
			}
			return nil
		}); err != nil {
			return err
		}

		meta := live.CachedGroup{
			RecordID:        groupRec.Id,
			Code:            prefCode,
			TrailID:         groupRec.GetString("trail_id"),
			OwnerDeviceHash: groupRec.GetString("owner_device_hash"),
			ExpiresAt:       newExp,
			LastDBSyncAt:    now,
		}
		store.UpsertGroup(meta)
		upsertGroupMemberInStore(store, prefCode, deviceHash, memberInput, now)
		return e.JSON(http.StatusOK, buildGroupSessionDtoFromStore(store, meta, deviceHash, now))
	}

	code, err := generateUniqueGroupCode(e.App, store, now)
	if err != nil {
		return err
	}

	groupRec := core.NewRecord(groupsCol)
	groupRec.Set("code", code)
	groupRec.Set("trail_id", strings.TrimSpace(req.TrailID))
	groupRec.Set("owner_device_hash", deviceHash)
	groupRec.Set("expires_at", toPBDateTime(newExp))
	if err := e.App.Save(groupRec); err != nil {
		return err
	}

	meta := live.CachedGroup{
		RecordID:        groupRec.Id,
		Code:            code,
		TrailID:         groupRec.GetString("trail_id"),
		OwnerDeviceHash: deviceHash,
		ExpiresAt:       newExp,
		LastDBSyncAt:    now,
	}
	store.UpsertGroup(meta)
	upsertGroupMemberInStore(store, code, deviceHash, memberInput, now)
	return e.JSON(http.StatusOK, buildGroupSessionDtoFromStore(store, meta, deviceHash, now))
}

// GetGroup handles GET /live/groups/{code} directly from RAM.
func (h *TrailLiveHandler) GetGroup(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	code, ok := normalizeAndValidateGroupCode(e.Request.PathValue("code"))
	if !ok {
		return e.BadRequestError("Invalid group code", nil)
	}

	now := h.nowUTC()
	store := h.readyStore(e.App)
	meta, active := resolveActiveGroupCached(e.App, store, code, now)
	if !active {
		return e.NotFoundError("Group not found or expired", nil)
	}

	callerDeviceHash := readDeviceHash(e.Request, false)
	return e.JSON(http.StatusOK, buildGroupSessionDtoFromStore(store, meta, callerDeviceHash, now))
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
	Stationary   *bool    `json:"stationary"`
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
	store := h.readyStore(e.App)
	if _, active := resolveActiveGroupCached(e.App, store, code, now); !active {
		return e.NotFoundError("Group not found or expired", nil)
	}

	newExp := now.Add(groupDefaultTTL)
	meta, _ := store.TouchGroupTTL(code, newExp, groupDefaultTTL+time.Second, now)
	_, _ = e.App.DB().NewQuery(
		"UPDATE trail_groups SET expires_at = {:exp} WHERE code = {:code}",
	).Bind(dbx.Params{"exp": toPBDateTime(newExp).String(), "code": code}).Execute()

	upsertGroupMemberInStore(store, code, deviceHash, groupMemberUpsertInput{
		DisplayName:            req.DisplayName,
		Lat:                    req.Lat,
		Lon:                    req.Lon,
		Ele:                    req.Ele,
		Accuracy:               req.Accuracy,
		Heading:                req.Heading,
		Speed:                  req.Speed,
		AlongTrackM:            req.AlongTrackM,
		InNavigation:           req.InNavigation,
		Stationary:             req.Stationary,
		ReplaceOptionalMetrics: false,
	}, now)

	return e.JSON(http.StatusOK, buildGroupSessionDtoFromStore(store, meta, deviceHash, now))
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
	Stationary   *bool    `json:"stationary"`
}

// PingGroup handles POST /live/groups/{code}/ping in RAM (0 SQLite queries on 99.86% of pings).
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
	store := h.readyStore(e.App)
	if _, active := resolveActiveGroupCached(e.App, store, code, now); !active {
		return e.NotFoundError("Group not found or expired", nil)
	}

	newExp := now.Add(groupDefaultTTL)
	meta, needsDBWrite := store.TouchGroupTTL(code, newExp, groupDBRefreshThreshold, now)
	if needsDBWrite {
		_, _ = e.App.DB().NewQuery(
			"UPDATE trail_groups SET expires_at = {:exp} WHERE code = {:code}",
		).Bind(dbx.Params{"exp": toPBDateTime(newExp).String(), "code": code}).Execute()
	}

	member := upsertGroupMemberInStore(store, code, deviceHash, groupMemberUpsertInput{
		DisplayName:            req.DisplayName,
		Lat:                    req.Lat,
		Lon:                    req.Lon,
		Ele:                    req.Ele,
		Accuracy:               req.Accuracy,
		Heading:                req.Heading,
		Speed:                  req.Speed,
		AlongTrackM:            req.AlongTrackM,
		InNavigation:           req.InNavigation,
		Stationary:             req.Stationary,
		ReplaceOptionalMetrics: true,
	}, now)

	h.liveHub().UpdateSubscriberLocation(deviceHash, *req.Lat, *req.Lon, meta.TrailID)
	broadcastDto := cachedMemberToDto(member, "", now)
	h.liveHub().PublishGroupEvent(code, "group_member_update", GroupMemberUpdateEventDto{
		Type:      "group_member_update",
		GroupCode: code,
		Member:    broadcastDto,
	})

	if ack := strings.TrimSpace(e.Request.URL.Query().Get("ack")); ack == "1" || strings.EqualFold(ack, "true") {
		return e.JSON(http.StatusOK, map[string]any{
			"ok":           true,
			"code":         code,
			"selfMemberId": member.MemberID,
			"expiresAt":    meta.ExpiresAt.UTC().Format(time.RFC3339),
		})
	}

	return e.JSON(http.StatusOK, buildGroupSessionDtoFromStore(store, meta, deviceHash, now))
}

// LeaveGroup handles POST /live/groups/{code}/leave in RAM and broadcasts `group_member_left`.
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
	store := h.readyStore(e.App)
	store.RemoveGroupMember(code, deviceHash)

	h.liveHub().PublishGroupEvent(code, "group_member_left", GroupMemberLeftDto{
		Type:      "group_member_left",
		GroupCode: code,
		MemberID:  selfMemberID,
	})

	return e.JSON(http.StatusOK, map[string]any{
		"ok":        true,
		"groupCode": code,
		"memberId":  selfMemberID,
	})
}

func cleanTrailGroupsGC(app core.App, store *live.LiveMemoryStore, now time.Time) error {
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
			"DELETE FROM trail_group_members WHERE last_seen = '' OR last_seen < {:cutoff}",
		).Bind(dbx.Params{"cutoff": staleMemberCutoff}).Execute(); err != nil {
			return err
		}
	}

	if store != nil {
		store.SweepGroupsGC(groupStaleMemberGCWindow, now)
	}
	return nil
}
