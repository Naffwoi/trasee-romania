package util

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/meilisearch/meilisearch-go"
)

func TestGenerateMeilisearchTokenCachesSigningKeyAcrossRequests(t *testing.T) {
	var getKeysHits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/keys" {
			getKeysHits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"results": []map[string]any{
					{
						"uid":     "01234567-89ab-4def-8123-456789abcdef",
						"name":    "Default Search API Key",
						"key":     "search-secret-key-at-least-32-bytes-long",
						"actions": []string{"search"},
					},
				},
			})
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	client := meilisearch.New(srv.URL, meilisearch.WithAPIKey("master-key"))
	rules := map[string]any{
		"trails": map[string]string{"filter": "public = true"},
	}

	for i := 0; i < 100; i++ {
		tok, err := GenerateMeilisearchToken(rules, client)
		if err != nil || tok == "" {
			t.Fatalf("iteration %d GenerateMeilisearchToken failed: %v", i, err)
		}
	}

	if hits := getKeysHits.Load(); hits != 1 {
		t.Fatalf("expected exactly 1 HTTP /keys fetch across 100 token mints, got %d", hits)
	}
}
