package handler

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/az-black/app-pengompres-gambar-pdf/internal/model"
	"github.com/gen2brain/go-fitz"
)

func writeSamplePng(t *testing.T, path string, w, h int, c color.RGBA) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.SetRGBA(x, y, color.RGBA{
				R: uint8(int(c.R) ^ (x & 0x3f)),
				G: uint8(int(c.G) ^ (y & 0x3f)),
				B: c.B,
				A: 255,
			})
		}
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
}

func TestCompressHandlerConvertCompressImageToPDFDirectAndMultiFileOrder(t *testing.T) {
	tmp := t.TempDir()
	in1 := filepath.Join(tmp, "alpha.png")
	in2 := filepath.Join(tmp, "beta.png")
	outDir := filepath.Join(tmp, "out_pdf")
	writeSamplePng(t, in1, 400, 300, color.RGBA{R: 200, G: 80, B: 40, A: 255})
	writeSamplePng(t, in2, 420, 280, color.RGBA{R: 40, G: 180, B: 90, A: 255})

	reqBody := model.CompressRequest{
		Files:        []string{in1, in2},
		OutputDir:    outDir,
		Action:       "convert_compress",
		TargetFormat: "PDF",
		TargetKB:     50,
	}
	rawJSON, err := json.Marshal(reqBody)
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/compress", bytes.NewReader(rawJSON))
	rec := httptest.NewRecorder()
	CompressHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected HTTP 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp model.CompressResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if !resp.Success || len(resp.Files) != 2 {
		t.Fatalf("expected 2 output PDFs, got resp=%+v", resp)
	}
	if !strings.HasSuffix(resp.Files[0], "alpha.pdf") || !strings.HasSuffix(resp.Files[1], "beta.pdf") {
		t.Fatalf("unexpected order/names: %v", resp.Files)
	}

	// Verify only final .pdf files exist in outDir (no leftover intermediate .png files)
	entries, err := os.ReadDir(outDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected exact 2 PDFs without temp PNGs in %s, found %d entries", outDir, len(entries))
	}

	for _, pdfPath := range resp.Files {
		info, statErr := os.Stat(pdfPath)
		if statErr != nil || info.Size() > 50*1024 {
			t.Fatalf("expected PDF <= 50KB, path=%s err=%v", pdfPath, statErr)
		}
		doc, fitzErr := fitz.New(pdfPath)
		if fitzErr != nil || doc.NumPage() != 1 {
			t.Fatalf("invalid PDF %s: err=%v", pdfPath, fitzErr)
		}
		_ = doc.Close()
	}
}
