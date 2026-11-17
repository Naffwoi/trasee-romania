package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		if err := createTrailPresenceCollection(app); err != nil {
			return err
		}
		if err := createTrailReportsCollection(app); err != nil {
			return err
		}
		if err := createTrailReportVotesCollection(app); err != nil {
			return err
		}
		if err := createSosAlertsCollection(app); err != nil {
			return err
		}
		if err := createSosRespondersCollection(app); err != nil {
			return err
		}
		if err := createPushSubscriptionsCollection(app); err != nil {
			return err
		}
		return nil
	}, func(app core.App) error {
		names := []string{
			"push_subscriptions",
			"sos_responders",
			"sos_alerts",
			"trail_report_votes",
			"trail_reports",
			"trail_presence",
		}
		for _, name := range names {
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

func createTrailPresenceCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("trail_presence"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("trail_presence")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "device_hash", Required: true, Hidden: true},
		&core.TextField{Name: "trail_id"},
		&core.NumberField{Name: "lat"},
		&core.NumberField{Name: "lon"},
		&core.NumberField{Name: "ele"},
		&core.BoolField{Name: "in_navigation"},
		&core.DateField{Name: "last_seen"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_trail_presence_device_hash", true, "`device_hash`", "")
	col.AddIndex("idx_trail_presence_last_seen", false, "`last_seen`", "")
	col.AddIndex("idx_trail_presence_trail_last_seen", false, "`trail_id`, `last_seen`", "")

	return app.Save(col)
}

func createTrailReportsCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("trail_reports"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("trail_reports")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "trail_id"},
		&core.TextField{Name: "category"},
		&core.TextField{Name: "kind"},
		&core.BoolField{Name: "is_permanent"},
		&core.TextField{Name: "condition_status"},
		&core.TextField{Name: "note", Max: 160},
		&core.NumberField{Name: "lat"},
		&core.NumberField{Name: "lon"},
		&core.NumberField{Name: "ele"},
		&core.NumberField{Name: "along_track_m"},
		&core.TextField{Name: "device_hash", Hidden: true},
		&core.TextField{Name: "author_actor"},
		&core.NumberField{Name: "confirm_count"},
		&core.NumberField{Name: "dismiss_count"},
		&core.NumberField{Name: "spam_count"},
		&core.DateField{Name: "last_confirmed_at"},
		&core.DateField{Name: "expires_at"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_trail_reports_trail_id", false, "`trail_id`", "")
	col.AddIndex("idx_trail_reports_status_expires", false, "`condition_status`, `expires_at`", "")

	return app.Save(col)
}

func createTrailReportVotesCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("trail_report_votes"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("trail_report_votes")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "report_id"},
		&core.TextField{Name: "device_hash", Hidden: true},
		&core.TextField{Name: "vote"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_trail_report_votes_report_id", false, "`report_id`", "")
	col.AddIndex("idx_trail_report_votes_unique", true, "`report_id`, `device_hash`", "")

	return app.Save(col)
}

func createSosAlertsCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("sos_alerts"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("sos_alerts")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "trail_id"},
		&core.TextField{Name: "status"},
		&core.TextField{Name: "reason"},
		&core.TextField{Name: "message", Max: 200},
		&core.TextField{Name: "requester_name", Max: 40},
		&core.NumberField{Name: "lat"},
		&core.NumberField{Name: "lon"},
		&core.NumberField{Name: "ele"},
		&core.TextField{Name: "device_hash", Hidden: true},
		&core.NumberField{Name: "responder_count"},
		&core.NumberField{Name: "nearest_distance_m"},
		&core.NumberField{Name: "nearest_eta_sec"},
		&core.DateField{Name: "expires_at"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_sos_alerts_trail_id", false, "`trail_id`", "")
	col.AddIndex("idx_sos_alerts_device_hash", false, "`device_hash`", "")
	col.AddIndex("idx_sos_alerts_status_expires", false, "`status`, `expires_at`", "")

	return app.Save(col)
}

func createSosRespondersCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("sos_responders"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("sos_responders")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "sos_id"},
		&core.TextField{Name: "device_hash", Hidden: true},
		&core.NumberField{Name: "lat"},
		&core.NumberField{Name: "lon"},
		&core.NumberField{Name: "ele"},
		&core.NumberField{Name: "distance_m"},
		&core.NumberField{Name: "eta_sec"},
		&core.TextField{Name: "status"},
		&core.DateField{Name: "last_seen"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_sos_responders_sos_id", false, "`sos_id`", "")
	col.AddIndex("idx_sos_responders_unique", true, "`sos_id`, `device_hash`", "")

	return app.Save(col)
}

func createPushSubscriptionsCollection(app core.App) error {
	if _, err := app.FindCollectionByNameOrId("push_subscriptions"); err == nil {
		return nil
	}

	col := core.NewBaseCollection("push_subscriptions")
	col.ListRule = nil
	col.ViewRule = nil
	col.CreateRule = nil
	col.UpdateRule = nil
	col.DeleteRule = nil

	col.Fields.Add(
		&core.TextField{Name: "device_hash", Hidden: true},
		&core.TextField{Name: "endpoint", Required: true},
		&core.TextField{Name: "p256dh"},
		&core.TextField{Name: "auth"},
		&core.NumberField{Name: "lat"},
		&core.NumberField{Name: "lon"},
		&core.TextField{Name: "trail_id"},
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)

	col.AddIndex("idx_push_subscriptions_device_hash", false, "`device_hash`", "")
	col.AddIndex("idx_push_subscriptions_endpoint", true, "`endpoint`", "")

	return app.Save(col)
}
