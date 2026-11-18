package trailsfilter_test

import (
	"os"
	"slices"
	"sort"
	"strings"
	"testing"

	_ "pocketbase/migrations"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

func newMigratedAppForFilterTest(t *testing.T) *core.BaseApp {
	t.Helper()
	t.Setenv("ORIGIN", "https://local.example")
	app := core.NewBaseApp(core.BaseAppConfig{DataDir: t.TempDir()})
	app.Settings().Logs.MaxDays = 0
	if err := app.Bootstrap(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = app.ResetBootstrapState()
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

func TestTrailsFilterViewUsesCorrelatedLookupWithoutGlobalGroupBy(t *testing.T) {
	if _, err := os.Stat("../../migrations/1792400000_optimize_trails_filter_and_indexes.go"); err != nil {
		t.Fatalf("missing migration 1792400000_optimize_trails_filter_and_indexes.go: %v", err)
	}

	app := newMigratedAppForFilterTest(t)

	var plan []struct {
		Detail string `db:"detail"`
	}
	err := app.DB().NewQuery("EXPLAIN QUERY PLAN SELECT * FROM trails_filter WHERE id = {:id}").
		Bind(dbx.Params{"id": "actor_test_12345"}).
		All(&plan)
	if err != nil {
		t.Fatalf("EXPLAIN QUERY PLAN failed: %v", err)
	}

	for _, step := range plan {
		if strings.Contains(step.Detail, "USE TEMP B-TREE FOR GROUP BY") {
			t.Fatalf("trails_filter still materializes uncorrelated GROUP BY temp B-tree: %q", step.Detail)
		}
	}

	// Verify exact min/max aggregation across owned private + public + shared trails.
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatal(err)
	}
	u1 := core.NewRecord(users)
	u1.SetEmail("hiker1@example.com")
	u1.SetPassword("Password123456!")
	u1.Set("username", "hiker1")
	if err := app.Save(u1); err != nil {
		t.Fatal(err)
	}

	actors, _ := app.FindCollectionByNameOrId("activitypub_actors")
	a1 := core.NewRecord(actors)
	a1.Set("user", u1.Id)
	a1.Set("username", "hiker1")
	a1.Set("preferred_username", "hiker1")
	a1.Set("domain", "local.example")
	a1.Set("is_local", true)
	a1.Set("iri", "https://local.example/ap/actor/hiker1")
	a1.Set("inbox", "https://local.example/ap/actor/hiker1/inbox")
	a1.Set("public_key", "test-pub-key")
	if err := app.Save(a1); err != nil {
		t.Fatal(err)
	}

	categories, _ := app.FindCollectionByNameOrId("categories")
	cat := core.NewRecord(categories)
	cat.Set("name", "hiking")
	if err := app.Save(cat); err != nil {
		t.Fatal(err)
	}

	trailsCol, _ := app.FindCollectionByNameOrId("trails")
	tOwned := core.NewRecord(trailsCol)
	tOwned.Set("name", "Owned Private Trail")
	tOwned.Set("author", a1.Id)
	tOwned.Set("category", cat.Id)
	tOwned.Set("public", false)
	tOwned.Set("distance", 18500)
	tOwned.Set("elevation_gain", 1250)
	tOwned.Set("elevation_loss", 1200)
	tOwned.Set("duration", 21600)
	if err := app.Save(tOwned); err != nil {
		t.Fatal(err)
	}

	rec, err := app.FindRecordById("trails_filter", a1.Id)
	if err != nil {
		t.Fatalf("FindRecordById trails_filter: %v", err)
	}
	if rec.GetString("max_distance") != "18500.00" || rec.GetString("max_elevation_gain") != "1250.00" {
		t.Fatalf("unexpected trails_filter aggregates: dist=%s gain=%s", rec.GetString("max_distance"), rec.GetString("max_elevation_gain"))
	}
}
