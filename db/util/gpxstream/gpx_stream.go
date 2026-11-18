package gpxstream

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"strconv"
	"unsafe"
)

// StreamedGPX holds compact [lat, lon] segments and bounding box extracted in one streaming pass.
type StreamedGPX struct {
	TrackSegments [][][2]float64
	RouteSegments [][][2]float64
	MinLat        float64
	MaxLat        float64
	MinLon        float64
	MaxLon        float64
	HasPoints     bool
}

func isXMLSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\r' || b == '\n'
}

func trimXMLSpace(b []byte) []byte {
	start := 0
	for start < len(b) && isXMLSpace(b[start]) {
		start++
	}
	end := len(b)
	for end > start && isXMLSpace(b[end-1]) {
		end--
	}
	return b[start:end]
}

func localXMLName(b []byte) []byte {
	if idx := bytes.IndexByte(b, ':'); idx >= 0 {
		return b[idx+1:]
	}
	return b
}

func internGPXTag(local []byte) string {
	switch string(local) {
	case "gpx":
		return "gpx"
	case "trk":
		return "trk"
	case "trkseg":
		return "trkseg"
	case "trkpt":
		return "trkpt"
	case "rte":
		return "rte"
	case "rtept":
		return "rtept"
	case "wpt":
		return "wpt"
	case "ele":
		return "ele"
	case "time":
		return "time"
	case "name":
		return "name"
	case "desc":
		return "desc"
	case "metadata":
		return "metadata"
	case "extensions":
		return "extensions"
	default:
		return string(local)
	}
}

func parseFloatBytes(b []byte) (float64, error) {
	if len(b) == 0 {
		return 0, errors.New("empty float")
	}
	s := unsafe.String(unsafe.SliceData(b), len(b))
	return strconv.ParseFloat(s, 64)
}

func parseLatLonFromAttrBytes(raw []byte) (float64, float64, error) {
	var lat, lon float64
	var hasLat, hasLon bool

	i := 0
	n := len(raw)
	for i < n {
		for i < n && isXMLSpace(raw[i]) {
			i++
		}
		if i >= n {
			break
		}
		nameStart := i
		for i < n && !isXMLSpace(raw[i]) && raw[i] != '=' && raw[i] != '/' {
			i++
		}
		if i == nameStart {
			return 0, 0, errors.New("malformed xml attribute name")
		}
		attrName := localXMLName(raw[nameStart:i])
		for i < n && isXMLSpace(raw[i]) {
			i++
		}
		if i >= n || raw[i] != '=' {
			return 0, 0, errors.New("malformed xml attribute missing '='")
		}
		i++
		for i < n && isXMLSpace(raw[i]) {
			i++
		}
		if i >= n || (raw[i] != '"' && raw[i] != '\'') {
			return 0, 0, errors.New("malformed xml attribute missing quote")
		}
		quote := raw[i]
		i++
		valStart := i
		endIdx := bytes.IndexByte(raw[i:], quote)
		if endIdx < 0 {
			return 0, 0, errors.New("unterminated xml attribute value")
		}
		val := raw[valStart : valStart+endIdx]
		i = valStart + endIdx + 1

		if len(attrName) == 3 {
			if attrName[0] == 'l' && attrName[1] == 'a' && attrName[2] == 't' {
				v, err := parseFloatBytes(val)
				if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < -90 || v > 90 {
					return 0, 0, fmt.Errorf("invalid lat %q", string(val))
				}
				lat = v
				hasLat = true
			} else if attrName[0] == 'l' && attrName[1] == 'o' && attrName[2] == 'n' {
				v, err := parseFloatBytes(val)
				if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < -180 || v > 180 {
					return 0, 0, fmt.Errorf("invalid lon %q", string(val))
				}
				lon = v
				hasLon = true
			}
		}
	}

	if !hasLat || !hasLon {
		return 0, 0, errors.New("missing lat/lon attributes")
	}
	return lat, lon, nil
}

func skipUntilSequence(br *bufio.Reader, seq []byte) error {
	matched := 0
	for {
		b, err := br.ReadByte()
		if err != nil {
			return err
		}
		if b == seq[matched] {
			matched++
			if matched == len(seq) {
				return nil
			}
		} else if b == seq[0] {
			matched = 1
		} else {
			matched = 0
		}
	}
}

// readTagBody reads from just after '<' up to and excluding the closing '>' (respecting quoted strings).
// For short tags that fit inside br's buffer without '>' in quotes, it returns a zero-alloc slice into br.
func readTagBody(br *bufio.Reader, scratch *[]byte) ([]byte, error) {
	chunk, err := br.ReadSlice('>')
	if err == nil {
		body := chunk[:len(chunk)-1]
		if !hasUnclosedQuote(body) {
			return body, nil
		}
		*scratch = append((*scratch)[:0], chunk...)
	} else if errors.Is(err, bufio.ErrBufferFull) {
		*scratch = append((*scratch)[:0], chunk...)
	} else {
		return nil, err
	}

	for {
		more, rErr := br.ReadSlice('>')
		*scratch = append(*scratch, more...)
		if rErr == nil {
			body := (*scratch)[:len(*scratch)-1]
			if !hasUnclosedQuote(body) {
				return body, nil
			}
		} else if !errors.Is(rErr, bufio.ErrBufferFull) {
			return nil, rErr
		}
	}
}

func hasUnclosedQuote(b []byte) bool {
	var quote byte
	for i := 0; i < len(b); i++ {
		c := b[i]
		if quote == 0 {
			if c == '"' || c == '\'' {
				quote = c
			}
		} else if c == quote {
			quote = 0
		}
	}
	return quote != 0
}

// StreamGPXData parses <trkseg>/<trkpt> and <rte>/<rtept> from r with zero per-point heap allocations.
func StreamGPXData(r io.Reader) (*StreamedGPX, error) {
	br := bufio.NewReaderSize(r, 16*1024)
	out := &StreamedGPX{
		MinLat: 90.0,
		MaxLat: -90.0,
		MinLon: 180.0,
		MaxLon: -180.0,
	}

	sawGPXRoot := false
	rootClosed := false
	inTrkSeg := false
	inRte := false
	var curTrkSeg [][2]float64
	var curRteSeg [][2]float64
	stack := make([]string, 0, 16)
	var scratch []byte

	recordBounds := func(lat, lon float64) {
		if lat < out.MinLat {
			out.MinLat = lat
		}
		if lat > out.MaxLat {
			out.MaxLat = lat
		}
		if lon < out.MinLon {
			out.MinLon = lon
		}
		if lon > out.MaxLon {
			out.MaxLon = lon
		}
		out.HasPoints = true
	}

	for {
		// Advance to next '<'. Outside root element, non-whitespace text is invalid XML.
		outsideRoot := len(stack) == 0
		for {
			slice, err := br.ReadSlice('<')
			if outsideRoot {
				text := slice
				if err == nil && len(text) > 0 {
					text = text[:len(text)-1]
				}
				if len(trimXMLSpace(text)) > 0 {
					return nil, errors.New("invalid xml: unexpected characters outside root element")
				}
			}
			if err == nil {
				break
			}
			if errors.Is(err, bufio.ErrBufferFull) {
				continue
			}
			if errors.Is(err, io.EOF) {
				if !sawGPXRoot || len(stack) != 0 {
					return nil, errors.New("invalid gpx: unexpected EOF or missing <gpx> root")
				}
				return out, nil
			}
			return nil, err
		}

		nextByte, err := br.Peek(1)
		if err != nil {
			return nil, errors.New("invalid xml: unexpected EOF after '<'")
		}

		switch nextByte[0] {
		case '?':
			_, _ = br.ReadByte()
			if err := skipUntilSequence(br, []byte("?>")); err != nil {
				return nil, errors.New("invalid xml: unterminated processing instruction")
			}
			continue
		case '!':
			_, _ = br.ReadByte()
			hdr, _ := br.Peek(7)
			if len(hdr) >= 2 && hdr[0] == '-' && hdr[1] == '-' {
				_, _ = br.Discard(2)
				if err := skipUntilSequence(br, []byte("-->")); err != nil {
					return nil, errors.New("invalid xml: unterminated comment")
				}
				continue
			}
			if len(hdr) >= 7 && string(hdr[:7]) == "[CDATA[" {
				if len(stack) == 0 {
					return nil, errors.New("invalid xml: CDATA outside root element")
				}
				_, _ = br.Discard(7)
				if err := skipUntilSequence(br, []byte("]]>")); err != nil {
					return nil, errors.New("invalid xml: unterminated CDATA")
				}
				continue
			}
			// <!DOCTYPE ...>
			depth := 1
			for depth > 0 {
				c, bErr := br.ReadByte()
				if bErr != nil {
					return nil, errors.New("invalid xml: unterminated declaration")
				}
				if c == '<' {
					depth++
				} else if c == '>' {
					depth--
				}
			}
			continue
		case '/':
			_, _ = br.ReadByte()
			endSlice, rErr := readTagBody(br, &scratch)
			if rErr != nil {
				return nil, errors.New("invalid xml: unterminated end tag")
			}
			local := localXMLName(trimXMLSpace(endSlice))
			if len(local) == 0 || len(stack) == 0 || stack[len(stack)-1] != string(local) {
				return nil, errors.New("invalid xml: mismatched closing tag")
			}
			stack = stack[:len(stack)-1]
			if len(stack) == 0 {
				rootClosed = true
			}
			if len(local) == 6 && string(local) == "trkseg" {
				if inTrkSeg && len(curTrkSeg) > 0 {
					out.TrackSegments = append(out.TrackSegments, curTrkSeg)
					curTrkSeg = nil
				}
				inTrkSeg = false
			} else if len(local) == 3 && string(local) == "rte" {
				if inRte && len(curRteSeg) > 0 {
					out.RouteSegments = append(out.RouteSegments, curRteSeg)
					curRteSeg = nil
				}
				inRte = false
			}
			continue
		}

		// Start or self-closing element.
		if rootClosed {
			return nil, errors.New("invalid xml: multiple root elements")
		}
		tagBody, err := readTagBody(br, &scratch)
		if err != nil {
			return nil, errors.New("invalid xml: unterminated start tag")
		}
		trimmed := trimXMLSpace(tagBody)
		if len(trimmed) == 0 {
			return nil, errors.New("invalid xml: empty tag")
		}
		selfClosing := false
		if trimmed[len(trimmed)-1] == '/' {
			selfClosing = true
			trimmed = trimXMLSpace(trimmed[:len(trimmed)-1])
		}
		if len(trimmed) == 0 {
			return nil, errors.New("invalid xml: empty self-closing tag")
		}

		nameEnd := 0
		for nameEnd < len(trimmed) && !isXMLSpace(trimmed[nameEnd]) {
			if trimmed[nameEnd] == '<' || trimmed[nameEnd] == '=' || trimmed[nameEnd] == '"' || trimmed[nameEnd] == '\'' {
				return nil, errors.New("invalid xml: illegal character in tag name")
			}
			nameEnd++
		}
		local := localXMLName(trimmed[:nameEnd])
		if len(local) == 0 {
			return nil, errors.New("invalid xml: empty local tag name")
		}
		attrBytes := trimmed[nameEnd:]

		switch len(local) {
		case 3:
			if local[0] == 'g' && local[1] == 'p' && local[2] == 'x' && len(stack) == 0 {
				sawGPXRoot = true
			} else if local[0] == 'r' && local[1] == 't' && local[2] == 'e' && !selfClosing {
				inRte = true
				curRteSeg = nil
			}
		case 5:
			if inTrkSeg && local[0] == 't' && local[1] == 'r' && local[2] == 'k' && local[3] == 'p' && local[4] == 't' {
				lat, lon, attrErr := parseLatLonFromAttrBytes(attrBytes)
				if attrErr != nil {
					return nil, attrErr
				}
				recordBounds(lat, lon)
				curTrkSeg = append(curTrkSeg, [2]float64{lat, lon})
			} else if inRte && local[0] == 'r' && local[1] == 't' && local[2] == 'e' && local[3] == 'p' && local[4] == 't' {
				lat, lon, attrErr := parseLatLonFromAttrBytes(attrBytes)
				if attrErr != nil {
					return nil, attrErr
				}
				recordBounds(lat, lon)
				curRteSeg = append(curRteSeg, [2]float64{lat, lon})
			}
		case 6:
			if !selfClosing && local[0] == 't' && local[1] == 'r' && local[2] == 'k' && local[3] == 's' && local[4] == 'e' && local[5] == 'g' {
				inTrkSeg = true
				curTrkSeg = nil
			}
		}

		if !selfClosing {
			stack = append(stack, internGPXTag(local))
		} else if len(stack) == 0 {
			rootClosed = true
		}
	}
}

// SimplifyLatLonMeters applies iterative Ramer-Douglas-Peucker simplification with planar meter tolerance.
func SimplifyLatLonMeters(pts [][2]float64, toleranceMeters float64) [][2]float64 {
	n := len(pts)
	if n <= 2 || toleranceMeters <= 0 {
		out := make([][2]float64, n)
		copy(out, pts)
		return out
	}

	const metersPerDegLat = 111132.92
	cosLat := math.Max(0.1, math.Cos(pts[n/2][0]*math.Pi/180.0))
	metersPerDegLon := metersPerDegLat * cosLat
	tolSq := toleranceMeters * toleranceMeters

	keep := make([]bool, n)
	keep[0] = true
	keep[n-1] = true

	type span struct{ start, end int }
	stack := make([]span, 0, 64)
	stack = append(stack, span{0, n - 1})

	for len(stack) > 0 {
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if cur.end-cur.start <= 1 {
			continue
		}

		ax := pts[cur.start][1] * metersPerDegLon
		ay := pts[cur.start][0] * metersPerDegLat
		bx := pts[cur.end][1] * metersPerDegLon
		by := pts[cur.end][0] * metersPerDegLat
		dx := bx - ax
		dy := by - ay
		segLenSq := dx*dx + dy*dy

		maxDistSq := -1.0
		maxIdx := -1
		for i := cur.start + 1; i < cur.end; i++ {
			px := pts[i][1]*metersPerDegLon - ax
			py := pts[i][0]*metersPerDegLat - ay
			var t float64
			if segLenSq > 1e-9 {
				t = (px*dx + py*dy) / segLenSq
				if t < 0 {
					t = 0
				} else if t > 1 {
					t = 1
				}
			}
			ex := px - t*dx
			ey := py - t*dy
			dSq := ex*ex + ey*ey
			if dSq > maxDistSq {
				maxDistSq = dSq
				maxIdx = i
			}
		}

		if maxDistSq > tolSq && maxIdx > cur.start {
			keep[maxIdx] = true
			stack = append(stack, span{cur.start, maxIdx}, span{maxIdx, cur.end})
		}
	}

	count := 0
	for _, k := range keep {
		if k {
			count++
		}
	}
	out := make([][2]float64, 0, count)
	for i, k := range keep {
		if k {
			out = append(out, pts[i])
		}
	}
	return out
}
