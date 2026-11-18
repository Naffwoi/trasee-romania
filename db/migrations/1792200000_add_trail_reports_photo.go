package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

const reportPhotoMaxBytes int64 = 2 * 1024 * 1024

func init() {
	m.Register(func(app core.App) error {
		col, err := app.FindCollectionByNameOrId("trail_reports")
		if err != nil {
			return err
		}
		if col.Fields.GetByName("photo") == nil {
			col.Fields.Add(&core.FileField{
				Name:      "photo",
				MaxSelect: 1,
				MaxSize:   reportPhotoMaxBytes,
				MimeTypes: []string{"image/jpeg", "image/webp"},
				Thumbs:    []string{"300x300", "600x0"},
				Protected: false,
			})
		}
		if col.Fields.GetByName("photo_verified") == nil {
			col.Fields.Add(&core.BoolField{
				Name: "photo_verified",
			})
		}
		return app.Save(col)
	}, func(app core.App) error {
		col, err := app.FindCollectionByNameOrId("trail_reports")
		if err != nil {
			return nil
		}
		col.Fields.RemoveByName("photo")
		col.Fields.RemoveByName("photo_verified")
		return app.Save(col)
	})
}
