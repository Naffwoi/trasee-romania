package util

import (
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

func makeTestJPEG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8((x * 5) % 255), G: uint8((y * 7) % 255), B: 90, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
		t.Fatalf("jpeg.Encode: %v", err)
	}
	return buf.Bytes()
}

func injectJPEGMetadata(t *testing.T, cleanJpeg []byte) []byte {
	t.Helper()
	if len(cleanJpeg) < 4 || cleanJpeg[0] != 0xFF || cleanJpeg[1] != 0xD8 {
		t.Fatal("invalid JPEG SOI")
	}
	app1 := []byte("Exif\x00\x00II*\x00SECRET_GPS_45.445833_25.456389_SERIAL_998877")
	app13 := []byte("Photoshop 3.0\x00IPTC_AUTHOR_NAME")
	com := []byte("Private camera comment")

	var out bytes.Buffer
	out.Write(cleanJpeg[:2])

	writeSeg := func(marker byte, payload []byte) {
		segLen := len(payload) + 2
		out.Write([]byte{0xFF, marker, byte(segLen >> 8), byte(segLen & 0xFF)})
		out.Write(payload)
	}
	writeSeg(0xE1, app1)
	writeSeg(0xED, app13)
	writeSeg(0xFE, com)
	out.Write(cleanJpeg[2:])
	return out.Bytes()
}

func makeSyntheticWebPWithExif() []byte {
	var body bytes.Buffer
	body.WriteString("WEBP")

	writeChunk := func(fourCC string, data []byte) {
		body.WriteString(fourCC)
		var sz [4]byte
		binary.LittleEndian.PutUint32(sz[:], uint32(len(data)))
		body.Write(sz[:])
		body.Write(data)
		if len(data)%2 == 1 {
			body.WriteByte(0)
		}
	}

	// VP8X flags byte: ICC (bit 5) | EXIF (bit 3) | XMP (bit 2)
	vp8x := make([]byte, 10)
	vp8x[0] = (1 << 5) | (1 << 3) | (1 << 2)
	writeChunk("VP8X", vp8x)
	// Minimal VP8L 1x1 lossless payload so mimetype detects image/webp cleanly
	writeChunk("VP8L", []byte{0x2f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})
	writeChunk("EXIF", []byte("Exif\x00\x00SECRET_WEBP_GPS"))
	writeChunk("XMP ", []byte("<x:xmpmeta>SECRET_WEBP_XMP</x:xmpmeta>"))
	writeChunk("ICCP", []byte("SECRET_ICC_PROFILE"))

	var out bytes.Buffer
	out.WriteString("RIFF")
	var riffLen [4]byte
	binary.LittleEndian.PutUint32(riffLen[:], uint32(body.Len()))
	out.Write(riffLen[:])
	out.Write(body.Bytes())
	return out.Bytes()
}

func TestStripImageMetadataJPEGAndWebP(t *testing.T) {
	dirtyJpeg := injectJPEGMetadata(t, makeTestJPEG(t, 320, 240))
	clean, ext, mimeType, err := StripImageMetadata(dirtyJpeg)
	if err != nil {
		t.Fatalf("StripImageMetadata(JPEG) failed: %v", err)
	}
	if ext != ".jpg" || mimeType != "image/jpeg" {
		t.Fatalf("got ext=%q mime=%q, want .jpg image/jpeg", ext, mimeType)
	}
	for _, secret := range []string{"Exif", "SECRET_GPS", "IPTC_AUTHOR_NAME", "Private camera comment"} {
		if bytes.Contains(clean, []byte(secret)) {
			t.Fatalf("stripped JPEG still contains %q", secret)
		}
	}
	if _, err := jpeg.Decode(bytes.NewReader(clean)); err != nil {
		t.Fatalf("stripped JPEG failed decode: %v", err)
	}

	dirtyWebP := makeSyntheticWebPWithExif()
	cleanWebP, extW, mimeW, err := StripImageMetadata(dirtyWebP)
	if err != nil {
		t.Fatalf("StripImageMetadata(WebP) failed: %v", err)
	}
	if extW != ".webp" || mimeW != "image/webp" {
		t.Fatalf("got ext=%q mime=%q, want .webp image/webp", extW, mimeW)
	}
	for _, secret := range []string{"SECRET_WEBP_GPS", "SECRET_WEBP_XMP", "SECRET_ICC_PROFILE", "EXIF", "XMP ", "ICCP"} {
		if bytes.Contains(cleanWebP, []byte(secret)) {
			t.Fatalf("stripped WebP still contains %q", secret)
		}
	}
	// Verify VP8X flags cleared for EXIF/XMP/ICC
	if len(cleanWebP) < 21 || string(cleanWebP[12:16]) != "VP8X" {
		t.Fatalf("expected VP8X chunk preserved, got %q", string(cleanWebP[12:16]))
	}
	if cleanWebP[20]&((1<<5)|(1<<3)|(1<<2)) != 0 {
		t.Fatalf("expected VP8X metadata flags cleared, got 0x%02x", cleanWebP[20])
	}
}

func TestStripImageMetadataRejectsSpoofedAndOversized(t *testing.T) {
	if _, _, _, err := StripImageMetadata(nil); !errors.Is(err, ErrPhotoEmpty) {
		t.Fatalf("empty payload err = %v, want ErrPhotoEmpty", err)
	}

	oversized := make([]byte, MaxReportPhotoBytes+1)
	oversized[0], oversized[1] = 0xFF, 0xD8
	if _, _, _, err := StripImageMetadata(oversized); !errors.Is(err, ErrPhotoTooLarge) {
		t.Fatalf("oversized payload err = %v, want ErrPhotoTooLarge", err)
	}

	if _, _, _, err := StripImageMetadata([]byte("%PDF-1.7\ndisguised")); !errors.Is(err, ErrUnsupportedPhoto) {
		t.Fatalf("PDF payload err = %v, want ErrUnsupportedPhoto", err)
	}

	if _, _, _, err := StripImageMetadata([]byte("<html><script>alert(1)</script></html>")); !errors.Is(err, ErrUnsupportedPhoto) {
		t.Fatalf("HTML payload err = %v, want ErrUnsupportedPhoto", err)
	}

	var pngBuf bytes.Buffer
	_ = png.Encode(&pngBuf, image.NewRGBA(image.Rect(0, 0, 4, 4)))
	if _, _, _, err := StripImageMetadata(pngBuf.Bytes()); !errors.Is(err, ErrUnsupportedPhoto) {
		t.Fatalf("PNG payload err = %v, want ErrUnsupportedPhoto", err)
	}

	// Corrupt JPEG with valid magic header
	if _, _, _, err := StripImageMetadata([]byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10}); err == nil {
		t.Fatal("expected corrupt truncated JPEG to fail")
	}
}
