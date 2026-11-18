package hooks

import (
	"fmt"
	"pocketbase/util"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

func ListFeedHandler() func(e *core.RecordsListRequestEvent) error {
	return func(e *core.RecordsListRequestEvent) error {
		if len(e.Records) == 0 {
			return e.Next()
		}

		requestInfo, err := e.RequestInfo()
		if err != nil {
			return err
		}
		fetchReadable := func(collection *core.Collection, ids []string) ([]*core.Record, error) {
			records, err := e.App.FindRecordsByIds(collection, ids)
			if err != nil {
				return nil, err
			}
			readable := make([]*core.Record, 0, len(records))
			for _, record := range records {
				if allowed, err := e.App.CanAccessRecord(record, requestInfo, collection.ViewRule); err == nil && allowed {
					readable = append(readable, record)
				}
			}
			return readable, nil
		}

		idsByType := map[string][]string{
			string(util.TrailFeed):     {},
			string(util.ListFeed):      {},
			string(util.SummitLogFeed): {},
		}
		for _, r := range e.Records {
			expand := r.Expand()
			delete(expand, "item")
			r.SetExpand(expand)

			typ := strings.Trim(r.GetString("type"), "\"")
			itemID := strings.Trim(r.GetString("item"), "\"")
			if itemID == "" {
				continue
			}
			if _, ok := idsByType[typ]; ok {
				idsByType[typ] = append(idsByType[typ], itemID)
			}
		}

		loadBatch := func(collectionName string, expands []string) (map[string]*core.Record, error) {
			ids := idsByType[collectionName]
			if len(ids) == 0 {
				return nil, nil
			}
			colName := collectionName
			switch collectionName {
			case string(util.TrailFeed):
				colName = "trails"
			case string(util.ListFeed):
				colName = "lists"
			case string(util.SummitLogFeed):
				colName = "summit_logs"
			}

			records, err := e.App.FindRecordsByIds(colName, ids)
			if err != nil {
				return nil, err
			}
			accessible := make([]*core.Record, 0, len(records))
			for _, rec := range records {
				if rec == nil {
					continue
				}
				if allowed, err := e.App.CanAccessRecord(rec, requestInfo, rec.Collection().ViewRule); err == nil && allowed {
					accessible = append(accessible, rec)
				}
			}
			if len(accessible) > 0 {
				if errs := e.App.ExpandRecords(accessible, expands, fetchReadable); len(errs) > 0 {
					return nil, fmt.Errorf("failed to batch expand %s feed items: %v", colName, errs)
				}
			}
			byID := make(map[string]*core.Record, len(accessible))
			for _, rec := range accessible {
				byID[rec.Id] = rec
			}
			return byID, nil
		}

		trailsByID, err := loadBatch(string(util.TrailFeed), []string{"author", "category"})
		if err != nil {
			return err
		}
		listsByID, err := loadBatch(string(util.ListFeed), []string{"author"})
		if err != nil {
			return err
		}
		logsByID, err := loadBatch(string(util.SummitLogFeed), []string{"author", "trail"})
		if err != nil {
			return err
		}

		for _, r := range e.Records {
			typ := strings.Trim(r.GetString("type"), "\"")
			itemID := strings.Trim(r.GetString("item"), "\"")
			var item *core.Record
			switch typ {
			case string(util.TrailFeed):
				item = trailsByID[itemID]
			case string(util.ListFeed):
				item = listsByID[itemID]
			case string(util.SummitLogFeed):
				item = logsByID[itemID]
			}
			if item != nil {
				r.MergeExpand(map[string]any{"item": item})
			}
		}

		return e.Next()
	}
}
