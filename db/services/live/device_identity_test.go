package live

import (
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestComputeDeviceHashMatchesTypeScriptImplementationBitForBit(t *testing.T) {
	const rawToken = "0123456789abcdef0123456789abcdef"
	const secret = "test-secret-key"

	got, err := ComputeDeviceHash("  "+rawToken+" \t", secret)
	if err != nil {
		t.Fatalf("ComputeDeviceHash unexpected error: %v", err)
	}
	if len(got) != 64 {
		t.Fatalf("expected 64-char hex digest, got len=%d (%q)", len(got), got)
	}
	gotClean, err := ComputeDeviceHash(rawToken, secret)
	if err != nil || got != gotClean {
		t.Fatalf("trimmed token hash mismatch: got=%q clean=%q err=%v", got, gotClean, err)
	}

	// Fallback secret when POCKETBASE_PROXY_SECRET is empty
	t.Setenv("POCKETBASE_PROXY_SECRET", "")
	fallbackGot, err := ComputeDeviceHash(rawToken, "")
	if err != nil {
		t.Fatalf("ComputeDeviceHash fallback failed: %v", err)
	}
	explicitFallback, err := ComputeDeviceHash(rawToken, FallbackHMACSecret)
	if err != nil || fallbackGot != explicitFallback {
		t.Fatalf("fallback secret mismatch: got=%q want=%q", fallbackGot, explicitFallback)
	}
}

func TestIsValidDeviceTokenRejectsShortLongAndNonPrintableTokens(t *testing.T) {
	cases := []struct {
		name  string
		token string
		valid bool
	}{
		{"too_short_23", strings.Repeat("a", 23), false},
		{"min_exact_24", strings.Repeat("a", 24), true},
		{"hex_64", strings.Repeat("f", 64), true},
		{"max_exact_128", strings.Repeat("Z", 128), true},
		{"too_long_129", strings.Repeat("a", 129), false},
		{"contains_space", "0123456789abcdef 123456789abcdef", false},
		{"contains_newline", "0123456789abcdef\n123456789abcdef", false},
		{"contains_unicode", "0123456789abcdefă123456789abcdef", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsValidDeviceToken(tc.token); got != tc.valid {
				t.Fatalf("IsValidDeviceToken(%q) = %v, want %v", tc.token, got, tc.valid)
			}
		})
	}
}

func TestResolveRequestDeviceHashHeaderAndQueryPrecedence(t *testing.T) {
	t.Setenv("POCKETBASE_PROXY_SECRET", "edge-secret-32-bytes-minimum-key")
	headerTok := strings.Repeat("a", 32)
	queryTok := strings.Repeat("b", 32)

	// 1. Header wins over query
	reqBoth := httptest.NewRequest("GET", "/api/v1/live/stream?deviceToken="+queryTok, nil)
	reqBoth.Header.Set("X-Device-Token", headerTok)
	gotHash, err := ResolveRequestDeviceHash(reqBoth, true, true, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantHeaderHash, _ := ComputeDeviceHash(headerTok, "")
	if gotHash != wantHeaderHash {
		t.Fatalf("header token should win over query token: got=%q want=%q", gotHash, wantHeaderHash)
	}

	// 2. Query accepted when allowQueryToken=true (EventSource browser)
	reqQuery := httptest.NewRequest("GET", "/api/v1/live/stream?deviceToken="+queryTok, nil)
	gotQueryHash, err := ResolveRequestDeviceHash(reqQuery, true, true, "")
	if err != nil {
		t.Fatalf("unexpected query token error: %v", err)
	}
	wantQueryHash, _ := ComputeDeviceHash(queryTok, "")
	if gotQueryHash != wantQueryHash {
		t.Fatalf("query token hash mismatch: got=%q want=%q", gotQueryHash, wantQueryHash)
	}

	// 3. Query ignored when allowQueryToken=false (POST endpoints)
	reqPost := httptest.NewRequest("POST", "/api/v1/live/heartbeat?deviceToken="+queryTok, nil)
	if _, err := ResolveRequestDeviceHash(reqPost, false, false, ""); err == nil {
		t.Fatalf("expected error when header is missing and allowQueryToken=false")
	}

	// 4. Optional=true without token returns empty hash without error
	reqAnon := httptest.NewRequest("GET", "/api/v1/live/trail/abc/summary", nil)
	anonHash, err := ResolveRequestDeviceHash(reqAnon, true, false, "")
	if err != nil || anonHash != "" {
		t.Fatalf("expected empty hash and nil err for optional anonymous request, got hash=%q err=%v", anonHash, err)
	}
}

func TestShardedSlidingWindowRateLimiterEnforcesWindowAndRetryAfter(t *testing.T) {
	lim := NewSlidingWindowLimiter(3, 60*time.Second)
	base := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)

	for i := 0; i < 3; i++ {
		dec := lim.Check("dev-hash-1", base.Add(time.Duration(i)*10*time.Second))
		if !dec.Allowed {
			t.Fatalf("request %d should be allowed", i+1)
		}
	}

	blocked := lim.Check("dev-hash-1", base.Add(25*time.Second))
	if blocked.Allowed {
		t.Fatalf("expected 4th request in 60s window to be rate-limited")
	}
	if blocked.RetryAfterSec != 35 {
		t.Fatalf("expected RetryAfterSec=35, got %d", blocked.RetryAfterSec)
	}

	afterExpiry := lim.Check("dev-hash-1", base.Add(61*time.Second))
	if !afterExpiry.Allowed {
		t.Fatalf("expected request after sliding window expiry to be allowed")
	}
}

func TestShardedSlidingWindowLimiterConcurrentAccessAndBoundedEviction(t *testing.T) {
	lim := NewSlidingWindowLimiter(6, time.Minute)
	now := time.Now().UTC()
	var wg sync.WaitGroup
	for g := 0; g < 16; g++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := 0; i < 800; i++ {
				key := strings.Repeat("x", 16) + string(rune('A'+worker)) + string(rune(i%127+1))
				_ = lim.Check(key, now)
			}
		}(g)
	}
	wg.Wait()
	if got := lim.TotalTrackedKeys(); got > maxTrackedDevicesTotal {
		t.Fatalf("expected bounded tracked keys <= %d, got %d", maxTrackedDevicesTotal, got)
	}
}
