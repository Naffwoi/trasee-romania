package routes

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/security"
)

type cachedActorEntry struct {
	actorID   string
	expiresAt int64
}

// ActorIDCache caches userID -> local ActivityPub actorID for ttl to avoid repeated SQLite queries.
type ActorIDCache struct {
	mu      sync.RWMutex
	ttlNs   int64
	entries map[string]cachedActorEntry
}

// NewActorIDCache creates a thread-safe cache with the given TTL.
func NewActorIDCache(ttl time.Duration) *ActorIDCache {
	if ttl <= 0 {
		ttl = 10 * time.Minute
	}
	return &ActorIDCache{
		ttlNs:   ttl.Nanoseconds(),
		entries: make(map[string]cachedActorEntry, 256),
	}
}

func (c *ActorIDCache) get(userID string, nowNs int64) (string, bool) {
	if c == nil || userID == "" {
		return "", false
	}
	c.mu.RLock()
	entry, ok := c.entries[userID]
	c.mu.RUnlock()
	if !ok || entry.expiresAt <= nowNs {
		return "", false
	}
	return entry.actorID, true
}

func (c *ActorIDCache) set(userID, actorID string, nowNs int64) {
	if c == nil || userID == "" || actorID == "" {
		return
	}
	c.mu.Lock()
	if len(c.entries) >= 4096 {
		for k, v := range c.entries {
			if v.expiresAt <= nowNs {
				delete(c.entries, k)
			}
		}
		if len(c.entries) >= 4096 {
			clear(c.entries)
		}
	}
	c.entries[userID] = cachedActorEntry{
		actorID:   actorID,
		expiresAt: nowNs + c.ttlNs,
	}
	c.mu.Unlock()
}

var defaultActorIDCache = NewActorIDCache(10 * time.Minute)

// ExtractPocketBaseTokenFromRequest extracts the JWT or wanderer_key_* from Authorization header or pb_auth cookie.
func ExtractPocketBaseTokenFromRequest(r *http.Request) string {
	if r == nil {
		return ""
	}

	if authHdr := strings.TrimSpace(r.Header.Get("Authorization")); authHdr != "" {
		if strings.HasPrefix(authHdr, "Bearer ") || strings.HasPrefix(authHdr, "bearer ") {
			tok := strings.TrimSpace(authHdr[7:])
			if tok != "" {
				return tok
			}
		} else {
			return authHdr
		}
	}

	cookie, err := r.Cookie("pb_auth")
	if err != nil || cookie == nil {
		return ""
	}
	rawVal := strings.TrimSpace(cookie.Value)
	if rawVal == "" {
		return ""
	}
	decoded, decErr := url.QueryUnescape(rawVal)
	if decErr != nil {
		decoded = rawVal
	}
	decoded = strings.TrimSpace(decoded)
	if strings.HasPrefix(decoded, "{") {
		var parsed struct {
			Token string `json:"token"`
		}
		if json.Unmarshal([]byte(decoded), &parsed) == nil && strings.TrimSpace(parsed.Token) != "" {
			return strings.TrimSpace(parsed.Token)
		}
	}
	return decoded
}

// ResolveAuthUserRecordFromRequest validates the extracted PocketBase JWT or wanderer_key_* without emitting Set-Cookie.
func ResolveAuthUserRecordFromRequest(app core.App, r *http.Request) *core.Record {
	if app == nil || r == nil {
		return nil
	}
	tok := ExtractPocketBaseTokenFromRequest(r)
	if tok == "" {
		return nil
	}

	if strings.HasPrefix(tok, "wanderer_key") {
		hashed := security.SHA256(tok)
		tokenRec, err := app.FindFirstRecordByFilter(
			"api_tokens",
			"token = {:hash}",
			dbx.Params{"hash": hashed},
		)
		if err != nil || tokenRec == nil {
			return nil
		}
		if exp := tokenRec.GetDateTime("expiration"); !exp.IsZero() && exp.Time().Before(time.Now()) {
			return nil
		}
		userRec, err := app.FindRecordById("users", tokenRec.GetString("user"))
		if err != nil {
			return nil
		}
		return userRec
	}

	authRec, err := app.FindAuthRecordByToken(tok, core.TokenTypeAuth)
	if err != nil || authRec == nil || authRec.Collection().Name != "users" {
		return nil
	}
	return authRec
}

// ResolveOptionalActorID resolves the local ActivityPub actor ID for an authenticated user, or "" for anonymous hikers.
func ResolveOptionalActorID(e *core.RequestEvent, cache *ActorIDCache) string {
	if e == nil || e.App == nil || e.Request == nil {
		return ""
	}
	if cache == nil {
		cache = defaultActorIDCache
	}

	var userRec *core.Record
	if e.Auth != nil && e.Auth.Collection().Name == "users" {
		userRec = e.Auth
	} else {
		userRec = ResolveAuthUserRecordFromRequest(e.App, e.Request)
	}
	if userRec == nil {
		return ""
	}

	nowNs := time.Now().UnixNano()
	if cached, ok := cache.get(userRec.Id, nowNs); ok {
		return cached
	}

	actorRec, err := e.App.FindFirstRecordByFilter(
		"activitypub_actors",
		"is_local = 1 && user = {:uid}",
		dbx.Params{"uid": userRec.Id},
	)
	if err != nil || actorRec == nil {
		return ""
	}
	cache.set(userRec.Id, actorRec.Id, nowNs)
	return actorRec.Id
}
