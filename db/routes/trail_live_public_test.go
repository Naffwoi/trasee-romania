package routes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/pocketbase/pocketbase/apis"

	"pocketbase/services/live"
)

func buildPublicLiveTestMux(t *testing.T, pushClient *http.Client) (http.Handler, *TrailLiveHandler) {
	t.Helper()
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	pbRouter, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("apis.NewRouter: %v", err)
	}
	hub := live.NewTrailLiveHub()
	handler := NewTrailLiveHandler(hub)
	handler.Vapid = live.NewVapidDispatcher(app.DataDir(), pushClient)
	handler.RateLimiters = live.NewDefaultLiveRateLimiterSet()
	handler.ActorCache = NewActorIDCache(0)

	registerTrailLiveRouterGroups(pbRouter, handler)
	mux, err := pbRouter.BuildMux()
	if err != nil {
		t.Fatalf("BuildMux: %v", err)
	}
	return mux, handler
}

func TestPublicLiveHeartbeatValidatesDeviceTokenStripsSpoofedHeadersAndRateLimits(t *testing.T) {
	mux, _ := buildPublicLiveTestMux(t, nil)
	validToken := strings.Repeat("d", 64)

	// 1. Missing X-Device-Token -> 400 {"message":"invalid_device_token"} even if attacker spoofs X-Device-Hash + X-Internal-Secret
	spoofReq := httptest.NewRequest(http.MethodPost, "/api/v1/live/heartbeat", strings.NewReader(`{"lat":45.408,"lon":25.542}`))
	spoofReq.Header.Set("Content-Type", "application/json")
	spoofReq.Header.Set("X-Device-Hash", strings.Repeat("f", 64))
	spoofReq.Header.Set("X-Internal-Secret", testLiveSecret)
	spoofRec := httptest.NewRecorder()
	mux.ServeHTTP(spoofRec, spoofReq)
	if spoofRec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 when X-Device-Token is missing despite spoofed headers, got %d (%s)", spoofRec.Code, spoofRec.Body.String())
	}

	// 2. 6 valid heartbeats in 60s -> 200 OK; 7th -> 429 + Retry-After
	for i := 0; i < 6; i++ {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/live/heartbeat", strings.NewReader(`{"lat":45.408,"lon":25.542,"inNavigation":true}`))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Device-Token", validToken)
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("heartbeat #%d expected 200, got %d: %s", i+1, rec.Code, rec.Body.String())
		}
	}

	req7 := httptest.NewRequest(http.MethodPost, "/api/v1/live/heartbeat", strings.NewReader(`{"lat":45.408,"lon":25.542}`))
	req7.Header.Set("Content-Type", "application/json")
	req7.Header.Set("X-Device-Token", validToken)
	rec7 := httptest.NewRecorder()
	mux.ServeHTTP(rec7, req7)
	if rec7.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on 7th heartbeat in 60s, got %d: %s", rec7.Code, rec7.Body.String())
	}
	if rec7.Header().Get("Retry-After") == "" {
		t.Fatalf("expected Retry-After header on 429 response")
	}
}

func TestPublicLiveSosDispatchesNativeWebPushAndNeverLeaksPushTargets(t *testing.T) {
	var pushReceived atomic.Int32
	doneCh := make(chan struct{}, 1)
	pushSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pushReceived.Add(1)
		w.WriteHeader(http.StatusCreated)
		select {
		case doneCh <- struct{}{}:
		default:
		}
	}))
	defer pushSrv.Close()

	mux, _ := buildPublicLiveTestMux(t, pushSrv.Client())

	// 1. Verify GET /api/v1/live/push/vapid-public-key
	vapidReq := httptest.NewRequest(http.MethodGet, "/api/v1/live/push/vapid-public-key", nil)
	vapidRec := httptest.NewRecorder()
	mux.ServeHTTP(vapidRec, vapidReq)
	if vapidRec.Code != http.StatusOK {
		t.Fatalf("vapid-public-key expected 200, got %d: %s", vapidRec.Code, vapidRec.Body.String())
	}
	var vapidBody map[string]string
	_ = json.Unmarshal(vapidRec.Body.Bytes(), &vapidBody)
	if len(vapidBody["publicKey"]) < 60 {
		t.Fatalf("expected valid publicKey, got %v", vapidBody)
	}

	// 2. Nearby hiker B subscribes to Web Push
	_, subPub, err := live.GenerateTestSubscriberKeys()
	if err != nil {
		t.Fatalf("GenerateTestSubscriberKeys: %v", err)
	}
	hikerBToken := strings.Repeat("b", 64)
	subBody, _ := json.Marshal(map[string]any{
		"endpoint": pushSrv.URL + "/notify-b",
		"keys": map[string]string{
			"p256dh": subPub,
			"auth":   "dGVzdC1hdXRoLTE2Ynl0ZXM",
		},
		"lat":     45.4085,
		"lon":     25.5425,
		"trailId": "bucegi-1",
	})
	subReq := httptest.NewRequest(http.MethodPost, "/api/v1/live/push/subscribe", strings.NewReader(string(subBody)))
	subReq.Header.Set("Content-Type", "application/json")
	subReq.Header.Set("X-Device-Token", hikerBToken)
	subRec := httptest.NewRecorder()
	mux.ServeHTTP(subRec, subReq)
	if subRec.Code != http.StatusOK {
		t.Fatalf("push subscribe expected 200, got %d: %s", subRec.Code, subRec.Body.String())
	}

	// 3. Hiker A triggers POST /api/v1/live/sos
	hikerAToken := strings.Repeat("a", 64)
	sosReq := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/live/sos",
		strings.NewReader(`{"trailId":"bucegi-1","reason":"injury","message":"Ajutor","lat":45.4080,"lon":25.5420,"ele":2100}`),
	)
	sosReq.Header.Set("Content-Type", "application/json")
	sosReq.Header.Set("X-Device-Token", hikerAToken)
	sosRec := httptest.NewRecorder()
	mux.ServeHTTP(sosRec, sosReq)
	if sosRec.Code != http.StatusOK {
		t.Fatalf("public POST /api/v1/live/sos expected 200, got %d: %s", sosRec.Code, sosRec.Body.String())
	}

	// CRITICAL SECURITY INVARIANT: public response MUST NEVER contain pushTargets!
	var sosResp map[string]any
	if err := json.Unmarshal(sosRec.Body.Bytes(), &sosResp); err != nil {
		t.Fatalf("unmarshal sos response: %v", err)
	}
	if _, leaked := sosResp["pushTargets"]; leaked {
		t.Fatalf("SECURITY VIOLATION: public /api/v1/live/sos leaked subscriber pushTargets: %s", sosRec.Body.String())
	}
	if sosResp["sos"] == nil {
		t.Fatalf("expected sos object in response, got %v", sosResp)
	}

	<-doneCh
	if pushReceived.Load() != 1 {
		t.Fatalf("expected 1 native Go Web Push notification dispatched, got %d", pushReceived.Load())
	}
}
