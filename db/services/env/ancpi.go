package env

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"pocketbase/util"
)

const (
	earthHalfCircumM    = 20037508.342789244
	maxAncpiTileBytes   = 10 * 1024 * 1024
	ancpiProbeCacheTTL  = 10 * time.Minute
	ancpiRequestTimeout = 8 * time.Second
)

var (
	ErrAncpiNotConfigured = errors.New("ANCPI_ORTHO_URL_TEMPLATE not configured")
	ErrAncpiInvalidURL    = errors.New("invalid ANCPI URL template")
	ErrAncpiInvalidTile   = errors.New("invalid tile coordinates")
	ErrAncpiInvalidMime   = errors.New("upstream response is not an image")
)

// XyzToEpsg3857Bbox converts Web Mercator XYZ tile coordinates into an EPSG:3857 bounding box.
func XyzToEpsg3857Bbox(z, x, y int) (minX, minY, maxX, maxY float64) {
	tileSpan := (2.0 * earthHalfCircumM) / math.Exp2(float64(z))
	minX = -earthHalfCircumM + float64(x)*tileSpan
	maxX = minX + tileSpan
	maxY = earthHalfCircumM - float64(y)*tileSpan
	minY = maxY - tileSpan
	return minX, minY, maxX, maxY
}

// AncpiService probes ANCPI orthophoto availability (cached 10m) and proxies WMS/XYZ tiles safely.
type AncpiService struct {
	doer        util.HTTPDoer
	templateURL string
	mu          sync.Mutex
	probedAt    time.Time
	available   bool
}

func NewAncpiService(doer util.HTTPDoer, templateURL string) *AncpiService {
	if doer == nil {
		doer = util.NewSafeURLClient(ancpiRequestTimeout, nil)
	}
	return &AncpiService{
		doer:        doer,
		templateURL: strings.TrimSpace(templateURL),
	}
}

var DefaultAncpiService = NewAncpiService(nil, "")

func (s *AncpiService) effectiveTemplate() string {
	if s != nil && s.templateURL != "" {
		return s.templateURL
	}
	return strings.TrimSpace(os.Getenv("ANCPI_ORTHO_URL_TEMPLATE"))
}

func (s *AncpiService) buildTileURL(z, x, y int) (string, error) {
	tpl := s.effectiveTemplate()
	if tpl == "" {
		return "", ErrAncpiNotConfigured
	}
	if z < 0 || z > 20 {
		return "", ErrAncpiInvalidTile
	}
	maxCoord := 1 << z
	if x < 0 || x >= maxCoord || y < 0 || y >= maxCoord {
		return "", ErrAncpiInvalidTile
	}

	u := strings.NewReplacer(
		"{z}", strconv.Itoa(z),
		"{x}", strconv.Itoa(x),
		"{y}", strconv.Itoa(y),
	).Replace(tpl)
	if strings.Contains(u, "{bbox-epsg-3857}") {
		minX, minY, maxX, maxY := XyzToEpsg3857Bbox(z, x, y)
		bbox := fmt.Sprintf("%.4f,%.4f,%.4f,%.4f", minX, minY, maxX, maxY)
		u = strings.ReplaceAll(u, "{bbox-epsg-3857}", bbox)
	}
	parsed, err := url.Parse(u)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil {
		return "", ErrAncpiInvalidURL
	}
	return u, nil
}

// ProbeAvailable checks whether ANCPI_ORTHO_URL_TEMPLATE is configured and responds with an image tile, cached for 10m.
func (s *AncpiService) ProbeAvailable(ctx context.Context) bool {
	if s.effectiveTemplate() == "" {
		return false
	}
	s.mu.Lock()
	if !s.probedAt.IsZero() && time.Since(s.probedAt) < ancpiProbeCacheTTL {
		avail := s.available
		s.mu.Unlock()
		return avail
	}
	s.mu.Unlock()

	probeCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	// Probe central Carpathians (Bucegi) at z=12
	_, _, status, err := s.FetchTile(probeCtx, 12, 2338, 1471)
	avail := err == nil && status == http.StatusOK

	s.mu.Lock()
	s.probedAt = time.Now()
	s.available = avail
	s.mu.Unlock()
	return avail
}

// FetchTile fetches a single orthophoto tile through the configured template with strict bounds, timeout, and MIME checks.
func (s *AncpiService) FetchTile(ctx context.Context, z, x, y int) ([]byte, string, int, error) {
	tileURL, err := s.buildTileURL(z, x, y)
	if err != nil {
		return nil, "", http.StatusBadRequest, err
	}
	return s.fetchTileURL(ctx, tileURL)
}

// FetchBbox fetches an orthophoto tile by EPSG:3857 bounding box when template uses {bbox-epsg-3857}.
func (s *AncpiService) FetchBbox(ctx context.Context, minX, minY, maxX, maxY float64) ([]byte, string, int, error) {
	tpl := s.effectiveTemplate()
	if tpl == "" {
		return nil, "", http.StatusBadRequest, ErrAncpiNotConfigured
	}
	if !strings.Contains(tpl, "{bbox-epsg-3857}") {
		return nil, "", http.StatusBadRequest, ErrAncpiInvalidTile
	}
	for _, v := range []float64{minX, minY, maxX, maxY} {
		if math.IsNaN(v) || math.IsInf(v, 0) || math.Abs(v) > earthHalfCircumM+1.0 {
			return nil, "", http.StatusBadRequest, ErrAncpiInvalidTile
		}
	}
	if minX >= maxX || minY >= maxY {
		return nil, "", http.StatusBadRequest, ErrAncpiInvalidTile
	}
	bbox := fmt.Sprintf("%.4f,%.4f,%.4f,%.4f", minX, minY, maxX, maxY)
	tileURL := strings.ReplaceAll(tpl, "{bbox-epsg-3857}", bbox)
	parsed, err := url.Parse(tileURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil {
		return nil, "", http.StatusBadRequest, ErrAncpiInvalidURL
	}
	return s.fetchTileURL(ctx, tileURL)
}

func (s *AncpiService) fetchTileURL(ctx context.Context, tileURL string) ([]byte, string, int, error) {
	reqCtx, cancel := context.WithTimeout(ctx, ancpiRequestTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, tileURL, nil)
	if err != nil {
		return nil, "", http.StatusBadRequest, err
	}
	resp, err := s.doer.Do(req)
	if err != nil {
		return nil, "", http.StatusBadGateway, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, "", resp.StatusCode, fmt.Errorf("upstream status %d", resp.StatusCode)
	}
	ct := strings.ToLower(strings.TrimSpace(resp.Header.Get("Content-Type")))
	if ct != "" && !strings.HasPrefix(ct, "image/") {
		return nil, "", http.StatusBadGateway, ErrAncpiInvalidMime
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxAncpiTileBytes+1))
	if err != nil {
		return nil, "", http.StatusBadGateway, err
	}
	if len(body) > maxAncpiTileBytes {
		return nil, "", http.StatusBadGateway, fmt.Errorf("upstream tile exceeds %d bytes", maxAncpiTileBytes)
	}
	if ct == "" {
		ct = "image/jpeg"
	}
	return body, ct, http.StatusOK, nil
}
