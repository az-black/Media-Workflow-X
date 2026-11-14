package service

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	appModel "github.com/az-black/app-pengompres-gambar-pdf/internal/model"
	"github.com/pdfcpu/pdfcpu/pkg/api"
	pdfmodel "github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
)

const qpdfMaxSourcesPerCall = 150

type WorkflowExecutionResult struct {
	Files            []string
	RotationsApplied bool
}

type qpdfPageSource struct {
	Path     string
	PageSpec string
}

var (
	cachedQpdfMu   sync.Mutex
	cachedQpdfPath string
)

func resolveQpdfPath() string {
	cachedQpdfMu.Lock()
	if cachedQpdfPath != "" {
		if info, err := os.Stat(cachedQpdfPath); err == nil && !info.IsDir() {
			p := cachedQpdfPath
			cachedQpdfMu.Unlock()
			return p
		}
		cachedQpdfPath = ""
	}
	cachedQpdfMu.Unlock()

	exeName := "qpdf"
	if runtime.GOOS == "windows" {
		exeName = "qpdf.exe"
	}

	var candidates []string
	addRoots := func(startDir string) {
		dir := startDir
		for depth := 0; depth < 7 && dir != ""; depth++ {
			candidates = append(candidates,
				filepath.Join(dir, "tools", "qpdf", "bin", exeName),
				filepath.Join(dir, "tools", "qpdf", "qpdf", "bin", exeName),
				filepath.Join(dir, "assets", "engine", "tools", "qpdf", "bin", exeName),
				filepath.Join(dir, "frontend_desktop", "assets", "engine", "tools", "qpdf", "bin", exeName),
				filepath.Join(dir, "Backend", "tools", "qpdf", "bin", exeName),
			)
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}

	if exePath, err := os.Executable(); err == nil {
		addRoots(filepath.Dir(exePath))
	}
	if wd, err := os.Getwd(); err == nil {
		addRoots(wd)
	}

	for _, cand := range candidates {
		if info, err := os.Stat(cand); err == nil && !info.IsDir() {
			abs, errAbs := filepath.Abs(cand)
			if errAbs == nil {
				cand = abs
			}
			cachedQpdfMu.Lock()
			cachedQpdfPath = cand
			cachedQpdfMu.Unlock()
			return cand
		}
	}

	if lookedUp, err := exec.LookPath(exeName); err == nil {
		abs, errAbs := filepath.Abs(lookedUp)
		if errAbs == nil {
			lookedUp = abs
		}
		cachedQpdfMu.Lock()
		cachedQpdfPath = lookedUp
		cachedQpdfMu.Unlock()
		return lookedUp
	}

	return ""
}

func runQpdfCommand(qpdfPath string, args []string) error {
	totalChars := 0
	for _, a := range args {
		totalChars += len(a) + 1
	}

	var cmd *exec.Cmd
	if len(args) > 16 || totalChars > 4000 {
		argFile, err := os.CreateTemp("", "qpdf_args_*.txt")
		if err != nil {
			return fmt.Errorf("gagal membuat parameter file QPDF: %w", err)
		}
		argFilePath := argFile.Name()
		defer os.Remove(argFilePath)

		var buf strings.Builder
		buf.Grow(totalChars + len(args))
		for _, a := range args {
			buf.WriteString(a)
			buf.WriteByte('\n')
		}
		if _, err := argFile.WriteString(buf.String()); err != nil {
			_ = argFile.Close()
			return fmt.Errorf("gagal menulis parameter file QPDF: %w", err)
		}
		if err := argFile.Close(); err != nil {
			return fmt.Errorf("gagal menutup parameter file QPDF: %w", err)
		}
		cmd = exec.Command(qpdfPath, "@"+argFilePath)
	} else {
		cmd = exec.Command(qpdfPath, args...)
	}

	cmd.Dir = filepath.Dir(qpdfPath)
	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &outBuf

	err := cmd.Run()
	if err != nil {
		// QPDF exit code 3 berarti berhasil disertai peringatan struktur non-fatal
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 3 {
			return nil
		}
		detail := strings.TrimSpace(outBuf.String())
		if detail != "" {
			return fmt.Errorf("QPDF error (%w): %s", err, detail)
		}
		return fmt.Errorf("QPDF error: %w", err)
	}
	return nil
}

// compactQpdfPageSpec memadatkan urutan nomor halaman menjadi notasi range QPDF,
// termasuk rentang naik ("1-20"), turun ("20-1"), dan gabungan seperti "1-3,5-4,10-8,1".
func compactQpdfPageSpec(pages []int) string {
	if len(pages) == 0 {
		return ""
	}
	parts := make([]string, 0, 8)
	i := 0
	for i < len(pages) {
		start := pages[i]
		end := start
		dir := 0
		j := i + 1
		for j < len(pages) {
			diff := pages[j] - end
			if dir == 0 {
				if diff == 1 || diff == -1 {
					dir = diff
					end = pages[j]
					j++
					continue
				}
				break
			} else if diff == dir {
				end = pages[j]
				j++
				continue
			}
			break
		}
		if start == end {
			parts = append(parts, strconv.Itoa(start))
		} else {
			parts = append(parts, fmt.Sprintf("%d-%d", start, end))
		}
		i = j
	}
	return strings.Join(parts, ",")
}

func normalizeRotationDeg(deg int) int {
	norm := ((deg % 360) + 360) % 360
	return norm
}

func normalizePageRotations(rot map[int]int) map[int]int {
	if len(rot) == 0 {
		return nil
	}
	out := make(map[int]int)
	for pageNum, deg := range rot {
		if pageNum < 1 {
			continue
		}
		norm := normalizeRotationDeg(deg)
		if norm == 0 {
			continue
		}
		out[pageNum] = norm
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func buildQpdfRotateFlags(rot map[int]int) []string {
	normMap := normalizePageRotations(rot)
	if len(normMap) == 0 {
		return nil
	}
	byAngle := make(map[int][]int)
	for pageNum, deg := range normMap {
		byAngle[deg] = append(byAngle[deg], pageNum)
	}
	angles := make([]int, 0, len(byAngle))
	for deg := range byAngle {
		angles = append(angles, deg)
	}
	sort.Ints(angles)

	flags := make([]string, 0, len(angles))
	for _, angle := range angles {
		pages := byAngle[angle]
		sort.Ints(pages)
		spec := compactQpdfPageSpec(pages)
		if spec != "" {
			flags = append(flags, fmt.Sprintf("--rotate=+%d:%s", angle, spec))
		}
	}
	return flags
}

func toAbsClean(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return path
}

func runQpdfAssemble(qpdfPath string, sources []qpdfPageSource, outputPdf string, rotations map[int]int) error {
	if len(sources) == 0 {
		return fmt.Errorf("sumber halaman PDF tidak boleh kosong")
	}
	outAbs := toAbsClean(outputPdf)
	if err := os.MkdirAll(filepath.Dir(outAbs), 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	rotFlags := buildQpdfRotateFlags(rotations)

	// Hindari menimpa file sumber jika outputPdf kebetulan menunjuk ke salah satu sumber
	sameAsInput := false
	for _, s := range sources {
		if strings.EqualFold(toAbsClean(s.Path), outAbs) {
			sameAsInput = true
			break
		}
	}
	writeTarget := outAbs
	if sameAsInput {
		writeTarget = outAbs + ".qpdf_tmp.pdf"
		defer os.Remove(writeTarget)
	}

	if len(sources) <= qpdfMaxSourcesPerCall {
		args := make([]string, 0, len(sources)*2+len(rotFlags)+4)
		args = append(args, "--empty", "--pages")
		for _, src := range sources {
			spec := strings.TrimSpace(src.PageSpec)
			if spec == "" {
				spec = "1-z"
			}
			args = append(args, toAbsClean(src.Path), spec)
		}
		args = append(args, "--")
		args = append(args, rotFlags...)
		args = append(args, writeTarget)

		if err := runQpdfCommand(qpdfPath, args); err != nil {
			return err
		}
	} else {
		// Batching aman untuk ratusan file agar tidak melebihi batas handle file OS C runtime
		chunkDir, err := os.MkdirTemp(filepath.Dir(outAbs), ".tmp_chunks_*")
		if err != nil {
			return fmt.Errorf("gagal membuat folder chunk sementara: %w", err)
		}
		defer os.RemoveAll(chunkDir)

		var chunks [][]qpdfPageSource
		for start := 0; start < len(sources); start += qpdfMaxSourcesPerCall {
			end := start + qpdfMaxSourcesPerCall
			if end > len(sources) {
				end = len(sources)
			}
			chunks = append(chunks, sources[start:end])
		}

		chunkFiles := make([]string, len(chunks))
		workerLimit := runtime.NumCPU()
		if workerLimit > 4 {
			workerLimit = 4
		}
		if workerLimit < 1 {
			workerLimit = 1
		}
		sem := make(chan struct{}, workerLimit)
		var wg sync.WaitGroup
		errChan := make(chan error, len(chunks))

		for idx, batch := range chunks {
			wg.Add(1)
			go func(i int, items []qpdfPageSource) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				chunkOut := filepath.Join(chunkDir, fmt.Sprintf("chunk_%d.pdf", i))
				if err := runQpdfAssemble(qpdfPath, items, chunkOut, nil); err != nil {
					errChan <- err
					return
				}
				chunkFiles[i] = chunkOut
			}(idx, batch)
		}
		wg.Wait()
		close(errChan)
		for err := range errChan {
			if err != nil {
				return err
			}
		}

		finalSources := make([]qpdfPageSource, len(chunkFiles))
		for i, cf := range chunkFiles {
			finalSources[i] = qpdfPageSource{Path: cf, PageSpec: "1-z"}
		}
		if err := runQpdfAssemble(qpdfPath, finalSources, writeTarget, rotations); err != nil {
			return err
		}
	}

	info, err := os.Stat(writeTarget)
	if err != nil || info.Size() <= 0 {
		return fmt.Errorf("QPDF menghasilkan output kosong: %s", writeTarget)
	}
	if sameAsInput {
		_ = os.Remove(outAbs)
		if err := os.Rename(writeTarget, outAbs); err != nil {
			return fmt.Errorf("gagal memindahkan output QPDF: %w", err)
		}
	}
	return nil
}

func runQpdfSplitSeparated(qpdfPath string, sourcePath string, pages []int, outputDir string, outputId string, rotations map[int]int) (string, error) {
	if len(pages) == 0 {
		return "", fmt.Errorf("pages tidak boleh kosong untuk split_separated")
	}
	outDirAbs := toAbsClean(outputDir)
	if err := os.MkdirAll(outDirAbs, 0755); err != nil {
		return "", fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	tmpSepDir, err := os.MkdirTemp(outDirAbs, ".tmp_sep_*")
	if err != nil {
		return "", fmt.Errorf("gagal membuat folder temporary split: %w", err)
	}
	defer os.RemoveAll(tmpSepDir)

	spec := compactQpdfPageSpec(pages)
	rotFlags := buildQpdfRotateFlags(rotations)
	pattern := filepath.Join(tmpSepDir, "part_%d.pdf")

	args := make([]string, 0, len(rotFlags)+8)
	args = append(args, "--empty", "--pages", toAbsClean(sourcePath), spec, "--")
	args = append(args, rotFlags...)
	args = append(args, "--split-pages=1", pattern)

	if err := runQpdfCommand(qpdfPath, args); err != nil {
		return "", err
	}

	entries, err := os.ReadDir(tmpSepDir)
	if err != nil {
		return "", fmt.Errorf("gagal membaca hasil split temporary: %w", err)
	}

	type indexedPart struct {
		idx  int
		path string
	}
	var parts []indexedPart
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasPrefix(name, "part_") || !strings.HasSuffix(strings.ToLower(name), ".pdf") {
			continue
		}
		numStr := strings.TrimSuffix(strings.TrimPrefix(name, "part_"), filepath.Ext(name))
		num, convErr := strconv.Atoi(numStr)
		if convErr != nil {
			continue
		}
		full := filepath.Join(tmpSepDir, name)
		if info, statErr := entry.Info(); statErr == nil && info.Size() > 0 {
			parts = append(parts, indexedPart{idx: num, path: full})
		}
	}

	sort.Slice(parts, func(i, j int) bool {
		return parts[i].idx < parts[j].idx
	})

	if len(parts) != len(pages) {
		return "", fmt.Errorf("jumlah output split QPDF (%d) tidak sesuai target halaman (%d)", len(parts), len(pages))
	}

	var firstSplitPath string
	for i, p := range parts {
		singleOut := filepath.Join(outDirAbs, fmt.Sprintf("%s_p%d.pdf", outputId, pages[i]))
		_ = os.Remove(singleOut)
		if err := os.Rename(p.path, singleOut); err != nil {
			if cpErr := copyFileFast(p.path, singleOut); cpErr != nil {
				return "", fmt.Errorf("gagal memindahkan file halaman %d: %w", pages[i], cpErr)
			}
		}
		if i == 0 {
			firstSplitPath = singleOut
		}
	}
	return firstSplitPath, nil
}

func copyFileFast(srcPath, dstPath string) error {
	if strings.EqualFold(toAbsClean(srcPath), toAbsClean(dstPath)) {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dstPath), 0755); err != nil {
		return err
	}
	in, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.Create(dstPath)
	if err != nil {
		return err
	}
	if _, err := io.CopyBuffer(out, in, make([]byte, 256*1024)); err != nil {
		_ = out.Close()
		_ = os.Remove(dstPath)
		return err
	}
	return out.Close()
}

func MergePdf(inputFiles []string, outputPdf string) error {
	if len(inputFiles) < 2 {
		return fmt.Errorf("minimal perlukan 2 file PDF untuk digabungkan")
	}
	if qpdfPath := resolveQpdfPath(); qpdfPath != "" {
		sources := make([]qpdfPageSource, len(inputFiles))
		for i, f := range inputFiles {
			if _, err := os.Stat(f); err != nil {
				return fmt.Errorf("file PDF tidak ditemukan: %s", f)
			}
			sources[i] = qpdfPageSource{Path: f, PageSpec: "1-z"}
		}
		if err := runQpdfAssemble(qpdfPath, sources, outputPdf, nil); err == nil {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(outputPdf), 0755); err != nil {
		return err
	}
	conf := pdfmodel.NewDefaultConfiguration()
	return api.MergeCreateFile(inputFiles, outputPdf, false, conf)
}

func SplitPdf(inputPdf string, outputDir string) error {
	if _, err := os.Stat(inputPdf); os.IsNotExist(err) {
		return fmt.Errorf("file PDF tidak ditemukan: %s", inputPdf)
	}
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %w", err)
	}
	if qpdfPath := resolveQpdfPath(); qpdfPath != "" {
		baseName := strings.TrimSuffix(filepath.Base(inputPdf), filepath.Ext(inputPdf))
		pattern := filepath.Join(toAbsClean(outputDir), baseName+"_page_%d.pdf")
		if err := runQpdfCommand(qpdfPath, []string{toAbsClean(inputPdf), "--split-pages=1", pattern}); err == nil {
			return nil
		}
	}
	conf := pdfmodel.NewDefaultConfiguration()
	return api.SplitFile(inputPdf, outputDir, 1, conf)
}

func ReorderPdf(inputPdf string, newOrder []int, outputPdf string) error {
	if _, err := os.Stat(inputPdf); os.IsNotExist(err) {
		return fmt.Errorf("file PDF tidak ditemukan: %s", inputPdf)
	}
	if len(newOrder) == 0 {
		return fmt.Errorf("urutan halaman baru tidak boleh kosong")
	}
	outputDir := filepath.Dir(outputPdf)
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %w", err)
	}
	if qpdfPath := resolveQpdfPath(); qpdfPath != "" {
		spec := compactQpdfPageSpec(newOrder)
		if err := runQpdfAssemble(qpdfPath, []qpdfPageSource{{Path: inputPdf, PageSpec: spec}}, outputPdf, nil); err == nil {
			return nil
		}
	}
	conf := pdfmodel.NewDefaultConfiguration()
	return extractPageSequence(inputPdf, newOrder, outputPdf, conf)
}

func isStrictlyAscending(pages []int) bool {
	if len(pages) <= 1 {
		return true
	}
	for i := 1; i < len(pages); i++ {
		if pages[i] <= pages[i-1] {
			return false
		}
	}
	return true
}

func compactAscendingStrings(pages []int) []string {
	if len(pages) == 0 {
		return nil
	}
	var specs []string
	start := pages[0]
	prev := pages[0]
	for i := 1; i < len(pages); i++ {
		if pages[i] == prev+1 {
			prev = pages[i]
		} else {
			if start == prev {
				specs = append(specs, strconv.Itoa(start))
			} else {
				specs = append(specs, fmt.Sprintf("%d-%d", start, prev))
			}
			start = pages[i]
			prev = pages[i]
		}
	}
	if start == prev {
		specs = append(specs, strconv.Itoa(start))
	} else {
		specs = append(specs, fmt.Sprintf("%d-%d", start, prev))
	}
	return specs
}

// Helper fallback: mengekstrak urutan halaman menggunakan pdfcpu secara terkompresi dan bounded paralel bila QPDF tidak tersedia.
func extractPageSequence(sourcePath string, pageSeq []int, outputPath string, conf *pdfmodel.Configuration) error {
	if len(pageSeq) == 1 {
		return api.TrimFile(sourcePath, outputPath, []string{strconv.Itoa(pageSeq[0])}, conf)
	}
	if isStrictlyAscending(pageSeq) {
		return api.TrimFile(sourcePath, outputPath, compactAscendingStrings(pageSeq), conf)
	}

	tempPagesDir := fmt.Sprintf("%s_seq_%d_%d", outputPath, os.Getpid(), time.Now().UnixNano())
	_ = os.MkdirAll(tempPagesDir, 0755)
	defer os.RemoveAll(tempPagesDir)

	pageFiles := make([]string, len(pageSeq))
	workerLimit := runtime.NumCPU()
	if workerLimit < 1 {
		workerLimit = 1
	}
	sem := make(chan struct{}, workerLimit)
	var wg sync.WaitGroup
	var errChan = make(chan error, len(pageSeq))

	for idx, pageNum := range pageSeq {
		wg.Add(1)
		go func(i int, pNum int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			pOut := filepath.Join(tempPagesDir, fmt.Sprintf("sub_p_%d_%d.pdf", i, pNum))
			if err := api.TrimFile(sourcePath, pOut, []string{strconv.Itoa(pNum)}, conf); err != nil {
				errChan <- fmt.Errorf("gagal trim halaman %d: %w", pNum, err)
				return
			}
			pageFiles[i] = pOut
		}(idx, pageNum)
	}

	wg.Wait()
	close(errChan)

	for err := range errChan {
		if err != nil {
			return err
		}
	}

	return api.MergeCreateFile(pageFiles, outputPath, false, conf)
}

// =========================================================================
// PIPELINE & MODULAR SERVICE
// =========================================================================

func ExecuteSingleStep(stepIndex int, step appModel.WorkflowStep, fileRegistry map[string]string, outputDir string) (string, string, error) {
	outId, outPath, _, err := executeSingleStepWithMeta(stepIndex, step, fileRegistry, outputDir)
	return outId, outPath, err
}

func executeSingleStepWithMeta(stepIndex int, step appModel.WorkflowStep, fileRegistry map[string]string, outputDir string) (string, string, bool, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", "", false, fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	qpdfPath := resolveQpdfPath()
	conf := pdfmodel.NewDefaultConfiguration()
	var generatedPath string
	rotationsApplied := false

	switch step.Action {

	// -------------------------------------------------------------------------
	// 1. SPLIT (Mendukung format "splits" baru maupun "ranges" lama)
	// -------------------------------------------------------------------------
	case "split", "split_multiple":
		var splitRules []appModel.MultipleSplitRule

		if len(step.Splits) > 0 {
			splitRules = step.Splits
		} else if len(step.Ranges) > 0 && step.TargetId != "" {
			for _, rng := range step.Ranges {
				splitRules = append(splitRules, appModel.MultipleSplitRule{
					SourceId: step.TargetId,
					Pages:    rng,
				})
			}
		}

		if len(splitRules) == 0 {
			return "", "", false, fmt.Errorf("splits atau ranges tidak boleh kosong untuk aksi split")
		}

		outPath := filepath.Join(outputDir, step.OutputId+".pdf")

		if qpdfPath != "" {
			sources := make([]qpdfPageSource, 0, len(splitRules))
			for i, r := range splitRules {
				sourcePath, exists := fileRegistry[r.SourceId]
				if !exists {
					return "", "", false, fmt.Errorf("sourceId '%s' pada slot %d tidak ditemukan", r.SourceId, i+1)
				}
				if len(r.Pages) == 0 {
					return "", "", false, fmt.Errorf("daftar halaman pada slot split %d tidak boleh kosong", i+1)
				}
				sources = append(sources, qpdfPageSource{
					Path:     sourcePath,
					PageSpec: compactQpdfPageSpec(r.Pages),
				})
			}
			if err := runQpdfAssemble(qpdfPath, sources, outPath, step.Rotations); err == nil {
				generatedPath = outPath
				rotationsApplied = true
				break
			}
		}

		slotFiles := make([]string, len(splitRules))
		tempSlotDir := filepath.Join(outputDir, fmt.Sprintf("temp_slots_%d_%d", stepIndex+1, time.Now().UnixNano()))
		_ = os.MkdirAll(tempSlotDir, 0755)
		defer os.RemoveAll(tempSlotDir)

		var wg sync.WaitGroup
		var errChan = make(chan error, len(splitRules))

		for idx, rule := range splitRules {
			wg.Add(1)
			go func(i int, r appModel.MultipleSplitRule) {
				defer wg.Done()
				sourcePath, exists := fileRegistry[r.SourceId]
				if !exists {
					errChan <- fmt.Errorf("sourceId '%s' pada slot %d tidak ditemukan", r.SourceId, i+1)
					return
				}

				slotPath := filepath.Join(tempSlotDir, fmt.Sprintf("slot_%d.pdf", i))
				if err := extractPageSequence(sourcePath, r.Pages, slotPath, conf); err != nil {
					errChan <- fmt.Errorf("gagal memproses slot split %d: %w", i+1, err)
					return
				}

				slotFiles[i] = slotPath
			}(idx, rule)
		}

		wg.Wait()
		close(errChan)

		for err := range errChan {
			if err != nil {
				return "", "", false, err
			}
		}

		if len(slotFiles) == 1 {
			if err := os.Rename(slotFiles[0], outPath); err != nil {
				if cpErr := copyFileFast(slotFiles[0], outPath); cpErr != nil {
					return "", "", false, fmt.Errorf("gagal menyimpan split tunggal: %w", cpErr)
				}
			}
		} else if err := api.MergeCreateFile(slotFiles, outPath, false, conf); err != nil {
			return "", "", false, fmt.Errorf("gagal auto-merge split: %w", err)
		}
		generatedPath = outPath

	// -------------------------------------------------------------------------
	// 2. REORDER (Mendukung format "reorders" baru maupun "newOrder" lama)
	// -------------------------------------------------------------------------
	case "reorder", "reorder_multiple":
		var reorderRules []appModel.MultipleReorderRule

		if len(step.Reorders) > 0 {
			reorderRules = step.Reorders
		} else if len(step.NewOrder) > 0 && step.TargetId != "" {
			reorderRules = append(reorderRules, appModel.MultipleReorderRule{
				SourceId: step.TargetId,
				NewOrder: step.NewOrder,
			})
		}

		if len(reorderRules) == 0 {
			return "", "", false, fmt.Errorf("reorders atau newOrder tidak boleh kosong untuk aksi reorder")
		}

		outPath := filepath.Join(outputDir, step.OutputId+".pdf")

		if qpdfPath != "" {
			sources := make([]qpdfPageSource, 0, len(reorderRules))
			for i, r := range reorderRules {
				sourcePath, exists := fileRegistry[r.SourceId]
				if !exists {
					return "", "", false, fmt.Errorf("sourceId '%s' pada reorder slot %d tidak ditemukan", r.SourceId, i+1)
				}
				if len(r.NewOrder) == 0 {
					return "", "", false, fmt.Errorf("urutan halaman pada reorder slot %d tidak boleh kosong", i+1)
				}
				sources = append(sources, qpdfPageSource{
					Path:     sourcePath,
					PageSpec: compactQpdfPageSpec(r.NewOrder),
				})
			}
			if err := runQpdfAssemble(qpdfPath, sources, outPath, step.Rotations); err == nil {
				generatedPath = outPath
				rotationsApplied = true
				break
			}
		}

		slotFiles := make([]string, len(reorderRules))
		tempSlotDir := filepath.Join(outputDir, fmt.Sprintf("temp_slots_%d_%d", stepIndex+1, time.Now().UnixNano()))
		_ = os.MkdirAll(tempSlotDir, 0755)
		defer os.RemoveAll(tempSlotDir)

		var wg sync.WaitGroup
		var errChan = make(chan error, len(reorderRules))

		for idx, rule := range reorderRules {
			wg.Add(1)
			go func(i int, r appModel.MultipleReorderRule) {
				defer wg.Done()
				sourcePath, exists := fileRegistry[r.SourceId]
				if !exists {
					errChan <- fmt.Errorf("sourceId '%s' pada reorder slot %d tidak ditemukan", r.SourceId, i+1)
					return
				}

				slotPath := filepath.Join(tempSlotDir, fmt.Sprintf("slot_%d.pdf", i))
				if err := extractPageSequence(sourcePath, r.NewOrder, slotPath, conf); err != nil {
					errChan <- fmt.Errorf("gagal memproses reorder slot %d: %w", i+1, err)
					return
				}

				slotFiles[i] = slotPath
			}(idx, rule)
		}

		wg.Wait()
		close(errChan)

		for err := range errChan {
			if err != nil {
				return "", "", false, err
			}
		}

		if len(slotFiles) == 1 {
			if err := os.Rename(slotFiles[0], outPath); err != nil {
				if cpErr := copyFileFast(slotFiles[0], outPath); cpErr != nil {
					return "", "", false, fmt.Errorf("gagal menyimpan reorder tunggal: %w", cpErr)
				}
			}
		} else if err := api.MergeCreateFile(slotFiles, outPath, false, conf); err != nil {
			return "", "", false, fmt.Errorf("gagal auto-merge reorder: %w", err)
		}
		generatedPath = outPath

	// -------------------------------------------------------------------------
	// 3. MERGE STANDAR (Menggabungkan beberapa file/pool jadi file utuh)
	// -------------------------------------------------------------------------
	case "merge":
		var filesToMerge []string
		for _, id := range step.InputIds {
			path, exists := fileRegistry[id]
			if !exists {
				return "", "", false, fmt.Errorf("input ID '%s' tidak ditemukan di registry", id)
			}
			filesToMerge = append(filesToMerge, path)
		}
		if len(filesToMerge) == 0 {
			return "", "", false, fmt.Errorf("inputIds tidak boleh kosong untuk aksi merge")
		}

		outPath := filepath.Join(outputDir, step.OutputId+".pdf")
		if len(filesToMerge) == 1 && len(normalizePageRotations(step.Rotations)) == 0 {
			if err := copyFileFast(filesToMerge[0], outPath); err != nil {
				return "", "", false, fmt.Errorf("gagal menyalin file tunggal merge: %w", err)
			}
			generatedPath = outPath
			rotationsApplied = true
			break
		}

		if qpdfPath != "" {
			sources := make([]qpdfPageSource, len(filesToMerge))
			for i, path := range filesToMerge {
				sources[i] = qpdfPageSource{Path: path, PageSpec: "1-z"}
			}
			if err := runQpdfAssemble(qpdfPath, sources, outPath, step.Rotations); err == nil {
				generatedPath = outPath
				rotationsApplied = true
				break
			}
		}

		if err := api.MergeCreateFile(filesToMerge, outPath, false, conf); err != nil {
			return "", "", false, fmt.Errorf("gagal merge file: %w", err)
		}
		generatedPath = outPath

	// -------------------------------------------------------------------------
	// 4. SPLIT SEPARATED (Pisah fisik murni dengan Single-Pass QPDF / Paralel)
	// -------------------------------------------------------------------------
	case "split_separated":
		sourcePath, exists := fileRegistry[step.TargetId]
		if !exists {
			return "", "", false, fmt.Errorf("targetId '%s' tidak ditemukan di registry", step.TargetId)
		}
		if len(step.Pages) == 0 {
			return "", "", false, fmt.Errorf("pages tidak boleh kosong untuk split_separated")
		}

		if qpdfPath != "" {
			firstOut, err := runQpdfSplitSeparated(qpdfPath, sourcePath, step.Pages, outputDir, step.OutputId, step.Rotations)
			if err == nil {
				generatedPath = firstOut
				rotationsApplied = true
				break
			}
		}

		workerLimit := runtime.NumCPU()
		if workerLimit < 1 {
			workerLimit = 1
		}
		sem := make(chan struct{}, workerLimit)
		var wg sync.WaitGroup
		var mu sync.Mutex
		var errChan = make(chan error, len(step.Pages))
		var firstSplitPath string

		for idx, p := range step.Pages {
			wg.Add(1)
			go func(i int, pageNum int) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				singleOut := filepath.Join(outputDir, fmt.Sprintf("%s_p%d.pdf", step.OutputId, pageNum))
				if err := api.TrimFile(sourcePath, singleOut, []string{strconv.Itoa(pageNum)}, conf); err != nil {
					errChan <- fmt.Errorf("gagal memisah halaman %d: %w", pageNum, err)
					return
				}

				mu.Lock()
				if i == 0 {
					firstSplitPath = singleOut
				}
				mu.Unlock()
			}(idx, p)
		}

		wg.Wait()
		close(errChan)

		for err := range errChan {
			if err != nil {
				return "", "", false, err
			}
		}

		generatedPath = firstSplitPath

	default:
		return "", "", false, fmt.Errorf("aksi tidak dikenal: %s", step.Action)
	}

	if len(normalizePageRotations(step.Rotations)) == 0 {
		rotationsApplied = true
	}

	return step.OutputId, generatedPath, rotationsApplied, nil
}

func ExecutePdfWorkflow(req appModel.PdfWorkflowRequest) ([]string, error) {
	res, err := ExecutePdfWorkflowDetailed(req)
	return res.Files, err
}

func ExecutePdfWorkflowDetailed(req appModel.PdfWorkflowRequest) (WorkflowExecutionResult, error) {
	fmt.Printf("[WORKFLOW] Memulai eksekusi workflow dengan %d langkah ke direktori: %s\n", len(req.Steps), req.OutputDir)

	if err := os.MkdirAll(req.OutputDir, 0755); err != nil {
		return WorkflowExecutionResult{}, fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	tempProcessDir, err := os.MkdirTemp("", "pdf_workflow_temp_*")
	if err != nil {
		return WorkflowExecutionResult{}, fmt.Errorf("gagal membuat folder temporary proses: %w", err)
	}
	defer os.RemoveAll(tempProcessDir)

	fileRegistry := make(map[string]string)
	for _, f := range req.InitialFiles {
		if f.ID == "" {
			return WorkflowExecutionResult{}, fmt.Errorf("setiap initialFile harus memiliki 'id'")
		}
		fileRegistry[f.ID] = f.Path
	}

	var finalOutputs []string
	allRotationsApplied := len(req.Steps) > 0
	totalSteps := len(req.Steps)

	for i, step := range req.Steps {
		fmt.Printf("[STEP %d/%d] Menjalankan aksi '%s' (Output ID: %s)...\n", i+1, totalSteps, step.Action, step.OutputId)

		targetDir := tempProcessDir
		if i == totalSteps-1 {
			targetDir = req.OutputDir // Step terakhir langsung dicetak ke folder tujuan utama
		}

		outId, outPath, stepRotApplied, err := executeSingleStepWithMeta(i, step, fileRegistry, targetDir)
		if err != nil {
			fmt.Printf("[STEP ERROR] Step %d (%s) gagal: %v\n", i+1, step.Action, err)
			return WorkflowExecutionResult{}, fmt.Errorf("gagal pada step %d (%s): %w", i+1, step.Action, err)
		}
		if !stepRotApplied {
			allRotationsApplied = false
		}

		if outId != "" {
			fileRegistry[outId] = outPath // Output file utuh otomatis masuk ke registry untuk disambung ke step berikutnya!
		}

		fmt.Printf("[STEP SUCCESS] Berhasil menghasilkan: %s\n", outPath)

		if i == totalSteps-1 {
			finalOutputs = append(finalOutputs, outPath)
		}
	}

	fmt.Printf("[WORKFLOW SUCCESS] Seluruh workflow selesai. File akhir disimpan di: %s\n", req.OutputDir)
	return WorkflowExecutionResult{
		Files:            finalOutputs,
		RotationsApplied: allRotationsApplied,
	}, nil
}
