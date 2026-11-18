package live

import "math"

const (
	// ~500m resolution at Carpathian latitudes (0.0045 deg lat ~= 500m, 0.0064 deg lon @ 45.5N ~= 500m).
	gridCellLatDeg = 0.0045
	gridCellLonDeg = 0.0064

	metersPerDegLat = 111132.92
)

func clampLat(lat float64) float64 {
	if lat < -89.999 {
		return -89.999
	}
	if lat > 89.999 {
		return 89.999
	}
	return lat
}

func clampLon(lon float64) float64 {
	if lon < -179.999 {
		return -179.999
	}
	if lon > 179.999 {
		return 179.999
	}
	return lon
}

func latBucket(lat float64) uint16 {
	v := int((clampLat(lat) + 90.0) / gridCellLatDeg)
	if v < 0 {
		v = 0
	}
	if v > 65535 {
		v = 65535
	}
	return uint16(v)
}

func lonBucket(lon float64) uint16 {
	v := int((clampLon(lon) + 180.0) / gridCellLonDeg)
	if v < 0 {
		v = 0
	}
	if v > 65535 {
		v = 65535
	}
	return uint16(v)
}

// GridCellKey packs (lat, lon) into a single 32-bit spatial bucket (~500m x 500m) with zero allocations.
func GridCellKey(lat, lon float64) uint32 {
	return (uint32(latBucket(lat)) << 16) | uint32(lonBucket(lon))
}

// GridCellsForBBox returns all 500m spatial cell keys intersecting [minLat..maxLat, minLon..maxLon] expanded by padMeters.
func GridCellsForBBox(minLat, maxLat, minLon, maxLon, padMeters float64) []uint32 {
	midLat := (minLat + maxLat) * 0.5
	cosLat := math.Max(0.1, math.Cos(midLat*math.Pi/180.0))
	dLat := padMeters / metersPerDegLat
	dLon := padMeters / (metersPerDegLat * cosLat)

	y0 := latBucket(minLat - dLat)
	y1 := latBucket(maxLat + dLat)
	x0 := lonBucket(minLon - dLon)
	x1 := lonBucket(maxLon + dLon)

	count := int(y1-y0+1) * int(x1-x0+1)
	out := make([]uint32, 0, count)
	for y := y0; y <= y1; y++ {
		prefix := uint32(y) << 16
		for x := x0; x <= x1; x++ {
			out = append(out, prefix|uint32(x))
		}
	}
	return out
}

// GridCellsForRadius returns all 500m spatial cell keys covering a circle of radiusMeters around (lat, lon).
func GridCellsForRadius(lat, lon, radiusMeters float64) []uint32 {
	return GridCellsForBBox(lat, lat, lon, lon, radiusMeters)
}

// DistanceToCorridorMeters computes the minimum planar projection distance in meters from (lat, lon) to a polyline.
func DistanceToCorridorMeters(lat, lon float64, coords [][2]float64) float64 {
	if len(coords) == 0 {
		return math.Inf(1)
	}
	cosLat := math.Max(0.1, math.Cos(lat*math.Pi/180.0))
	metersPerDegLon := metersPerDegLat * cosLat

	if len(coords) == 1 {
		dx := (coords[0][1] - lon) * metersPerDegLon
		dy := (coords[0][0] - lat) * metersPerDegLat
		return math.Hypot(dx, dy)
	}

	minDistSq := math.Inf(1)
	for i := 0; i < len(coords)-1; i++ {
		ax := (coords[i][1] - lon) * metersPerDegLon
		ay := (coords[i][0] - lat) * metersPerDegLat
		bx := (coords[i+1][1] - lon) * metersPerDegLon
		by := (coords[i+1][0] - lat) * metersPerDegLat

		dx := bx - ax
		dy := by - ay
		segLenSq := dx*dx + dy*dy
		var t float64
		if segLenSq > 1e-9 {
			t = -(ax*dx + ay*dy) / segLenSq
			if t < 0 {
				t = 0
			} else if t > 1 {
				t = 1
			}
		}
		px := ax + t*dx
		py := ay + t*dy
		dSq := px*px + py*py
		if dSq < minDistSq {
			minDistSq = dSq
		}
	}
	return math.Sqrt(minDistSq)
}
