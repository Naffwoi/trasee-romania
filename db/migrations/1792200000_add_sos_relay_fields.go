package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(func(app core.App) error {
		col, err := app.FindCollectionByNameOrId("sos_alerts")
		if err != nil {
			return err
		}

		if col.Fields.GetByName("client_sos_id") == nil {
			col.Fields.Add(&core.TextField{Name: "client_sos_id", Max: 32})
		}
		if col.Fields.GetByName("sos_claim_hash") == nil {
			col.Fields.Add(&core.TextField{Name: "sos_claim_hash", Max: 64, Hidden: true})
		}
		if col.Fields.GetByName("last_packet_epoch") == nil {
			col.Fields.Add(&core.NumberField{Name: "last_packet_epoch"})
		}
		if col.Fields.GetByName("relayed_by_hash") == nil {
			col.Fields.Add(&core.TextField{Name: "relayed_by_hash", Hidden: true})
		}
		if col.Fields.GetByName("origin_lat") == nil {
			col.Fields.Add(&core.NumberField{Name: "origin_lat", Hidden: true})
		}
		if col.Fields.GetByName("origin_lon") == nil {
			col.Fields.Add(&core.NumberField{Name: "origin_lon", Hidden: true})
		}

		col.AddIndex(
			"idx_sos_alerts_client_sos_id",
			true,
			"`client_sos_id`",
			"client_sos_id IS NOT NULL AND client_sos_id != ''",
		)

		return app.Save(col)
	}, func(app core.App) error {
		col, err := app.FindCollectionByNameOrId("sos_alerts")
		if err != nil {
			return nil
		}

		col.RemoveIndex("idx_sos_alerts_client_sos_id")
		col.Fields.RemoveByName("client_sos_id")
		col.Fields.RemoveByName("sos_claim_hash")
		col.Fields.RemoveByName("last_packet_epoch")
		col.Fields.RemoveByName("relayed_by_hash")
		col.Fields.RemoveByName("origin_lat")
		col.Fields.RemoveByName("origin_lon")

		return app.Save(col)
	})
}
