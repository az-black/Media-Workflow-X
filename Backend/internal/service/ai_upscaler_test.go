package service

import (
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveAIModelAndScaleFromList(t *testing.T) {
	installed := []string{
		"custom-model-alpha",
		"realesr-animevideov3-x2",
		"realesr-animevideov3-x3",
		"realesr-animevideov3-x4",
		"realesrgan-x4plus",
		"realesrgan-x4plus-anime",
	}

	// 1. Scale is taken strictly from inputScale, never parsed from model name
	m, s := ResolveAIModelAndScaleFromList(installed, "realesr-animevideov3-x2", 3)
	if m != "realesr-animevideov3-x2" || s != 3 {
		t.Fatalf("expected (realesr-animevideov3-x2, 3), got (%s, %d)", m, s)
	}

	// 2. Omitted/non-positive scale falls back uniformly to defaultAIUpscaleScale (4), regardless of "-x2" in name
	m, s = ResolveAIModelAndScaleFromList(installed, "realesr-animevideov3-x2", 0)
	if m != "realesr-animevideov3-x2" || s != defaultAIUpscaleScale {
		t.Fatalf("expected (realesr-animevideov3-x2, %d), got (%s, %d)", defaultAIUpscaleScale, m, s)
	}

	// 3. Any installed model name (without scale hint in name) resolves dynamically with custom integer scale
	m, s = ResolveAIModelAndScaleFromList(installed, "custom-model-alpha", 6)
	if m != "custom-model-alpha" || s != 6 {
		t.Fatalf("expected (custom-model-alpha, 6), got (%s, %d)", m, s)
	}

	// 4. Case-insensitive match returns exact disk filename
	m, s = ResolveAIModelAndScaleFromList(installed, "REALESRGAN-X4PLUS", 2)
	if m != "realesrgan-x4plus" || s != 2 {
		t.Fatalf("expected (realesrgan-x4plus, 2), got (%s, %d)", m, s)
	}

	// 5. Unknown/empty model falls back cleanly to first available model without losing user's scale
	m, s = ResolveAIModelAndScaleFromList(installed, "missing-model", 3)
	if m != "custom-model-alpha" || s != 3 {
		t.Fatalf("expected (custom-model-alpha, 3), got (%s, %d)", m, s)
	}
}

func TestDetectModelNativeScaleFromParam(t *testing.T) {
	backendDir, _ := locateWorkspaceDirs(t)
	modelsDir := filepath.Join(backendDir, "tools", "realesrgan", "models")

	expected := map[string]int{
		"realesr-animevideov3-x2": 2,
		"realesr-animevideov3-x3": 3,
		"realesr-animevideov3-x4": 4,
		"realesrgan-x4plus-anime": 4,
		"realesrgan-x4plus":       4,
	}
	for model, want := range expected {
		paramPath := filepath.Join(modelsDir, model+".param")
		if _, err := os.Stat(paramPath); err != nil {
			t.Skipf("param missing: %s", paramPath)
		}
		got := DetectModelNativeScaleFromParam(paramPath)
		if got != want {
			t.Fatalf("DetectModelNativeScaleFromParam(%s) = %d, want %d", model, got, want)
		}
	}

	// Missing file falls back cleanly to defaultAIUpscaleScale
	if got := DetectModelNativeScaleFromParam(filepath.Join(t.TempDir(), "missing.param")); got != defaultAIUpscaleScale {
		t.Fatalf("missing param fallback = %d, want %d", got, defaultAIUpscaleScale)
	}
}

func TestFinalizeUpscaledPNGAndAdaptiveHelpers(t *testing.T) {
	if chooseAdaptiveTileSize(180) != "0" || chooseAdaptiveTileSize(400) != "0" {
		t.Fatalf("expected small image <=400px to use tile size 0")
	}
	if chooseAdaptiveTileSize(401) != "256" || chooseAdaptiveTileSize(1654) != "256" {
		t.Fatalf("expected image >400px to use tile size 256")
	}

	if !shouldRunExtraNativeAIPass(2, 4, 2, 360) {
		t.Fatalf("expected extra pass for 2->4 with x2 model")
	}
	if !shouldRunExtraNativeAIPass(2, 3, 2, 360) {
		t.Fatalf("expected extra pass for 2->3 with x2 model (supersample 4x->3x)")
	}
	if shouldRunExtraNativeAIPass(4, 2, 4, 800) {
		t.Fatalf("unexpected extra pass when target < current")
	}
	if shouldRunExtraNativeAIPass(2, 4, 2, 2400) {
		t.Fatalf("unexpected extra pass when intermediate exceeds VRAM safety threshold")
	}

	// Test cropping + SSAA CatmullRom downsample
	tmp := t.TempDir()
	paddedSrc := filepath.Join(tmp, "padded.png")
	srcImg := image.NewRGBA(image.Rect(0, 0, 416, 416)) // simulates 101x103 padded to 104x104 -> x4
	for y := 0; y < 416; y++ {
		for x := 0; x < 416; x++ {
			c := color.RGBA{R: 10, G: 200, B: 30, A: 255}
			if x >= 404 || y >= 412 {
				c = color.RGBA{R: 255, G: 0, B: 0, A: 255} // padding strip that must be cropped out
			}
			srcImg.SetRGBA(x, y, c)
		}
	}
	f, err := os.Create(paddedSrc)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, srcImg); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	// Unpad 404x412 and SSAA downsample to 2x of 101x103 = 202x206
	outPath := filepath.Join(tmp, "final_2x.png")
	if err := finalizeUpscaledPNG(paddedSrc, outPath, 404, 412, 202, 206); err != nil {
		t.Fatalf("finalizeUpscaledPNG error: %v", err)
	}
	dec, err := decodeImageFile(outPath)
	if err != nil {
		t.Fatal(err)
	}
	if dec.Bounds().Dx() != 202 || dec.Bounds().Dy() != 206 {
		t.Fatalf("expected 202x206, got %dx%d", dec.Bounds().Dx(), dec.Bounds().Dy())
	}
	r, g, b, _ := dec.At(200, 204).RGBA()
	if (g >> 8) < 150 || (r >> 8) > 80 || (b >> 8) > 80 {
		t.Fatalf("expected unpadded green corner pixel, got RGB=(%d,%d,%d)", r>>8, g>>8, b>>8)
	}
}

func TestRealEsrganNoTileScramblingAcrossModelsAndManualScales(t *testing.T) {
	backendDir, _ := locateWorkspaceDirs(t)
	origWd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(backendDir); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chdir(origWd) }()

	if _, _, err := resolveRealEsrganToolPaths(); err != nil {
		t.Skipf("realesrgan binary unavailable: %v", err)
	}

	// Create 401x503 (>400px so GPU -t 256 tiling runs, AND non-multiple-of-4 for x4plus padding!)
	// 4 distinct solid quadrants: TL=Red, TR=Green, BL=Blue, BR=Yellow
	const origW, origH = 401, 503
	srcImg := image.NewRGBA(image.Rect(0, 0, origW, origH))
	for y := 0; y < origH; y++ {
		for x := 0; x < origW; x++ {
			var c color.RGBA
			switch {
			case x < origW/2 && y < origH/2:
				c = color.RGBA{R: 235, G: 25, B: 25, A: 255}
			case x >= origW/2 && y < origH/2:
				c = color.RGBA{R: 25, G: 225, B: 25, A: 255}
			case x < origW/2 && y >= origH/2:
				c = color.RGBA{R: 25, G: 40, B: 235, A: 255}
			default:
				c = color.RGBA{R: 235, G: 225, B: 25, A: 255}
			}
			srcImg.SetRGBA(x, y, c)
		}
	}

	tmp := t.TempDir()
	inPath := filepath.Join(tmp, "quadrants_401x503.png")
	f, err := os.Create(inPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, srcImg); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()

	verifyQuadrants := func(t *testing.T, imgPath string, wantScale int) {
		t.Helper()
		outImg, err := decodeImageFile(imgPath)
		if err != nil {
			t.Fatalf("decode %s: %v", imgPath, err)
		}
		gotW, gotH := outImg.Bounds().Dx(), outImg.Bounds().Dy()
		if gotW != origW*wantScale || gotH != origH*wantScale {
			t.Fatalf("expected dims %dx%d, got %dx%d", origW*wantScale, origH*wantScale, gotW, gotH)
		}
		checkPt := func(label string, px, py int, wantR, wantG, wantB bool) {
			r16, g16, b16, _ := outImg.At(px, py).RGBA()
			r, g, b := r16>>8, g16>>8, b16>>8
			if wantR != (r > 150) || wantG != (g > 150) || wantB != (b > 150) {
				t.Fatalf("tile scrambling detected at %s (%d,%d) in %s: got RGB=(%d,%d,%d)", label, px, py, imgPath, r, g, b)
			}
		}
		checkPt("TL-Red", gotW/4, gotH/4, true, false, false)
		checkPt("TR-Green", (gotW*3)/4, gotH/4, false, true, false)
		checkPt("BL-Blue", gotW/4, (gotH*3)/4, false, false, true)
		checkPt("BR-Yellow", (gotW*3)/4, (gotH*3)/4, true, true, false)
	}

	// 1. realesrgan-x4plus-anime with user manual scale = 2 (mismatch with native 4x used to scramble!)
	outX4PlusS2 := filepath.Join(tmp, "out_x4plus_anime_s2.png")
	if err := EnhanceImageWithAI(inPath, outX4PlusS2, 2, "realesrgan-x4plus-anime"); err != nil {
		t.Fatalf("EnhanceImageWithAI(x4plus-anime, 2) error: %v", err)
	}
	verifyQuadrants(t, outX4PlusS2, 2)

	// 2. realesr-animevideov3-x2 with user manual scale = 4 (two native 2x passes, NO tile scrambling!)
	outV3X2S4 := filepath.Join(tmp, "out_v3x2_s4.png")
	if err := EnhanceImageWithAI(inPath, outV3X2S4, 4, "realesr-animevideov3-x2"); err != nil {
		t.Fatalf("EnhanceImageWithAI(v3-x2, 4) error: %v", err)
	}
	verifyQuadrants(t, outV3X2S4, 4)
}

func TestEdgePreservingLumaCrispAndJpgPreconvert(t *testing.T) {
	// 1. Verify applyEdgePreservingLumaCrisp sharpens soft edge transitions while leaving flat interiors untouched
	img := image.NewRGBA(image.Rect(0, 0, 24, 24))
	for y := 0; y < 24; y++ {
		for x := 0; x < 24; x++ {
			var v uint8
			switch {
			case x < 10:
				v = 30
			case x == 10:
				v = 90
			case x == 11:
				v = 170
			default:
				v = 235
			}
			img.SetRGBA(x, y, color.RGBA{R: v, G: v, B: v, A: 255})
		}
	}
	beforeStep := int(img.RGBAAt(11, 12).R) - int(img.RGBAAt(10, 12).R)
	applyEdgePreservingLumaCrisp(img, 0.44, 3.5, 42.0)
	afterStep := int(img.RGBAAt(11, 12).R) - int(img.RGBAAt(10, 12).R)
	if afterStep <= beforeStep {
		t.Fatalf("expected luma crisp to increase edge slope: before=%d after=%d", beforeStep, afterStep)
	}
	if gotFlat := img.RGBAAt(3, 12); gotFlat.R != 30 || gotFlat.G != 30 || gotFlat.B != 30 {
		t.Fatalf("expected flat region unchanged, got %+v", gotFlat)
	}

	// 2. Verify prepareInputForRealEsrgan always converts mod-4 .jpg/.jpeg into clean lossless .png
	tmp := t.TempDir()
	jpgPath := filepath.Join(tmp, "mod4.jpeg")
	srcMod4 := image.NewRGBA(image.Rect(0, 0, 16, 16))
	fJpg, err := os.Create(jpgPath)
	if err != nil {
		t.Fatal(err)
	}
	_ = png.Encode(fJpg, srcMod4) // format doesn't affect extension check; test valid PNG inside .jpeg too or real JPEG
	_ = fJpg.Close()
	// Replace with actual valid JPEG bytes
	_ = os.Remove(jpgPath)
	fJpg2, err := os.Create(jpgPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := jpeg.Encode(fJpg2, srcMod4, &jpeg.Options{Quality: 85}); err != nil {
		t.Fatal(err)
	}
	_ = fJpg2.Close()

	prePath, cleanup, _, err := prepareInputForRealEsrgan(jpgPath, tmp, "realesrgan-x4plus-anime")
	if err != nil {
		t.Fatalf("prepareInputForRealEsrgan error: %v", err)
	}
	if !cleanup || filepath.Ext(prePath) != ".png" {
		t.Fatalf("expected mod-4 .jpeg to convert to clean temporary .png, got path=%s cleanup=%v", prePath, cleanup)
	}
}
