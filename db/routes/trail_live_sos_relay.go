package routes

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"pocketbase/util"
)

const (
	sosRelayMaxEpochFutureSkewSec = 120
	sosRelayMaxOriginDriftMeters  = 10000.0
	sosClaimDomainPrefix          = "trasee-sos-claim-v1:"
)

var (
	errSosRelayNotFound  = errors.New("relayed SOS alert not found")
	errSosRelayForbidden = errors.New("relayed SOS claim verification failed")
)

func normalizeLowerHexFixed(raw string, expectedLen int) (string, bool) {
	s := strings.ToLower(strings.TrimSpace(raw))
	if len(s) != expectedLen {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return "", false
		}
	}
	return s, true
}

// computeSosClaimHashFromSecret computes the canonical Lamport preimage commitment:
//
//	secretBytes, err := hex.DecodeString(strings.ToLower(strings.TrimSpace(sosClaimSecret))) // len 16
//	sum := sha256.Sum256(append([]byte("trasee-sos-claim-v1:"), secretBytes...))
//	sosClaimHash = hex.EncodeToString(sum[:8])
func computeSosClaimHashFromSecret(sosClaimSecret string) (string, bool) {
	normSecret, ok := normalizeLowerHexFixed(sosClaimSecret, 32)
	if !ok {
		return "", false
	}
	secretBytes, err := hex.DecodeString(normSecret)
	if err != nil || len(secretBytes) != 16 {
		return "", false
	}
	sum := sha256.Sum256(append([]byte(sosClaimDomainPrefix), secretBytes...))
	return hex.EncodeToString(sum[:8]), true
}

func verifySosClaimHashConstantTime(computedHash, storedHash string) bool {
	normComputed, ok1 := normalizeLowerHexFixed(computedHash, 16)
	normStored, ok2 := normalizeLowerHexFixed(storedHash, 16)
	if !ok1 || !ok2 {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(normComputed), []byte(normStored)) == 1
}

func clampRelayPacketEpoch(rawEpoch *float64, now time.Time, defaultToNow bool) (int64, bool) {
	maxEpoch := now.Unix() + sosRelayMaxEpochFutureSkewSec
	if rawEpoch == nil || math.IsNaN(*rawEpoch) || math.IsInf(*rawEpoch, 0) || *rawEpoch <= 0 {
		if defaultToNow {
			return now.Unix(), true
		}
		return 0, false
	}
	ep := int64(math.Round(*rawEpoch))
	if ep <= 0 {
		if defaultToNow {
			return now.Unix(), true
		}
		return 0, false
	}
	if ep > maxEpoch {
		ep = maxEpoch
	}
	return ep, true
}

type relaySosRequest struct {
	ClientSosID    string   `json:"clientSosId"`
	SosClaimHash   string   `json:"sosClaimHash"`
	Status         string   `json:"status"`
	SosClaimSecret string   `json:"sosClaimSecret"`
	TrailID        string   `json:"trailId"`
	Reason         string   `json:"reason"`
	Message        string   `json:"message"`
	RequesterName  string   `json:"requesterName"`
	Lat            *float64 `json:"lat"`
	Lon            *float64 `json:"lon"`
	Ele            *float64 `json:"ele"`
	PacketEpochSec *float64 `json:"packetEpochSec"`
	HopCount       *int     `json:"hopCount"`
}

// RelaySos handles POST /live/sos/relay for Store-and-Forward BLE mules.
// The uploading mule never becomes the SOS owner (`device_hash = ""` -> `isMine: false`).
func (h *TrailLiveHandler) RelaySos(e *core.RequestEvent) error {
	if err := verifyLiveInternalSecret(e); err != nil {
		return err
	}
	muleDeviceHash, err := requireDeviceHash(e)
	if err != nil {
		return err
	}

	var req relaySosRequest
	if err := e.BindBody(&req); err != nil {
		return e.BadRequestError("Invalid JSON body", err)
	}

	clientSosID, ok := normalizeLowerHexFixed(req.ClientSosID, 16)
	if !ok {
		return e.BadRequestError("Invalid clientSosId", nil)
	}

	status := strings.ToLower(strings.TrimSpace(req.Status))
	if status == "" {
		status = "active"
	}
	if !allowedSosStatuses[status] {
		return e.BadRequestError("Invalid SOS status", nil)
	}

	now := h.nowUTC()
	isResolution := status == "resolved" || status == "cancelled"

	if isResolution {
		var optionalClaimHash string
		if strings.TrimSpace(req.SosClaimHash) != "" {
			hVal, ok := normalizeLowerHexFixed(req.SosClaimHash, 16)
			if !ok {
				return e.BadRequestError("Invalid sosClaimHash", nil)
			}
			optionalClaimHash = hVal
		}

		computedSecretHash, ok := computeSosClaimHashFromSecret(req.SosClaimSecret)
		if !ok {
			return e.ForbiddenError("Valid sosClaimSecret is required to resolve relayed SOS", nil)
		}

		var sosRec *core.Record
		var respondingDevices map[string]bool
		shouldBroadcast := false

		txErr := e.App.RunInTransaction(func(txApp core.App) error {
			found, findErr := txApp.FindFirstRecordByFilter(
				"sos_alerts",
				"client_sos_id = {:cid}",
				dbx.Params{"cid": clientSosID},
			)
			if findErr != nil || found == nil {
				return errSosRelayNotFound
			}
			sosRec = found

			storedHash := sosRec.GetString("sos_claim_hash")
			if !verifySosClaimHashConstantTime(computedSecretHash, storedHash) {
				return errSosRelayForbidden
			}
			if optionalClaimHash != "" && !verifySosClaimHashConstantTime(optionalClaimHash, storedHash) {
				return errSosRelayForbidden
			}

			if sosRec.GetString("status") != status {
				sosRec.Set("status", status)
				if ep, hasEp := clampRelayPacketEpoch(req.PacketEpochSec, now, false); hasEp && ep > int64(sosRec.GetFloat("last_packet_epoch")) {
					sosRec.Set("last_packet_epoch", ep)
				}
				var statsErr error
				respondingDevices, statsErr = recomputeSosResponderStats(txApp, sosRec, now)
				if statsErr != nil {
					return statsErr
				}
				if saveErr := txApp.Save(sosRec); saveErr != nil {
					return saveErr
				}
				shouldBroadcast = true
			} else {
				respondingDevices, _ = loadActiveRespondersMap(txApp, sosRec.Id, now)
			}
			return nil
		})
		if txErr != nil {
			if errors.Is(txErr, errSosRelayNotFound) {
				return e.NotFoundError("SOS alert not found", nil)
			}
			if errors.Is(txErr, errSosRelayForbidden) {
				return e.ForbiddenError("Invalid sosClaimSecret for SOS alert", nil)
			}
			return txErr
		}

		if shouldBroadcast {
			h.broadcastSosRecord(sosRec, respondingDevices)
		}
		dto := toSosAlertDto(sosRec, muleDeviceHash, respondingDevices)
		return e.JSON(http.StatusOK, map[string]any{
			"sos":         dto,
			"pushTargets": []PushTargetDto{},
			"created":     false,
		})
	}

	// Active SOS alert relay path (`PKT_SOS_ALERT`).
	claimHash, ok := normalizeLowerHexFixed(req.SosClaimHash, 16)
	if !ok {
		return e.BadRequestError("Invalid sosClaimHash", nil)
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

	ele := 0.0
	if req.Ele != nil && !math.IsNaN(*req.Ele) && !math.IsInf(*req.Ele, 0) {
		ele = *req.Ele
	}
	trailID := strings.TrimSpace(req.TrailID)
	cleanMessage := sanitizePlainText(req.Message, 200)
	cleanRequester := sanitizePlainText(req.RequesterName, 40)

	sosCol, err := e.App.FindCachedCollectionByNameOrId("sos_alerts")
	if err != nil {
		return err
	}

	var sosRec *core.Record
	var respondingDevices map[string]bool
	created := false
	shouldBroadcast := false

	txErr := e.App.RunInTransaction(func(txApp core.App) error {
		existing, findErr := txApp.FindFirstRecordByFilter(
			"sos_alerts",
			"client_sos_id = {:cid}",
			dbx.Params{"cid": clientSosID},
		)
		if findErr != nil || existing == nil {
			clampedEpoch, _ := clampRelayPacketEpoch(req.PacketEpochSec, now, true)
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
			rec.Set("device_hash", "")
			rec.Set("client_sos_id", clientSosID)
			rec.Set("sos_claim_hash", claimHash)
			rec.Set("last_packet_epoch", clampedEpoch)
			rec.Set("relayed_by_hash", muleDeviceHash)
			rec.Set("responder_count", 0)
			rec.Set("nearest_distance_m", 0)
			rec.Set("nearest_eta_sec", 0)
			rec.Set("expires_at", toPBDateTime(now.Add(sosDefaultTTL)))

			if saveErr := txApp.Save(rec); saveErr != nil {
				return saveErr
			}
			sosRec = rec
			respondingDevices = map[string]bool{}
			created = true
			shouldBroadcast = true
			return nil
		}

		sosRec = existing
		if !verifySosClaimHashConstantTime(claimHash, sosRec.GetString("sos_claim_hash")) {
			return errSosRelayForbidden
		}

		clampedEpoch, hasEpoch := clampRelayPacketEpoch(req.PacketEpochSec, now, false)
		prevEpoch := int64(sosRec.GetFloat("last_packet_epoch"))

		if sosRec.GetString("status") == "active" && hasEpoch && clampedEpoch > prevEpoch {
			originLat := sosRec.GetFloat("origin_lat")
			originLon := sosRec.GetFloat("origin_lon")
			if originLat == 0 && originLon == 0 {
				originLat = sosRec.GetFloat("lat")
				originLon = sosRec.GetFloat("lon")
			}
			driftM := util.HaversineDistanceMeters(originLat, originLon, *req.Lat, *req.Lon)
			if driftM <= sosRelayMaxOriginDriftMeters {
				sosRec.Set("lat", *req.Lat)
				sosRec.Set("lon", *req.Lon)
				sosRec.Set("ele", ele)
				sosRec.Set("last_packet_epoch", clampedEpoch)
				if sosRec.GetString("trail_id") == "" && trailID != "" {
					sosRec.Set("trail_id", trailID)
				}
				if sosRec.GetString("message") == "" && cleanMessage != "" {
					sosRec.Set("message", cleanMessage)
				}
				if sosRec.GetString("requester_name") == "" && cleanRequester != "" {
					sosRec.Set("requester_name", cleanRequester)
				}

				var statsErr error
				respondingDevices, statsErr = recomputeSosResponderStats(txApp, sosRec, now)
				if statsErr != nil {
					return statsErr
				}
				if saveErr := txApp.Save(sosRec); saveErr != nil {
					return saveErr
				}
				shouldBroadcast = true
				return nil
			}
		}

		respondingDevices, _ = loadActiveRespondersMap(txApp, sosRec.Id, now)
		return nil
	})
	if txErr != nil {
		if errors.Is(txErr, errSosRelayForbidden) {
			return e.ForbiddenError("Invalid sosClaimHash for existing SOS alert", nil)
		}
		return txErr
	}

	pushTargets := []PushTargetDto{}
	if created {
		pts, ptErr := selectSosPushTargets(
			e.App,
			muleDeviceHash,
			sosRec.GetString("trail_id"),
			sosRec.GetFloat("lat"),
			sosRec.GetFloat("lon"),
			now,
		)
		if ptErr != nil {
			return ptErr
		}
		if len(pts) > 0 {
			pushTargets = pts
		}
	}

	if shouldBroadcast {
		h.broadcastSosRecord(sosRec, respondingDevices)
	}

	dto := toSosAlertDto(sosRec, muleDeviceHash, respondingDevices)
	return e.JSON(http.StatusOK, map[string]any{
		"sos":         dto,
		"pushTargets": pushTargets,
		"created":     created,
	})
}
