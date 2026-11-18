package util

import (
	"fmt"
	"io"

	"github.com/pocketbase/pocketbase/core"
	"github.com/twpayne/go-polyline"
)

const PolylineMaxLength = 5 * 1024 * 1024

type TrailGeometry struct {
	Polyline            string
	MinLat              float64
	MaxLat              float64
	MinLon              float64
	MaxLon              float64
	BoundingBoxDiagonal float64
}

func openRecordGPXReader(app core.App, r *core.Record) (io.ReadCloser, func(), error) {
	if uploads := r.GetUnsavedFiles("gpx"); len(uploads) > 0 {
		rc, err := uploads[len(uploads)-1].Reader.Open()
		if err != nil {
			return nil, nil, fmt.Errorf("open unsaved gpx: %w", err)
		}
		return rc, func() { _ = rc.Close() }, nil
	}

	gpxPath := r.GetString("gpx")
	if len(gpxPath) == 0 {
		return nil, nil, nil
	}
	fsys, err := app.NewFilesystem()
	if err != nil {
		return nil, nil, fmt.Errorf("open filesystem: %w", err)
	}
	gpxFilePath := r.BaseFilesPath() + "/" + gpxPath
	rc, err := fsys.GetReader(gpxFilePath)
	if err != nil {
		_ = fsys.Close()
		return nil, nil, fmt.Errorf("open gpx file %q: %w", gpxFilePath, err)
	}
	cleanup := func() {
		_ = rc.Close()
		_ = fsys.Close()
	}
	return rc, cleanup, nil
}

func ComputeTrailGeometry(app core.App, r *core.Record) (*TrailGeometry, error) {
	geometry := &TrailGeometry{
		MinLat: r.GetFloat("lat"),
		MaxLat: r.GetFloat("lat"),
		MinLon: r.GetFloat("lon"),
		MaxLon: r.GetFloat("lon"),
	}

	reader, cleanup, err := openRecordGPXReader(app, r)
	if err != nil {
		return nil, err
	}
	if reader == nil {
		return geometry, nil
	}
	defer cleanup()

	streamed, err := StreamGPXData(reader)
	if err != nil {
		return nil, fmt.Errorf("parse gpx stream: %w", err)
	}

	coordinates := make([][]float64, 0, 256)
	for _, seg := range streamed.TrackSegments {
		simplified := SimplifyLatLonMeters(seg, 50.0)
		for _, pt := range simplified {
			coordinates = append(coordinates, []float64{pt[0], pt[1]})
		}
	}
	geometry.Polyline = string(polyline.EncodeCoords(coordinates))

	if streamed.HasPoints {
		geometry.MinLat = streamed.MinLat
		geometry.MaxLat = streamed.MaxLat
		geometry.MinLon = streamed.MinLon
		geometry.MaxLon = streamed.MaxLon
		geometry.BoundingBoxDiagonal = HaversineDistance(streamed.MinLat, streamed.MinLon, streamed.MaxLat, streamed.MaxLon)
	}

	return geometry, nil
}

func ComputePolyline(app core.App, r *core.Record) (string, error) {
	geometry, err := ComputeTrailGeometry(app, r)
	if err != nil {
		return "", err
	}
	return geometry.Polyline, nil
}

// ApplyGeometryFields populates polyline and bounding box fields onto r in memory without issuing an extra SQL save.
func ApplyGeometryFields(app core.App, r *core.Record) error {
	geometry, err := ComputeTrailGeometry(app, r)
	if err != nil {
		return err
	}
	if len(geometry.Polyline) > PolylineMaxLength {
		return fmt.Errorf("polyline exceeds maximum length of %d characters", PolylineMaxLength)
	}
	r.Set("polyline", geometry.Polyline)
	r.Set("min_lat", geometry.MinLat)
	r.Set("max_lat", geometry.MaxLat)
	r.Set("min_lon", geometry.MinLon)
	r.Set("max_lon", geometry.MaxLon)
	r.Set("bounding_box_diagonal", geometry.BoundingBoxDiagonal)
	return nil
}

func SavePolyline(app core.App, r *core.Record) error {
	if err := ApplyGeometryFields(app, r); err != nil {
		return err
	}
	if err := app.UnsafeWithoutHooks().Save(r); err != nil {
		return fmt.Errorf("save trail geometry: %w", err)
	}
	return nil
}
