package util

import (
	"io"

	"pocketbase/util/gpxstream"
)

// StreamedGPX holds compact [lat, lon] segments and bounding box extracted in one SAX pass.
type StreamedGPX = gpxstream.StreamedGPX

// StreamGPXData parses <trkseg>/<trkpt> and <rte>/<rtept> from r without allocating an XML DOM tree.
func StreamGPXData(r io.Reader) (*StreamedGPX, error) {
	return gpxstream.StreamGPXData(r)
}

// SimplifyLatLonMeters applies iterative Ramer-Douglas-Peucker simplification with planar meter tolerance.
func SimplifyLatLonMeters(pts [][2]float64, toleranceMeters float64) [][2]float64 {
	return gpxstream.SimplifyLatLonMeters(pts, toleranceMeters)
}
