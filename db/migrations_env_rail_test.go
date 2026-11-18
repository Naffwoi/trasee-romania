package main

import (
	"slices"
	"sort"
	"testing"

	"github.com/pocketbase/pocketbase/core"

	_ "pocketbase/migrations"
	"pocketbase/util"
)

func newMigratedEnvTestApp(t *testing.T) *core.BaseApp {
	t.Helper()
	t.Setenv("ORIGIN", "https://local.example")
	app := core.NewBaseApp(core.BaseAppConfig{DataDir: t.TempDir()})
	app.Settings().Logs.MaxDays = 0
	if err := app.Bootstrap(); err != nil {
		t.Fatalf("bootstrap test app: %v", err)
	}
	t.Cleanup(func() {
		if err := app.ResetBootstrapState(); err != nil {
			t.Error(err)
		}
	})

	migrations := slices.Clone(core.AppMigrations.Items())
	sort.Slice(migrations, func(i, j int) bool { return migrations[i].File < migrations[j].File })
	for _, m := range migrations {
		switch m.File {
		case "1742167033_init_meilisearch.go", "1744651602_add_polyline.go", "1749831369_update_sortable_attributes.go":
			continue
		}
		if err := app.RunInTransaction(m.Up); err != nil {
			t.Fatalf("apply %s: %v", m.File, err)
		}
	}
	return app
}

func TestEnvHazardsAndRailMigrationAndSearchDoc(t *testing.T) {
	app := newMigratedEnvTestApp(t)

	trailsCol, err := app.FindCollectionByNameOrId("trails")
	if err != nil {
		t.Fatalf("trails collection missing: %v", err)
	}
	for _, fieldName := range []string{
		"train_accessible",
		"rail_station_name",
		"rail_station_distance_m",
		"rail_station_lat",
		"rail_station_lon",
		"is_water_gorge",
	} {
		if trailsCol.Fields.GetByName(fieldName) == nil {
			t.Fatalf("expected field %q on trails collection", fieldName)
		}
	}

	hazardsCol, err := app.FindCollectionByNameOrId("env_hazards")
	if err != nil {
		t.Fatalf("env_hazards collection missing: %v", err)
	}
	for _, fieldName := range []string{
		"external_key", "source", "hazard_type", "severity",
		"title", "lat", "lon", "radius_m", "affected_trail_ids", "expires_at",
	} {
		if hazardsCol.Fields.GetByName(fieldName) == nil {
			t.Fatalf("expected field %q on env_hazards collection", fieldName)
		}
	}

	if util.SearchDocumentVersions["trails"] < 4 {
		t.Fatalf("expected SearchDocumentVersions[trails] >= 4, got %d", util.SearchDocumentVersions["trails"])
	}

	settings := searchIndexSettings()["trails"]
	foundFilterable := false
	for _, attr := range settings.FilterableAttributes {
		if attr == "train_accessible" {
			foundFilterable = true
			break
		}
	}
	if !foundFilterable {
		t.Fatalf("expected train_accessible in trails FilterableAttributes")
	}

	actorsCol, _ := app.FindCollectionByNameOrId("activitypub_actors")
	actor := core.NewRecord(actorsCol)
	actor.Set("username", "romania")
	actor.Set("preferred_username", "romania")
	actor.Set("domain", "local.example")
	actor.Set("is_local", true)
	actor.Set("iri", "https://local.example/actors/romania")
	actor.Set("inbox", "https://local.example/actors/romania/inbox")
	actor.Set("public_key", "pem")
	if err := app.Save(actor); err != nil {
		t.Fatalf("save actor: %v", err)
	}

	trail := core.NewRecord(trailsCol)
	trail.Set("name", "Gara Bușteni – Cascada Urlătoarea")
	trail.Set("author", actor.Id)
	trail.Set("public", true)
	trail.Set("train_accessible", true)
	trail.Set("rail_station_name", "Bușteni")
	trail.Set("rail_station_distance_m", 640)
	trail.Set("rail_station_lat", 45.4119)
	trail.Set("rail_station_lon", 25.5378)
	trail.Set("is_water_gorge", true)
	if err := app.Save(trail); err != nil {
		t.Fatalf("save trail: %v", err)
	}

	doc, err := util.TrailSearchDocument(app, trail)
	if err != nil {
		t.Fatalf("TrailSearchDocument failed: %v", err)
	}
	if doc["train_accessible"] != true {
		t.Fatalf("expected train_accessible=true in search doc, got %v", doc["train_accessible"])
	}
	if doc["rail_station_name"] != "Bușteni" {
		t.Fatalf("expected rail_station_name=Bușteni, got %v", doc["rail_station_name"])
	}
	if doc["rail_station_distance_m"] != float64(640) {
		t.Fatalf("expected rail_station_distance_m=640, got %v", doc["rail_station_distance_m"])
	}
	if doc["rail_station_lat"] != 45.4119 || doc["rail_station_lon"] != 25.5378 {
		t.Fatalf("expected rail_station_lat/lon in search doc, got %v, %v", doc["rail_station_lat"], doc["rail_station_lon"])
	}
	if doc["is_water_gorge"] != true {
		t.Fatalf("expected is_water_gorge=true in search doc, got %v", doc["is_water_gorge"])
	}
}
