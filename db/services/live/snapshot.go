package live

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type persistedSnapshot struct {
	Version    int                             `json:"version"`
	SavedAt    time.Time                       `json:"savedAt"`
	Presence   []PresenceEntry                 `json:"presence"`
	Groups     []persistedGroupSnapshot        `json:"groups"`
	Responders map[string][]CachedSosResponder `json:"responders"`
}

type persistedGroupSnapshot struct {
	Meta    CachedGroup         `json:"meta"`
	Members []CachedGroupMember `json:"members"`
}

// SaveSnapshot atomically writes active presence, group members, and SOS responders to disk via temp+fsync+rename.
func (s *LiveMemoryStore) SaveSnapshot(path string, now time.Time) error {
	if path == "" {
		return nil
	}
	snap := persistedSnapshot{
		Version:    1,
		SavedAt:    now.UTC(),
		Responders: make(map[string][]CachedSosResponder),
	}

	presenceCutoff := now.Add(-PresenceRetentionWindow)
	for i := 0; i < numMemoryShards; i++ {
		sh := &s.presence[i]
		sh.mu.RLock()
		for _, p := range sh.entries {
			if !p.LastSeen.Before(presenceCutoff) {
				snap.Presence = append(snap.Presence, *p)
			}
		}
		sh.mu.RUnlock()
	}

	memberCutoff := now.Add(-2 * time.Hour)
	for i := 0; i < numMemoryShards; i++ {
		sh := &s.groups[i]
		sh.mu.RLock()
		for _, bucket := range sh.groups {
			if !bucket.meta.ExpiresAt.IsZero() && bucket.meta.ExpiresAt.Before(now) {
				continue
			}
			gs := persistedGroupSnapshot{Meta: bucket.meta}
			for _, m := range bucket.members {
				if !m.LastSeen.Before(memberCutoff) {
					gs.Members = append(gs.Members, *m)
				}
			}
			snap.Groups = append(snap.Groups, gs)
		}
		sh.mu.RUnlock()
	}

	s.sosMu.RLock()
	for sosID, rmap := range s.responders {
		list := make([]CachedSosResponder, 0, len(rmap))
		for _, r := range rmap {
			if !r.LastSeen.Before(presenceCutoff) {
				list = append(list, *r)
			}
		}
		if len(list) > 0 {
			snap.Responders[sosID] = list
		}
	}
	s.sosMu.RUnlock()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	encoded, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	tmpPath := path + ".tmp"
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(encoded); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}

// LoadSnapshot hydrates presence, group telemetry, and SOS responders if the snapshot file is fresher than maxAge.
func (s *LiveMemoryStore) LoadSnapshot(path string, maxAge time.Duration, now time.Time) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var snap persistedSnapshot
	if err := json.Unmarshal(raw, &snap); err != nil {
		return err
	}
	if maxAge > 0 && now.Sub(snap.SavedAt) > maxAge {
		return nil
	}

	for _, p := range snap.Presence {
		if !p.LastSeen.Before(now.Add(-PresenceRetentionWindow)) {
			s.UpsertPresence(p)
		}
	}
	for _, gs := range snap.Groups {
		if !gs.Meta.ExpiresAt.IsZero() && gs.Meta.ExpiresAt.Before(now) {
			continue
		}
		s.UpsertGroup(gs.Meta)
		for _, m := range gs.Members {
			s.UpsertGroupMember(gs.Meta.Code, m)
		}
	}
	for _, list := range snap.Responders {
		for _, r := range list {
			s.UpsertSosResponder(r)
		}
	}
	return nil
}
