package service

import (
	"bufio"
	"fmt"
	"image"
	"image/color"
	_ "image/gif"
	_ "image/jpeg"
	"image/png"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

const defaultAIUpscaleScale = 4

// Batas aman proses Vulkan GPU simultan agar 1GB VRAM tidak thrashing
var aiGpuSem = make(chan struct{}, 2)

type cachedNativeScaleEntry struct {
	modTime time.Time
	scale   int
}

var (
	aiModelsCacheMu    sync.RWMutex
	cachedModelsDir    string
	cachedModelsMod    time.Time
	cachedModelsList   []string
	aiScaleCacheMu     sync.RWMutex
	cachedNativeScales = make(map[string]cachedNativeScaleEntry)
	fastBestSpeedPng   = png.Encoder{CompressionLevel: png.BestSpeed}
)

// GetAvailableAIModels secara dinamis memindai folder models/ untuk mendeteksi semua model yang tersedia
func GetAvailableAIModels() ([]string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return nil, fmt.Errorf("gagal mendapatkan working directory: %v", err)
	}

	modelsDir := filepath.Join(wd, "tools", "realesrgan", "models")

	// Jika folder models belum ada, kembalikan slice kosong
	dirInfo, err := os.Stat(modelsDir)
	if os.IsNotExist(err) {
		return []string{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("gagal membaca folder models: %v", err)
	}

	aiModelsCacheMu.RLock()
	if cachedModelsList != nil && cachedModelsDir == modelsDir && cachedModelsMod.Equal(dirInfo.ModTime()) {
		out := append([]string(nil), cachedModelsList...)
		aiModelsCacheMu.RUnlock()
		return out, nil
	}
	aiModelsCacheMu.RUnlock()

	files, err := os.ReadDir(modelsDir)
	if err != nil {
		return nil, fmt.Errorf("gagal membaca folder models: %v", err)
	}

	type modelPair struct {
		hasParam bool
		hasBin   bool
	}
	modelPairs := make(map[string]*modelPair)
	for _, file := range files {
		if file.IsDir() {
			continue
		}
		// Ambil nama file dan buang ekstensi (.param atau .bin) untuk mendapatkan nama model yang bersih
		ext := strings.ToLower(filepath.Ext(file.Name()))
		if ext != ".param" && ext != ".bin" {
			continue
		}
		modelName := strings.TrimSuffix(file.Name(), filepath.Ext(file.Name()))
		pair, exists := modelPairs[modelName]
		if !exists {
			pair = &modelPair{}
			modelPairs[modelName] = pair
		}
		if ext == ".param" {
			pair.hasParam = true
		} else {
			pair.hasBin = true
		}
	}

	var models []string
	for modelName, pair := range modelPairs {
		if pair.hasParam && pair.hasBin {
			models = append(models, modelName)
		}
	}
	sort.Strings(models)

	aiModelsCacheMu.Lock()
	cachedModelsDir = modelsDir
	cachedModelsMod = dirInfo.ModTime()
	cachedModelsList = append([]string(nil), models...)
	aiModelsCacheMu.Unlock()

	return models, nil
}

// ResolveAIModelAndScale meneruskan pilihan model terpasang dan scale integer dari pengguna tanpa membaca skala dari nama model
func ResolveAIModelAndScale(inputModel string, inputScale int) (string, int) {
	available, _ := GetAvailableAIModels()
	return ResolveAIModelAndScaleFromList(available, inputModel, inputScale)
}

// ResolveAIModelAndScaleFromList memisahkan resolusi dinamis daftar model dan skala eksplisit pengguna
func ResolveAIModelAndScaleFromList(available []string, inputModel string, inputScale int) (string, int) {
	raw := strings.TrimSpace(inputModel)
	targetScale := inputScale
	if targetScale <= 0 {
		targetScale = defaultAIUpscaleScale
	}
	if targetScale > 16 {
		targetScale = 16
	}

	var resolvedModel string
	if len(available) > 0 {
		for _, m := range available {
			if strings.EqualFold(m, raw) {
				resolvedModel = m
				break
			}
		}
		if resolvedModel == "" {
			resolvedModel = available[0]
		}
	} else if raw != "" {
		resolvedModel = raw
	} else {
		resolvedModel = "realesr-animevideov3-x4"
	}

	return resolvedModel, targetScale
}

// DetectModelNativeScaleFromParam membaca arsitektur graf NCNN (.param) secara dinamis
// (PixelShuffle/DepthToSpace, Interp, Deconvolution, stride downsample) untuk mengetahui faktor
// pembesaran asli yang WAJIB diberikan ke flag `-s` biner realesrgan-ncnn-vulkan.exe agar
// penggabungan tile GPU tidak pernah salah indeks / pecah kotak-kotak.
func DetectModelNativeScaleFromParam(paramPath string) int {
	f, err := os.Open(paramPath)
	if err != nil {
		return defaultAIUpscaleScale
	}
	defer f.Close()

	blobScales := make(map[string]float64)
	var lastOutBlob string
	lineIdx := 0

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		lineIdx++
		// Baris 1 = magic (7767517), Baris 2 = layer_count blob_count
		if lineIdx <= 2 {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		layerType := fields[0]
		inCount, errIn := strconv.Atoi(fields[2])
		outCount, errOut := strconv.Atoi(fields[3])
		if errIn != nil || errOut != nil || inCount < 0 || outCount < 0 {
			continue
		}
		minEnd := 4 + inCount + outCount
		if len(fields) < minEnd {
			continue
		}

		inBlobs := fields[4 : 4+inCount]
		outBlobs := fields[4+inCount : minEnd]
		params := fields[minEnd:]

		if layerType == "Input" {
			for _, ob := range outBlobs {
				blobScales[ob] = 1.0
				lastOutBlob = ob
			}
			continue
		}

		baseScale := 0.0
		for _, ib := range inBlobs {
			if s, ok := blobScales[ib]; ok && s > baseScale {
				baseScale = s
			}
		}
		if baseScale <= 0 {
			baseScale = 1.0
		}

		mult := 1.0
		switch layerType {
		case "PixelShuffle", "DepthToSpace":
			if val, ok := parseParamFloat(params, "0"); ok && val > 0 {
				mult = val
			}
		case "Interp":
			// Pada NCNN Interp: 1=height_scale, 2=width_scale (bila mode skala dipakai)
			if hScale, ok := parseParamFloat(params, "1"); ok && hScale > 0 {
				mult = hScale
			} else if wScale, ok := parseParamFloat(params, "2"); ok && wScale > 0 {
				mult = wScale
			}
		case "Deconvolution", "DeconvolutionDepthWise":
			if stride, ok := parseParamFloat(params, "3"); ok && stride > 1 {
				mult = stride
			}
		case "Convolution", "ConvolutionDepthWise", "Pooling":
			if stride, ok := parseParamFloat(params, "3"); ok && stride > 1 {
				mult = 1.0 / stride
			}
		}

		nextScale := baseScale * mult
		for _, ob := range outBlobs {
			blobScales[ob] = nextScale
			lastOutBlob = ob
		}
	}

	if err := scanner.Err(); err != nil {
		return defaultAIUpscaleScale
	}

	rawScale := 0.0
	if s, ok := blobScales["output"]; ok && s > 0 {
		rawScale = s
	} else if lastOutBlob != "" {
		rawScale = blobScales[lastOutBlob]
	}

	rounded := int(math.Round(rawScale))
	if rounded < 1 || rounded > 16 {
		return defaultAIUpscaleScale
	}
	return rounded
}

func parseParamFloat(params []string, key string) (float64, bool) {
	prefix := key + "="
	for _, p := range params {
		if strings.HasPrefix(p, prefix) {
			v, err := strconv.ParseFloat(strings.TrimPrefix(p, prefix), 64)
			if err == nil {
				return v, true
			}
		}
	}
	return 0, false
}

func detectModelNativeScale(modelsDir, modelName string) int {
	paramPath := filepath.Join(modelsDir, modelName+".param")
	info, err := os.Stat(paramPath)
	if err != nil {
		return defaultAIUpscaleScale
	}

	aiScaleCacheMu.RLock()
	if cached, ok := cachedNativeScales[paramPath]; ok && cached.modTime.Equal(info.ModTime()) && cached.scale > 0 {
		aiScaleCacheMu.RUnlock()
		return cached.scale
	}
	aiScaleCacheMu.RUnlock()

	detected := DetectModelNativeScaleFromParam(paramPath)
	aiScaleCacheMu.Lock()
	cachedNativeScales[paramPath] = cachedNativeScaleEntry{
		modTime: info.ModTime(),
		scale:   detected,
	}
	aiScaleCacheMu.Unlock()
	return detected
}

func resolveRealEsrganToolPaths() (string, string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", "", fmt.Errorf("gagal mendapatkan working directory: %v", err)
	}

	toolDir := filepath.Join(wd, "tools", "realesrgan")
	execPath := filepath.Join(toolDir, "realesrgan-ncnn-vulkan.exe")
	if _, err := os.Stat(execPath); os.IsNotExist(err) {
		if exeSelf, exeErr := os.Executable(); exeErr == nil {
			altDir := filepath.Join(filepath.Dir(exeSelf), "tools", "realesrgan")
			altExec := filepath.Join(altDir, "realesrgan-ncnn-vulkan.exe")
			if _, statErr := os.Stat(altExec); statErr == nil {
				toolDir = altDir
				execPath = altExec
			}
		}
	}
	if _, err := os.Stat(execPath); os.IsNotExist(err) {
		return "", "", fmt.Errorf("file binary Real-ESRGAN tidak ditemukan di: %s", execPath)
	}
	return toolDir, filepath.Join(toolDir, "models"), nil
}

func chooseAdaptiveTileSize(maxDim int) string {
	// Empiris GPU AMD Vega 8: tile 0 (~auto) lebih cepat untuk gambar kecil <= 400px,
	// sementara tile 256 paling cepat dan aman VRAM untuk halaman/gambar besar.
	if maxDim > 0 && maxDim <= 400 {
		return "0"
	}
	return "256"
}

func readImageDimensions(path string) (int, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	cfg, _, err := image.DecodeConfig(f)
	if err != nil {
		return 0, 0, err
	}
	return cfg.Width, cfg.Height, nil
}

func shouldRunExtraNativeAIPass(currentScale, targetScale, nativeScale, currentMaxDim int) bool {
	if nativeScale < 2 || currentScale >= targetScale {
		return false
	}
	// Batasi input pass ke-2 <= 2048px agar tetap cepat dan tidak menghabiskan VRAM 1GB
	if currentMaxDim <= 0 || currentMaxDim > 2048 {
		return false
	}
	if currentScale*nativeScale <= targetScale {
		return true
	}
	// Jika target > 1.25x hasil pass saat ini (mis. user minta 3x pada model x2),
	// jalankan pass ke-2 (jadi 4x) lalu SSAA CatmullRom turun ke 3x agar jauh lebih tajam.
	return float64(targetScale) > float64(currentScale)*1.25
}

func runRealEsrganSingle(toolDir, modelsDir, modelName string, nativeScale int, tileSize, inPath, outPath string) error {
	aiGpuSem <- struct{}{}
	defer func() { <-aiGpuSem }()

	cmd := exec.Command(
		"./realesrgan-ncnn-vulkan.exe",
		"-i", inPath,
		"-o", outPath,
		"-n", modelName,
		"-s", fmt.Sprintf("%d", nativeScale),
		"-m", modelsDir,
		"-t", tileSize,
		"-g", "0",
		"-j", "2:2:2",
	)
	cmd.Dir = toolDir

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("gagal Upscale AI model '%s' (native %dx): %v, detail: %s", modelName, nativeScale, err, string(output))
	}
	return nil
}

func runRealEsrganDirectory(toolDir, modelsDir, modelName string, nativeScale int, tileSize, inDir, outDir string) error {
	aiGpuSem <- struct{}{}
	defer func() { <-aiGpuSem }()

	cmd := exec.Command(
		"./realesrgan-ncnn-vulkan.exe",
		"-i", inDir,
		"-o", outDir,
		"-n", modelName,
		"-s", fmt.Sprintf("%d", nativeScale),
		"-m", modelsDir,
		"-t", tileSize,
		"-g", "0",
		"-j", "2:2:2",
		"-f", "png",
	)
	cmd.Dir = toolDir

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("gagal Batch Upscale AI model '%s' (native %dx): %v, detail: %s", modelName, nativeScale, err, string(output))
	}
	return nil
}

// prepareInputForRealEsrgan menangani konversi ke PNG lossless (agar JPG/JPEG tidak didekode
// secara lossy oleh stb_image di realesrgan) serta padding kelipatan-4 bila model x4plus.
// Mengembalikan (pathSiapProses, perluHapusSementara, apakahDiPadding, err).
func prepareInputForRealEsrgan(srcPath, tempDir, modelName string) (string, bool, bool, error) {
	extLower := strings.ToLower(filepath.Ext(srcPath))
	needsFormatConvert := extLower != ".png"
	needsPad := false
	if strings.Contains(strings.ToLower(modelName), "x4plus") {
		needsPad, _ = imageNeedsMultiple4Pad(srcPath)
	}
	if !needsFormatConvert && !needsPad {
		return srcPath, false, false, nil
	}

	tmpF, errTmp := os.CreateTemp(tempDir, "temp_padded_*.png")
	if errTmp != nil {
		return srcPath, false, false, nil
	}
	tempPaddedPath := tmpF.Name()
	_ = tmpF.Close()

	if err := padImageForX4Plus(srcPath, tempPaddedPath); err != nil {
		_ = os.Remove(tempPaddedPath)
		return srcPath, false, false, nil
	}
	return tempPaddedPath, true, true, nil
}

// applyEdgePreservingLumaCrisp menajamkan tepi pada kanal luminansi (Y) menggunakan
// separabel 5-tap blur + adaptive threshold agar bebas halo & bebas noise di area gradasi halus,
// menyamai ketajaman raster PDF resolusi tinggi.
func applyEdgePreservingLumaCrisp(rgba *image.RGBA, amount, threshold, maxDelta float64) {
	if rgba == nil {
		return
	}
	b := rgba.Bounds()
	w, h := b.Dx(), b.Dy()
	if w < 5 || h < 5 || amount <= 0 {
		return
	}

	total := w * h
	luma := make([]float64, total)
	tmpBlur := make([]float64, total)

	clampIdx := func(v, maxV int) int {
		if v < 0 {
			return 0
		}
		if v >= maxV {
			return maxV - 1
		}
		return v
	}

	parallelRows := func(fn func(yStart, yEnd int)) {
		workers := runtime.NumCPU()
		if workers > 8 {
			workers = 8
		}
		if workers > h {
			workers = h
		}
		if workers <= 1 {
			fn(0, h)
			return
		}
		var wg sync.WaitGroup
		chunk := (h + workers - 1) / workers
		for start := 0; start < h; start += chunk {
			end := start + chunk
			if end > h {
				end = h
			}
			wg.Add(1)
			go func(ys, ye int) {
				defer wg.Done()
				fn(ys, ye)
			}(start, end)
		}
		wg.Wait()
	}

	// Pass 1: ekstrak luma + horizontal 5-tap [1 4 6 4 1]/16
	parallelRows(func(yStart, yEnd int) {
		for y := yStart; y < yEnd; y++ {
			off := y * rgba.Stride
			row := y * w
			for x := 0; x < w; x++ {
				i := off + x*4
				luma[row+x] = 0.299*float64(rgba.Pix[i]) + 0.587*float64(rgba.Pix[i+1]) + 0.114*float64(rgba.Pix[i+2])
			}
			for x := 0; x < w; x++ {
				tmpBlur[row+x] = (luma[row+clampIdx(x-2, w)] +
					4.0*luma[row+clampIdx(x-1, w)] +
					6.0*luma[row+x] +
					4.0*luma[row+clampIdx(x+1, w)] +
					luma[row+clampIdx(x+2, w)]) / 16.0
			}
		}
	})

	// Pass 2: vertikal 5-tap + koreksi luminansi terkendali langsung ke RGB
	parallelRows(func(yStart, yEnd int) {
		for y := yStart; y < yEnd; y++ {
			off := y * rgba.Stride
			row := y * w
			rM2 := clampIdx(y-2, h) * w
			rM1 := clampIdx(y-1, h) * w
			r0 := row
			rP1 := clampIdx(y+1, h) * w
			rP2 := clampIdx(y+2, h) * w
			for x := 0; x < w; x++ {
				blurVal := (tmpBlur[rM2+x] +
					4.0*tmpBlur[rM1+x] +
					6.0*tmpBlur[r0+x] +
					4.0*tmpBlur[rP1+x] +
					tmpBlur[rP2+x]) / 16.0
				diff := luma[row+x] - blurVal
				if diff < threshold && diff > -threshold {
					continue
				}
				// Soft knee di sekitar threshold untuk cegah transisi kasar
				if diff > 0 {
					diff -= threshold * 0.5
				} else {
					diff += threshold * 0.5
				}
				delta := diff * amount
				if delta > maxDelta {
					delta = maxDelta
				} else if delta < -maxDelta {
					delta = -maxDelta
				}
				i := off + x*4
				nr := float64(rgba.Pix[i]) + delta
				ng := float64(rgba.Pix[i+1]) + delta
				nb := float64(rgba.Pix[i+2]) + delta
				if nr < 0 {
					nr = 0
				} else if nr > 255 {
					nr = 255
				}
				if ng < 0 {
					ng = 0
				} else if ng > 255 {
					ng = 255
				}
				if nb < 0 {
					nb = 0
				} else if nb > 255 {
					nb = 255
				}
				rgba.Pix[i] = uint8(nr + 0.5)
				rgba.Pix[i+1] = uint8(ng + 0.5)
				rgba.Pix[i+2] = uint8(nb + 0.5)
			}
		}
	})
}

func chooseSSAAExtraModel(modelsDir, resolvedModel string, origMaxDim, currentMaxDim, currentScale, targetScale int) (string, int, bool) {
	// Sudah tercakup oleh extra pass bila user minta targetScale > currentScale;
	// khusus gambar input kecil (<= 480px) di target normal (mis. 4x), jalankan 1 pass SSAA cepat
	// agar detail rambut/tepi setajam raster PDF 200 DPI.
	if currentScale < targetScale || origMaxDim <= 0 || origMaxDim > 480 {
		return "", 0, false
	}
	if currentMaxDim <= 0 || currentMaxDim > 1024 {
		return "", 0, false
	}
	lower := strings.ToLower(resolvedModel)
	if strings.Contains(lower, "anime") {
		v3x2 := "realesr-animevideov3-x2"
		if _, err := os.Stat(filepath.Join(modelsDir, v3x2+".param")); err == nil {
			if _, errBin := os.Stat(filepath.Join(modelsDir, v3x2+".bin")); errBin == nil {
				return v3x2, 2, true
			}
		}
	}
	if currentMaxDim <= 512 {
		ns := detectModelNativeScale(modelsDir, resolvedModel)
		if ns >= 2 {
			return resolvedModel, ns, true
		}
	}
	return "", 0, false
}

// finalizeUpscaledPNG memangkas kembali sisa padding kelipatan-4 dan melakukan resampling presisi
// (SSAA / CatmullRom) bila skala manual pengguna berbeda dari skala native model Real-ESRGAN.
func finalizeUpscaledPNG(srcPngPath, dstPngPath string, unpadW, unpadH, finalW, finalH int) error {
	return finalizeUpscaledPNGWithOptions(srcPngPath, dstPngPath, unpadW, unpadH, finalW, finalH, false)
}

func finalizeUpscaledPNGWithOptions(srcPngPath, dstPngPath string, unpadW, unpadH, finalW, finalH int, crispEdges bool) error {
	srcW, srcH, err := readImageDimensions(srcPngPath)
	if err != nil {
		return err
	}

	if unpadW <= 0 || unpadW > srcW {
		unpadW = srcW
	}
	if unpadH <= 0 || unpadH > srcH {
		unpadH = srcH
	}
	if finalW <= 0 {
		finalW = unpadW
	}
	if finalH <= 0 {
		finalH = unpadH
	}

	// Fast-path: tidak ada padding, dimensi tepat, dan tidak perlu penajaman tepi tambahan -> zero re-encode!
	if !crispEdges && unpadW == srcW && unpadH == srcH && finalW == srcW && finalH == srcH {
		if strings.EqualFold(filepath.Clean(srcPngPath), filepath.Clean(dstPngPath)) {
			return nil
		}
		return moveFileSafe(srcPngPath, dstPngPath)
	}

	img, err := decodeImageFile(srcPngPath)
	if err != nil {
		return err
	}

	b := img.Bounds()
	cropRect := image.Rect(b.Min.X, b.Min.Y, b.Min.X+unpadW, b.Min.Y+unpadH)

	var rgbaOut *image.RGBA
	if unpadW == finalW && unpadH == finalH {
		rgbaOut = image.NewRGBA(image.Rect(0, 0, unpadW, unpadH))
		draw.Draw(rgbaOut, rgbaOut.Bounds(), img, cropRect.Min, draw.Src)
	} else {
		// Crop area aktif lalu resample CatmullRom ke resolusi target persis (SSAA tajam tanpa pecah tile)
		rgbaOut = image.NewRGBA(image.Rect(0, 0, finalW, finalH))
		draw.CatmullRom.Scale(rgbaOut, rgbaOut.Bounds(), img, cropRect, draw.Src, nil)
	}

	if crispEdges {
		applyEdgePreservingLumaCrisp(rgbaOut, 0.44, 3.5, 42.0)
	}

	tmpOutPath := dstPngPath + ".tmp.png"
	outFile, err := os.Create(tmpOutPath)
	if err != nil {
		return err
	}
	encErr := fastBestSpeedPng.Encode(outFile, rgbaOut)
	closeErr := outFile.Close()
	if encErr != nil {
		_ = os.Remove(tmpOutPath)
		return encErr
	}
	if closeErr != nil {
		_ = os.Remove(tmpOutPath)
		return closeErr
	}
	return moveFileSafe(tmpOutPath, dstPngPath)
}

// EnhanceImageWithAI memperjelas dan membesarkan resolusi gambar dengan Real-ESRGAN menggunakan skala
// native graf `.param` untuk menghindari kerusakan tile, lalu menyelaraskan ke skala integer pilihan pengguna.
func EnhanceImageWithAI(inputPath, outputPath string, scale int, modelName string) error {
	toolDir, modelsDir, err := resolveRealEsrganToolPaths()
	if err != nil {
		return err
	}

	resolvedModel, targetScale := ResolveAIModelAndScale(modelName, scale)
	nativeScale := detectModelNativeScale(modelsDir, resolvedModel)

	absInputPath, err := filepath.Abs(inputPath)
	if err != nil {
		return fmt.Errorf("gagal meresolusi path input: %v", err)
	}
	absOutputPath, err := filepath.Abs(outputPath)
	if err != nil {
		return fmt.Errorf("gagal meresolusi path output: %v", err)
	}

	outputDir := filepath.Dir(absOutputPath)
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %v", err)
	}

	origW, origH, dimErr := readImageDimensions(absInputPath)
	workDir, err := os.MkdirTemp(outputDir, "mwx_ai_single_*")
	if err != nil {
		return fmt.Errorf("gagal membuat temp dir AI: %w", err)
	}
	defer os.RemoveAll(workDir)

	pass1Input, cleanupP1, _, err := prepareInputForRealEsrgan(absInputPath, workDir, resolvedModel)
	if err != nil {
		return err
	}
	if cleanupP1 {
		defer os.Remove(pass1Input)
	}

	maxDim := origW
	if origH > maxDim {
		maxDim = origH
	}
	if maxDim == 0 {
		if pw, ph, pErr := readImageDimensions(pass1Input); pErr == nil {
			if pw > ph {
				maxDim = pw
			} else {
				maxDim = ph
			}
			if origW == 0 {
				origW, origH = pw, ph
			}
		}
	}

	pass1Out := filepath.Join(workDir, "pass1.png")
	if err := runRealEsrganSingle(toolDir, modelsDir, resolvedModel, nativeScale, chooseAdaptiveTileSize(maxDim), pass1Input, pass1Out); err != nil {
		return err
	}

	currentOut := pass1Out
	currentScale := nativeScale

	// Jika target scale user lebih besar dari nativeScale (mis. 4x pada animevideov3-x2, atau 8x pada x4plus),
	// lakukan maksimal 1 pass AI tambahan saat ukuran masih aman untuk VRAM GPU.
	currentW := origW * currentScale
	currentH := origH * currentScale
	if pw, ph, pErr := readImageDimensions(currentOut); pErr == nil {
		// Pangkas padding dari pass 1 sebelum menentukan apakah pass 2 berjalan
		if dimErr == nil && (pw != origW*currentScale || ph != origH*currentScale) {
			croppedPass1 := filepath.Join(workDir, "pass1_cropped.png")
			if cErr := finalizeUpscaledPNG(currentOut, croppedPass1, origW*currentScale, origH*currentScale, origW*currentScale, origH*currentScale); cErr == nil {
				currentOut = croppedPass1
				pw, ph = origW*currentScale, origH*currentScale
			}
		}
		if origW == 0 {
			origW = pw / currentScale
			origH = ph / currentScale
		}
		currentW, currentH = pw, ph
	}

	nextMaxDim := currentW
	if currentH > nextMaxDim {
		nextMaxDim = currentH
	}
	if shouldRunExtraNativeAIPass(currentScale, targetScale, nativeScale, nextMaxDim) {
		pass2Input, cleanupP2, _, _ := prepareInputForRealEsrgan(currentOut, workDir, resolvedModel)
		if cleanupP2 {
			defer os.Remove(pass2Input)
		}
		pass2Out := filepath.Join(workDir, "pass2.png")
		if err := runRealEsrganSingle(toolDir, modelsDir, resolvedModel, nativeScale, chooseAdaptiveTileSize(nextMaxDim), pass2Input, pass2Out); err != nil {
			return err
		}
		currentOut = pass2Out
		currentScale *= nativeScale
	} else if ssaaModel, ssaaScale, okSSAA := chooseSSAAExtraModel(modelsDir, resolvedModel, maxDim, nextMaxDim, currentScale, targetScale); okSSAA {
		pass2Input, cleanupP2, _, _ := prepareInputForRealEsrgan(currentOut, workDir, ssaaModel)
		if cleanupP2 {
			defer os.Remove(pass2Input)
		}
		pass2Out := filepath.Join(workDir, "pass2_ssaa.png")
		if err := runRealEsrganSingle(toolDir, modelsDir, ssaaModel, ssaaScale, chooseAdaptiveTileSize(nextMaxDim), pass2Input, pass2Out); err == nil {
			currentOut = pass2Out
			currentScale *= ssaaScale
		}
	}

	unpadW := origW * currentScale
	unpadH := origH * currentScale
	finalW := origW * targetScale
	finalH := origH * targetScale
	if unpadW <= 0 || unpadH <= 0 {
		if rw, rh, rErr := readImageDimensions(currentOut); rErr == nil {
			unpadW, unpadH = rw, rh
			finalW, finalH = rw, rh
		}
	}

	return finalizeUpscaledPNGWithOptions(currentOut, absOutputPath, unpadW, unpadH, finalW, finalH, true)
}

// EnhanceDirectoryWithAI menjalankan Real-ESRGAN NCNN dalam mode batch direktori (-i dir -o dir -f png)
// dengan menjaga `-s` selalu sesuai skala native model `.param` lalu memfinalisasi skala target user secara paralel.
func EnhanceDirectoryWithAI(inputDir, outputDir string, scale int, modelName string) error {
	toolDir, modelsDir, err := resolveRealEsrganToolPaths()
	if err != nil {
		return err
	}

	absInputDir, err := filepath.Abs(inputDir)
	if err != nil {
		return fmt.Errorf("gagal meresolusi direktori input: %v", err)
	}
	absOutputDir, err := filepath.Abs(outputDir)
	if err != nil {
		return fmt.Errorf("gagal meresolusi direktori output: %v", err)
	}
	if err := os.MkdirAll(absOutputDir, 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output AI: %v", err)
	}

	resolvedModel, targetScale := ResolveAIModelAndScale(modelName, scale)
	nativeScale := detectModelNativeScale(modelsDir, resolvedModel)

	entries, err := os.ReadDir(absInputDir)
	if err != nil {
		return fmt.Errorf("gagal membaca direktori input: %w", err)
	}

	type itemMeta struct {
		stem  string
		origW int
		origH int
	}
	var items []itemMeta
	maxInputDim := 0
	anyNeedsPad := false
	isX4Plus := strings.Contains(strings.ToLower(resolvedModel), "x4plus")

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		src := filepath.Join(absInputDir, e.Name())
		w, h, dimErr := readImageDimensions(src)
		if dimErr != nil {
			continue
		}
		if w > maxInputDim {
			maxInputDim = w
		}
		if h > maxInputDim {
			maxInputDim = h
		}
		if isX4Plus && ((w&3) != 0 || (h&3) != 0) {
			anyNeedsPad = true
		}
		stem := strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))
		items = append(items, itemMeta{stem: stem, origW: w, origH: h})
	}
	if len(items) == 0 {
		return fmt.Errorf("tidak ada gambar valid di direktori input AI")
	}

	workRoot, err := os.MkdirTemp("", "mwx_batch_ai_*")
	if err != nil {
		return fmt.Errorf("gagal membuat direktori kerja AI: %w", err)
	}
	defer os.RemoveAll(workRoot)

	workInputDir := absInputDir
	if anyNeedsPad {
		padDir := filepath.Join(workRoot, "pad_in")
		if mkErr := os.MkdirAll(padDir, 0755); mkErr == nil {
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				src := filepath.Join(absInputDir, e.Name())
				stem := strings.TrimSuffix(e.Name(), filepath.Ext(e.Name()))
				dst := filepath.Join(padDir, stem+".png")
				if padErr := padImageForX4Plus(src, dst); padErr != nil {
					_ = copyFile(src, filepath.Join(padDir, e.Name()))
				}
			}
			workInputDir = padDir
		}
	}

	pass1OutDir := filepath.Join(workRoot, "pass1_out")
	if err := os.MkdirAll(pass1OutDir, 0755); err != nil {
		return err
	}

	if err := runRealEsrganDirectory(
		toolDir,
		modelsDir,
		resolvedModel,
		nativeScale,
		chooseAdaptiveTileSize(maxInputDim),
		workInputDir,
		pass1OutDir,
	); err != nil {
		return err
	}

	currentOutDir := pass1OutDir
	currentScale := nativeScale

	// Cek apakah butuh pass native kedua untuk user targetScale > nativeScale
	nextMaxDim := maxInputDim * currentScale
	if shouldRunExtraNativeAIPass(currentScale, targetScale, nativeScale, nextMaxDim) {
		pass2InDir := currentOutDir
		if anyNeedsPad || isX4Plus {
			cleanDir := filepath.Join(workRoot, "pass2_in")
			if mkErr := os.MkdirAll(cleanDir, 0755); mkErr == nil {
				for _, it := range items {
					src := filepath.Join(currentOutDir, it.stem+".png")
					unpadW, unpadH := it.origW*currentScale, it.origH*currentScale
					dst := filepath.Join(cleanDir, it.stem+".png")
					_ = finalizeUpscaledPNG(src, dst, unpadW, unpadH, unpadW, unpadH)
				}
				pass2InDir = cleanDir
			}
		}
		pass2OutDir := filepath.Join(workRoot, "pass2_out")
		if err := os.MkdirAll(pass2OutDir, 0755); err == nil {
			if err := runRealEsrganDirectory(
				toolDir,
				modelsDir,
				resolvedModel,
				nativeScale,
				chooseAdaptiveTileSize(nextMaxDim),
				pass2InDir,
				pass2OutDir,
			); err != nil {
				return err
			}
			currentOutDir = pass2OutDir
			currentScale *= nativeScale
		}
	}

	// Finalisasi crop sisa padding + rescale CatmullRom ke exact (origW * targetScale, origH * targetScale) secara paralel
	workers := runtime.NumCPU()
	if workers > 8 {
		workers = 8
	}
	if workers > len(items) {
		workers = len(items)
	}
	if workers < 1 {
		workers = 1
	}

	itemCh := make(chan itemMeta, len(items))
	for _, it := range items {
		itemCh <- it
	}
	close(itemCh)

	var wg sync.WaitGroup
	var errOnce sync.Once
	var firstErr error
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for it := range itemCh {
				src := filepath.Join(currentOutDir, it.stem+".png")
				if _, statErr := os.Stat(src); statErr != nil {
					continue
				}
				dst := filepath.Join(absOutputDir, it.stem+".png")
				unpadW := it.origW * currentScale
				unpadH := it.origH * currentScale
				finalW := it.origW * targetScale
				finalH := it.origH * targetScale
				if fErr := finalizeUpscaledPNG(src, dst, unpadW, unpadH, finalW, finalH); fErr != nil {
					errOnce.Do(func() { firstErr = fErr })
					return
				}
			}
		}()
	}
	wg.Wait()

	return firstErr
}

func imageNeedsMultiple4Pad(srcPath string) (bool, error) {
	file, err := os.Open(srcPath)
	if err != nil {
		return false, err
	}
	defer file.Close()

	cfg, _, err := image.DecodeConfig(file)
	if err != nil {
		return false, err
	}
	return (cfg.Width&3) != 0 || (cfg.Height&3) != 0, nil
}

// Helper untuk memastikan dimensi gambar kelipatan 4 agar model x4plus tidak crash,
// menggunakan replikasi piksel tepi (edge clamp) sehingga tepi gambar bebas halo transparan/hitam.
func padImageForX4Plus(srcPath, dstPath string) error {
	file, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer file.Close()

	cfg, _, err := image.DecodeConfig(file)
	if err != nil {
		return err
	}
	w, h := cfg.Width, cfg.Height
	newW := (w + 3) &^ 3
	newH := (h + 3) &^ 3

	if newW == w && newH == h {
		extLower := strings.ToLower(filepath.Ext(srcPath))
		if extLower == ".png" {
			// Hanya salin langsung bila sumber sudah PNG lossless kelipatan-4; JPG/JPEG selalu
			// dikonversi ke PNG bersih oleh decoder Go agar bebas artefak stb_image.
			_ = file.Close()
			return copyFile(srcPath, dstPath)
		}
	}

	if _, err := file.Seek(0, 0); err != nil {
		return err
	}
	img, _, err := image.Decode(file)
	if err != nil {
		return err
	}
	bounds := img.Bounds()

	newImg := image.NewRGBA(image.Rect(0, 0, newW, newH))
	draw.Draw(newImg, image.Rect(0, 0, w, h), img, bounds.Min, draw.Src)

	// Replikasi kolom paling kanan pada area [w..newW)
	if w > 0 && newW > w {
		for y := 0; y < h; y++ {
			edge := color.RGBAModel.Convert(newImg.RGBAAt(w-1, y)).(color.RGBA)
			for x := w; x < newW; x++ {
				newImg.SetRGBA(x, y, edge)
			}
		}
	}
	// Replikasi baris paling bawah pada area [h..newH) termasuk pojok kanan bawah
	if h > 0 && newH > h {
		for x := 0; x < newW; x++ {
			edge := newImg.RGBAAt(x, h-1)
			for y := h; y < newH; y++ {
				newImg.SetRGBA(x, y, edge)
			}
		}
	}

	outFile, err := os.Create(dstPath)
	if err != nil {
		return err
	}
	defer outFile.Close()

	return fastBestSpeedPng.Encode(outFile, newImg)
}
