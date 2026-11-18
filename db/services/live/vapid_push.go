package live

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

const (
	// DefaultVapidSubject matches vapid_push.ts.
	DefaultVapidSubject   = "mailto:trasee@skillfy.ro"
	vapidKeyFileName      = ".vapid_keys.json"
	maxConcurrentPushSend = 8
	defaultPushTimeout    = 10 * time.Second
)

var sosReasonLabelsRo = map[string]string{
	"lost":       "Rătăcit",
	"injury":     "Accidentare",
	"exhaustion": "Epuizare / Fără apă",
	"other":      "Ajutor pe traseu",
}

// VapidKeyPair stores base64url P-256 keys for RFC 8292 ES256 signing.
type VapidKeyPair struct {
	PublicKey  string `json:"publicKey"`
	PrivateKey string `json:"privateKey"`
}

// SosPushAlertInfo holds fields needed to build an SOS Web Push notification.
type SosPushAlertInfo struct {
	ID            string
	TrailID       string
	Reason        string
	Message       string
	RequesterName string
}

// SosPushTarget describes a Web Push subscription within 5 km of the SOS alert.
type SosPushTarget struct {
	Endpoint  string
	P256dh    string
	Auth      string
	DistanceM float64
}

// SosPushPayload matches web/src/service-worker.ts expectations.
type SosPushPayload struct {
	Type    string `json:"type"`
	SosID   string `json:"sosId"`
	TrailID string `json:"trailId"`
	Title   string `json:"title"`
	Body    string `json:"body"`
	URL     string `json:"url"`
}

// DispatchSummary reports the outcome of sending a batch of Web Push notifications.
type DispatchSummary struct {
	Sent         int `json:"sent"`
	StaleRemoved int `json:"staleRemoved"`
	Failed       int `json:"failed"`
}

// GenerateTestSubscriberKeys generates a valid base64url P-256 keypair for unit tests.
func GenerateTestSubscriberKeys() (privateKey, publicKey string, err error) {
	return webpush.GenerateVAPIDKeys()
}

func formatDistanceRo(distanceM float64, hasDistance bool) string {
	if !hasDistance || math.IsNaN(distanceM) || math.IsInf(distanceM, 0) || distanceM < 0 {
		return ""
	}
	if distanceM >= 1000 {
		return fmt.Sprintf("la %.1f km", distanceM/1000.0)
	}
	return fmt.Sprintf("la %d m", int(math.Round(distanceM)))
}

// BuildSosPushPayload constructs the exact JSON message expected by web/src/service-worker.ts.
func BuildSosPushPayload(sos SosPushAlertInfo, distanceM float64, hasDistance bool) SosPushPayload {
	trailID := strings.TrimSpace(sos.TrailID)
	rawReason := strings.TrimSpace(sos.Reason)
	reasonLabel := sosReasonLabelsRo[rawReason]
	if reasonLabel == "" {
		if rawReason != "" {
			reasonLabel = rawReason
		} else {
			reasonLabel = "Ajutor pe traseu"
		}
	}

	headerParts := make([]string, 0, 3)
	headerParts = append(headerParts, reasonLabel)
	if reqName := strings.TrimSpace(sos.RequesterName); reqName != "" {
		headerParts = append(headerParts, "("+reqName+")")
	}
	if distPart := formatDistanceRo(distanceM, hasDistance); distPart != "" {
		headerParts = append(headerParts, distPart)
	}
	header := strings.Join(headerParts, " · ")

	body := header
	if msg := strings.TrimSpace(sos.Message); msg != "" {
		body = header + " — " + msg
	}

	targetURL := "/map?sos=" + sos.ID
	if trailID != "" {
		targetURL = "/map/trail/@romania/" + trailID + "/navigate?sos=" + sos.ID
	}

	return SosPushPayload{
		Type:    "sos_alert",
		SosID:   sos.ID,
		TrailID: trailID,
		Title:   "🆘 Ajutor solicitat în apropiere!",
		Body:    body,
		URL:     targetURL,
	}
}

// VapidDispatcher manages VAPID keys and bounded parallel SOS Web Push delivery.
type VapidDispatcher struct {
	mu         sync.Mutex
	dataDir    string
	subject    string
	httpClient *http.Client
	cachedKeys *VapidKeyPair
}

// NewVapidDispatcher creates a dispatcher bound to PocketBase's dataDir.
func NewVapidDispatcher(dataDir string, customClient *http.Client) *VapidDispatcher {
	if customClient == nil {
		customClient = &http.Client{Timeout: defaultPushTimeout}
	}
	subj := strings.TrimSpace(os.Getenv("VAPID_SUBJECT"))
	if subj == "" {
		subj = DefaultVapidSubject
	}
	return &VapidDispatcher{
		dataDir:    dataDir,
		subject:    subj,
		httpClient: customClient,
	}
}

func readPersistedVapidFile(path string) (*VapidKeyPair, bool) {
	if strings.TrimSpace(path) == "" {
		return nil, false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	var parsed VapidKeyPair
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, false
	}
	parsed.PublicKey = strings.TrimSpace(parsed.PublicKey)
	parsed.PrivateKey = strings.TrimSpace(parsed.PrivateKey)
	if parsed.PublicKey == "" || parsed.PrivateKey == "" {
		return nil, false
	}
	return &parsed, true
}

func persistVapidFileAtomically(dir string, keys VapidKeyPair) {
	if strings.TrimSpace(dir) == "" {
		return
	}
	_ = os.MkdirAll(dir, 0o755)
	finalPath := filepath.Join(dir, vapidKeyFileName)
	tmpPath := fmt.Sprintf("%s.%d.%d.tmp", finalPath, os.Getpid(), time.Now().UnixNano())
	encoded, err := json.MarshalIndent(keys, "", "  ")
	if err != nil {
		return
	}
	if err := os.WriteFile(tmpPath, encoded, 0o600); err != nil {
		_ = os.Remove(tmpPath)
		return
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		_ = os.Remove(tmpPath)
	}
}

// EnsureKeys loads or generates the VAPID keypair (env -> <dataDir>/.vapid_keys.json -> legacy -> generate).
func (d *VapidDispatcher) EnsureKeys() (VapidKeyPair, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if envPub, envPriv := strings.TrimSpace(os.Getenv("VAPID_PUBLIC_KEY")), strings.TrimSpace(os.Getenv("VAPID_PRIVATE_KEY")); envPub != "" && envPriv != "" {
		pair := VapidKeyPair{PublicKey: envPub, PrivateKey: envPriv}
		d.cachedKeys = &pair
		return pair, nil
	}

	if d.cachedKeys != nil {
		return *d.cachedKeys, nil
	}

	primaryPath := filepath.Join(d.dataDir, vapidKeyFileName)
	if persisted, ok := readPersistedVapidFile(primaryPath); ok {
		d.cachedKeys = persisted
		return *persisted, nil
	}

	if legacyPath := strings.TrimSpace(os.Getenv("VAPID_LEGACY_KEY_FILE")); legacyPath != "" {
		if migrated, ok := readPersistedVapidFile(legacyPath); ok {
			persistVapidFileAtomically(d.dataDir, *migrated)
			d.cachedKeys = migrated
			return *migrated, nil
		}
	}

	priv, pub, err := webpush.GenerateVAPIDKeys()
	if err != nil {
		return VapidKeyPair{}, err
	}
	generated := VapidKeyPair{
		PublicKey:  pub,
		PrivateKey: priv,
	}
	persistVapidFileAtomically(d.dataDir, generated)
	d.cachedKeys = &generated
	return generated, nil
}

// PublicKey returns the base64url VAPID public key.
func (d *VapidDispatcher) PublicKey() (string, error) {
	keys, err := d.EnsureKeys()
	if err != nil {
		return "", err
	}
	return keys.PublicKey, nil
}

// DispatchSosPush encrypts RFC 8291 (aes128gcm) payloads and sends them via a bounded worker pool.
func (d *VapidDispatcher) DispatchSosPush(
	ctx context.Context,
	sos SosPushAlertInfo,
	targets []SosPushTarget,
	onStaleEndpoint func(endpoint string),
) DispatchSummary {
	if len(targets) == 0 {
		return DispatchSummary{}
	}
	keys, err := d.EnsureKeys()
	if err != nil {
		return DispatchSummary{Failed: len(targets)}
	}

	sem := make(chan struct{}, maxConcurrentPushSend)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var summary DispatchSummary

	for _, target := range targets {
		t := target
		endpoint := strings.TrimSpace(t.Endpoint)
		p256dh := strings.TrimSpace(t.P256dh)
		auth := strings.TrimSpace(t.Auth)
		if endpoint == "" || p256dh == "" || auth == "" {
			mu.Lock()
			summary.Failed++
			mu.Unlock()
			continue
		}

		wg.Add(1)
		go func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				mu.Lock()
				summary.Failed++
				mu.Unlock()
				return
			}

			payload := BuildSosPushPayload(sos, t.DistanceM, true)
			rawPayload, encErr := json.Marshal(payload)
			if encErr != nil {
				mu.Lock()
				summary.Failed++
				mu.Unlock()
				return
			}

			resp, sendErr := webpush.SendNotificationWithContext(
				ctx,
				rawPayload,
				&webpush.Subscription{
					Endpoint: endpoint,
					Keys: webpush.Keys{
						P256dh: p256dh,
						Auth:   auth,
					},
				},
				&webpush.Options{
					HTTPClient:      d.httpClient,
					Subscriber:      d.subject,
					VAPIDPublicKey:  keys.PublicKey,
					VAPIDPrivateKey: keys.PrivateKey,
					TTL:             3600,
					Urgency:         webpush.UrgencyHigh,
				},
			)
			if resp != nil && resp.Body != nil {
				_ = resp.Body.Close()
			}

			statusCode := 0
			if resp != nil {
				statusCode = resp.StatusCode
			}
			if statusCode == http.StatusNotFound || statusCode == http.StatusGone {
				mu.Lock()
				summary.StaleRemoved++
				mu.Unlock()
				if onStaleEndpoint != nil {
					onStaleEndpoint(endpoint)
				}
				return
			}
			if sendErr != nil || statusCode < 200 || statusCode >= 300 {
				mu.Lock()
				summary.Failed++
				mu.Unlock()
				return
			}

			mu.Lock()
			summary.Sent++
			mu.Unlock()
		}()
	}

	wg.Wait()
	return summary
}

// DispatchSosPushAsync dispatches SOS Web Push notifications asynchronously with a 30s timeout.
func (d *VapidDispatcher) DispatchSosPushAsync(
	sos SosPushAlertInfo,
	targets []SosPushTarget,
	onStaleEndpoint func(endpoint string),
) {
	if d == nil || len(targets) == 0 {
		return
	}
	copied := make([]SosPushTarget, len(targets))
	copy(copied, targets)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = d.DispatchSosPush(ctx, sos, copied, onStaleEndpoint)
	}()
}
