package service

import (
	"bytes"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/gen2brain/go-fitz"
	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/signintech/gopdf"
	_ "golang.org/x/image/webp"
)

func copyFile(src, dst string) error {
	absSrc, err1 := filepath.Abs(src)
	absDst, err2 := filepath.Abs(dst)
	if err1 == nil && err2 == nil && strings.EqualFold(absSrc, absDst) {
		return nil
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func renderPdfWithFitzWorkers(pdfPath string, fn func(doc *fitz.Document, pageIdx int) error) (int, error) {
	pdfBytes, err := os.ReadFile(pdfPath)
	if err != nil {
		return 0, fmt.Errorf("gagal membaca PDF: %w", err)
	}
	firstDoc, err := fitz.NewFromMemory(pdfBytes)
	if err != nil {
		return 0, fmt.Errorf("gagal membuka PDF: %w", err)
	}
	defer firstDoc.Close()

	numPages := firstDoc.NumPage()
	if numPages <= 0 {
		return 0, nil
	}

	workers := runtime.NumCPU()
	if workers > 8 {
		workers = 8
	}
	if workers > numPages {
		workers = numPages
	}
	if workers < 1 {
		workers = 1
	}

	var nextPage atomic.Int64
	var errOnce sync.Once
	var firstErr error
	var wg sync.WaitGroup

	runWorker := func(doc *fitz.Document) {
		for {
			idx := int(nextPage.Add(1) - 1)
			if idx >= numPages {
				return
			}
			if wErr := fn(doc, idx); wErr != nil {
				errOnce.Do(func() { firstErr = wErr })
				return
			}
		}
	}

	for w := 1; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			wDoc, mErr := fitz.NewFromMemory(pdfBytes)
			if mErr != nil {
				errOnce.Do(func() { firstErr = mErr })
				return
			}
			defer wDoc.Close()
			runWorker(wDoc)
		}()
	}

	runWorker(firstDoc)
	wg.Wait()

	if firstErr != nil {
		return numPages, firstErr
	}
	return numPages, nil
}

func renderPDFPagesToImagesParallel(pdfPath string, dpi float64) ([]image.Image, int, error) {
	if dpi <= 0 {
		dpi = 200.0
	}
	var images []image.Image
	var mu sync.Mutex

	numPages, err := renderPdfWithFitzWorkers(pdfPath, func(doc *fitz.Document, pageIdx int) error {
		mu.Lock()
		if images == nil {
			images = make([]image.Image, doc.NumPage())
		}
		mu.Unlock()

		img, rErr := doc.ImageDPI(pageIdx, dpi)
		if rErr != nil {
			return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, rErr)
		}
		images[pageIdx] = img
		return nil
	})
	if err != nil {
		return nil, numPages, err
	}
	return images, numPages, nil
}

func adaptivePdfDpi(targetKBPerPage int64) float64 {
	if targetKBPerPage <= 0 {
		// Convert Only / tanpa targetKB: jaga ketajaman 200 DPI (bukan 120 DPI!)
		return 200.0
	}
	if targetKBPerPage >= 1000 {
		return 300.0
	}
	if targetKBPerPage >= 500 {
		return 200.0
	}
	if targetKBPerPage >= 100 {
		return 150.0
	}
	return 120.0
}

func isSameImageEncoding(srcExt, dstExt string) bool {
	s := strings.ToLower(strings.TrimPrefix(srcExt, "."))
	d := strings.ToLower(strings.TrimPrefix(dstExt, "."))
	if s == d {
		return true
	}
	return (s == "jpg" || s == "jpeg") && (d == "jpg" || d == "jpeg")
}

func ConvertFormatOnly(inputPaths []string, outputDir string, targetFormat string, targetKBPerPage int64, engineChoice string) ([]string, error) {
	var resultFiles []string
	targetFormat = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(targetFormat), "."))
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return nil, fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	for _, inputPath := range inputPaths {
		ext := strings.ToLower(filepath.Ext(inputPath))
		baseName := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))

		// SKENARIO 0: DOCX / DOC -> PDF
		if ext == ".docx" || ext == ".doc" {
			outputPath := filepath.Join(outputDir, fmt.Sprintf("%s.pdf", baseName))
			if err := ConvertDocxToPdf(inputPath, outputPath, engineChoice); err != nil {
				return nil, fmt.Errorf("gagal konversi Word ke PDF: %w", err)
			}
			fmt.Printf("✅ Dokumen Word berhasil diubah ke PDF: %s\n", outputPath)
			resultFiles = append(resultFiles, outputPath)
			continue
		}

		// SKENARIO 1: PDF -> Gambar (Streaming parallel multi-context fitz tanpa kehilangan kualitas)
		if ext == ".pdf" {
			dpi := adaptivePdfDpi(targetKBPerPage)
			var pagePaths []string
			var pathMu sync.Mutex

			numPages, err := renderPdfWithFitzWorkers(inputPath, func(doc *fitz.Document, pageIdx int) error {
				pathMu.Lock()
				if pagePaths == nil {
					pagePaths = make([]string, doc.NumPage())
				}
				pathMu.Unlock()

				outputPath := filepath.Join(outputDir, fmt.Sprintf("%s_page_%d.%s", baseName, pageIdx+1, targetFormat))
				if targetFormat == "png" {
					pngBytes, pErr := doc.ImagePNG(pageIdx, dpi)
					if pErr != nil {
						return fmt.Errorf("gagal render PNG halaman %d: %w", pageIdx+1, pErr)
					}
					if wErr := os.WriteFile(outputPath, pngBytes, 0644); wErr != nil {
						return fmt.Errorf("gagal menyimpan gambar halaman %d: %w", pageIdx+1, wErr)
					}
				} else if targetFormat == "jpg" || targetFormat == "jpeg" {
					img, iErr := doc.ImageDPI(pageIdx, dpi)
					if iErr != nil {
						return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, iErr)
					}
					var jpgBuf bytes.Buffer
					if eErr := jpeg.Encode(&jpgBuf, img, &jpeg.Options{Quality: 100}); eErr != nil {
						return fmt.Errorf("gagal encode gambar halaman %d: %w", pageIdx+1, eErr)
					}
					if wErr := os.WriteFile(outputPath, jpgBuf.Bytes(), 0644); wErr != nil {
						return fmt.Errorf("gagal menyimpan gambar halaman %d: %w", pageIdx+1, wErr)
					}
				} else {
					return fmt.Errorf("format target tidak didukung: %s", targetFormat)
				}

				pagePaths[pageIdx] = outputPath
				return nil
			})
			if err != nil {
				return nil, fmt.Errorf("gagal konversi PDF ke Gambar: %w", err)
			}
			if numPages == 0 {
				return nil, fmt.Errorf("pdf tidak memiliki halaman")
			}

			resultFiles = append(resultFiles, pagePaths...)
			continue
		}

		// SKENARIO 2: Gambar -> PDF
		if targetFormat == "pdf" {
			outputPath := filepath.Join(outputDir, fmt.Sprintf("%s.pdf", baseName))
			if err := os.Remove(outputPath); err != nil && !os.IsNotExist(err) {
				return nil, fmt.Errorf("gagal membersihkan PDF lama: %w", err)
			}

			if err := api.ImportImagesFile([]string{inputPath}, outputPath, nil, nil); err != nil {
				fallbackPath, fbErr := ConvertImageToPDF(inputPath, outputDir, 0)
				if fbErr != nil {
					return nil, fmt.Errorf("gagal konversi Gambar ke PDF: %w (fallback: %v)", err, fbErr)
				}
				outputPath = fallbackPath
			}

			fmt.Printf("✅ Gambar berhasil diubah ke PDF: %s\n", outputPath)
			resultFiles = append(resultFiles, outputPath)
			continue
		}

		// SKENARIO 3: Gambar -> Gambar (Same-format fast copy bit-identical; Cross-format Quality 100 / Lossless PNG)
		outputPath := filepath.Join(outputDir, fmt.Sprintf("%s_converted.%s", baseName, targetFormat))
		if targetFormat != "jpg" && targetFormat != "jpeg" && targetFormat != "png" {
			return nil, fmt.Errorf("format target tidak didukung: %s", targetFormat)
		}

		if isSameImageEncoding(ext, targetFormat) {
			if err := copyFile(inputPath, outputPath); err != nil {
				return nil, fmt.Errorf("gagal menyalin gambar %s: %w", inputPath, err)
			}
			resultFiles = append(resultFiles, outputPath)
			continue
		}

		file, err := os.Open(inputPath)
		if err != nil {
			return nil, fmt.Errorf("gagal membuka gambar %s: %w", inputPath, err)
		}
		img, _, err := image.Decode(file)
		_ = file.Close()
		if err != nil {
			return nil, fmt.Errorf("gagal decode gambar %s: %w", inputPath, err)
		}

		var outBuf bytes.Buffer
		switch targetFormat {
		case "jpg", "jpeg":
			err = jpeg.Encode(&outBuf, img, &jpeg.Options{Quality: 100})
		case "png":
			err = fastPngShared.Encode(&outBuf, ensureFastPNGSource(img))
		}
		if err != nil {
			return nil, fmt.Errorf("gagal encode gambar ke %s: %w", targetFormat, err)
		}
		if err := os.WriteFile(outputPath, outBuf.Bytes(), 0644); err != nil {
			return nil, fmt.Errorf("gagal menulis file output: %w", err)
		}

		fmt.Printf("✅ Gambar berhasil diubah ke format %s: %s\n", strings.ToUpper(targetFormat), outputPath)
		resultFiles = append(resultFiles, outputPath)
	}

	return resultFiles, nil
}

// =============================================================================
// FITUR 1: UBAH FORMAT GAMBAR (PNG <-> JPG <-> JPEG)
// =============================================================================
func ConvertImageFormat(inputPath, outputPath string) error {
	srcExt := strings.ToLower(filepath.Ext(inputPath))
	targetExt := strings.ToLower(filepath.Ext(outputPath))
	if targetExt != ".jpg" && targetExt != ".jpeg" && targetExt != ".png" {
		return fmt.Errorf("format gambar tidak didukung: %s (Gunakan .png, .jpg, atau .jpeg)", targetExt)
	}

	if isSameImageEncoding(srcExt, targetExt) {
		return copyFile(inputPath, outputPath)
	}

	file, err := os.Open(inputPath)
	if err != nil {
		return fmt.Errorf("gagal membuka gambar: %w", err)
	}
	img, _, err := image.Decode(file)
	_ = file.Close()
	if err != nil {
		return fmt.Errorf("gagal decode gambar: %w", err)
	}

	var outBuf bytes.Buffer
	switch targetExt {
	case ".jpg", ".jpeg":
		err = jpeg.Encode(&outBuf, img, &jpeg.Options{Quality: 95})
	case ".png":
		err = fastPngShared.Encode(&outBuf, ensureFastPNGSource(img))
	}
	if err != nil {
		return err
	}

	return os.WriteFile(outputPath, outBuf.Bytes(), 0644)
}

// =============================================================================
// FITUR 2: KONVERSI GAMBAR KE PDF (100% IN-MEMORY GOPDF, TANPA TEMP FILE)
// =============================================================================
func ConvertImageToPDF(inputPath string, outputDir string, targetKB int64) (string, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	fileName := filepath.Base(inputPath)
	ext := strings.ToLower(filepath.Ext(fileName))
	baseName := fileName[:len(fileName)-len(filepath.Ext(fileName))]
	outputPath := filepath.Join(outputDir, baseName+".pdf")

	var imgBytes []byte
	var width, height int

	if targetKB <= 0 && (ext == ".jpg" || ext == ".jpeg" || ext == ".png") {
		raw, rErr := os.ReadFile(inputPath)
		if rErr == nil {
			if cfg, _, cErr := image.DecodeConfig(bytes.NewReader(raw)); cErr == nil && cfg.Width > 0 && cfg.Height > 0 {
				if holder, hErr := gopdf.ImageHolderByBytes(raw); hErr == nil {
					pdf := gopdf.GoPdf{}
					pdf.Start(gopdf.Config{
						PageSize: gopdf.Rect{W: float64(cfg.Width), H: float64(cfg.Height)},
					})
					pdf.AddPage()
					if iErr := pdf.ImageByHolder(holder, 0, 0, &gopdf.Rect{W: float64(cfg.Width), H: float64(cfg.Height)}); iErr == nil {
						if wErr := pdf.WritePdf(outputPath); wErr == nil {
							return outputPath, nil
						}
					}
				}
			}
		}
	}

	inputFile, err := os.Open(inputPath)
	if err != nil {
		return "", fmt.Errorf("gagal membuka gambar input: %w", err)
	}
	img, _, err := image.Decode(inputFile)
	_ = inputFile.Close()
	if err != nil {
		return "", fmt.Errorf("gagal decode gambar input: %w", err)
	}

	effectiveTargetKB := targetKB
	if targetKB > 10 {
		// Sisakan ~2 KB headroom untuk wrapper struktur objek PDF agar ukuran file akhir presisi <= targetKB
		effectiveTargetKB = targetKB - 2
	}

	buf, err := compressImageToSizeMemory(img, effectiveTargetKB)
	if err != nil {
		return "", fmt.Errorf("gagal kompresi gambar sebelum ke PDF: %w", err)
	}
	imgBytes = buf.Bytes()

	cfg, _, err := image.DecodeConfig(bytes.NewReader(imgBytes))
	if err != nil {
		width = img.Bounds().Dx()
		height = img.Bounds().Dy()
	} else {
		width = cfg.Width
		height = cfg.Height
	}

	holder, err := gopdf.ImageHolderByBytes(imgBytes)
	if err != nil {
		return "", fmt.Errorf("gagal membuat image holder: %w", err)
	}

	pdf := gopdf.GoPdf{}
	pdf.Start(gopdf.Config{
		PageSize: gopdf.Rect{
			W: float64(width),
			H: float64(height),
		},
	})
	pdf.AddPage()

	if err := pdf.ImageByHolder(holder, 0, 0, &gopdf.Rect{
		W: float64(width),
		H: float64(height),
	}); err != nil {
		return "", fmt.Errorf("gagal menyisipkan gambar ke PDF: %w", err)
	}

	if err := pdf.WritePdf(outputPath); err != nil {
		return "", fmt.Errorf("gagal menyimpan PDF: %w", err)
	}

	return outputPath, nil
}

// =============================================================================
// FITUR 3: KONVERSI PDF KE GAMBAR (MULTI-CONTEXT PARALEL FITZ)
// =============================================================================
func ConvertPDFToImage(inputPath, outputDir string, targetFormat string, dpi int) error {
	targetFormat = strings.ToLower(strings.TrimPrefix(targetFormat, "."))
	if targetFormat != "jpg" && targetFormat != "jpeg" && targetFormat != "png" {
		return fmt.Errorf("format tujuan tidak didukung: %s", targetFormat)
	}
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return err
	}
	if dpi <= 0 {
		dpi = 200
	}

	baseName := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))
	_, err := renderPdfWithFitzWorkers(inputPath, func(doc *fitz.Document, pageIdx int) error {
		outputPath := filepath.Join(outputDir, fmt.Sprintf("%s_page_%d.%s", baseName, pageIdx+1, targetFormat))
		if targetFormat == "png" {
			pngBytes, pErr := doc.ImagePNG(pageIdx, float64(dpi))
			if pErr != nil {
				return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, pErr)
			}
			return os.WriteFile(outputPath, pngBytes, 0644)
		}
		img, rErr := doc.ImageDPI(pageIdx, float64(dpi))
		if rErr != nil {
			return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, rErr)
		}
		var jpgBuf bytes.Buffer
		if eErr := jpeg.Encode(&jpgBuf, img, &jpeg.Options{Quality: 95}); eErr != nil {
			return fmt.Errorf("gagal encode gambar halaman %d: %w", pageIdx+1, eErr)
		}
		return os.WriteFile(outputPath, jpgBuf.Bytes(), 0644)
	})
	return err
}

func renderPDFToZeroPaddedPNGs(inputPath, outputDir string, dpi float64) (int, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return 0, err
	}
	if dpi <= 0 {
		dpi = 150.0
	}
	return renderPdfWithFitzWorkers(inputPath, func(doc *fitz.Document, pageIdx int) error {
		pngBytes, pErr := doc.ImagePNG(pageIdx, dpi)
		if pErr != nil {
			return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, pErr)
		}
		outPath := filepath.Join(outputDir, fmt.Sprintf("page_%04d.png", pageIdx+1))
		return os.WriteFile(outPath, pngBytes, 0644)
	})
}

// ConvertPDFToHDImagesInMemory merender PDF ke gambar dengan DPI adaptif paralel (minimal 200 DPI jika targetKBPerPage <= 0)
func ConvertPDFToHDImagesInMemory(pdfPath string, targetKBPerPage int64) ([]image.Image, error) {
	dpi := adaptivePdfDpi(targetKBPerPage)
	fmt.Printf("[DEBUG] Render PDF -> targetKBPerPage: %d KB | Selected DPI: %.1f\n", targetKBPerPage, dpi)
	images, _, err := renderPDFPagesToImagesParallel(pdfPath, dpi)
	return images, err
}

// ConvertPDFToHDImagesForAI merender PDF ke gambar HD (300 DPI) paralel untuk AI Upscale
func ConvertPDFToHDImagesForAI(pdfPath string) ([]image.Image, error) {
	dpi := 300.0
	fmt.Printf("[DEBUG AI RENDER] Render PDF untuk AI Upscale | Fixed DPI: %.1f\n", dpi)
	images, _, err := renderPDFPagesToImagesParallel(pdfPath, dpi)
	return images, err
}

// ConvertPDFToCompressedImage melakukan streaming paralel render + kompresi + tulis per halaman
func ConvertPDFToCompressedImage(inputPath string, outputDir string, targetKB int64, targetFormat string, isTargetPerPage bool) ([]string, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return nil, fmt.Errorf("gagal membuat direktori output: %w", err)
	}
	normFmt := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(targetFormat), "."))
	if normFmt == "" {
		normFmt = "png"
	}

	baseName := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))
	var outputPaths []string
	var metaMu sync.Mutex

	numPages, err := renderPdfWithFitzWorkers(inputPath, func(doc *fitz.Document, pageIdx int) error {
		nPages := doc.NumPage()
		targetKBPerPage := targetKB
		if !isTargetPerPage && nPages > 0 {
			targetKBPerPage = targetKB / int64(nPages)
			if targetKBPerPage < 50 {
				targetKBPerPage = 50
			}
		}

		metaMu.Lock()
		if outputPaths == nil {
			outputPaths = make([]string, nPages)
		}
		metaMu.Unlock()

		pageDpi := adaptivePdfDpi(targetKBPerPage)
		rawImg, rErr := doc.ImageDPI(pageIdx, pageDpi)
		if rErr != nil {
			return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, rErr)
		}

		var buf *bytes.Buffer
		var encErr error
		if normFmt == "png" {
			buf, encErr = compressPNGToSizeMemory(rawImg, targetKBPerPage)
		} else {
			buf, encErr = compressImageToSizeMemory(rawImg, targetKBPerPage)
		}
		if encErr != nil {
			return fmt.Errorf("gagal mengompres halaman %d: %w", pageIdx+1, encErr)
		}

		outPath := filepath.Join(outputDir, fmt.Sprintf("%s_page_%d_compressed.%s", baseName, pageIdx+1, normFmt))
		if writeErr := os.WriteFile(outPath, buf.Bytes(), 0644); writeErr != nil {
			return fmt.Errorf("gagal menyimpan file halaman %d: %w", pageIdx+1, writeErr)
		}

		outputPaths[pageIdx] = outPath
		return nil
	})
	if err != nil {
		return nil, err
	}
	if numPages == 0 {
		return nil, fmt.Errorf("pdf kosong")
	}

	return outputPaths, nil
}

// =============================================================================
// FITUR: GAMBAR -> REAL-ESRGAN -> JPEG KUALITAS MAKSIMAL (Quality: 100) -> PDF
// =============================================================================
func ProcessImageUpscaleToPDFBytes(inputPath string, scale int, modelName string) ([]byte, error) {
	tmpDir, err := os.MkdirTemp("", "img_upscale_pdf_fast_*")
	if err != nil {
		return nil, fmt.Errorf("gagal membuat temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	tempRawOutput := filepath.Join(tmpDir, "raw_output.png")
	if err := EnhanceImageWithAI(inputPath, tempRawOutput, scale, modelName); err != nil {
		return nil, fmt.Errorf("gagal menjalankan upscale AI: %w", err)
	}

	rawFile, err := os.Open(tempRawOutput)
	if err != nil {
		return nil, fmt.Errorf("gagal membuka hasil upscale: %w", err)
	}
	img, _, err := image.Decode(rawFile)
	_ = rawFile.Close()
	if err != nil {
		return nil, fmt.Errorf("gagal decode gambar hasil upscale: %w", err)
	}

	var jpgBuf bytes.Buffer
	if err := jpeg.Encode(&jpgBuf, img, &jpeg.Options{Quality: 100}); err != nil {
		return nil, fmt.Errorf("gagal encode JPEG kualitas 100: %w", err)
	}

	w := float64(img.Bounds().Dx())
	h := float64(img.Bounds().Dy())

	holder, err := gopdf.ImageHolderByBytes(jpgBuf.Bytes())
	if err != nil {
		return nil, fmt.Errorf("gagal membuat image holder: %w", err)
	}

	pdf := gopdf.GoPdf{}
	pdf.Start(gopdf.Config{
		PageSize: gopdf.Rect{W: w, H: h},
	})
	pdf.AddPage()
	if err := pdf.ImageByHolder(holder, 0, 0, &gopdf.Rect{W: w, H: h}); err != nil {
		return nil, fmt.Errorf("gagal menyisipkan gambar ke PDF: %w", err)
	}

	var pdfBuf bytes.Buffer
	if _, err := pdf.WriteTo(&pdfBuf); err != nil {
		return nil, fmt.Errorf("gagal menulis PDF ke memori: %w", err)
	}

	return pdfBuf.Bytes(), nil
}

// ConvertMultipleImagesToPDF menyusun daftar gambar langsung ke dalam 1 dokumen PDF tanpa kompresi ulang
func ConvertMultipleImagesToPDF(imagePaths []string, outputPath string) error {
	if len(imagePaths) == 0 {
		return fmt.Errorf("daftar gambar kosong")
	}
	_ = os.Remove(outputPath)
	if err := api.ImportImagesFile(imagePaths, outputPath, nil, nil); err == nil {
		return nil
	}

	// Fallback gopdf bila ada format selain JPG/PNG standar (misal WEBP/GIF)
	pdf := gopdf.GoPdf{}
	initialized := false
	for idx, imgPath := range imagePaths {
		f, err := os.Open(imgPath)
		if err != nil {
			return err
		}
		img, _, decErr := image.Decode(f)
		_ = f.Close()
		if decErr != nil {
			return decErr
		}
		var pngBuf bytes.Buffer
		if encErr := fastPngShared.Encode(&pngBuf, ensureFastPNGSource(img)); encErr != nil {
			return encErr
		}
		w := float64(img.Bounds().Dx())
		h := float64(img.Bounds().Dy())
		if !initialized {
			pdf.Start(gopdf.Config{PageSize: gopdf.Rect{W: w, H: h}})
			pdf.AddPage()
			initialized = true
		} else {
			pdf.AddPageWithOption(gopdf.PageOption{PageSize: &gopdf.Rect{W: w, H: h}})
		}
		holder, hErr := gopdf.ImageHolderByBytes(pngBuf.Bytes())
		if hErr != nil {
			return fmt.Errorf("gagal holder halaman %d: %w", idx+1, hErr)
		}
		if err := pdf.ImageByHolder(holder, 0, 0, &gopdf.Rect{W: w, H: h}); err != nil {
			return err
		}
	}
	return pdf.WritePdf(outputPath)
}

