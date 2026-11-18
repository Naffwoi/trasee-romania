package main

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	_ "pocketbase/migrations"
	"pocketbase/util"
)

func TestEnvHazardsAndRailMigrationAndSearchDoc(t *testing.T) {
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatalf("failed to init test app: %v", err)
	}
	defer app.Cleanup()

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
	actor.Set("is_local", true)
	actor.Set("iri", "https://example.com/actors/romania")
	actor.Set("inbox", "https://example.com/actors/romania/inbox")
	actor.Set("public_key", "pem")
	if err := app.UnsafeWithoutHooks().Save(actor); err != nil {
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
	if err := app.UnsafeWithoutHooks().Save(trail); err != nil {
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
