package routes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/security"
)

func seedTestUserActorAndAPIToken(t *testing.T, app core.App) (user *core.Record, actorID string, jwt string, rawAPIToken string) {
	t.Helper()

	usersCol, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatalf("find users collection: %v", err)
	}
	u := core.NewRecord(usersCol)
	u.SetEmail("drumet@trasee.ro")
	u.SetPassword("ParolaMunteSigura123!")
	u.Set("username", "drumetro")
	u.Set("name", "Drumet Carpati")
	u.SetVerified(true)
	if err := app.Save(u); err != nil {
		t.Fatalf("save test user: %v", err)
	}

	actorsCol, err := app.FindCollectionByNameOrId("activitypub_actors")
	if err != nil {
		t.Fatalf("find activitypub_actors collection: %v", err)
	}
	actor, err := app.FindFirstRecordByFilter("activitypub_actors", "is_local = 1 && user = {:uid}", map[string]any{"uid": u.Id})
	if err != nil || actor == nil {
		actor = core.NewRecord(actorsCol)
		actor.Set("user", u.Id)
		actor.Set("username", "drumetro")
		actor.Set("preferred_username", "drumetro")
		actor.Set("domain", "localhost")
		actor.Set("is_local", true)
		actor.Set("iri", "https://localhost/activitypub/actor/"+u.Id)
		actor.Set("inbox", "https://localhost/activitypub/actor/"+u.Id+"/inbox")
		actor.Set("public_key", "test-pub")
		if saveErr := app.Save(actor); saveErr != nil {
			t.Fatalf("save test actor: %v", saveErr)
		}
	}

	tok, err := u.NewAuthToken()
	if err != nil {
		t.Fatalf("mint user auth token: %v", err)
	}

	rawKey := "wanderer_key_0123456789abcdef0123456789abcdef"
	tokensCol, err := app.FindCollectionByNameOrId("api_tokens")
	if err == nil && tokensCol != nil {
		apiRec := core.NewRecord(tokensCol)
		apiRec.Set("user", u.Id)
		apiRec.Set("name", "cli-test")
		apiRec.Set("token", security.SHA256(rawKey))
		_ = app.Save(apiRec)
	}

	return u, actor.Id, tok, rawKey
}

func TestResolveOptionalActorIDSupportsPbAuthCookieBearerJwtAndWandererKey(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	_, wantActorID, jwt, rawAPIToken := seedTestUserActorAndAPIToken(t, app)
	cache := NewActorIDCache(10 * time.Minute)

	// 1. URL-encoded pb_auth cookie (standard SvelteKit / PocketBase JS SDK format)
	cookiePayload, _ := json.Marshal(map[string]any{
		"token": jwt,
		"record": map[string]any{
			"id": "ignored-client-side-field",
		},
	})
	reqCookie := httptest.NewRequest(http.MethodPost, "/api/v1/live/reports", nil)
	reqCookie.AddCookie(&http.Cookie{
		Name:  "pb_auth",
		Value: url.QueryEscape(string(cookiePayload)),
	})
	evCookie := &core.RequestEvent{App: app}
	evCookie.Request = reqCookie
	evCookie.Response = httptest.NewRecorder()

	if got := ResolveOptionalActorID(evCookie, cache); got != wantActorID {
		t.Fatalf("Cookie pb_auth actor mismatch: got=%q want=%q", got, wantActorID)
	}
	if setCookie := evCookie.Response.Header().Get("Set-Cookie"); setCookie != "" {
		t.Fatalf("ResolveOptionalActorID must never emit Set-Cookie, got %q", setCookie)
	}

	// 2. Authorization: Bearer <jwt>
	reqBearer := httptest.NewRequest(http.MethodPost, "/api/v1/live/reports", nil)
	reqBearer.Header.Set("Authorization", "Bearer "+jwt)
	evBearer := &core.RequestEvent{App: app}
	evBearer.Request = reqBearer
	evBearer.Response = httptest.NewRecorder()
	if got := ResolveOptionalActorID(evBearer, cache); got != wantActorID {
		t.Fatalf("Bearer JWT actor mismatch: got=%q want=%q", got, wantActorID)
	}

	// 3. Authorization: Bearer wanderer_key_...
	reqAPIKey := httptest.NewRequest(http.MethodPost, "/api/v1/live/reports", nil)
	reqAPIKey.Header.Set("Authorization", "Bearer "+rawAPIToken)
	evAPIKey := &core.RequestEvent{App: app}
	evAPIKey.Request = reqAPIKey
	evAPIKey.Response = httptest.NewRecorder()
	if got := ResolveOptionalActorID(evAPIKey, cache); got != wantActorID {
		t.Fatalf("Bearer wanderer_key actor mismatch: got=%q want=%q", got, wantActorID)
	}

	// 4. Anonymous zero-account hiker -> empty string
	reqAnon := httptest.NewRequest(http.MethodPost, "/api/v1/live/reports", nil)
	evAnon := &core.RequestEvent{App: app}
	evAnon.Request = reqAnon
	evAnon.Response = httptest.NewRecorder()
	if got := ResolveOptionalActorID(evAnon, cache); got != "" {
		t.Fatalf("expected empty actorID for anonymous hiker, got %q", got)
	}
}
