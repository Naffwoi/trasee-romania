package live

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

func TestVapidDispatcherPersistsAndReloadsAtomicKeyPair(t *testing.T) {
	t.Setenv("VAPID_PUBLIC_KEY", "")
	t.Setenv("VAPID_PRIVATE_KEY", "")
	t.Setenv("VAPID_LEGACY_KEY_FILE", "")

	dir := t.TempDir()
	d1 := NewVapidDispatcher(dir, nil)
	pub1, err := d1.PublicKey()
	if err != nil || len(pub1) < 60 {
		t.Fatalf("expected valid generated VAPID public key, got %q (err=%v)", pub1, err)
	}

	keyPath := filepath.Join(dir, ".vapid_keys.json")
	info, statErr := os.Stat(keyPath)
	if statErr != nil {
		t.Fatalf("expected persisted .vapid_keys.json at %s: %v", keyPath, statErr)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("expected 0600 permissions on .vapid_keys.json, got %o", info.Mode().Perm())
	}

	d2 := NewVapidDispatcher(dir, nil)
	pub2, err := d2.PublicKey()
	if err != nil || pub2 != pub1 {
		t.Fatalf("reloaded VAPID public key mismatch: got=%q want=%q err=%v", pub2, pub1, err)
	}
}

func TestBuildSosPushPayloadMatchesWebPwaServiceWorkerContract(t *testing.T) {
	payload := BuildSosPushPayload(SosPushAlertInfo{
		ID:            "sos123456789abc",
		TrailID:       "ayl2z0tf824rp3n",
		Reason:        "injury",
		Message:       "Gleznă luxată sub șa",
		RequesterName: "Andrei",
	}, 1420, true)

	if payload.Type != "sos_alert" {
		t.Fatalf("unexpected type: %q", payload.Type)
	}
	if payload.Title != "🆘 Ajutor solicitat în apropiere!" {
		t.Fatalf("unexpected title: %q", payload.Title)
	}
	wantBody := "Accidentare · (Andrei) · la 1.4 km — Gleznă luxată sub șa"
	if payload.Body != wantBody {
		t.Fatalf("body mismatch:\ngot:  %q\nwant: %q", payload.Body, wantBody)
	}
	wantURL := "/map/trail/@romania/ayl2z0tf824rp3n/navigate?sos=sos123456789abc"
	if payload.URL != wantURL {
		t.Fatalf("url mismatch: got=%q want=%q", payload.URL, wantURL)
	}
}

func TestDispatchSosPushSendsEncryptedRFC8291AndRemoves410Endpoints(t *testing.T) {
	var delivered atomic.Int32
	var goneHit atomic.Int32

	pushSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Encoding") != "aes128gcm" {
			t.Errorf("expected RFC 8291 aes128gcm encoding, got %q", r.Header.Get("Content-Encoding"))
		}
		if r.Header.Get("Urgency") != "high" {
			t.Errorf("expected Urgency=high header, got %q", r.Header.Get("Urgency"))
		}
		if r.URL.Path == "/gone" {
			goneHit.Add(1)
			w.WriteHeader(http.StatusGone)
			return
		}
		delivered.Add(1)
		w.WriteHeader(http.StatusCreated)
	}))
	defer pushSrv.Close()

	subPriv, subPub, err := GenerateTestSubscriberKeys()
	if err != nil {
		t.Fatalf("generate subscriber keys: %v", err)
	}
	_ = subPriv

	dir := t.TempDir()
	dispatcher := NewVapidDispatcher(dir, pushSrv.Client())

	var mu sync.Mutex
	var staleRemoved []string

	targets := []SosPushTarget{
		{
			Endpoint:  pushSrv.URL + "/ok",
			P256dh:    subPub,
			Auth:      "dGVzdC1hdXRoLTE2Ynl0ZXM",
			DistanceM: 350,
		},
		{
			Endpoint:  pushSrv.URL + "/gone",
			P256dh:    subPub,
			Auth:      "dGVzdC1hdXRoLTE2Ynl0ZXM",
			DistanceM: 800,
		},
	}

	summary := dispatcher.DispatchSosPush(
		context.Background(),
		SosPushAlertInfo{
			ID:      "sos999",
			TrailID: "trail1",
			Reason:  "lost",
		},
		targets,
		func(staleEndpoint string) {
			mu.Lock()
			staleRemoved = append(staleRemoved, staleEndpoint)
			mu.Unlock()
		},
	)

	if summary.Sent != 1 || summary.StaleRemoved != 1 || summary.Failed != 0 {
		raw, _ := json.Marshal(summary)
		t.Fatalf("unexpected dispatch summary: %s (delivered=%d gone=%d)", raw, delivered.Load(), goneHit.Load())
	}
	if len(staleRemoved) != 1 || staleRemoved[0] != pushSrv.URL+"/gone" {
		t.Fatalf("expected /gone endpoint to be reported stale, got %v", staleRemoved)
	}
}
