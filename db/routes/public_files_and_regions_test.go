package routes

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/filesystem"

	"pocketbase/services/regions"
)

func addPbAuthCookie(req *http.Request, jwt string) {
	raw, _ := json.Marshal(map[string]any{"token": jwt})
	req.AddCookie(&http.Cookie{
		Name:  "pb_auth",
		Value: url.QueryEscape(string(raw)),
	})
}

func TestPublicFilesRouteServesZeroCopyRangeETagAndEnforcesPrivateInstanceGate(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	RegisterZeroCopyFileDownloadHook(app)

	user, _, jwt, _ := seedTestUserActorAndAPIToken(t, app)

	avatarBytes := []byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>`)
	f, err := filesystem.NewFileFromBytes(avatarBytes, "varf_omu.svg")
	if err != nil {
		t.Fatalf("NewFileFromBytes: %v", err)
	}
	user.Set("avatar", f)
	if err := app.Save(user); err != nil {
		t.Fatalf("save user with avatar: %v", err)
	}
	storedFilename := user.GetString("avatar")

	pbRouter, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("NewRouter: %v", err)
	}
	se := &core.ServeEvent{App: app, Router: pbRouter}
	RegisterPublicFilesAndRegionsRoutes(se)
	mux, err := pbRouter.BuildMux()
	if err != nil {
		t.Fatalf("BuildMux: %v", err)
	}

	targetURL := "/api/v1/files/users/" + user.Id + "/" + storedFilename

	// 1. Public instance (PUBLIC_PRIVATE_INSTANCE=false): anonymous 200 + immutable Cache-Control + ETag + 304 + 206 Range
	t.Setenv("PUBLIC_PRIVATE_INSTANCE", "false")
	req1 := httptest.NewRequest(http.MethodGet, targetURL, nil)
	rec1 := httptest.NewRecorder()
	mux.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusOK {
		t.Fatalf("public file GET expected 200, got %d: %s", rec1.Code, rec1.Body.String())
	}
	if cc := rec1.Header().Get("Cache-Control"); cc != "public, max-age=31536000, immutable" {
		t.Fatalf("expected immutable public Cache-Control, got %q", cc)
	}
	etag := rec1.Header().Get("ETag")
	if etag == "" {
		t.Fatalf("expected strong ETag header on served file")
	}

	// Conditional If-None-Match -> 304 Not Modified
	req304 := httptest.NewRequest(http.MethodGet, targetURL, nil)
	req304.Header.Set("If-None-Match", etag)
	rec304 := httptest.NewRecorder()
	mux.ServeHTTP(rec304, req304)
	if rec304.Code != http.StatusNotModified {
		t.Fatalf("expected 304 Not Modified on matching ETag, got %d", rec304.Code)
	}

	// HTTP Range -> 206 Partial Content
	reqRange := httptest.NewRequest(http.MethodGet, targetURL, nil)
	reqRange.Header.Set("Range", "bytes=0-3")
	reqRange.Header.Set("If-Range", etag)
	recRange := httptest.NewRecorder()
	mux.ServeHTTP(recRange, reqRange)
	if recRange.Code != http.StatusPartialContent || recRange.Body.String() != "<svg" {
		t.Fatalf("expected 206 '<svg', got %d %q", recRange.Code, recRange.Body.String())
	}

	// 2. Private instance (PUBLIC_PRIVATE_INSTANCE=true): anonymous -> 401; pb_auth cookie -> 200 private Cache-Control
	t.Setenv("PUBLIC_PRIVATE_INSTANCE", "true")
	reqPrivAnon := httptest.NewRequest(http.MethodGet, targetURL, nil)
	recPrivAnon := httptest.NewRecorder()
	mux.ServeHTTP(recPrivAnon, reqPrivAnon)
	if recPrivAnon.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 on private instance without pb_auth, got %d", recPrivAnon.Code)
	}

	reqPrivAuth := httptest.NewRequest(http.MethodGet, targetURL, nil)
	addPbAuthCookie(reqPrivAuth, jwt)
	recPrivAuth := httptest.NewRecorder()
	mux.ServeHTTP(recPrivAuth, reqPrivAuth)
	if recPrivAuth.Code != http.StatusOK {
		t.Fatalf("expected 200 on private instance with valid pb_auth cookie, got %d", recPrivAuth.Code)
	}
	if cc := recPrivAuth.Header().Get("Cache-Control"); cc != "private, max-age=86400, immutable" {
		t.Fatalf("expected private Cache-Control on private instance, got %q", cc)
	}
}

func TestPublicRegionsDownloadSupportsPbAuthCookieHeadAndRange(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	_, _, jwt, _ := seedTestUserActorAndAPIToken(t, app)

	archivePath := regions.RegionArchivePath(app, "romania")
	if err := os.MkdirAll(filepath.Dir(archivePath), 0o755); err != nil {
		t.Fatal(err)
	}
	payload := []byte("PMTiles\x03-romania-vector-archive-bytes")
	if err := os.WriteFile(archivePath, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	fixedMod := time.Date(2026, 11, 18, 3, 0, 0, 0, time.UTC)
	_ = os.Chtimes(archivePath, fixedMod, fixedMod)

	pbRouter, err := apis.NewRouter(app)
	if err != nil {
		t.Fatal(err)
	}
	se := &core.ServeEvent{App: app, Router: pbRouter}
	RegisterPublicFilesAndRegionsRoutes(se)
	mux, err := pbRouter.BuildMux()
	if err != nil {
		t.Fatal(err)
	}

	// Anonymous -> 401
	anonReq := httptest.NewRequest(http.MethodGet, "/api/v1/regions/romania/download", nil)
	anonRec := httptest.NewRecorder()
	mux.ServeHTTP(anonRec, anonReq)
	if anonRec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without auth on /api/v1/regions/romania/download, got %d", anonRec.Code)
	}

	// HEAD with pb_auth cookie -> 200 empty body, ETag, Content-Disposition
	headReq := httptest.NewRequest(http.MethodHead, "/api/v1/regions/romania/download", nil)
	addPbAuthCookie(headReq, jwt)
	headRec := httptest.NewRecorder()
	mux.ServeHTTP(headRec, headReq)
	if headRec.Code != http.StatusOK || headRec.Body.Len() != 0 {
		t.Fatalf("expected 200 empty body on HEAD, got code=%d len=%d", headRec.Code, headRec.Body.Len())
	}
	etag := headRec.Header().Get("ETag")
	if etag == "" {
		t.Fatalf("expected ETag on HEAD /api/v1/regions/romania/download")
	}
	if disp := headRec.Header().Get("Content-Disposition"); disp != `attachment; filename="romania-vector.pmtiles"` {
		t.Fatalf("unexpected Content-Disposition: %q", disp)
	}

	// GET Range with pb_auth cookie -> 206 Partial Content
	rangeReq := httptest.NewRequest(http.MethodGet, "/api/v1/regions/romania/download", nil)
	addPbAuthCookie(rangeReq, jwt)
	rangeReq.Header.Set("Range", "bytes=8-")
	rangeReq.Header.Set("If-Range", etag)
	rangeRec := httptest.NewRecorder()
	mux.ServeHTTP(rangeRec, rangeReq)
	if rangeRec.Code != http.StatusPartialContent || rangeRec.Body.String() != "-romania-vector-archive-bytes" {
		t.Fatalf("expected 206 resumed body, got code=%d body=%q", rangeRec.Code, rangeRec.Body.String())
	}
}
