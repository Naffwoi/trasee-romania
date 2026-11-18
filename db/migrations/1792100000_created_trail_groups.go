package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		if err := createTrailGroupsCollection(app); err != nil {
			return err
		}
		if err := createTrailGroupMembersCollection(app); err != nil {
			return err
		}
		return nil
	}, func(app core.App) error {
		for _, name := range []string{"trail_group_members", "trail_groups"} {
			col, err := app.FindCollectionByNameOrId(name)
			if err != nil {
				continue
			}
			if err := app.Delete(col); err != nil {
				return err
			}
		}
		return nil
	})
}

func createTrailGroupsCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("trail_groups"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("trail_groups")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "code", Required: true, Max: 8},
		&core.TextField{Name: "trail_id"},
		&core.TextField{Name: "owner_device_hash", Hidden: true},
		&core.DateField{Name: "expires_at"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_trail_groups_code", true, "`code`", "")
	col.AddIndex("idx_trail_groups_expires_at", false, "`expires_at`", "")

	return app.Save(col)
}

func createTrailGroupMembersCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("trail_group_members"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("trail_group_members")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "group_code", Required: true, Max: 8},
		&core.TextField{Name: "member_id", Required: true, Max: 24},
		&core.TextField{Name: "device_hash", Required: true, Hidden: true},
		&core.TextField{Name: "display_name", Max: 24},
		&core.TextField{Name: "color_hex", Max: 16},
		&core.NumberField{Name: "lat"},
		&core.NumberField{Name: "lon"},
		&core.NumberField{Name: "ele"},
		&core.NumberField{Name: "accuracy"},
		&core.NumberField{Name: "heading"},
		&core.NumberField{Name: "speed"},
		&core.NumberField{Name: "along_track_m"},
		&core.BoolField{Name: "in_navigation"},
		&core.DateField{Name: "last_seen"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_trail_group_members_group_code", false, "`group_code`", "")
	col.AddIndex("idx_trail_group_members_unique_device", true, "`group_code`, `device_hash`", "")
	col.AddIndex("idx_trail_group_members_unique_member", true, "`group_code`, `member_id`", "")
	col.AddIndex("idx_trail_group_members_last_seen", false, "`last_seen`", "")

	return app.Save(col)
}
