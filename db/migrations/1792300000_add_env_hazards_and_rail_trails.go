package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		if err := addRailAndGorgeFieldsToTrails(app); err != nil {
			return err
		}
		return createEnvHazardsCollection(app)
	}, func(app core.App) error {
		if col, err := app.FindCollectionByNameOrId("env_hazards"); err == nil && col != nil {
			if err := app.Delete(col); err != nil {
				return err
			}
		}
		trailsCol, err := app.FindCollectionByNameOrId("trails")
		if err != nil {
			return nil
		}
		for _, name := range []string{
			"train_accessible",
			"rail_station_name",
			"rail_station_distance_m",
			"rail_station_lat",
			"rail_station_lon",
			"is_water_gorge",
		} {
			trailsCol.Fields.RemoveByName(name)
		}
		return app.Save(trailsCol)
	})
}

func addRailAndGorgeFieldsToTrails(app core.App) error {
	col, err := app.FindCollectionByNameOrId("trails")
	if err != nil {
		return err
	}
	if col.Fields.GetByName("train_accessible") == nil {
		col.Fields.Add(&core.BoolField{Name: "train_accessible"})
	}
	if col.Fields.GetByName("rail_station_name") == nil {
		col.Fields.Add(&core.TextField{Name: "rail_station_name", Max: 120})
	}
	if col.Fields.GetByName("rail_station_distance_m") == nil {
		col.Fields.Add(&core.NumberField{Name: "rail_station_distance_m"})
	}
	if col.Fields.GetByName("rail_station_lat") == nil {
		col.Fields.Add(&core.NumberField{Name: "rail_station_lat"})
	}
	if col.Fields.GetByName("rail_station_lon") == nil {
		col.Fields.Add(&core.NumberField{Name: "rail_station_lon"})
	}
	if col.Fields.GetByName("is_water_gorge") == nil {
		col.Fields.Add(&core.BoolField{Name: "is_water_gorge"})
	}
	return app.Save(col)
}

func createEnvHazardsCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("env_hazards"); err == nil {
		return nil
	}
	col := core.NewBaseCollection("env_hazards")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "external_key", Required: true, Max: 160},
		&core.SelectField{
			Name:     "source",
			Required: true,
			Values:   []string{"nasa_firms", "gfw_dist_alert"},
		},
		&core.SelectField{
			Name:     "hazard_type",
			Required: true,
			Values:   []string{"wildfire", "forest_disturbance"},
		},
		&core.SelectField{
			Name:     "severity",
			Required: true,
			Values:   []string{"warning", "danger"},
		},
		&core.TextField{Name: "title", Max: 200},
		&core.NumberField{Name: "lat", Required: true},
		&core.NumberField{Name: "lon", Required: true},
		&core.NumberField{Name: "radius_m"},
		&core.TextField{Name: "confidence", Max: 40},
		&core.NumberField{Name: "frp_mw"},
		&core.JSONField{Name: "affected_trail_ids", MaxSize: 65536},
		&core.DateField{Name: "detected_at"},
		&core.DateField{Name: "expires_at"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_env_hazards_external_key", true, "`external_key`", "")
	col.AddIndex("idx_env_hazards_expires_at", false, "`expires_at`", "")
	col.AddIndex("idx_env_hazards_coords", false, "`lat`, `lon`", "")

	return app.Save(col)
}
