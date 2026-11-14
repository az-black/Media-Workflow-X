package handler

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/az-black/app-pengompres-gambar-pdf/internal/model"
	"github.com/az-black/app-pengompres-gambar-pdf/internal/service"
)

func processSingleCompressFile(path string, req model.CompressRequest, scale int) ([]string, error) {
	ext := strings.ToLower(filepath.Ext(path))
	normTarget := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(req.TargetFormat), "."))

	// =========================================================================
	// ISOLASI MUTLAK CONVERT ONLY: PDF -> DOCX
	// Berjalan langsung tanpa menyentuh kompresi / targetKB / targetKBPerPage
	// =========================================================================
	if req.Action == "convert_only" && ext == ".pdf" && normTarget == "docx" {
		baseName := strings.TrimSuffix(filepath.Base(path), ext)
		outputDocxPath := filepath.Join(req.OutputDir, baseName+".docx")

		var err error
		if strings.ToLower(req.Engine) == "libreoffice" {
			err = service.ConvertPdfToDocxLibreOffice(path, req.OutputDir)
		} else {
			err = service.ConvertPdfToDocx(path, outputDocxPath)
		}
		if err != nil {
			return nil, fmt.Errorf("Gagal konversi PDF ke DOCX: %w", err)
		}
		return []string{outputDocxPath}, nil
	}

	switch req.Action {
	case "upscale_ai":
		outPaths, err := service.ProcessPath(path, req.OutputDir, req.TargetKB, req.TargetFormat, req.IsTargetPerPage, req.Action, scale, req.CompressionType, req.Engine, req.Model)
		if err != nil {
			return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
		}
		return outPaths, nil

	case "convert_only":
		if (ext == ".docx" || ext == ".doc") && normTarget == "pdf" {
			baseName := strings.TrimSuffix(filepath.Base(path), ext)
			outputPdfPath := filepath.Join(req.OutputDir, baseName+".pdf")
			if err := service.ConvertDocxToPdf(path, outputPdfPath, req.Engine); err != nil {
				return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
			}
			return []string{outputPdfPath}, nil
		}

		convertedFiles, err := service.ConvertFormatOnly([]string{path}, req.OutputDir, req.TargetFormat, 0, req.Engine)
		if err != nil {
			return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
		}
		return convertedFiles, nil

	case "convert_compress":
		if ext == ".pdf" && normTarget == "pdf" {
			compType := strings.ToLower(strings.TrimSpace(req.CompressionType))
			if compType == "" {
				compType = "native"
			}
			compressedPDF, err := service.CompressPDFViaImageToBytes(path, req.TargetKB, req.IsTargetPerPage, compType)
			if err != nil {
				return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
			}
			baseName := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
			outputPath := filepath.Join(req.OutputDir, fmt.Sprintf("%s_compressed.pdf", baseName))
			if writeErr := os.WriteFile(outputPath, compressedPDF, 0644); writeErr != nil {
				return nil, fmt.Errorf("Gagal memproses file %s: %w", path, writeErr)
			}
			return []string{outputPath}, nil
		}

		if ext == ".pdf" {
			compressedImages, err := service.ConvertPDFToCompressedImage(path, req.OutputDir, req.TargetKB, req.TargetFormat, req.IsTargetPerPage)
			if err != nil {
				return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
			}
			return compressedImages, nil
		}

		// Gambar non-Word -> PDF langsung via in-memory gopdf (tanpa temp file PNG perantara)
		if normTarget == "pdf" && ext != ".doc" && ext != ".docx" {
			outPdf, err := service.ConvertImageToPDF(path, req.OutputDir, req.TargetKB)
			if err != nil {
				return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
			}
			return []string{outPdf}, nil
		}

		outPaths, err := service.ProcessPath(path, req.OutputDir, req.TargetKB, req.TargetFormat, req.IsTargetPerPage, req.Action, scale, req.CompressionType, req.Engine, req.Model)
		if err != nil {
			return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
		}
		return outPaths, nil

	default:
		outPaths, err := service.ProcessPath(path, req.OutputDir, req.TargetKB, req.TargetFormat, req.IsTargetPerPage, "convert_compress", scale, req.CompressionType, req.Engine, req.Model)
		if err != nil {
			return nil, fmt.Errorf("Gagal memproses file %s: %w", path, err)
		}
		return outPaths, nil
	}
}

func CompressHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(model.CompressResponse{
			Success: false,
			Message: "Method tidak diizinkan",
		})
		return
	}

	var req model.CompressRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(model.CompressResponse{
			Success: false,
			Message: "Format request JSON tidak valid: " + err.Error(),
		})
		return
	}

	// 1. Buat folder output jika belum ada
	if err := os.MkdirAll(req.OutputDir, os.ModePerm); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(model.CompressResponse{
			Success: false,
			Message: "Gagal membuat folder output: " + err.Error(),
		})
		return
	}

	// Hormati scale manual positif dari pengguna; jika <= 0 biarkan service meresolusi otomatis secara dinamis
	scale := req.Scale
	if scale < 0 {
		scale = 0
	}

	// Set default action jika kosong
	if req.Action == "" {
		req.Action = "convert_compress"
	}

	var outputFiles []string

	// 2. Eksekusi per file (langsung jika 1 file; worker pool terurut jika banyak file)
	if len(req.Files) == 1 {
		outPaths, err := processSingleCompressFile(req.Files[0], req, scale)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(model.CompressResponse{
				Success: false,
				Message: err.Error(),
			})
			return
		}
		outputFiles = outPaths
	} else if len(req.Files) > 1 {
		perFileOutputs := make([][]string, len(req.Files))
		workers := 4
		if req.Action == "upscale_ai" {
			workers = 2
		}
		if len(req.Files) < workers {
			workers = len(req.Files)
		}

		idxCh := make(chan int, len(req.Files))
		for i := range req.Files {
			idxCh <- i
		}
		close(idxCh)

		var wg sync.WaitGroup
		var errOnce sync.Once
		var firstErr error
		for wIdx := 0; wIdx < workers; wIdx++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for idx := range idxCh {
					outPaths, err := processSingleCompressFile(req.Files[idx], req, scale)
					if err != nil {
						errOnce.Do(func() { firstErr = err })
						return
					}
					perFileOutputs[idx] = outPaths
				}
			}()
		}
		wg.Wait()

		if firstErr != nil {
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(model.CompressResponse{
				Success: false,
				Message: firstErr.Error(),
			})
			return
		}
		for _, outPaths := range perFileOutputs {
			outputFiles = append(outputFiles, outPaths...)
		}
	}

	// 3. Kirim response sukses
	response := model.CompressResponse{
		Success:      true,
		Message:      "Proses berhasil dilaksanakan",
		Files:        outputFiles,
		TargetFormat: req.TargetFormat,
		TotalFiles:   len(outputFiles),
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)
}


// ==========================================
// HANDLER TERPISAH: PDF MANAGER
// ==========================================

func MergePdfHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	var req model.MergeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(model.CompressResponse{Success: false, Message: err.Error()})
		return
	}

	mergedPath := filepath.Join(req.OutputDir, "merged_output.pdf")
	if err := service.MergePdf(req.Files, mergedPath); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(model.CompressResponse{Success: false, Message: err.Error()})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(model.CompressResponse{
		Success:    true,
		Message:    "PDF berhasil digabungkan",
		Files:      []string{mergedPath},
		TotalFiles: 1,
	})
}

func SplitPdfHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	var req model.SplitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(model.CompressResponse{Success: false, Message: err.Error()})
		return
	}

	if err := service.SplitPdf(req.File, req.OutputDir); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(model.CompressResponse{Success: false, Message: err.Error()})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(model.CompressResponse{
		Success: true,
		Message: "PDF berhasil dipecah",
	})
}

func ReorderPdfHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	var req model.ReorderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(model.CompressResponse{Success: false, Message: err.Error()})
		return
	}

	baseName := strings.TrimSuffix(filepath.Base(req.File), filepath.Ext(req.File))
	reorderedPath := filepath.Join(req.OutputDir, baseName+"_reordered.pdf")

	if err := service.ReorderPdf(req.File, req.NewOrder, reorderedPath); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(model.CompressResponse{Success: false, Message: err.Error()})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(model.CompressResponse{
		Success:    true,
		Message:    "Urutan halaman PDF berhasil diatur ulang",
		Files:      []string{reorderedPath},
		TotalFiles: 1,
	})
}

// =========================================================================
// [DITAMBAHKAN] HANDLER UTAMA UNTUK WORKFLOW BERANTAI (SPLIT, MERGE, REORDER)
// =========================================================================

func PdfWorkflowHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		json.NewEncoder(w).Encode(model.CompressResponse{
			Success: false,
			Message: "Method tidak diizinkan",
		})
		return
	}

	var req model.PdfWorkflowRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(model.CompressResponse{
			Success: false,
			Message: "Format request JSON tidak valid: " + err.Error(),
		})
		return
	}

	result, err := service.ExecutePdfWorkflowDetailed(req)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(model.CompressResponse{
			Success: false,
			Message: "Gagal mengeksekusi workflow PDF: " + err.Error(),
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(model.CompressResponse{
		Success:          true,
		Message:          "Workflow PDF berhasil dijalankan secara fleksibel",
		Files:            result.Files,
		TotalFiles:       len(result.Files),
		RotationsApplied: result.RotationsApplied,
	})
}

// =========================================================================
// HEALTH & ENGINE WARMUP HANDLERS
// =========================================================================

type EngineWarmupRequest struct {
	Engine string `json:"engine"`
}

type EngineWarmupResponse struct {
	Success  bool   `json:"success"`
	Engine   string `json:"engine"`
	Message  string `json:"message"`
	WarmedUp bool   `json:"warmed_up"`
}

func HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "ok",
		"backend": "online",
	})
}

func EngineWarmupHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	engine := "word"
	if r.Method == http.MethodPost {
		var req EngineWarmupRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err == nil && req.Engine != "" {
			engine = req.Engine
		}
	} else {
		qEngine := r.URL.Query().Get("engine")
		if qEngine != "" {
			engine = qEngine
		}
	}

	err := service.WarmupDocEngine(engine)
	if err != nil {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(EngineWarmupResponse{
			Success:  false,
			Engine:   engine,
			Message:  err.Error(),
			WarmedUp: false,
		})
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(EngineWarmupResponse{
		Success:  true,
		Engine:   engine,
		Message:  fmt.Sprintf("Engine %s berhasil dihangatkan dan siap", engine),
		WarmedUp: true,
	})
}
