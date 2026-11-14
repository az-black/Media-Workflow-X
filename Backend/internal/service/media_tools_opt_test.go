package service

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gen2brain/go-fitz"
)

func makeSyntheticTestImage(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r := uint8((x * 255) / w)
			g := uint8((y * 255) / h)
			b := uint8(((x ^ y) * 3) & 0xff)
			if (x/24+y/24)%2 == 0 {
				r = r ^ 0x2a
				g = g ^ 0x15
			}
			img.SetRGBA(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
		}
	}
	return img
}

func locateWorkspaceDirs(t *testing.T) (backendDir string, samplesDir string) {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	cur := wd
	for i := 0; i < 6; i++ {
		bCand := filepath.Join(cur, "Backend")
		sCand := filepath.Join(cur, "sample_files")
		if _, err1 := os.Stat(filepath.Join(cur, "go.mod")); err1 == nil {
			backendDir = cur
		}
		if _, err1 := os.Stat(filepath.Join(bCand, "go.mod")); err1 == nil {
			backendDir = bCand
		}
		if info, err2 := os.Stat(sCand); err2 == nil && info.IsDir() {
			samplesDir = sCand
		}
		if backendDir != "" && samplesDir != "" {
			return backendDir, samplesDir
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	return backendDir, samplesDir
}

func TestCompressImageToSizeMemoryAccuracyAndQuality(t *testing.T) {
	img := makeSyntheticTestImage(1000, 750)

	// 1. Unbounded targetKB <= 0 returns crisp Q=95 JPEG
	bufFull, err := compressImageToSizeMemory(img, 0)
	if err != nil {
		t.Fatalf("compressImageToSizeMemory(0) error: %v", err)
	}
	decodedFull, _, err := image.Decode(bytes.NewReader(bufFull.Bytes()))
	if err != nil {
		t.Fatalf("decode full Q=95 jpeg error: %v", err)
	}
	if decodedFull.Bounds().Dx() != 1000 || decodedFull.Bounds().Dy() != 750 {
		t.Fatalf("unexpected dimensions: %v", decodedFull.Bounds())
	}

	// 2. Strict full-res binary search target (80 KB) fits <= targetKB
	buf80, err := compressImageToSizeMemory(img, 80)
	if err != nil {
		t.Fatalf("compressImageToSizeMemory(80) error: %v", err)
	}
	if int64(buf80.Len()) > 80*1024 {
		t.Fatalf("expected <= 80 KB, got %d bytes", buf80.Len())
	}
	if _, _, err := image.Decode(bytes.NewReader(buf80.Bytes())); err != nil {
		t.Fatalf("decoded 80KB output invalid: %v", err)
	}

	// 3. Aggressive target (10 KB) triggers proportional downscale + binary search and stays <= 10 KB
	buf10, err := compressImageToSizeMemory(img, 10)
	if err != nil {
		t.Fatalf("compressImageToSizeMemory(10) error: %v", err)
	}
	if int64(buf10.Len()) > 10*1024 {
		t.Fatalf("expected <= 10 KB, got %d bytes", buf10.Len())
	}
	if _, err := jpeg.Decode(bytes.NewReader(buf10.Bytes())); err != nil {
		t.Fatalf("decoded 10KB JPEG invalid: %v", err)
	}
}

func TestCompressPNGToSizeMemoryPreservesPNGAndLosslessFirst(t *testing.T) {
	img := makeSyntheticTestImage(320, 240)

	bufFull, err := compressPNGToSizeMemory(img, 500)
	if err != nil {
		t.Fatalf("compressPNGToSizeMemory(500) error: %v", err)
	}
	dec, format, err := image.Decode(bytes.NewReader(bufFull.Bytes()))
	if err != nil {
		t.Fatalf("decode PNG error: %v", err)
	}
	if format != "png" {
		t.Fatalf("expected png format, got %q", format)
	}
	if dec.Bounds().Dx() != 320 || dec.Bounds().Dy() != 240 {
		t.Fatalf("expected full lossless dims 320x240, got %v", dec.Bounds())
	}

	bufTight, err := compressPNGToSizeMemory(img, 6)
	if err != nil {
		t.Fatalf("compressPNGToSizeMemory(6) error: %v", err)
	}
	if _, decFmt, err := image.Decode(bytes.NewReader(bufTight.Bytes())); err != nil || decFmt != "png" {
		t.Fatalf("expected valid PNG output under tight budget, fmt=%q err=%v", decFmt, err)
	}

	// YCbCr (JPEG-decoded 2400x1800) -> 8-bit PNG <= 150KB must be fast (< 2s) and not fall back to 16-bit NRGBA64/RGBA64
	large := makeSyntheticTestImage(2400, 1800)
	var jpgBuf bytes.Buffer
	if err := jpeg.Encode(&jpgBuf, large, &jpeg.Options{Quality: 92}); err != nil {
		t.Fatal(err)
	}
	ycbcrImg, _, err := image.Decode(bytes.NewReader(jpgBuf.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := ycbcrImg.(*image.YCbCr); !ok {
		t.Fatalf("expected *image.YCbCr from JPEG decode, got %T", ycbcrImg)
	}
	start := time.Now()
	ycbcrPngBuf, err := compressPNGToSizeMemory(ycbcrImg, 150)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("compressPNGToSizeMemory(YCbCr, 150) error: %v", err)
	}
	if int64(ycbcrPngBuf.Len()) > 150*1024 {
		t.Fatalf("expected <= 150KB PNG, got %d bytes", ycbcrPngBuf.Len())
	}
	cfg, decFmt, err := image.DecodeConfig(bytes.NewReader(ycbcrPngBuf.Bytes()))
	if err != nil || decFmt != "png" {
		t.Fatalf("expected valid PNG from YCbCr, fmt=%q err=%v", decFmt, err)
	}
	if cfg.ColorModel == color.RGBA64Model || cfg.ColorModel == color.NRGBA64Model {
		t.Fatalf("expected 8-bit color model, got 16-bit %v", cfg.ColorModel)
	}
	t.Logf("YCbCr 2400x1800 -> <=150KB PNG elapsed: %v (%d bytes, %dx%d)", elapsed, ycbcrPngBuf.Len(), cfg.Width, cfg.Height)
}

func TestPadImageForX4PlusEarlyExitAndPixelPreservation(t *testing.T) {
	tmp := t.TempDir()

	// Odd 101x103 PNG -> padded to 104x104
	oddImg := makeSyntheticTestImage(101, 103)
	oddPath := filepath.Join(tmp, "odd.png")
	fOdd, err := os.Create(oddPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(fOdd, oddImg); err != nil {
		t.Fatal(err)
	}
	_ = fOdd.Close()

	needPad, err := imageNeedsMultiple4Pad(oddPath)
	if err != nil || !needPad {
		t.Fatalf("expected needPad=true for 101x103, got (%v, %v)", needPad, err)
	}

	paddedOut := filepath.Join(tmp, "odd_padded.png")
	if err := padImageForX4Plus(oddPath, paddedOut); err != nil {
		t.Fatalf("padImageForX4Plus(odd) error: %v", err)
	}
	padFile, err := os.Open(paddedOut)
	if err != nil {
		t.Fatal(err)
	}
	defer padFile.Close()
	paddedDec, _, err := image.Decode(padFile)
	if err != nil {
		t.Fatal(err)
	}
	if paddedDec.Bounds().Dx() != 104 || paddedDec.Bounds().Dy() != 104 {
		t.Fatalf("expected 104x104 padded dims, got %v", paddedDec.Bounds())
	}
	r1, g1, b1, a1 := paddedDec.At(50, 60).RGBA()
	r2, g2, b2, a2 := oddImg.At(50, 60).RGBA()
	if r1 != r2 || g1 != g2 || b1 != b2 || a1 != a2 {
		t.Fatalf("top-left pixel mismatch after pad: got (%d,%d,%d,%d), want (%d,%d,%d,%d)", r1, g1, b1, a1, r2, g2, b2, a2)
	}

	// Already multiple of 4 (100x104) -> needsPad=false & bit-identical copy
	evenImg := makeSyntheticTestImage(100, 104)
	evenPath := filepath.Join(tmp, "even.png")
	fEven, err := os.Create(evenPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(fEven, evenImg); err != nil {
		t.Fatal(err)
	}
	_ = fEven.Close()

	needEvenPad, err := imageNeedsMultiple4Pad(evenPath)
	if err != nil || needEvenPad {
		t.Fatalf("expected needPad=false for 100x104, got (%v, %v)", needEvenPad, err)
	}
	evenCopyOut := filepath.Join(tmp, "even_copied.png")
	if err := padImageForX4Plus(evenPath, evenCopyOut); err != nil {
		t.Fatalf("padImageForX4Plus(even) error: %v", err)
	}
	origBytes, _ := os.ReadFile(evenPath)
	copyBytes, _ := os.ReadFile(evenCopyOut)
	if !bytes.Equal(origBytes, copyBytes) {
		t.Fatalf("expected bit-identical fast copy for %%4 aligned image")
	}
}

func TestConvertFormatOnlyHighDPIAndSameFormatCopy(t *testing.T) {
	_, samplesDir := locateWorkspaceDirs(t)
	tmp := t.TempDir()

	// 1. Same-format JPG -> JPEG is bit-identical fast copy
	img := makeSyntheticTestImage(160, 120)
	srcJpg := filepath.Join(tmp, "photo.jpg")
	f, err := os.Create(srcJpg)
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(f, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	outDir1 := filepath.Join(tmp, "out_same")
	outs, err := ConvertFormatOnly([]string{srcJpg}, outDir1, "JPEG", 0, "word")
	if err != nil {
		t.Fatalf("ConvertFormatOnly JPG->JPEG error: %v", err)
	}
	if len(outs) != 1 {
		t.Fatalf("expected 1 output, got %d", len(outs))
	}
	origB, _ := os.ReadFile(srcJpg)
	outB, _ := os.ReadFile(outs[0])
	if !bytes.Equal(origB, outB) {
		t.Fatalf("expected bit-identical output on JPG->JPEG Convert Only")
	}

	// 2. PDF -> PNG with targetKBPerPage=0 preserves 200 DPI sharpness and exact page ordering
	if samplesDir != "" {
		fokbi := filepath.Join(samplesDir, "pdf", "FOKBI.pdf")
		if _, statErr := os.Stat(fokbi); statErr == nil {
			outDirPdf := filepath.Join(tmp, "out_fokbi")
			pdfOuts, err := ConvertFormatOnly([]string{fokbi}, outDirPdf, "png", 0, "word")
			if err != nil {
				t.Fatalf("ConvertFormatOnly FOKBI.pdf -> PNG error: %v", err)
			}
			if len(pdfOuts) == 0 {
				t.Fatalf("expected at least 1 rendered PNG page")
			}
			pf, _ := os.Open(pdfOuts[0])
			cfg, _, decErr := image.DecodeConfig(pf)
			_ = pf.Close()
			if decErr != nil {
				t.Fatalf("DecodeConfig rendered PNG error: %v", decErr)
			}
			// 200 DPI A4 is ~1654px wide (vs degraded 120 DPI ~992px)
			if cfg.Width < 1400 {
				t.Fatalf("expected high-sharpness 200 DPI width >= 1400px, got %dpx", cfg.Width)
			}
		}

		jurnal := filepath.Join(samplesDir, "pdf", "jurnal1.pdf")
		if _, statErr := os.Stat(jurnal); statErr == nil {
			outDirJ := filepath.Join(tmp, "out_jurnal")
			jOuts, err := ConvertFormatOnly([]string{jurnal}, outDirJ, "png", 0, "word")
			if err != nil {
				t.Fatalf("ConvertFormatOnly jurnal1.pdf -> PNG error: %v", err)
			}
			if len(jOuts) != 31 {
				t.Fatalf("expected 31 pages, got %d", len(jOuts))
			}
			for i, p := range jOuts {
				expectedSuffix := fmt.Sprintf("_page_%d.png", i+1)
				if !strings.HasSuffix(p, expectedSuffix) {
					t.Fatalf("page %d out of order: got %s", i+1, p)
				}
			}
		}
	}
}

func TestProcessFileConvertCompressOutputsValidTargetFormats(t *testing.T) {
	tmp := t.TempDir()
	img := makeSyntheticTestImage(480, 360)
	srcPng := filepath.Join(tmp, "sample.png")
	f, err := os.Create(srcPng)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	// 1. PNG -> PNG convert_compress MUST emit true PNG bytes even when targetKB < original size
	outPngDir := filepath.Join(tmp, "out_png")
	_ = os.MkdirAll(outPngDir, 0755)
	pngPaths, err := ProcessFile(srcPng, outPngDir, 3, "png", false, "convert_compress", 0, "", "word", "")
	if err != nil || len(pngPaths) != 1 {
		t.Fatalf("ProcessFile PNG->PNG error: %v", err)
	}
	pf, _ := os.Open(pngPaths[0])
	_, decFmt, err := image.Decode(pf)
	_ = pf.Close()
	if err != nil || decFmt != "png" {
		t.Fatalf("expected valid PNG encoding, got format=%q err=%v", decFmt, err)
	}

	// 2. PNG -> JPG convert_compress <= targetKB
	outJpgDir := filepath.Join(tmp, "out_jpg")
	_ = os.MkdirAll(outJpgDir, 0755)
	jpgPaths, err := ProcessFile(srcPng, outJpgDir, 25, "jpg", false, "convert_compress", 0, "", "word", "")
	if err != nil || len(jpgPaths) != 1 {
		t.Fatalf("ProcessFile PNG->JPG error: %v", err)
	}
	if info, _ := os.Stat(jpgPaths[0]); info.Size() > 25*1024 {
		t.Fatalf("expected JPG <= 25KB, got %d bytes", info.Size())
	}

	// 3. PNG -> PDF convert_compress via ConvertImageToPDF fits targetKB
	outPdfDir := filepath.Join(tmp, "out_pdf")
	pdfPath, err := ConvertImageToPDF(srcPng, outPdfDir, 40)
	if err != nil {
		t.Fatalf("ConvertImageToPDF error: %v", err)
	}
	if info, _ := os.Stat(pdfPath); info.Size() > 40*1024 {
		t.Fatalf("expected PDF <= 40KB, got %d bytes", info.Size())
	}
	doc, err := fitz.New(pdfPath)
	if err != nil || doc.NumPage() != 1 {
		t.Fatalf("expected valid 1-page PDF, numPages=%d err=%v", func() int {
			if doc != nil {
				return doc.NumPage()
			}
			return 0
		}(), err)
	}
	_ = doc.Close()
}

func TestCompressPDFViaImageToBytesNativeAndRasterOnSamples(t *testing.T) {
	backendDir, samplesDir := locateWorkspaceDirs(t)
	if samplesDir == "" {
		t.Skip("sample_files directory not found")
	}
	if backendDir != "" {
		origWd, _ := os.Getwd()
		if err := os.Chdir(backendDir); err == nil {
			t.Cleanup(func() { _ = os.Chdir(origWd) })
		}
	}

	file1 := filepath.Join(samplesDir, "pdf", "file1.pdf")
	if _, err := os.Stat(file1); err == nil {
		srcDoc, err := fitz.New(file1)
		if err != nil {
			t.Fatal(err)
		}
		origPages := srcDoc.NumPage()
		_ = srcDoc.Close()

		rasterBytes, err := CompressPDFViaImageToBytes(file1, 350, false, "raster")
		if err != nil {
			t.Fatalf("Raster compress file1.pdf error: %v", err)
		}
		rDoc, err := fitz.NewFromMemory(rasterBytes)
		if err != nil {
			t.Fatalf("Raster output invalid PDF: %v", err)
		}
		if rDoc.NumPage() != origPages {
			t.Fatalf("Raster page count mismatch: got %d want %d", rDoc.NumPage(), origPages)
		}
		_ = rDoc.Close()
		if len(rasterBytes) > 400*1024 {
			t.Fatalf("Raster PDF too large for 350KB target: %d bytes", len(rasterBytes))
		}
	}

	file2 := filepath.Join(samplesDir, "pdf", "file2.pdf")
	if _, err := os.Stat(file2); err == nil {
		if _, cppErr := findCppEngine(); cppErr == nil {
			srcDoc, err := fitz.New(file2)
			if err != nil {
				t.Fatal(err)
			}
			origPages := srcDoc.NumPage()
			_ = srcDoc.Close()

			nativeBytes, err := CompressPDFViaImageToBytes(file2, 2000, false, "native")
			if err != nil {
				t.Fatalf("Native compress file2.pdf error: %v", err)
			}
			nDoc, err := fitz.NewFromMemory(nativeBytes)
			if err != nil {
				t.Fatalf("Native output invalid PDF: %v", err)
			}
			if nDoc.NumPage() != origPages {
				t.Fatalf("Native page count mismatch: got %d want %d", nDoc.NumPage(), origPages)
			}
			_ = nDoc.Close()
			if len(nativeBytes) > 2050*1024 {
				t.Fatalf("Native PDF missed 2000KB target: %d bytes", len(nativeBytes))
			}
		}
	}
}
