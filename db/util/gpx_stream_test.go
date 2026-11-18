package util

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

func TestStreamGPXDataTracksRoutesAndMalformedXML(t *testing.T) {
	raw := `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test">
  <trk>
    <name>Bucegi</name>
    <trkseg>
      <trkpt lat="45.4000" lon="25.5000"><ele>1900</ele></trkpt>
      <trkpt lat="45.4001" lon="25.5001"><ele>1905</ele></trkpt>
      <trkpt lat="45.4200" lon="25.5300"><ele>2200</ele></trkpt>
    </trkseg>
  </trk>
  <rte>
    <rtept lat="45.3900" lon="25.4800"/>
    <rtept lat="45.4500" lon="25.5600"/>
  </rte>
</gpx>`

	parsed, err := StreamGPXData(strings.NewReader(raw))
	if err != nil {
		t.Fatalf("StreamGPXData: %v", err)
	}
	if !parsed.HasPoints || len(parsed.TrackSegments) != 1 || len(parsed.TrackSegments[0]) != 3 || len(parsed.RouteSegments) != 1 {
		t.Fatalf("unexpected parsed segments: %+v", parsed)
	}
	if parsed.MinLat != 45.3900 || parsed.MaxLat != 45.4500 || parsed.MinLon != 25.4800 || parsed.MaxLon != 25.5600 {
		t.Fatalf("unexpected bounds: %+v", parsed)
	}

	// Collinear middle point (~14m away from start, <0.5m off-line) is simplified away at 50m tolerance.
	simplified := SimplifyLatLonMeters(parsed.TrackSegments[0], 50.0)
	if len(simplified) != 2 {
		t.Fatalf("expected 2 simplified endpoints, got %d: %v", len(simplified), simplified)
	}

	// Non-GPX / broken XML must fail cleanly.
	if _, err := StreamGPXData(strings.NewReader("not xml at all")); err == nil {
		t.Fatal("expected error for plain text non-XML input")
	}
	if _, err := StreamGPXData(strings.NewReader("<gpx><trk><trkseg><trkpt lat=\"bad\" lon=\"25\"/>")); err == nil {
		t.Fatal("expected error for malformed/unclosed GPX")
	}
}

func BenchmarkStreamGPXData50kPoints(b *testing.B) {
	var buf bytes.Buffer
	buf.WriteString(`<?xml version="1.0"?><gpx version="1.1"><trk><trkseg>`)
	for i := 0; i < 50000; i++ {
		fmt.Fprintf(&buf, `<trkpt lat="%.6f" lon="%.6f"><ele>2000.5</ele><time>2026-11-18T10:00:00Z</time></trkpt>`,
			45.30+float64(i)*0.00001, 25.40+float64(i%200)*0.00002)
	}
	buf.WriteString(`</trkseg></trk></gpx>`)
	payload := buf.Bytes()

	b.ReportAllocs()
	b.SetBytes(int64(len(payload)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		res, err := StreamGPXData(bytes.NewReader(payload))
		if err != nil || len(res.TrackSegments) != 1 {
			b.Fatalf("unexpected parse result: %v", err)
		}
	}
}
