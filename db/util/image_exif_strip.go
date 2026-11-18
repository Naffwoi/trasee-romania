package util

import (
	"bytes"
	"encoding/binary"
	"errors"

	"github.com/gabriel-vasile/mimetype"
)

// MaxReportPhotoBytes is the maximum accepted upload size for trail report photos (2 MB).
const MaxReportPhotoBytes = 2 * 1024 * 1024

var (
	ErrPhotoEmpty       = errors.New("empty photo payload")
	ErrPhotoTooLarge    = errors.New("photo exceeds 2 MB limit")
	ErrUnsupportedPhoto = errors.New("photo must be JPEG or WebP")
	ErrCorruptContainer = errors.New("corrupt image container")
)

// StripImageMetadata validates image magic bytes and losslessly strips all EXIF,
// GPS, XMP, IPTC, ICC, and comment segments from JPEG and WebP containers.
func StripImageMetadata(raw []byte) (clean []byte, ext string, mimeType string, err error) {
	if len(raw) == 0 {
		return nil, "", "", ErrPhotoEmpty
	}
	if len(raw) > MaxReportPhotoBytes {
		return nil, "", "", ErrPhotoTooLarge
	}

	detected := mimetype.Detect(raw)
	switch detected.String() {
	case "image/jpeg":
		stripped, sErr := stripJPEGSegments(raw)
		if sErr != nil {
			return nil, "", "", sErr
		}
		return stripped, ".jpg", "image/jpeg", nil
	case "image/webp":
		stripped, sErr := stripWebPChunks(raw)
		if sErr != nil {
			return nil, "", "", sErr
		}
		return stripped, ".webp", "image/webp", nil
	default:
		return nil, "", "", ErrUnsupportedPhoto
	}
}

func stripJPEGSegments(raw []byte) ([]byte, error) {
	if len(raw) < 4 || raw[0] != 0xFF || raw[1] != 0xD8 {
		return nil, ErrCorruptContainer
	}
	var out bytes.Buffer
	out.Grow(len(raw))
	out.Write([]byte{0xFF, 0xD8})

	pos := 2
	for pos < len(raw) {
		if raw[pos] != 0xFF {
			return nil, ErrCorruptContainer
		}
		for pos < len(raw) && raw[pos] == 0xFF {
			pos++
		}
		if pos >= len(raw) {
			break
		}
		marker := raw[pos]
		pos++

		// Standalone markers without length
		if marker == 0xD9 { // EOI
			out.Write([]byte{0xFF, 0xD9})
			return out.Bytes(), nil
		}
		if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
			out.Write([]byte{0xFF, marker})
			continue
		}
		if pos+2 > len(raw) {
			return nil, ErrCorruptContainer
		}
		segLen := int(binary.BigEndian.Uint16(raw[pos : pos+2]))
		if segLen < 2 || pos+segLen > len(raw) {
			return nil, ErrCorruptContainer
		}

		if marker == 0xDA { // SOS: copy header + remainder of entropy-coded stream up to EOI
			out.Write([]byte{0xFF, marker})
			out.Write(raw[pos:])
			return out.Bytes(), nil
		}

		// Drop APP1..APP15 (0xE1..0xEF) and COM (0xFE); keep APP0 (0xE0 JFIF) & codec tables.
		drop := (marker >= 0xE1 && marker <= 0xEF) || marker == 0xFE
		if !drop {
			out.Write([]byte{0xFF, marker})
			out.Write(raw[pos : pos+segLen])
		}
		pos += segLen
	}
	return nil, ErrCorruptContainer
}

func stripWebPChunks(raw []byte) ([]byte, error) {
	if len(raw) < 12 || string(raw[0:4]) != "RIFF" || string(raw[8:12]) != "WEBP" {
		return nil, ErrCorruptContainer
	}
	var body bytes.Buffer
	body.WriteString("WEBP")

	pos := 12
	for pos+8 <= len(raw) {
		fourCC := string(raw[pos : pos+4])
		chunkSize := int(binary.LittleEndian.Uint32(raw[pos+4 : pos+8]))
		paddedSize := chunkSize + (chunkSize & 1)
		if chunkSize < 0 || pos+8+paddedSize > len(raw) {
			return nil, ErrCorruptContainer
		}
		payload := raw[pos+8 : pos+8+paddedSize]
		if fourCC != "EXIF" && fourCC != "XMP " && fourCC != "ICCP" {
			body.WriteString(fourCC)
			var sz [4]byte
			binary.LittleEndian.PutUint32(sz[:], uint32(chunkSize))
			body.Write(sz[:])
			if fourCC == "VP8X" && len(payload) >= 4 {
				cleanVP8X := append([]byte(nil), payload...)
				// Clear ICC (bit 5), EXIF (bit 3), and XMP (bit 2) flags
				cleanVP8X[0] &^= (1 << 5) | (1 << 3) | (1 << 2)
				body.Write(cleanVP8X)
			} else {
				body.Write(payload)
			}
		}
		pos += 8 + paddedSize
	}

	var out bytes.Buffer
	out.Grow(8 + body.Len())
	out.WriteString("RIFF")
	var riffLen [4]byte
	binary.LittleEndian.PutUint32(riffLen[:], uint32(body.Len()))
	out.Write(riffLen[:])
	out.Write(body.Bytes())
	return out.Bytes(), nil
}
