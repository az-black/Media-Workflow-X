package service

import (
	"bytes"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"

	"github.com/gen2brain/go-fitz"
	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"github.com/signintech/gopdf"
	"golang.org/x/image/draw"
)

// Cek ukuran file (KB)
func FileSizeKB(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size() / 1024
}

//DEAD CODE
// ScaleImageToTargetKB memperbesar gambar secara instan tanpa lewat Real-ESRGAN AI
// func ScaleImageToTargetKB(inputPath, outputPath string, targetKB int64, format string) error {
// 	file, err := os.Open(inputPath)
// 	if err != nil {
// 		return err
// 	}
// 	defer file.Close()

// 	img, _, err := image.Decode(file)
// 	if err != nil {
// 		return err
// 	}

// 	targetBytes := targetKB * 1024
// 	currentImg := img

// 	// Hitung perkiraan estimasi perbesaran
// 	var buf bytes.Buffer
// 	if err := encodeImage(&buf, currentImg, format); err != nil {
// 		return err
// 	}

// 	// Perbesar dimensi piksel sampai mendatangi targetBytes
// 	for int64(buf.Len()) < targetBytes {
// 		ratio := float64(targetBytes) / float64(buf.Len())
// 		scale := math.Sqrt(ratio) * 0.95

// 		if scale <= 1.05 {
// 			break
// 		}

// 		currentImg = resizeImageLinear(currentImg, scale)
// 		buf.Reset()
// 		if err := encodeImage(&buf, currentImg, format); err != nil {
// 			return err
// 		}
// 	}

// 	// Simpan file hasil
// 	outFile, err := os.Create(outputPath)
// 	if err != nil {
// 		return err
// 	}
// 	defer outFile.Close()

// 	_, err = outFile.Write(buf.Bytes())
// 	return err
// }

// func encodeImage(buf *bytes.Buffer, img image.Image, format string) error {
// 	if format == "png" {
// 		encoder := png.Encoder{CompressionLevel: png.BestCompression}
// 		return encoder.Encode(buf, img)
// 	}
// 	return jpeg.Encode(buf, img, &jpeg.Options{Quality: 90})
// }

// Helper function untuk mengubah dimensi gambar menggunakan interpolasi Bi-Linear
func resizeImage(src image.Image, scale float64) image.Image {
	if scale >= 0.99 {
		return src
	}

	bounds := src.Bounds()
	newWidth := int(float64(bounds.Dx()) * scale)
	newHeight := int(float64(bounds.Dy()) * scale)

	if newWidth < 10 {
		newWidth = 10
	}
	if newHeight < 10 {
		newHeight = 10
	}

	dst := image.NewRGBA(image.Rect(0, 0, newWidth, newHeight))
	draw.BiLinear.Scale(dst, dst.Bounds(), src, bounds, draw.Src, nil)
	return dst
}

func compressImageToSizeMemory(img image.Image, targetKB int64) (*bytes.Buffer, error) {
	if targetKB <= 0 {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
			return nil, err
		}
		return &buf, nil
	}

	targetBytes := targetKB * 1024
	encodeJPEG := func(src image.Image, q int) (*bytes.Buffer, error) {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, src, &jpeg.Options{Quality: q}); err != nil {
			return nil, err
		}
		return &buf, nil
	}

	// 1. Cek cepat Q=95 (kualitas tinggi penuh); jika sudah <= target, langsung selesai (1x encode)
	if buf95, err := encodeJPEG(img, 95); err == nil {
		if int64(buf95.Len()) <= targetBytes {
			return buf95, nil
		}
	}

	// 2. Cek batas bawah resolusi penuh Q=10; jika Q=10 <= target, cari Q tertinggi exact via binary search [10..94]
	buf10, err10 := encodeJPEG(img, 10)
	if err10 == nil && int64(buf10.Len()) <= targetBytes {
		bestBuf := buf10
		low, high := 11, 94
		for low <= high {
			mid := low + (high-low)/2
			cand, err := encodeJPEG(img, mid)
			if err != nil {
				high = mid - 1
				continue
			}
			if int64(cand.Len()) <= targetBytes {
				bestBuf = cand
				low = mid + 1
			} else {
				high = mid - 1
			}
		}
		return bestBuf, nil
	}

	// 3. Jika Q=10 resolusi penuh masih > targetBytes: hitung skala awal proporsional sqrt(ratio) lalu maksimalkan Q
	currentImg := img
	totalScale := 1.0
	refSize := int64(0)
	if buf10 != nil {
		refSize = int64(buf10.Len())
	}
	var lastBuf *bytes.Buffer

	for step := 0; step < 4; step++ {
		scale := 0.78
		if refSize > targetBytes && targetBytes > 0 {
			scale = math.Sqrt(float64(targetBytes)/float64(refSize)) * 0.92
			if scale > 0.90 {
				scale = 0.90
			} else if scale < 0.12 {
				scale = 0.12
			}
		}

		totalScale *= scale
		if totalScale < 0.02 {
			totalScale = 0.02
		}
		currentImg = resizeImageLinear(img, totalScale)

		if candQ20, err := encodeJPEG(currentImg, 20); err == nil {
			lastBuf = candQ20
			refSize = int64(candQ20.Len())
			if refSize <= targetBytes {
				// Coba tingkatkan kualitas JPEG [21..85] pada dimensi yang sudah pas target ini
				bestScaled := candQ20
				low, high := 21, 85
				for low <= high {
					mid := low + (high-low)/2
					cand, errMid := encodeJPEG(currentImg, mid)
					if errMid != nil {
						high = mid - 1
						continue
					}
					if int64(cand.Len()) <= targetBytes {
						bestScaled = cand
						low = mid + 1
					} else {
						high = mid - 1
					}
				}
				return bestScaled, nil
			}
		} else {
			break
		}
	}

	if lastBuf != nil && lastBuf.Len() > 0 {
		return lastBuf, nil
	}

	var finalFallback bytes.Buffer
	_ = jpeg.Encode(&finalFallback, currentImg, &jpeg.Options{Quality: 10})
	return &finalFallback, nil
}

type pngBufPool struct {
	pool sync.Pool
}

func (p *pngBufPool) Get() *png.EncoderBuffer {
	if v := p.pool.Get(); v != nil {
		return v.(*png.EncoderBuffer)
	}
	return nil
}

func (p *pngBufPool) Put(b *png.EncoderBuffer) {
	if b != nil {
		p.pool.Put(b)
	}
}

var (
	fastPngBufPool = &pngBufPool{}
	bestPngBufPool = &pngBufPool{}
	fastPngShared  = png.Encoder{CompressionLevel: png.BestSpeed, BufferPool: fastPngBufPool}
	bestPngShared  = png.Encoder{CompressionLevel: png.BestCompression, BufferPool: bestPngBufPool}
)

// ensureFastPNGSource mengonversi format citra non-slice (seperti YCbCr dari JPEG/WebP)
// ke *image.RGBA / *image.NRGBA agar png.Encode menggunakan jalur salin 24/32-bit cepat
// alih-alih jatuh ke encoding 16-bit cbTC16 dengan jutaan pemanggilan virtual m.At(x, y).
func ensureFastPNGSource(img image.Image) image.Image {
	switch img.(type) {
	case *image.RGBA, *image.NRGBA, *image.Gray, *image.Paletted, *image.RGBA64, *image.NRGBA64, *image.Gray16:
		return img
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= 0 || h <= 0 {
		return img
	}
	if _, ok := img.(*image.YCbCr); ok {
		dst := image.NewRGBA(image.Rect(0, 0, w, h))
		draw.Draw(dst, dst.Bounds(), img, b.Min, draw.Src)
		return dst
	}
	dst := image.NewNRGBA(image.Rect(0, 0, w, h))
	draw.Draw(dst, dst.Bounds(), img, b.Min, draw.Src)
	return dst
}

// compressPNGToSizeMemory mengompresi gambar ke format PNG valid: utamakan 100% lossless full-res
// sebelum melakukan downscale dimensi jika targetKB ketat masih terlampaui.
func compressPNGToSizeMemory(img image.Image, targetKB int64) (*bytes.Buffer, error) {
	src := ensureFastPNGSource(img)

	var buf bytes.Buffer
	if err := fastPngShared.Encode(&buf, src); err != nil {
		return nil, err
	}
	if targetKB <= 0 {
		return &buf, nil
	}

	targetBytes := targetKB * 1024
	if int64(buf.Len()) <= targetBytes {
		return &buf, nil
	}

	// Hanya jalankan zlib level 9 pada resolusi penuh bila ukuran masih dalam batas realistis (<= 145% targetBytes)
	if int64(buf.Len()) <= targetBytes*145/100 {
		var bestBuf bytes.Buffer
		if err := bestPngShared.Encode(&bestBuf, src); err == nil && bestBuf.Len() > 0 {
			if int64(bestBuf.Len()) <= targetBytes {
				return &bestBuf, nil
			}
			if bestBuf.Len() < buf.Len() {
				buf = bestBuf
			}
		}
	}

	totalScale := 1.0
	prevW, prevH := src.Bounds().Dx(), src.Bounds().Dy()

	for i := 0; i < 5 && int64(buf.Len()) > targetBytes; i++ {
		ratio := float64(targetBytes) / float64(buf.Len())
		stepFactor := math.Sqrt(ratio) * 0.94
		if stepFactor > 0.92 {
			stepFactor = 0.92
		}
		if stepFactor < 0.04 {
			stepFactor = 0.04
		}

		totalScale *= stepFactor
		if totalScale < 0.02 {
			totalScale = 0.02
		}

		// Resample langsung dari gambar sumber asli agar ketajaman maksimal tanpa multi-pass blur
		nextImg := resizeImage(src, totalScale)
		nw, nh := nextImg.Bounds().Dx(), nextImg.Bounds().Dy()
		if nw == prevW && nh == prevH {
			totalScale *= 0.85
			if totalScale < 0.02 {
				break
			}
			nextImg = resizeImage(src, totalScale)
			nw, nh = nextImg.Bounds().Dx(), nextImg.Bounds().Dy()
			if nw == prevW && nh == prevH {
				break
			}
		}
		prevW, prevH = nw, nh

		buf.Reset()
		if err := fastPngShared.Encode(&buf, nextImg); err != nil {
			return nil, err
		}
		if int64(buf.Len()) > targetBytes && int64(buf.Len()) <= targetBytes*135/100 {
			var maxCompressed bytes.Buffer
			if err := bestPngShared.Encode(&maxCompressed, nextImg); err == nil && maxCompressed.Len() > 0 && maxCompressed.Len() < buf.Len() {
				buf = maxCompressed
			}
		}
	}

	return &buf, nil
}

// Helper resize menggunakan BiLinear
func resizeImageLinear(src image.Image, scale float64) image.Image {
	bounds := src.Bounds()
	newWidth := int(float64(bounds.Dx()) * scale)
	newHeight := int(float64(bounds.Dy()) * scale)

	if newWidth < 1 {
		newWidth = 1
	}
	if newHeight < 1 {
		newHeight = 1
	}

	dst := image.NewRGBA(image.Rect(0, 0, newWidth, newHeight))
	draw.BiLinear.Scale(dst, dst.Bounds(), src, bounds, draw.Src, nil)
	return dst
}

func compressPDFToSize(inputPath, outputPath string, targetKB int64) error {
	// 1. CEK AWAL: Jika file asli sudah <= target, langsung copy
	fileInfo, err := os.Stat(inputPath)
	if err == nil {
		originalKB := fileInfo.Size() / 1024
		if originalKB <= targetKB {
			fmt.Printf("File asli (%d KB) sudah lebih kecil/sama dengan target (%d KB), menyalin langsung...\n", originalKB, targetKB)
			return copyFile(inputPath, outputPath)
		}
	}

	conf := model.NewDefaultConfiguration()
	err = api.OptimizeFile(inputPath, outputPath, conf)
	if err == nil {
		optimizedKB := FileSizeKB(outputPath)
		if optimizedKB <= targetKB {
			fmt.Printf("   → PDF berhasil dikompresi via pdfcpu Optimize: %d KB (Target: %d KB)\n", optimizedKB, targetKB)
			return nil
		}
	}

	fmt.Printf("   ℹ️ Optimasi struktur belum mencapai target (%d KB). Beralih ke kompresi berbasis gambar...\n", targetKB)

	// 2. Pemrosesan biner murni di RAM (3 parameter: inputPath, targetKB, isTargetPerPage)
	pdfBytes, err := CompressPDFViaImageToBytes(inputPath, targetKB, false, "auto")
	if err != nil {
		return fmt.Errorf("gagal kompresi PDF via image fallback: %w", err)
	}

	// 3. Tulis biner PDF ([]byte) dari RAM langsung ke outputPath
	if err := os.WriteFile(outputPath, pdfBytes, 0644); err != nil {
		return fmt.Errorf("gagal menyimpan hasil PDF ke disk: %w", err)
	}

	return nil
}

// findCppEngine Mencari lokasi binary .exe C++ (OpenCV + QPDF SDK)
func findCppEngine() (string, error) {
	candidates := []string{
		filepath.Join("tools", "pdf_compressor", "build", "Release", "pdf_compressor.exe"),
		filepath.Join("tools", "pdf_compressor", "build", "Debug", "pdf_compressor.exe"),
		filepath.Join("tools", "pdf_compressor", "build", "pdf_compressor.exe"),
	}
	if exeSelf, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exeSelf)
		candidates = append(candidates,
			filepath.Join(exeDir, "tools", "pdf_compressor", "build", "Release", "pdf_compressor.exe"),
			filepath.Join(exeDir, "tools", "pdf_compressor", "build", "pdf_compressor.exe"),
		)
	}

	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}

	return "", fmt.Errorf("binary C++ Engine tidak ditemukan")
}

// CompressPDFViaNativeOnly Kompresi terpisah: Teks/Font, Vektor, dan Gambar
func CompressPDFViaNativeOnly(inputPath string, targetKB int64) ([]byte, error) {
	if targetKB <= 0 || FileSizeKB(inputPath) <= targetKB {
		return os.ReadFile(inputPath)
	}

	// 1. Tahap 1: pdfcpu Optimize
	tmpStage1File, errTmp := os.CreateTemp("", "native_s1_*.pdf")
	stage1Input := inputPath
	if errTmp == nil {
		tmpStage1 := tmpStage1File.Name()
		_ = tmpStage1File.Close()
		defer os.Remove(tmpStage1)

		conf := model.NewDefaultConfiguration()
		conf.Cmd = model.OPTIMIZE
		if err := api.OptimizeFile(inputPath, tmpStage1, conf); err == nil {
			if info, statErr := os.Stat(tmpStage1); statErr == nil && info.Size() > 0 {
				stage1Input = tmpStage1
				if info.Size()/1024 <= targetKB {
					return os.ReadFile(tmpStage1)
				}
			}
		}
	}

	// 2. Tahap 2+3: Jika C++ engine tersedia (sudah dilengkapi libqpdf in-memory Pass 0 + multi-thread),
	// langsung jalankan ke stage1Input tanpa redundansi proses qpdf.exe terpisah.
	if cppExePath, err := findCppEngine(); err == nil {
		tmpStage3File, errTmp3 := os.CreateTemp("", "native_s3_*.pdf")
		if errTmp3 == nil {
			tmpStage3 := tmpStage3File.Name()
			_ = tmpStage3File.Close()
			defer os.Remove(tmpStage3)

			cmdCpp := exec.Command(cppExePath, stage1Input, tmpStage3, fmt.Sprintf("%d", targetKB))
			cmdCpp.Stdout = os.Stdout
			cmdCpp.Stderr = os.Stderr
			if err := cmdCpp.Run(); err != nil {
				fmt.Printf("[C++ RUN ERROR] %v\n", err)
			}
			if info, err := os.Stat(tmpStage3); err == nil && info.Size() > 0 {
				return os.ReadFile(tmpStage3)
			}
		}
	}

	// Fallback QPDF CLI jika C++ engine tidak tersedia
	qpdfExe := resolveQpdfPath()
	if qpdfExe == "" {
		qpdfExe = filepath.Join("tools", "qpdf", "bin", "qpdf.exe")
	}
	tmpStage2File, errTmp2 := os.CreateTemp("", "native_s2_*.pdf")
	if errTmp2 == nil {
		tmpStage2 := tmpStage2File.Name()
		_ = tmpStage2File.Close()
		defer os.Remove(tmpStage2)
		if err := exec.Command(qpdfExe, "--compress-streams=y", "--object-streams=generate", "--recompress-flate", stage1Input, tmpStage2).Run(); err == nil {
			if info, statErr := os.Stat(tmpStage2); statErr == nil && info.Size() > 0 {
				return os.ReadFile(tmpStage2)
			}
		}
	}

	return os.ReadFile(stage1Input)
}

// CompressPDFViaImage mengompresi PDF dengan mengonversinya ke gambar HD,
// mengompres gambarnya ke TargetKB, lalu mengemasnya kembali menjadi PDF baru.
func CompressPDFViaImageToBytes(inputPath string, targetKB int64, isTargetPerPage bool, compressionType string) ([]byte, error) {
	// 1. Hitung Target KB Efektif (Total Dokumen)
	var effectiveTargetKB int64 = targetKB
	if isTargetPerPage {
		doc, err := fitz.New(inputPath)
		if err == nil {
			numPages := int64(doc.NumPage())
			doc.Close()
			if numPages > 0 {
				effectiveTargetKB = targetKB * numPages
			}
		}
	}

	// =========================================================================
	// TAMBAHKAN KODE DI SINI (Sebelum Routing Manual)
	// =========================================================================
	fileInfo, err := os.Stat(inputPath)
	if err != nil {
		return nil, fmt.Errorf("gagal membaca info file asli: %w", err)
	}
	originalSizeKB := fileInfo.Size() / 1024

	// Jika target yang diminta LEBIH BESAR atau SAMA DENGAN ukuran asli,
	// tidak perlu dikompresi (langsung kembalikan file asli).
	if effectiveTargetKB >= originalSizeKB {
		fmt.Printf("[INFO] Target (%d KB) >= Ukuran Asli (%d KB). Memakai file asli tanpa kompresi.\n", effectiveTargetKB, originalSizeKB)
		return os.ReadFile(inputPath)
	}

	// 2. Routing Manual Berdasarkan Parameter compression_type
	switch compressionType {
	case "native":
		fmt.Printf("[MANUAL OPTION] Menggunakan Mode Native Stream (Target Total: %d KB)...\n", effectiveTargetKB)
		return CompressPDFViaNativeOnly(inputPath, effectiveTargetKB)

	case "raster":
		fmt.Printf("[MANUAL OPTION] Menggunakan Mode Rasterization (Target Total: %d KB)...\n", effectiveTargetKB)
		// KIRIM effectiveTargetKB AGAR KONSISTEN DENGAN MODE NATIVE
		return processRasterization(inputPath, effectiveTargetKB, isTargetPerPage)

	default:
		return nil, fmt.Errorf("compression_type '%s' tidak valid, gunakan 'native' atau 'raster'", compressionType)
	}
}

// processRasterization memproses alur: PDF -> Image (150 DPI) -> Dynamic Budget Redistribution -> PDF murni di RAM
func processRasterization(inputPath string, targetKB int64, isTargetPerPage bool) ([]byte, error) {
	rawImages, numPages, err := renderPDFPagesToImagesParallel(inputPath, 150.0)
	if err != nil {
		return nil, err
	}
	if numPages == 0 {
		return nil, fmt.Errorf("pdf tidak memiliki halaman untuk diproses")
	}

	// 1. Hitung Target Total Efektif
	var effectiveTargetKB int64 = targetKB
	if isTargetPerPage {
		effectiveTargetKB = targetKB * int64(numPages)
	}

	fmt.Printf("[INFO] Mode Rasterization: %d Halaman | Target Total: %d KB\n", numPages, effectiveTargetKB)

	type pageData struct {
		index      int
		compressed *bytes.Buffer
		sizeKB     int64
		targetKB   int64
		wPt        float64
		hPt        float64
	}

	pages := make([]pageData, numPages)

	// TAHAP 1: Kompresi paralel berbobot worker pool dengan Alokasi Rata-rata
	baseTargetPerPage := effectiveTargetKB / int64(numPages)
	if baseTargetPerPage < 30 {
		baseTargetPerPage = 30
	}

	var firstErr error
	var errOnce sync.Once
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

	pageCh := make(chan int, numPages)
	for i := 0; i < numPages; i++ {
		pageCh <- i
	}
	close(pageCh)

	var wgPass1 sync.WaitGroup
	for w := 0; w < workers; w++ {
		wgPass1.Add(1)
		go func() {
			defer wgPass1.Done()
			for index := range pageCh {
				img := rawImages[index]
				pxW := img.Bounds().Dx()
				pxH := img.Bounds().Dy()
				const renderDPI = 150.0
				wPt := float64(pxW) * 72.0 / renderDPI
				hPt := float64(pxH) * 72.0 / renderDPI

				buf, err := compressImageToSizeMemory(img, baseTargetPerPage)
				if err != nil {
					errOnce.Do(func() { firstErr = fmt.Errorf("gagal kompresi awal halaman %d: %w", index+1, err) })
					return
				}

				pages[index] = pageData{
					index:      index,
					compressed: buf,
					sizeKB:     int64(buf.Len()) / 1024,
					targetKB:   baseTargetPerPage,
					wPt:        wPt,
					hPt:        hPt,
				}
			}
		}()
	}
	wgPass1.Wait()

	if firstErr != nil {
		return nil, firstErr
	}

	// TAHAP 2: Alokasi Dinamis Sisa Kuota (Budget Redistribution)
	if !isTargetPerPage {
		var totalUsedKB int64 = 0
		for _, p := range pages {
			totalUsedKB += p.sizeKB
		}

		surplusKB := effectiveTargetKB - totalUsedKB
		if surplusKB > 50 {
			fmt.Printf("[DEBUG] Surplus Kuota Terdeteksi: %d KB. Memulai redistribusi anggaran dinamis...\n", surplusKB)

			var heavyPageIndices []int
			for i, p := range pages {
				if p.sizeKB >= (p.targetKB * 80 / 100) {
					heavyPageIndices = append(heavyPageIndices, i)
				}
			}

			if len(heavyPageIndices) > 0 {
				bonusPerPage := surplusKB / int64(len(heavyPageIndices))
				heavyCh := make(chan int, len(heavyPageIndices))
				for _, idx := range heavyPageIndices {
					heavyCh <- idx
				}
				close(heavyCh)

				w2 := workers
				if len(heavyPageIndices) < w2 {
					w2 = len(heavyPageIndices)
				}
				var wgPass2 sync.WaitGroup
				for w := 0; w < w2; w++ {
					wgPass2.Add(1)
					go func() {
						defer wgPass2.Done()
						for pageIdx := range heavyCh {
							newTargetKB := pages[pageIdx].targetKB + bonusPerPage
							buf, err := compressImageToSizeMemory(rawImages[pageIdx], newTargetKB)
							if err == nil && buf.Len() > pages[pageIdx].compressed.Len() {
								pages[pageIdx].compressed = buf
								pages[pageIdx].sizeKB = int64(buf.Len()) / 1024
							}
						}
					}()
				}
				wgPass2.Wait()
			}
		}
	}

	var finalTotalKB int64 = 0
	for i := range pages {
		finalTotalKB += pages[i].sizeKB
		rawImages[i] = nil // bebaskan bitmap mentah sebelum menyusun PDF di RAM
	}

	fmt.Printf("[INFO] Hasil Akhir Ukuran PDF Raster: %d KB (Target Total: %d KB)\n", finalTotalKB, effectiveTargetKB)

	// TAHAP 3: Susun ke Dokumen PDF 100% di RAM (tanpa temporary files di disk)
	pdf := gopdf.GoPdf{}
	pdf.Start(gopdf.Config{
		PageSize: gopdf.Rect{
			W: pages[0].wPt,
			H: pages[0].hPt,
		},
	})

	for i, res := range pages {
		if i > 0 {
			pdf.AddPageWithOption(gopdf.PageOption{
				PageSize: &gopdf.Rect{
					W: res.wPt,
					H: res.hPt,
				},
			})
		} else {
			pdf.AddPage()
		}

		holder, err := gopdf.ImageHolderByBytes(res.compressed.Bytes())
		if err != nil {
			return nil, fmt.Errorf("gagal membuat image holder halaman %d: %w", res.index+1, err)
		}
		if err := pdf.ImageByHolder(holder, 0, 0, &gopdf.Rect{
			W: res.wPt,
			H: res.hPt,
		}); err != nil {
			return nil, fmt.Errorf("gagal menyisipkan gambar halaman %d ke gopdf: %w", res.index+1, err)
		}
	}

	var pdfOut bytes.Buffer
	if _, err := pdf.WriteTo(&pdfOut); err != nil {
		return nil, fmt.Errorf("gagal menulis gopdf ke memori: %w", err)
	}

	fmt.Printf("[SUKSES] Mode Rasterization berhasil diselesaikan dengan akurasi target presisi!\n")
	return pdfOut.Bytes(), nil
}

// ProcessRasterUpscaleAI memproses alur khusus upscale_ai: PDF -> Image (150 DPI) -> Batch Real-ESRGAN -> JPEG (Quality 92) -> PDF
func ProcessRasterUpscaleAI(inputPath string, scale int, modelName string) ([]byte, error) {
	fmt.Printf("[INFO] Memulai Raster AI Upscale untuk file: %s (Scale: %dx)...\n", filepath.Base(inputPath), scale)

	tmpDir, err := os.MkdirTemp("", "raster_upscale_ai_*")
	if err != nil {
		return nil, fmt.Errorf("gagal membuat temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	inDir := filepath.Join(tmpDir, "in")
	outDir := filepath.Join(tmpDir, "out")
	if err := os.MkdirAll(inDir, 0755); err != nil {
		return nil, err
	}

	// 1. Render halaman PDF paralel ke PNG zero-padded (150 DPI)
	type pageRect struct {
		wPt float64
		hPt float64
	}
	pageRects := map[int]pageRect{}
	var rectsMu sync.Mutex

	numPages, err := renderPdfWithFitzWorkers(inputPath, func(doc *fitz.Document, pageIdx int) error {
		img, rErr := doc.ImageDPI(pageIdx, 150.0)
		if rErr != nil {
			return fmt.Errorf("gagal render halaman %d: %w", pageIdx+1, rErr)
		}
		const renderDPI = 150.0
		wPt := float64(img.Bounds().Dx()) * 72.0 / renderDPI
		hPt := float64(img.Bounds().Dy()) * 72.0 / renderDPI
		rectsMu.Lock()
		pageRects[pageIdx] = pageRect{wPt: wPt, hPt: hPt}
		rectsMu.Unlock()

		var pngBuf bytes.Buffer
		if encErr := fastPngShared.Encode(&pngBuf, img); encErr != nil {
			return encErr
		}
		return os.WriteFile(filepath.Join(inDir, fmt.Sprintf("page_%04d.png", pageIdx+1)), pngBuf.Bytes(), 0644)
	})
	if err != nil {
		return nil, err
	}
	if numPages == 0 {
		return nil, fmt.Errorf("pdf tidak memiliki halaman untuk diproses")
	}

	// 2. Satu kali batch Real-ESRGAN AI untuk seluruh halaman
	batchErr := EnhanceDirectoryWithAI(inDir, outDir, scale, modelName)
	if batchErr != nil {
		return nil, batchErr
	}

	// 3. Encode paralel ke JPEG Quality 92 di RAM
	jpegBytesPerPage := make([][]byte, numPages)
	var firstErr error
	var errOnce sync.Once

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

	pageCh := make(chan int, numPages)
	for i := 0; i < numPages; i++ {
		pageCh <- i
	}
	close(pageCh)

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range pageCh {
				srcPng := filepath.Join(outDir, fmt.Sprintf("page_%04d.png", idx+1))
				if _, statErr := os.Stat(srcPng); statErr != nil {
					srcPng = filepath.Join(inDir, fmt.Sprintf("page_%04d.png", idx+1))
				}
				f, oErr := os.Open(srcPng)
				if oErr != nil {
					errOnce.Do(func() { firstErr = oErr })
					return
				}
				decoded, _, dErr := image.Decode(f)
				_ = f.Close()
				if dErr != nil {
					errOnce.Do(func() { firstErr = dErr })
					return
				}
				var jb bytes.Buffer
				if eErr := jpeg.Encode(&jb, decoded, &jpeg.Options{Quality: 92}); eErr != nil {
					errOnce.Do(func() { firstErr = eErr })
					return
				}
				jpegBytesPerPage[idx] = jb.Bytes()
			}
		}()
	}
	wg.Wait()

	if firstErr != nil {
		return nil, firstErr
	}

	// 4. Susun kembali ke format PDF menggunakan gopdf di RAM (perbaiki bug pdf.Start tunggal!)
	pdf := gopdf.GoPdf{}
	pdf.Start(gopdf.Config{
		PageSize: gopdf.Rect{
			W: pageRects[0].wPt,
			H: pageRects[0].hPt,
		},
	})

	for idx := 0; idx < numPages; idx++ {
		rect := pageRects[idx]
		if idx > 0 {
			pdf.AddPageWithOption(gopdf.PageOption{
				PageSize: &gopdf.Rect{W: rect.wPt, H: rect.hPt},
			})
		} else {
			pdf.AddPage()
		}

		holder, hErr := gopdf.ImageHolderByBytes(jpegBytesPerPage[idx])
		if hErr != nil {
			return nil, fmt.Errorf("gagal membuat image holder halaman %d: %w", idx+1, hErr)
		}
		if err := pdf.ImageByHolder(holder, 0, 0, &gopdf.Rect{W: rect.wPt, H: rect.hPt}); err != nil {
			return nil, fmt.Errorf("gagal menyisipkan gambar halaman %d ke gopdf: %w", idx+1, err)
		}
	}

	var pdfOut bytes.Buffer
	if _, err := pdf.WriteTo(&pdfOut); err != nil {
		return nil, fmt.Errorf("gagal menulis gopdf: %w", err)
	}

	fmt.Printf("[SUKSES] PDF ber-upscale AI berhasil dibuat dengan format JPEG!\n")
	return pdfOut.Bytes(), nil
}

// Helper untuk memanggil executable C++ pdf_compressor
func compressPDFWithCPP(inputPath, outputPath string, targetKB int64) error {
	exePath, err := findCppEngine()
	if err != nil {
		exePath = filepath.Join("tools", "pdf_compressor", "build", "pdf_compressor.exe")
	}

	// Kirim argumen: input, output, dan target size (KB)
	cmd := exec.Command(exePath, inputPath, outputPath, fmt.Sprintf("%d", targetKB))

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("cpp compressor error: %v, detail: %s", err, string(output))
	}

	return nil
}

func OptimizePDFStream(inputPath string, targetKB int64) ([]byte, error) {
	tmpFile, err := os.CreateTemp("", "compressed_*.pdf")
	if err != nil {
		return nil, fmt.Errorf("gagal membuat temp file: %w", err)
	}
	tmpPath := tmpFile.Name()
	tmpFile.Close()
	defer os.Remove(tmpPath)

	err = compressPDFWithCPP(inputPath, tmpPath, targetKB)
	if err != nil {
		return nil, fmt.Errorf("gagal optimasi PDF via cpp: %w", err)
	}

	compressedBytes, err := os.ReadFile(tmpPath)
	if err != nil {
		return nil, fmt.Errorf("gagal membaca hasil kompresi: %w", err)
	}

	return compressedBytes, nil
}
