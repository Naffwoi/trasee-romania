package routes

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"

	"pocketbase/services/live"
	"pocketbase/util"
)

func injectFakeApp1ExifAndComment(t *testing.T, cleanJpeg []byte) []byte {
	t.Helper()
	if len(cleanJpeg) < 4 || cleanJpeg[0] != 0xFF || cleanJpeg[1] != 0xD8 {
		t.Fatalf("not a valid JPEG SOI")
	}
	exifPayload := []byte("Exif\x00\x00II*\x00SECRET_GPS_45.445833_25.456389_SERIAL_998877")
	app1Len := len(exifPayload) + 2
	comPayload := []byte("User private camera comment")
	comLen := len(comPayload) + 2

	var out bytes.Buffer
	out.Write(cleanJpeg[:2])
	out.Write([]byte{0xFF, 0xE1, byte(app1Len >> 8), byte(app1Len & 0xFF)})
	out.Write(exifPayload)
	out.Write([]byte{0xFF, 0xFE, byte(comLen >> 8), byte(comLen & 0xFF)})
	out.Write(comPayload)
	out.Write(cleanJpeg[2:])
	return out.Bytes()
}

func makeSampleJpeg(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8((x * 5) % 255), G: uint8((y * 7) % 255), B: 90, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
		t.Fatalf("jpeg.Encode: %v", err)
	}
	return buf.Bytes()
}

func TestStripImageMetadataRemovesExifAndRejectsNonImages(t *testing.T) {
	dirty := injectFakeApp1ExifAndComment(t, makeSampleJpeg(t, 640, 480))
	if !bytes.Contains(dirty, []byte("SECRET_GPS")) {
		t.Fatal("precondition failed: dirty JPEG missing fake EXIF")
	}

	clean, ext, mimeType, err := util.StripImageMetadata(dirty)
	if err != nil {
		t.Fatalf("StripImageMetadata failed: %v", err)
	}
	if ext != ".jpg" || mimeType != "image/jpeg" {
		t.Fatalf("got ext=%q mime=%q, want .jpg image/jpeg", ext, mimeType)
	}
	if bytes.Contains(clean, []byte("Exif")) || bytes.Contains(clean, []byte("SECRET_GPS")) || bytes.Contains(clean, []byte("private camera")) {
		t.Fatalf("expected all EXIF/COM bytes stripped from output JPEG")
	}
	if _, err := jpeg.Decode(bytes.NewReader(clean)); err != nil {
		t.Fatalf("cleaned JPEG failed to decode: %v", err)
	}

	if _, _, _, err := util.StripImageMetadata([]byte("%PDF-1.7 disguised")); err == nil {
		t.Fatalf("expected non-image payload to be rejected")
	}
}

func buildMultipartReportRequest(t *testing.T, target string, fields map[string]string, filename, contentType string, fileBytes []byte) *http.Request {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	for k, v := range fields {
		if err := mw.WriteField(k, v); err != nil {
			t.Fatal(err)
		}
	}
	if len(fileBytes) > 0 {
		partHeader := make(textproto.MIMEHeader)
		partHeader.Set("Content-Disposition", `form-data; name="photo"; filename="`+filename+`"`)
		partHeader.Set("Content-Type", contentType)
		part, err := mw.CreatePart(partHeader)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := part.Write(fileBytes); err != nil {
			t.Fatal(err)
		}
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, target, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	return req
}

func TestCreateReportMultipartPhotoStripsExifOnDiskAndReturnsUrls(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)
	handler := NewTrailLiveHandler(live.NewTrailLiveHub())

	dirtyJpeg := injectFakeApp1ExifAndComment(t, makeSampleJpeg(t, 800, 600))
	req := buildMultipartReportRequest(t, "/live/reports", map[string]string{
		"trailId":       "trail-bucegi-1",
		"category":      "bear",
		"note":          "Urme proaspete pe poteca",
		"lat":           "45.4458",
		"lon":           "25.4563",
		"ele":           "2040",
		"photoVerified": "true",
	}, "urs.jpg", "image/jpeg", dirtyJpeg)
	req.Header.Set("X-Internal-Secret", testLiveSecret)
	req.Header.Set("X-Device-Hash", "dev-photo-hash-1")

	rec := httptest.NewRecorder()
	ev := &core.RequestEvent{App: app}
	ev.Request = req
	ev.Response = rec
	if err := handler.CreateReport(ev); err != nil {
		t.Fatalf("CreateReport multipart failed: %v", err)
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}

	var parsed struct {
		Report TrailReportDto `json:"report"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &parsed); err != nil {
		t.Fatal(err)
	}
	if !parsed.Report.PhotoVerified {
		t.Fatalf("expected PhotoVerified=true")
	}
	if parsed.Report.PhotoUrl == nil || parsed.Report.PhotoThumbUrl == nil {
		t.Fatalf("expected non-nil PhotoUrl and PhotoThumbUrl, got %+v", parsed.Report)
	}

	// Verify stored bytes on disk inside pb_data/storage contain ZERO EXIF bytes.
	dbRec, err := app.FindRecordById("trail_reports", parsed.Report.ID)
	if err != nil {
		t.Fatal(err)
	}
	storedName := dbRec.GetString("photo")
	storedPath := filepath.Join(app.DataDir(), "storage", dbRec.Collection().Id, dbRec.Id, storedName)
	storedBytes, err := os.ReadFile(storedPath)
	if err != nil {
		t.Fatalf("read stored photo %s: %v", storedPath, err)
	}
	if bytes.Contains(storedBytes, []byte("SECRET_GPS")) || bytes.Contains(storedBytes, []byte("Exif")) {
		t.Fatalf("stored file on disk leaked EXIF metadata!")
	}

	// Verify RAM-indexed summary query also returns photoUrl, photoThumbUrl, and photoVerified!
	status, sumRaw := invokeLiveHandler(t, app, handler.TrailSummary, liveCallOptions{
		method:     http.MethodGet,
		target:     "/live/trail/trail-bucegi-1/summary?lat=45.4458&lon=25.4563",
		secret:     testLiveSecret,
		deviceHash: "dev-photo-hash-2",
		pathValues: map[string]string{"id": "trail-bucegi-1"},
	})
	if status != http.StatusOK {
		t.Fatalf("summary status = %d: %s", status, sumRaw)
	}
	var sumResp struct {
		Reports []TrailReportDto `json:"reports"`
	}
	if err := json.Unmarshal(sumRaw, &sumResp); err != nil {
		t.Fatal(err)
	}
	if len(sumResp.Reports) != 1 {
		t.Fatalf("expected 1 report from RAM store, got %d", len(sumResp.Reports))
	}
	ramRep := sumResp.Reports[0]
	if ramRep.PhotoUrl == nil || *ramRep.PhotoUrl != *parsed.Report.PhotoUrl ||
		ramRep.PhotoThumbUrl == nil || *ramRep.PhotoThumbUrl != *parsed.Report.PhotoThumbUrl ||
		!ramRep.PhotoVerified {
		t.Fatalf("RAM-indexed report lost photo fields: got %+v, want %+v", ramRep, parsed.Report)
	}
}

func TestPublicLiveMultipartPhotoUploadSummaryAndThumb(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)

	pbRouter, err := apis.NewRouter(app)
	if err != nil {
		t.Fatalf("apis.NewRouter: %v", err)
	}
	handler := NewTrailLiveHandler(live.NewTrailLiveHub())
	handler.RateLimiters = live.NewDefaultLiveRateLimiterSet()
	handler.ActorCache = NewActorIDCache(0)
	registerTrailLiveRouterGroups(pbRouter, handler)

	se := &core.ServeEvent{App: app, Router: pbRouter}
	RegisterPublicFilesAndRegionsRoutes(se)

	mux, err := pbRouter.BuildMux()
	if err != nil {
		t.Fatalf("BuildMux: %v", err)
	}

	dirtyJpeg := injectFakeApp1ExifAndComment(t, makeSampleJpeg(t, 800, 600))
	req := buildMultipartReportRequest(t, "/api/v1/live/reports", map[string]string{
		"trailId":       "trail-public-photo",
		"category":      "spring",
		"note":          "Izvor clar",
		"lat":           "45.4100",
		"lon":           "25.5400",
		"ele":           "1800",
		"photoVerified": "true",
	}, "izvor.jpg", "image/jpeg", dirtyJpeg)
	req.Header.Set("X-Device-Token", strings.Repeat("c", 64))

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /api/v1/live/reports status = %d, want 200: %s", rec.Code, rec.Body.String())
	}

	var created struct {
		Report TrailReportDto `json:"report"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Report.PhotoThumbUrl == nil || !created.Report.PhotoVerified {
		t.Fatalf("expected public upload photoThumbUrl and photoVerified=true, got %+v", created.Report)
	}

	// Verify GET /api/v1/live/trail/{id}/summary returns photo fields from RAM
	sumReq := httptest.NewRequest(http.MethodGet, "/api/v1/live/trail/trail-public-photo/summary?lat=45.4100&lon=25.5400", nil)
	sumRec := httptest.NewRecorder()
	mux.ServeHTTP(sumRec, sumReq)
	if sumRec.Code != http.StatusOK {
		t.Fatalf("GET /api/v1/live/trail/.../summary status = %d: %s", sumRec.Code, sumRec.Body.String())
	}
	var sumResp struct {
		Reports []TrailReportDto `json:"reports"`
	}
	_ = json.Unmarshal(sumRec.Body.Bytes(), &sumResp)
	if len(sumResp.Reports) != 1 || sumResp.Reports[0].PhotoThumbUrl == nil || !sumResp.Reports[0].PhotoVerified {
		t.Fatalf("public summary missing photo metadata: %+v", sumResp.Reports)
	}

	// Verify GET /api/v1/files/trail_reports/{id}/{file}?thumb=300x300 serves resized thumbnail
	thumbReq := httptest.NewRequest(http.MethodGet, *created.Report.PhotoThumbUrl, nil)
	thumbRec := httptest.NewRecorder()
	mux.ServeHTTP(thumbRec, thumbReq)
	if thumbRec.Code != http.StatusOK {
		t.Fatalf("GET %s status = %d: %s", *created.Report.PhotoThumbUrl, thumbRec.Code, thumbRec.Body.String())
	}
	if ct := thumbRec.Header().Get("Content-Type"); !strings.Contains(ct, "image/jpeg") {
		t.Fatalf("expected image/jpeg thumb content-type, got %q", ct)
	}
	if thumbRec.Body.Len() == 0 {
		t.Fatalf("expected non-empty thumbnail body")
	}

	// Spoofed PDF upload on public endpoint must be rejected (400)
	badReq := buildMultipartReportRequest(t, "/api/v1/live/reports", map[string]string{
		"trailId":  "trail-public-photo",
		"category": "bear",
		"lat":      "45.4150",
		"lon":      "25.5450",
	}, "fake.jpg", "image/jpeg", []byte("%PDF-1.7 spoofed"))
	badReq.Header.Set("X-Device-Token", strings.Repeat("d", 64))
	badRec := httptest.NewRecorder()
	mux.ServeHTTP(badRec, badReq)
	if badRec.Code != http.StatusBadRequest {
		t.Fatalf("spoofed PDF status = %d, want 400: %s", badRec.Code, badRec.Body.String())
	}
}

func TestCreateReportDedupAttachesPhotoIfMissing(t *testing.T) {
	app := newRemoteRealSchemaApp(t)
	t.Setenv("POCKETBASE_PROXY_SECRET", testLiveSecret)
	handler := NewTrailLiveHandler(live.NewTrailLiveHub())

	// 1. Create text-only report
	st, raw1 := invokeLiveHandler(t, app, handler.CreateReport, liveCallOptions{
		method:     http.MethodPost,
		target:     "/live/reports",
		body:       `{"trailId":"trail-dedup-photo","category":"fallen_tree_terrain","note":"Copac cazut","lat":45.4200,"lon":25.5500}`,
		secret:     testLiveSecret,
		deviceHash: "dev-dedup-1",
	})
	if st != http.StatusOK {
		t.Fatalf("initial report status = %d: %s", st, raw1)
	}
	var w1 struct {
		Report TrailReportDto `json:"report"`
	}
	_ = json.Unmarshal(raw1, &w1)
	if w1.Report.PhotoUrl != nil {
		t.Fatalf("expected nil PhotoUrl initially, got %v", *w1.Report.PhotoUrl)
	}

	// 2. Duplicate report within 40m with photo attaches the photo & photoVerified
	dirtyJpeg := injectFakeApp1ExifAndComment(t, makeSampleJpeg(t, 400, 300))
	req2 := buildMultipartReportRequest(t, "/live/reports", map[string]string{
		"trailId":       "trail-dedup-photo",
		"category":      "fallen_tree_terrain",
		"lat":           "45.4201",
		"lon":           "25.5500",
		"photoVerified": "true",
	}, "copac.jpg", "image/jpeg", dirtyJpeg)
	req2.Header.Set("X-Internal-Secret", testLiveSecret)
	req2.Header.Set("X-Device-Hash", "dev-dedup-2")
	rec2 := httptest.NewRecorder()
	ev2 := &core.RequestEvent{App: app}
	ev2.Request = req2
	ev2.Response = rec2
	if err := handler.CreateReport(ev2); err != nil {
		t.Fatalf("dedup multipart failed: %v", err)
	}
	if rec2.Code != http.StatusOK {
		t.Fatalf("dedup status = %d: %s", rec2.Code, rec2.Body.String())
	}
	var w2 struct {
		Report TrailReportDto `json:"report"`
	}
	_ = json.Unmarshal(rec2.Body.Bytes(), &w2)
	if w2.Report.ID != w1.Report.ID || w2.Report.ConfirmCount != 2 || w2.Report.PhotoUrl == nil || !w2.Report.PhotoVerified {
		t.Fatalf("expected dedup to attach photo & confirm=2, got %+v", w2.Report)
	}
}
