package service

import (
	"bytes"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	_ "golang.org/x/image/webp"
)

func moveFileSafe(src, dst string) error {
	if err := os.Rename(src, dst); err == nil {
		return nil
	}
	if err := copyFile(src, dst); err != nil {
		return err
	}
	_ = os.Remove(src)
	return nil
}

func decodeImageFile(path string) (image.Image, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	return img, err
}

// ProcessPath menangani input baik berupa file maupun folder
func ProcessPath(path string, outputDir string, targetKB int64, targetFormat string, isTargetPerPage bool, action string, scale int, compressionType string, engineChoice string, modelName string) ([]string, error) {
	info, err := os.Stat(path)
	if err != nil {
		fmt.Println("❌ Tidak bisa membuka:", path)
		return nil, err
	}

	var processedFiles []string

	if info.IsDir() {
		err := filepath.Walk(path, func(filePath string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() {
				return nil
			}

			// Hindari memproses file di folder output
			if strings.HasPrefix(filePath, outputDir) {
				return nil
			}

			outPath, errFile := ProcessFile(filePath, outputDir, targetKB, targetFormat, isTargetPerPage, action, scale, compressionType, engineChoice, modelName)
			if errFile == nil && outPath != nil {
				processedFiles = append(processedFiles, outPath...)
			}
			return nil
		})
		return processedFiles, err
	}

	// Jika input adalah file tunggal
	outPath, errFile := ProcessFile(path, outputDir, targetKB, targetFormat, isTargetPerPage, action, scale, compressionType, engineChoice, modelName)
	if errFile == nil && outPath != nil {
		processedFiles = append(processedFiles, outPath...)
	}
	return processedFiles, errFile
}

// Helper untuk validasi nama model Real-ESRGAN terpasang serta meneruskan scale pengguna
func resolveModelNameAndScale(inputModel string, inputScale int) (string, int) {
	return ResolveAIModelAndScale(inputModel, inputScale)
}

// ProcessFile memproses per file sesuai Action
func ProcessFile(inputPath, outputDir string, targetKB int64, targetFormat string, isTargetPerPage bool, action string, scale int, compressionType string, engineChoice string, modelName string) ([]string, error) {
	inputExt := strings.ToLower(filepath.Ext(inputPath))
	targetFormat = strings.ToLower(strings.TrimSpace(targetFormat))

	// Normalisasi format target
	if targetFormat == "" {
		targetFormat = inputExt
	} else if !strings.HasPrefix(targetFormat, ".") {
		targetFormat = "." + targetFormat
	}

	normInputExt := inputExt
	normTargetFormat := targetFormat
	if normInputExt == ".jpeg" {
		normInputExt = ".jpg"
	}
	if normTargetFormat == ".jpeg" {
		normTargetFormat = ".jpg"
	}

	baseName := strings.TrimSuffix(filepath.Base(inputPath), inputExt)

	// -------------------------------------------------------------------------
	// 0. INPUT FILE WORD (.docx, .doc) -> ACTION: convert_only / convert_compress
	// -------------------------------------------------------------------------
	if normInputExt == ".docx" || normInputExt == ".doc" {
		outputPath := filepath.Join(outputDir, baseName+".pdf")

		fmt.Printf("📄 Mengonversi dokumen Word ke PDF: %s\n", inputPath)
		err := ConvertDocxToPdf(inputPath, outputPath, engineChoice)
		if err != nil {
			fmt.Println("❌ Error konversi DOCX/DOC ke PDF:", inputPath, err)
			return nil, err
		}

		fmt.Println("✅ Dokumen Word berhasil diubah ke PDF:", outputPath)

		if action == "convert_only" {
			return []string{outputPath}, nil
		}
	}

	// -------------------------------------------------------------------------
	// 1. ACTION: UPSCALE AI (2x, 3x, 4x) - MURNI SKALA AI, TANPA TARGET KB
	// -------------------------------------------------------------------------
	if action == "upscale_ai" {
		normTargetFormat := strings.ToLower(strings.TrimPrefix(targetFormat, "."))
		if normTargetFormat == "" {
			normTargetFormat = "png"
		}

		// Evaluasi nama model & skala secara akurat
		cleanModelName, activeScale := resolveModelNameAndScale(modelName, scale)

		// A. Jika target akhir adalah PDF (Render paralel -> Single Batch Real-ESRGAN -> Bungkus Lossless ke 1 PDF)
		if normTargetFormat == "pdf" {
			outputPath := filepath.Join(outputDir, baseName+".pdf")
			tempDir, mkErr := os.MkdirTemp("", "mwx_upscale_pdf_*")
			if mkErr != nil {
				return nil, fmt.Errorf("gagal membuat direktori sementara: %w", mkErr)
			}
			defer os.RemoveAll(tempDir)

			var validUpscaledImages []string

			if normInputExt == ".pdf" {
				inDir := filepath.Join(tempDir, "in")
				outDir := filepath.Join(tempDir, "out")
				fmt.Printf("📄 [UPSCALE AI] Render paralel PDF ke gambar PNG (150 DPI)...\n")
				numPages, err := renderPDFToZeroPaddedPNGs(inputPath, inDir, 150.0)
				if err != nil {
					return nil, fmt.Errorf("gagal merender PDF ke gambar: %w", err)
				}
				if numPages == 0 {
					return nil, fmt.Errorf("tidak ada halaman PDF yang ditemukan untuk di-upscale")
				}

				fmt.Printf("🚀 [UPSCALE AI BATCH] Model: %s, Scale: %dx | %d halaman...\n", cleanModelName, activeScale, numPages)
				if err := EnhanceDirectoryWithAI(inDir, outDir, activeScale, cleanModelName); err != nil {
					return nil, err
				}

				for i := 0; i < numPages; i++ {
					cand := filepath.Join(outDir, fmt.Sprintf("page_%04d.png", i+1))
					if _, statErr := os.Stat(cand); statErr == nil {
						validUpscaledImages = append(validUpscaledImages, cand)
					}
				}
			} else {
				tempUpscaledPng := filepath.Join(tempDir, "upscaled.png")
				fmt.Printf("🚀 [UPSCALE AI] Model: %s, Scale: %dx | Gambar -> PDF\n", cleanModelName, activeScale)
				if errAI := EnhanceImageWithAI(inputPath, tempUpscaledPng, activeScale, cleanModelName); errAI != nil {
					return nil, fmt.Errorf("gagal upscale gambar: %w", errAI)
				}
				if _, statErr := os.Stat(tempUpscaledPng); statErr == nil {
					validUpscaledImages = append(validUpscaledImages, tempUpscaledPng)
				}
			}

			if len(validUpscaledImages) == 0 {
				return nil, fmt.Errorf("gagal memproses gambar upscaled untuk PDF")
			}

			// Bungkus seluruh gambar PNG upscaled dalam urutan halaman 1..N menjadi 1 PDF lossless
			_ = os.Remove(outputPath)
			if err := api.ImportImagesFile(validUpscaledImages, outputPath, nil, nil); err != nil {
				if fbErr := ConvertMultipleImagesToPDF(validUpscaledImages, outputPath); fbErr != nil {
					return nil, fmt.Errorf("gagal membungkus gambar upscaled ke PDF: %w", fbErr)
				}
			}

			fmt.Println("✅ [UPSCALE AI] PDF kualitas tinggi & lossless berhasil dibuat:", outputPath)
			return []string{outputPath}, nil
		}

		// B. Jika input adalah PDF dan target akhir adalah FORMAT GAMBAR
		if normInputExt == ".pdf" {
			tempDir, mkErr := os.MkdirTemp("", "mwx_upscale_pdfimg_*")
			if mkErr != nil {
				return nil, fmt.Errorf("gagal membuat direktori sementara: %w", mkErr)
			}
			defer os.RemoveAll(tempDir)

			inDir := filepath.Join(tempDir, "in")
			outDir := filepath.Join(tempDir, "out")

			fmt.Printf("📄 Mengonversi paralel semua halaman PDF ke PNG untuk AI Upscale (200 DPI)...\n")
			numPages, err := renderPDFToZeroPaddedPNGs(inputPath, inDir, 200.0)
			if err != nil {
				return nil, fmt.Errorf("gagal merender PDF ke gambar: %w", err)
			}
			if numPages == 0 {
				return nil, fmt.Errorf("tidak ada halaman PDF yang berhasil diekstrak")
			}

			fmt.Printf("🚀 Menjalankan Batch Real-ESRGAN AI (Model: %s, Scale: %dx) untuk %d halaman...\n", cleanModelName, activeScale, numPages)
			if err := EnhanceDirectoryWithAI(inDir, outDir, activeScale, cleanModelName); err != nil {
				return nil, err
			}

			outputExt := "." + normTargetFormat
			results := make([]string, numPages)
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
			var firstErr error
			var errOnce sync.Once
			for w := 0; w < workers; w++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					for idx := range pageCh {
						srcPng := filepath.Join(outDir, fmt.Sprintf("page_%04d.png", idx+1))
						if _, statErr := os.Stat(srcPng); statErr != nil {
							continue
						}
						pageOutputName := fmt.Sprintf("%s_page%d_upscaled%s", baseName, idx+1, outputExt)
						pageOutputPath := filepath.Join(outputDir, pageOutputName)

						if normTargetFormat == "png" {
							if mvErr := moveFileSafe(srcPng, pageOutputPath); mvErr != nil {
								errOnce.Do(func() { firstErr = mvErr })
								return
							}
						} else {
							img, dErr := decodeImageFile(srcPng)
							if dErr != nil {
								errOnce.Do(func() { firstErr = dErr })
								return
							}
							var jpgBuf bytes.Buffer
							if eErr := jpeg.Encode(&jpgBuf, img, &jpeg.Options{Quality: 100}); eErr != nil {
								errOnce.Do(func() { firstErr = eErr })
								return
							}
							if wErr := os.WriteFile(pageOutputPath, jpgBuf.Bytes(), 0644); wErr != nil {
								errOnce.Do(func() { firstErr = wErr })
								return
							}
						}
						results[idx] = pageOutputPath
					}
				}()
			}
			wg.Wait()

			var finalResults []string
			for _, p := range results {
				if p != "" {
					finalResults = append(finalResults, p)
				}
			}
			if len(finalResults) == 0 {
				if firstErr != nil {
					return nil, firstErr
				}
				return nil, fmt.Errorf("gagal memproses semua halaman PDF untuk upscale")
			}

			fmt.Printf("✅ [UPSCALE AI] %d halaman berhasil di-upscale.\n", len(finalResults))
			return finalResults, nil
		}

		// C. Jika input adalah file gambar tunggal ke format gambar
		outputExt := "." + normTargetFormat
		outputPath := filepath.Join(outputDir, baseName+"_upscaled"+outputExt)
		fmt.Printf("🚀 Menjalankan Real-ESRGAN AI (Model: %s, Scale: %dx)...\n", cleanModelName, activeScale)

		if normTargetFormat == "png" {
			if err := EnhanceImageWithAI(inputPath, outputPath, activeScale, cleanModelName); err != nil {
				fmt.Println("❌ Error Upscale AI:", inputPath, err)
				return nil, err
			}
			fmt.Println("✅ Berhasil melakukan Upscale AI ke format:", outputPath)
			return []string{outputPath}, nil
		}

		tmpDir, mkErr := os.MkdirTemp("", "mwx_upscale_img_*")
		if mkErr != nil {
			return nil, fmt.Errorf("gagal membuat temp dir: %w", mkErr)
		}
		defer os.RemoveAll(tmpDir)

		tempPngPath := filepath.Join(tmpDir, "upscaled.png")
		if err := EnhanceImageWithAI(inputPath, tempPngPath, activeScale, cleanModelName); err != nil {
			fmt.Println("❌ Error Upscale AI:", inputPath, err)
			return nil, err
		}

		if normTargetFormat == "jpg" || normTargetFormat == "jpeg" {
			upscaledImg, dErr := decodeImageFile(tempPngPath)
			if dErr != nil {
				return nil, fmt.Errorf("gagal decode hasil upscale untuk JPG: %w", dErr)
			}
			var jpgBuf bytes.Buffer
			if eErr := jpeg.Encode(&jpgBuf, upscaledImg, &jpeg.Options{Quality: 100}); eErr != nil {
				return nil, fmt.Errorf("gagal encode hasil upscale ke JPG: %w", eErr)
			}
			if wErr := os.WriteFile(outputPath, jpgBuf.Bytes(), 0644); wErr != nil {
				return nil, fmt.Errorf("gagal menyimpan hasil upscale JPG: %w", wErr)
			}
		} else if err := ConvertImageFormat(tempPngPath, outputPath); err != nil {
			fmt.Println("❌ Error konversi format hasil upscale:", err)
			return nil, err
		}

		fmt.Println("✅ Berhasil melakukan Upscale AI ke format:", outputPath)
		return []string{outputPath}, nil
	}

	// -------------------------------------------------------------------------
	// 2. INPUT FILE PDF (Kompresi / Konversi Biasa)
	// -------------------------------------------------------------------------
	if normInputExt == ".pdf" {
		if normTargetFormat == ".jpg" || normTargetFormat == ".png" {
			err := ConvertPDFToImage(inputPath, outputDir, targetFormat, 200)
			if err != nil {
				fmt.Println("❌ Error konversi PDF ke Gambar:", inputPath, err)
				return nil, err
			}
			fmt.Println("✅ PDF berhasil diubah ke Gambar di folder:", outputDir)
			return []string{outputDir}, nil
		}

		outputPath := filepath.Join(outputDir, filepath.Base(inputPath))
		err := compressPDFToSize(inputPath, outputPath, targetKB)
		if err != nil {
			fmt.Println("❌ Error kompres PDF:", inputPath, err)
			return nil, err
		}
		fmt.Println("✅ PDF terkompres:", outputPath)
		return []string{outputPath}, nil
	}

	// -------------------------------------------------------------------------
	// 3. INPUT FILE GAMBAR (.jpg, .png, .webp, .gif)
	// -------------------------------------------------------------------------
	if normInputExt == ".jpg" || normInputExt == ".png" || normInputExt == ".webp" || normInputExt == ".gif" {
		if normTargetFormat == ".pdf" {
			outputPath, err := ConvertImageToPDF(inputPath, outputDir, targetKB)
			if err != nil {
				fmt.Println("❌ Error konversi Gambar ke PDF:", inputPath, err)
				return nil, err
			}
			fmt.Println("✅ Gambar berhasil diubah ke PDF:", outputPath)
			return []string{outputPath}, nil
		}

		outputPath := filepath.Join(outputDir, baseName+targetFormat)

		if action == "convert_only" {
			err := ConvertImageFormat(inputPath, outputPath)
			if err != nil {
				fmt.Println("❌ Error konversi format:", inputPath, err)
				return nil, err
			}
			fmt.Println("✅ Gambar berhasil dikonversi:", outputPath)
			return []string{outputPath}, nil
		}

		// Jalur cepat: jika format encoding sudah sama dan ukuran asli sudah <= targetKB, salin bit-identical
		if normInputExt == normTargetFormat && targetKB > 0 {
			if info, statErr := os.Stat(inputPath); statErr == nil && info.Size() <= targetKB*1024 {
				if err := copyFile(inputPath, outputPath); err == nil {
					fmt.Println("✅ Gambar sudah memenuhi target KB (salin langsung):", outputPath)
					return []string{outputPath}, nil
				}
			}
		}

		// Decode sekali di RAM tanpa menulis/membaca file sementara di disk
		imgToCompress, err := decodeImageFile(inputPath)
		if err != nil {
			return nil, fmt.Errorf("gagal decode gambar %s: %w", inputPath, err)
		}

		var buf *bytes.Buffer
		if normTargetFormat == ".png" {
			buf, err = compressPNGToSizeMemory(imgToCompress, targetKB)
		} else {
			buf, err = compressImageToSizeMemory(imgToCompress, targetKB)
		}
		if err != nil {
			fmt.Println("❌ Error kompresi gambar:", inputPath, err)
			return nil, err
		}

		if err = os.WriteFile(outputPath, buf.Bytes(), 0644); err != nil {
			fmt.Println("❌ Error menyimpan file hasil kompresi:", outputPath, err)
			return nil, err
		}

		fmt.Println("✅ Gambar berhasil dikompresi:", outputPath)
		return []string{outputPath}, nil
	}

	return nil, fmt.Errorf("format file tidak didukung: %s", inputPath)
}