package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

const correlatedTrailsFilterViewQuery = `SELECT
    a.id,
    a.user,
    COALESCE(printf("%.2f", (SELECT MAX(v) FROM (
        SELECT MAX(distance) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MAX(t.distance) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.max_distance
    ))), 0) AS max_distance,
    COALESCE(printf("%.2f", (SELECT MAX(v) FROM (
        SELECT MAX(elevation_gain) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MAX(t.elevation_gain) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.max_elevation_gain
    ))), 0) AS max_elevation_gain,
    COALESCE(printf("%.2f", (SELECT MAX(v) FROM (
        SELECT MAX(elevation_loss) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MAX(t.elevation_loss) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.max_elevation_loss
    ))), 0) AS max_elevation_loss,
    COALESCE(printf("%.2f", (SELECT MAX(v) FROM (
        SELECT MAX(duration) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MAX(t.duration) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.max_duration
    ))), 0) AS max_duration,
    COALESCE(printf("%.2f", (SELECT MIN(v) FROM (
        SELECT MIN(distance) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MIN(t.distance) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.min_distance
    ))), 0) AS min_distance,
    COALESCE(printf("%.2f", (SELECT MIN(v) FROM (
        SELECT MIN(elevation_gain) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MIN(t.elevation_gain) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.min_elevation_gain
    ))), 0) AS min_elevation_gain,
    COALESCE(printf("%.2f", (SELECT MIN(v) FROM (
        SELECT MIN(elevation_loss) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MIN(t.elevation_loss) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.min_elevation_loss
    ))), 0) AS min_elevation_loss,
    COALESCE(printf("%.2f", (SELECT MIN(v) FROM (
        SELECT MIN(duration) AS v FROM trails WHERE author = a.id
        UNION ALL
        SELECT MIN(t.duration) FROM trail_share ts JOIN trails t ON t.id = ts.trail WHERE ts.actor = a.id
        UNION ALL
        SELECT p.min_duration
    ))), 0) AS min_duration
FROM activitypub_actors a
CROSS JOIN (
    SELECT
        MAX(distance) AS max_distance,
        MIN(distance) AS min_distance,
        MAX(elevation_gain) AS max_elevation_gain,
        MIN(elevation_gain) AS min_elevation_gain,
        MAX(elevation_loss) AS max_elevation_loss,
        MIN(elevation_loss) AS min_elevation_loss,
        MAX(duration) AS max_duration,
        MIN(duration) AS min_duration
    FROM trails
    WHERE public = TRUE
) p
WHERE a.user != ""`

const previousUncorrelatedTrailsFilterViewQuery = `WITH local_actors AS (
    SELECT id FROM activitypub_actors WHERE user != ""
),
pub AS (
    SELECT
        MAX(distance) AS max_distance,       MIN(distance) AS min_distance,
        MAX(elevation_gain) AS max_elevation_gain, MIN(elevation_gain) AS min_elevation_gain,
        MAX(elevation_loss) AS max_elevation_loss, MIN(elevation_loss) AS min_elevation_loss,
        MAX(duration) AS max_duration,       MIN(duration) AS min_duration
    FROM trails
    WHERE public = TRUE
)
SELECT
    a.id,
    a.user,
    COALESCE(printf("%.2f", MAX(t.max_distance)), 0) AS max_distance,
    COALESCE(printf("%.2f", MAX(t.max_elevation_gain)), 0) AS max_elevation_gain,
    COALESCE(printf("%.2f", MAX(t.max_elevation_loss)), 0) AS max_elevation_loss,
    COALESCE(printf("%.2f", MAX(t.max_duration)), 0) AS max_duration,
    COALESCE(printf("%.2f", MIN(t.min_distance)), 0) AS min_distance,
    COALESCE(printf("%.2f", MIN(t.min_elevation_gain)), 0) AS min_elevation_gain,
    COALESCE(printf("%.2f", MIN(t.min_elevation_loss)), 0) AS min_elevation_loss,
    COALESCE(printf("%.2f", MIN(t.min_duration)), 0) AS min_duration
FROM activitypub_actors a
LEFT JOIN (
    SELECT author AS actor_id,
        MAX(distance) AS max_distance, MIN(distance) AS min_distance,
        MAX(elevation_gain) AS max_elevation_gain, MIN(elevation_gain) AS min_elevation_gain,
        MAX(elevation_loss) AS max_elevation_loss, MIN(elevation_loss) AS min_elevation_loss,
        MAX(duration) AS max_duration, MIN(duration) AS min_duration
    FROM trails
    WHERE author IN (SELECT id FROM local_actors)
    GROUP BY author
    UNION ALL
    SELECT ts.actor AS actor_id,
        MAX(t.distance), MIN(t.distance),
        MAX(t.elevation_gain), MIN(t.elevation_gain),
        MAX(t.elevation_loss), MIN(t.elevation_loss),
        MAX(t.duration), MIN(t.duration)
    FROM trail_share ts
    JOIN trails t ON t.id = ts.trail
    WHERE ts.actor IN (SELECT id FROM local_actors)
    GROUP BY ts.actor
    UNION ALL
    SELECT a2.id AS actor_id,
        p.max_distance, p.min_distance,
        p.max_elevation_gain, p.min_elevation_gain,
        p.max_elevation_loss, p.min_elevation_loss,
        p.max_duration, p.min_duration
    FROM local_actors a2
    CROSS JOIN pub p
) t ON t.actor_id = a.id
WHERE a.user != ""
GROUP BY a.id;`

func init() {
	m.Register(func(app core.App) error {
		trails, err := app.FindCollectionByNameOrId("trails")
		if err != nil {
			return err
		}
		trails.AddIndex(
			"idx_trails_author_metrics",
			false,
			"`author`, `distance`, `elevation_gain`, `elevation_loss`, `duration`",
			"",
		)
		trails.AddIndex(
			"idx_trails_public_filter_metrics",
			false,
			"`public`, `distance`, `elevation_gain`, `elevation_loss`, `duration`",
			"",
		)
		if err := app.Save(trails); err != nil {
			return err
		}

		if sos, sosErr := app.FindCollectionByNameOrId("sos_alerts"); sosErr == nil && sos != nil {
			if sos.GetIndex("idx_sos_alerts_status_expires") == "" {
				sos.AddIndex("idx_sos_alerts_status_expires", false, "`status`, `expires_at`", "")
				if err := app.Save(sos); err != nil {
					return err
				}
			}
		}

		filterView, err := app.FindCollectionByNameOrId("trails_filter")
		if err != nil {
			return err
		}
		filterView.ViewQuery = correlatedTrailsFilterViewQuery
		return app.Save(filterView)
	}, func(app core.App) error {
		filterView, err := app.FindCollectionByNameOrId("trails_filter")
		if err != nil {
			return err
		}
		filterView.ViewQuery = previousUncorrelatedTrailsFilterViewQuery
		if err := app.Save(filterView); err != nil {
			return err
		}

		trails, err := app.FindCollectionByNameOrId("trails")
		if err != nil {
			return err
		}
		trails.RemoveIndex("idx_trails_author_metrics")
		trails.RemoveIndex("idx_trails_public_filter_metrics")
		return app.Save(trails)
	})
}
