package routes

import (
	"cmp"
	"fmt"
	"hash/fnv"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/twpayne/go-polyline"

	"pocketbase/services/live"
)

var hubStoreRegistry sync.Map // map[*live.TrailLiveHub]*live.LiveMemoryStore

func storeForHub(hub *live.TrailLiveHub) *live.LiveMemoryStore {
	if hub == nil || hub == live.DefaultHub() {
		return live.DefaultMemoryStore()
	}
	if v, ok := hubStoreRegistry.Load(hub); ok {
		return v.(*live.LiveMemoryStore)
	}
	fresh := live.NewLiveMemoryStore()
	actual, _ := hubStoreRegistry.LoadOrStore(hub, fresh)
	return actual.(*live.LiveMemoryStore)
}

func recordToCachedReport(rec *core.Record) live.CachedReport {
	created := rec.GetDateTime("created").Time().UTC()
	if created.IsZero() {
		created = time.Now().UTC()
	}
	lastConf := rec.GetDateTime("last_confirmed_at").Time().UTC()
	if lastConf.IsZero() {
		lastConf = created
	}
	isPerm := rec.GetBool("is_permanent")
	if meta, ok := reportCategories[rec.GetString("category")]; ok && meta.IsPermanent {
		isPerm = true
	}
	var exp time.Time
	if !isPerm {
		exp = rec.GetDateTime("expires_at").Time().UTC()
	}
	photoFile := strings.TrimSpace(rec.GetString("photo"))
	return live.CachedReport{
		ID:              rec.Id,
		TrailID:         rec.GetString("trail_id"),
		Category:        rec.GetString("category"),
		Kind:            rec.GetString("kind"),
		IsPermanent:     isPerm,
		ConditionStatus: rec.GetString("condition_status"),
		Note:            rec.GetString("note"),
		Lat:             rec.GetFloat("lat"),
		Lon:             rec.GetFloat("lon"),
		Ele:             rec.GetFloat("ele"),
		AlongTrackM:     rec.GetFloat("along_track_m"),
		PhotoFile:       photoFile,
		PhotoVerified:   photoFile != "" && rec.GetBool("photo_verified"),
		DeviceHash:      rec.GetString("device_hash"),
		AuthorActor:     rec.GetString("author_actor"),
		ConfirmCount:    rec.GetInt("confirm_count"),
		DismissCount:    rec.GetInt("dismiss_count"),
		SpamCount:       rec.GetInt("spam_count"),
		CreatedAt:       created,
		LastConfirmedAt: lastConf,
		ExpiresAt:       exp,
	}
}

func cachedReportToDto(rep live.CachedReport) TrailReportDto {
	createdStr := rep.CreatedAt.UTC().Format(time.RFC3339)
	lastConfStr := createdStr
	if !rep.LastConfirmedAt.IsZero() {
		lastConfStr = rep.LastConfirmedAt.UTC().Format(time.RFC3339)
	}
	var expPtr *string
	if !rep.IsPermanent && !rep.ExpiresAt.IsZero() {
		s := rep.ExpiresAt.UTC().Format(time.RFC3339)
		expPtr = &s
	}
	var alongPtr *float64
	if rep.AlongTrackM >= 0 {
		v := rep.AlongTrackM
		alongPtr = &v
	}
	photoUrlPtr, photoThumbUrlPtr := reportPhotoURLs(rep.ID, rep.PhotoFile)
	return TrailReportDto{
		ID:              rep.ID,
		TrailID:         rep.TrailID,
		Category:        rep.Category,
		Kind:            rep.Kind,
		IsPermanent:     rep.IsPermanent,
		ConditionStatus: rep.ConditionStatus,
		Note:            rep.Note,
		Lat:             rep.Lat,
		Lon:             rep.Lon,
		Ele:             rep.Ele,
		AlongTrackM:     alongPtr,
		PhotoUrl:        photoUrlPtr,
		PhotoThumbUrl:   photoThumbUrlPtr,
		PhotoVerified:   photoUrlPtr != nil && rep.PhotoVerified,
		ConfirmCount:    rep.ConfirmCount,
		DismissCount:    rep.DismissCount,
		CreatedAt:       createdStr,
		LastConfirmedAt: lastConfStr,
		ExpiresAt:       expPtr,
	}
}

func recordToCachedSos(rec *core.Record) live.CachedSosAlert {
	created := rec.GetDateTime("created").Time().UTC()
	if created.IsZero() {
		created = time.Now().UTC()
	}
	return live.CachedSosAlert{
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
		OriginLat:        rec.GetFloat("origin_lat"),
		OriginLon:        rec.GetFloat("origin_lon"),
		DeviceHash:       rec.GetString("device_hash"),
		SosClaimHash:     rec.GetString("sos_claim_hash"),
		LastPacketEpoch:  int64(rec.GetFloat("last_packet_epoch")),
		RelayedByHash:    rec.GetString("relayed_by_hash"),
		ResponderCount:   rec.GetInt("responder_count"),
		NearestDistanceM: rec.GetFloat("nearest_distance_m"),
		NearestEtaSec:    rec.GetInt("nearest_eta_sec"),
		CreatedAt:        created,
		ExpiresAt:        rec.GetDateTime("expires_at").Time().UTC(),
	}
}

func cachedSosToDto(alert live.CachedSosAlert, callerDeviceHash string, respondingDevices map[string]bool) SosAlertDto {
	createdStr := alert.CreatedAt.UTC().Format(time.RFC3339)
	var expPtr *string
	if !alert.ExpiresAt.IsZero() {
		s := alert.ExpiresAt.UTC().Format(time.RFC3339)
		expPtr = &s
	}
	var nearestEtaPtr *int
	var nearestDistPtr *float64
	if alert.ResponderCount > 0 {
		eta := alert.NearestEtaSec
		dist := alert.NearestDistanceM
		nearestEtaPtr = &eta
		nearestDistPtr = &dist
	}
	isMine := callerDeviceHash != "" && alert.DeviceHash != "" && callerDeviceHash == alert.DeviceHash
	amResponding := callerDeviceHash != "" && respondingDevices[callerDeviceHash]

	return SosAlertDto{
		ID:               alert.ID,
		ClientSosID:      alert.ClientSosID,
		TrailID:          alert.TrailID,
		Status:           alert.Status,
		Reason:           alert.Reason,
		Message:          alert.Message,
		RequesterName:    alert.RequesterName,
		Lat:              alert.Lat,
		Lon:              alert.Lon,
		Ele:              alert.Ele,
		ResponderCount:   alert.ResponderCount,
		NearestEtaSec:    nearestEtaPtr,
		NearestDistanceM: nearestDistPtr,
		IsMine:           isMine,
		AmResponding:     amResponding,
		CreatedAt:        createdStr,
		ExpiresAt:        expPtr,
	}
}

// HydrateLiveMemoryStore loads durable reports, active SOS alerts, push subscriptions,
// and active trail_groups into store once on startup (or lazy test init).
func HydrateLiveMemoryStore(app core.App, store *live.LiveMemoryStore) error {
	return store.EnsureHydrated(func(s *live.LiveMemoryStore) error {
		if reports, err := app.FindRecordsByFilter(
			"trail_reports",
			"condition_status = 'active' || condition_status = 'dry_or_closed'",
			"",
			0,
			0,
			nil,
		); err == nil {
			for _, rec := range reports {
				s.UpsertReport(recordToCachedReport(rec))
			}
		}

		if sosList, err := app.FindRecordsByFilter(
			"sos_alerts",
			"status = 'active'",
			"",
			0,
			0,
			nil,
		); err == nil {
			for _, rec := range sosList {
				s.UpsertSos(recordToCachedSos(rec))
				if resps, rErr := app.FindRecordsByFilter(
					"sos_responders",
					"sos_id = {:sid} && status = 'coming'",
					"",
					0,
					0,
					dbx.Params{"sid": rec.Id},
				); rErr == nil {
					for _, r := range resps {
						s.UpsertSosResponder(live.CachedSosResponder{
							RecordID:   r.Id,
							SosID:      rec.Id,
							DeviceHash: r.GetString("device_hash"),
							Lat:        r.GetFloat("lat"),
							Lon:        r.GetFloat("lon"),
							Ele:        r.GetFloat("ele"),
							DistanceM:  r.GetFloat("distance_m"),
							EtaSec:     r.GetInt("eta_sec"),
							Status:     r.GetString("status"),
							LastSeen:   r.GetDateTime("last_seen").Time().UTC(),
						})
					}
				}
			}
		}

		if subs, err := app.FindAllRecords("push_subscriptions"); err == nil {
			for _, sub := range subs {
				s.UpsertPushSub(live.PushSubEntry{
					ID:         sub.Id,
					DeviceHash: sub.GetString("device_hash"),
					Endpoint:   sub.GetString("endpoint"),
					P256dh:     sub.GetString("p256dh"),
					Auth:       sub.GetString("auth"),
					Lat:        sub.GetFloat("lat"),
					Lon:        sub.GetFloat("lon"),
					TrailID:    sub.GetString("trail_id"),
				}, true)
			}
		}

		if groups, err := app.FindAllRecords("trail_groups"); err == nil {
			for _, g := range groups {
				s.UpsertGroup(live.CachedGroup{
					RecordID:        g.Id,
					Code:            g.GetString("code"),
					TrailID:         g.GetString("trail_id"),
					OwnerDeviceHash: g.GetString("owner_device_hash"),
					ExpiresAt:       g.GetDateTime("expires_at").Time().UTC(),
					LastDBSyncAt:    g.GetDateTime("updated").Time().UTC(),
				})
			}
		}
		return nil
	})
}

func resolveTrailCorridorCached(app core.App, store *live.LiveMemoryStore, trailID string, refLat, refLon float64, hasRefCoords bool) [][2]float64 {
	trailID = strings.TrimSpace(trailID)
	if trailID != "" {
		if cached, ok := store.GetTrailCorridor(trailID); ok {
			return cached
		}
		if trailRec, err := app.FindRecordById("trails", trailID); err == nil && trailRec != nil {
			if poly := strings.TrimSpace(trailRec.GetString("polyline")); poly != "" {
				if decoded, _, decErr := polyline.DecodeCoords([]byte(poly)); decErr == nil && len(decoded) > 0 {
					compact := make([][2]float64, len(decoded))
					for i, pt := range decoded {
						compact[i] = [2]float64{pt[0], pt[1]}
					}
					store.PutTrailCorridor(trailID, compact)
					return compact
				}
			}
			tLat := trailRec.GetFloat("lat")
			tLon := trailRec.GetFloat("lon")
			if tLat != 0 || tLon != 0 {
				single := [][2]float64{{tLat, tLon}}
				store.PutTrailCorridor(trailID, single)
				return single
			}
		}
	}
	if hasRefCoords {
		return [][2]float64{{refLat, refLon}}
	}
	return nil
}

// computeLiveStateHash computes a deterministic 64-bit FNV-1a hex digest over reports + sosAlerts sorted ascending by ID.
func computeLiveStateHash(reports []TrailReportDto, sosAlerts []SosAlertDto) string {
	repIdx := make([]int, len(reports))
	for i := range repIdx {
		repIdx[i] = i
	}
	slices.SortFunc(repIdx, func(a, b int) int {
		return cmp.Compare(reports[a].ID, reports[b].ID)
	})

	sosIdx := make([]int, len(sosAlerts))
	for i := range sosIdx {
		sosIdx[i] = i
	}
	slices.SortFunc(sosIdx, func(a, b int) int {
		return cmp.Compare(sosAlerts[a].ID, sosAlerts[b].ID)
	})

	h := fnv.New64a()
	var numBuf [32]byte
	writeStr := func(s string) {
		_, _ = h.Write([]byte(s))
		_, _ = h.Write([]byte{0})
	}
	writeInt := func(v int) {
		_, _ = h.Write(strconv.AppendInt(numBuf[:0], int64(v), 10))
		_, _ = h.Write([]byte{0})
	}
	writeFloat := func(v float64) {
		_, _ = h.Write(strconv.AppendFloat(numBuf[:0], v, 'f', 5, 64))
		_, _ = h.Write([]byte{0})
	}

	writeInt(len(repIdx))
	for _, idx := range repIdx {
		r := reports[idx]
		writeStr(r.ID)
		writeStr(r.ConditionStatus)
		writeInt(r.ConfirmCount)
		writeInt(r.DismissCount)
		writeStr(r.LastConfirmedAt)
		if r.ExpiresAt != nil {
			writeStr(*r.ExpiresAt)
		}
		writeStr(r.Note)
		if r.PhotoUrl != nil {
			writeStr(*r.PhotoUrl)
		}
		if r.PhotoVerified {
			writeInt(1)
		} else {
			writeInt(0)
		}
	}

	writeInt(len(sosIdx))
	for _, idx := range sosIdx {
		s := sosAlerts[idx]
		writeStr(s.ID)
		writeStr(s.Status)
		writeFloat(s.Lat)
		writeFloat(s.Lon)
		writeInt(s.ResponderCount)
		if s.NearestEtaSec != nil {
			writeInt(*s.NearestEtaSec)
		}
		if s.NearestDistanceM != nil {
			writeFloat(*s.NearestDistanceM)
		}
		if s.IsMine {
			writeInt(1)
		} else {
			writeInt(0)
		}
		if s.AmResponding {
			writeInt(1)
		} else {
			writeInt(0)
		}
	}
	return fmt.Sprintf("%016x", h.Sum64())
}

func flushDirtyPushSubsToDB(app core.App, store *live.LiveMemoryStore) error {
	dirty := store.DrainDirtyPushSubs()
	if len(dirty) == 0 {
		return nil
	}
	return app.RunInTransaction(func(txApp core.App) error {
		for _, sub := range dirty {
			_, err := txApp.DB().NewQuery(
				"UPDATE push_subscriptions SET lat = {:lat}, lon = {:lon}, trail_id = {:trail} WHERE id = {:id}",
			).Bind(dbx.Params{
				"lat":   sub.SavedLat,
				"lon":   sub.SavedLon,
				"trail": sub.SavedTrail,
				"id":    sub.ID,
			}).Execute()
			if err != nil {
				return err
			}
		}
		return nil
	})
}
