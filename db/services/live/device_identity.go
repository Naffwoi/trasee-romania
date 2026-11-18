package live

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"os"
	"strings"
)

const (
	// FallbackHMACSecret matches FALLBACK_HMAC_SECRET in web/src/lib/server/live/device_identity.ts.
	FallbackHMACSecret   = "wanderer-live-fallback"
	DeviceTokenMinLength = 24
	DeviceTokenMaxLength = 128
)

// ErrInvalidDeviceToken signals a missing or malformed X-Device-Token (HTTP 400).
var ErrInvalidDeviceToken = errors.New("invalid_device_token")

// IsValidDeviceToken checks that raw is 24..128 strictly printable non-whitespace ASCII bytes (0x21..0x7E).
func IsValidDeviceToken(raw string) bool {
	n := len(raw)
	if n < DeviceTokenMinLength || n > DeviceTokenMaxLength {
		return false
	}
	for i := 0; i < n; i++ {
		b := raw[i]
		if b < 0x21 || b > 0x7E {
			return false
		}
	}
	return true
}

// ComputeDeviceHash computes lowercase hex HMAC-SHA256(secret, strings.TrimSpace(rawToken)).
func ComputeDeviceHash(rawToken string, secretOverride string) (string, error) {
	trimmed := strings.TrimSpace(rawToken)
	if !IsValidDeviceToken(trimmed) {
		return "", ErrInvalidDeviceToken
	}

	hmacKey := secretOverride
	if hmacKey == "" {
		hmacKey = os.Getenv("POCKETBASE_PROXY_SECRET")
	}
	if hmacKey == "" {
		hmacKey = FallbackHMACSecret
	}

	mac := hmac.New(sha256.New, []byte(hmacKey))
	_, _ = mac.Write([]byte(trimmed))
	var sum [sha256.Size]byte
	return hex.EncodeToString(mac.Sum(sum[:0])), nil
}

// ExtractRawDeviceToken reads X-Device-Token header and optionally ?deviceToken= query param.
func ExtractRawDeviceToken(r *http.Request, allowQueryToken bool) string {
	if r == nil {
		return ""
	}
	if hdr := strings.TrimSpace(r.Header.Get("X-Device-Token")); hdr != "" {
		return hdr
	}
	if allowQueryToken && r.URL != nil {
		if q := strings.TrimSpace(r.URL.Query().Get("deviceToken")); q != "" {
			return q
		}
	}
	return ""
}

// ResolveRequestDeviceHash extracts and validates anonymous device identity.
func ResolveRequestDeviceHash(
	r *http.Request,
	optional bool,
	allowQueryToken bool,
	secretOverride string,
) (string, error) {
	raw := ExtractRawDeviceToken(r, allowQueryToken)
	if raw == "" {
		if optional {
			return "", nil
		}
		return "", ErrInvalidDeviceToken
	}
	return ComputeDeviceHash(raw, secretOverride)
}
