package service

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	appModel "github.com/az-black/app-pengompres-gambar-pdf/internal/model"
	"github.com/pdfcpu/pdfcpu/pkg/api"
)

func buildTestSyntheticPdfBytes(pageCount int, taggedLabel string) []byte {
	var kids strings.Builder
	for i := 0; i < pageCount; i++ {
		if i > 0 {
			kids.WriteByte(' ')
		}
		kids.WriteString(strconv.Itoa(3 + i*2))
		kids.WriteString(" 0 R")
	}

	var buf strings.Builder
	buf.WriteString("%PDF-1.4\n")
	buf.WriteString("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
	buf.WriteString(fmt.Sprintf(
		"2 0 obj\n<< /Type /Pages /Count %d /MediaBox [0 0 595 842] /Kids [ %s ] >>\nendobj\n",
		pageCount, kids.String(),
	))

	for i := 0; i < pageCount; i++ {
		pageObj := 3 + i*2
		contentObj := pageObj + 1
		// Width varies subtly per page so page identity after reorder/split can be verified
		w := 595 + i*10
		stream := fmt.Sprintf("q (%s-P%d) Tj Q\n", taggedLabel, i+1)
		buf.WriteString(fmt.Sprintf(
			"%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d 842] /Contents %d 0 R >>\nendobj\n",
			pageObj, w, contentObj,
		))
		buf.WriteString(fmt.Sprintf(
			"%d 0 obj\n<< /Length %d >>\nstream\n%sendstream\nendobj\n",
			contentObj, len(stream), stream,
		))
	}

	buf.WriteString("%%EOF\n")
	return []byte(buf.String())
}

func writeTestPdf(t *testing.T, dir, name string, pageCount int, tag string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, buildTestSyntheticPdfBytes(pageCount, tag), 0644); err != nil {
		t.Fatalf("failed to write test PDF %s: %v", p, err)
	}
	return p
}

type inspectedPdfPage struct {
	WidthPt  float64
	Rotation int
}

func inspectPdfWithQpdf(t *testing.T, qpdfPath, pdfPath string) []inspectedPdfPage {
	t.Helper()
	cmd := exec.Command(qpdfPath, "--json=2", toAbsClean(pdfPath))
	cmd.Dir = filepath.Dir(qpdfPath)
	out, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 3 {
			// non-fatal QPDF warning; stdout JSON is valid
		} else {
			t.Fatalf("qpdf --json=2 failed on %s: %v", pdfPath, err)
		}
	}

	var doc struct {
		Pages []struct {
			Object string `json:"object"`
		} `json:"pages"`
		Qpdf []json.RawMessage `json:"qpdf"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatalf("failed to parse qpdf json on %s: %v", pdfPath, err)
	}

	// qpdf json=2 format: qpdf[1] is map of objectKey -> {"value": {...}}
	var objs map[string]struct {
		Value map[string]any `json:"value"`
	}
	if len(doc.Qpdf) >= 2 {
		_ = json.Unmarshal(doc.Qpdf[1], &objs)
	}

	var result []inspectedPdfPage
	for _, p := range doc.Pages {
		info := inspectedPdfPage{WidthPt: 595, Rotation: 0}
		entry, ok := objs["obj:"+p.Object]
		if !ok {
			entry, ok = objs[p.Object]
		}
		if ok {
			if rotRaw, hasRot := entry.Value["/Rotate"]; hasRot {
				switch v := rotRaw.(type) {
				case float64:
					info.Rotation = normalizeRotationDeg(int(v))
				}
			}
			if mbRaw, hasMb := entry.Value["/MediaBox"]; hasMb {
				if arr, ok := mbRaw.([]any); ok && len(arr) >= 4 {
					x1, _ := arr[0].(float64)
					x2, _ := arr[2].(float64)
					info.WidthPt = x2 - x1
				}
			}
		}
		result = append(result, info)
	}
	return result
}

func TestCompactQpdfPageSpecAndRotateFlags(t *testing.T) {
	if got := compactQpdfPageSpec(nil); got != "" {
		t.Fatalf("expected empty spec, got %q", got)
	}
	if got := compactQpdfPageSpec([]int{5}); got != "5" {
		t.Fatalf("expected 5, got %q", got)
	}
	if got := compactQpdfPageSpec([]int{1, 2, 3, 4, 5}); got != "1-5" {
		t.Fatalf("expected 1-5, got %q", got)
	}
	if got := compactQpdfPageSpec([]int{20, 19, 18, 17}); got != "20-17" {
		t.Fatalf("expected 20-17, got %q", got)
	}
	if got := compactQpdfPageSpec([]int{1, 2, 3, 5, 4, 10, 9, 8, 1, 1}); got != "1-3,5-4,10-8,1,1" {
		t.Fatalf("expected 1-3,5-4,10-8,1,1, got %q", got)
	}

	flags := buildQpdfRotateFlags(map[int]int{
		1: 90,
		2: 90,
		3: 90,
		4: -90,
		5: 360, // zero net rotation -> dropped
	})
	if len(flags) != 2 || flags[0] != "--rotate=+90:1-3" || flags[1] != "--rotate=+270:4" {
		t.Fatalf("unexpected rotate flags: %#v", flags)
	}
}

func TestPdfManagerPoolsAndRotations(t *testing.T) {
	qpdfPath := resolveQpdfPath()
	if qpdfPath == "" {
		t.Skip("qpdf.exe tidak ditemukan pada environment test")
	}

	tmpDir := t.TempDir()
	docA := writeTestPdf(t, tmpDir, "docA.pdf", 5, "A") // widths 595, 605, 615, 625, 635
	docB := writeTestPdf(t, tmpDir, "docB.pdf", 3, "B") // widths 595, 605, 615

	// 1. Split + Rotations
	splitOutDir := filepath.Join(tmpDir, "out_split")
	resSplit, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{{ID: "a", Path: docA}},
		OutputDir:    splitOutDir,
		Steps: []appModel.WorkflowStep{
			{
				Action:   "split",
				OutputId: "split_res",
				Splits: []appModel.MultipleSplitRule{
					{SourceId: "a", Pages: []int{2, 4, 5}},
				},
				Rotations: map[int]int{1: 90, 3: 180},
			},
		},
	})
	if err != nil {
		t.Fatalf("split workflow failed: %v", err)
	}
	if !resSplit.RotationsApplied || len(resSplit.Files) != 1 {
		t.Fatalf("unexpected split result: %#v", resSplit)
	}
	splitPages := inspectPdfWithQpdf(t, qpdfPath, resSplit.Files[0])
	if len(splitPages) != 3 {
		t.Fatalf("expected 3 split pages, got %d", len(splitPages))
	}
	if splitPages[0].WidthPt != 605 || splitPages[1].WidthPt != 625 || splitPages[2].WidthPt != 635 {
		t.Fatalf("unexpected split page widths (identity): %#v", splitPages)
	}
	if splitPages[0].Rotation != 90 || splitPages[1].Rotation != 0 || splitPages[2].Rotation != 180 {
		t.Fatalf("unexpected split page rotations: %#v", splitPages)
	}

	// 2. Reorder + Rotations
	reorderOutDir := filepath.Join(tmpDir, "out_reorder")
	resReorder, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{{ID: "a", Path: docA}},
		OutputDir:    reorderOutDir,
		Steps: []appModel.WorkflowStep{
			{
				Action:   "reorder",
				OutputId: "reorder_res",
				Reorders: []appModel.MultipleReorderRule{
					{SourceId: "a", NewOrder: []int{5, 1, 3}},
				},
				Rotations: map[int]int{2: 270},
			},
		},
	})
	if err != nil {
		t.Fatalf("reorder workflow failed: %v", err)
	}
	reorderPages := inspectPdfWithQpdf(t, qpdfPath, resReorder.Files[0])
	if len(reorderPages) != 3 {
		t.Fatalf("expected 3 reorder pages, got %d", len(reorderPages))
	}
	if reorderPages[0].WidthPt != 635 || reorderPages[1].WidthPt != 595 || reorderPages[2].WidthPt != 615 {
		t.Fatalf("unexpected reordered page widths: %#v", reorderPages)
	}
	if reorderPages[0].Rotation != 0 || reorderPages[1].Rotation != 270 || reorderPages[2].Rotation != 0 {
		t.Fatalf("unexpected reorder rotations: %#v", reorderPages)
	}

	// 3. Merge + Rotations + chaining with prior output
	mergeOutDir := filepath.Join(tmpDir, "out_merge")
	resMerge, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{
			{ID: "a", Path: docA},
			{ID: "b", Path: docB},
		},
		OutputDir: mergeOutDir,
		Steps: []appModel.WorkflowStep{
			{
				Action:   "split",
				OutputId: "s1",
				Splits:   []appModel.MultipleSplitRule{{SourceId: "a", Pages: []int{1, 2}}},
			},
			{
				Action:    "merge",
				OutputId:  "final_merged",
				InputIds:  []string{"s1", "b"},
				Rotations: map[int]int{4: 90}, // 4th page = 2nd page of docB
			},
		},
	})
	if err != nil {
		t.Fatalf("chained merge workflow failed: %v", err)
	}
	mergePages := inspectPdfWithQpdf(t, qpdfPath, resMerge.Files[0])
	if len(mergePages) != 5 {
		t.Fatalf("expected 5 merged pages, got %d", len(mergePages))
	}
	if mergePages[3].Rotation != 90 || mergePages[0].Rotation != 0 {
		t.Fatalf("unexpected merge rotations: %#v", mergePages)
	}

	// 4. Split Separated + Rotations
	sepOutDir := filepath.Join(tmpDir, "out_sep")
	resSep, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{{ID: "a", Path: docA}},
		OutputDir:    sepOutDir,
		Steps: []appModel.WorkflowStep{
			{
				Action:    "split_separated",
				TargetId:  "a",
				OutputId:  "sep_out",
				Pages:     []int{1, 3, 5},
				Rotations: map[int]int{2: 90, 3: 180}, // 2nd output = page 3 (+90), 3rd = page 5 (+180)
			},
		},
	})
	if err != nil {
		t.Fatalf("split_separated workflow failed: %v", err)
	}
	if !resSep.RotationsApplied {
		t.Fatalf("expected RotationsApplied=true for split_separated")
	}
	p1 := inspectPdfWithQpdf(t, qpdfPath, filepath.Join(sepOutDir, "sep_out_p1.pdf"))
	p3 := inspectPdfWithQpdf(t, qpdfPath, filepath.Join(sepOutDir, "sep_out_p3.pdf"))
	p5 := inspectPdfWithQpdf(t, qpdfPath, filepath.Join(sepOutDir, "sep_out_p5.pdf"))
	if len(p1) != 1 || p1[0].WidthPt != 595 || p1[0].Rotation != 0 {
		t.Fatalf("unexpected split_separated p1: %#v", p1)
	}
	if len(p3) != 1 || p3[0].WidthPt != 615 || p3[0].Rotation != 90 {
		t.Fatalf("unexpected split_separated p3: %#v", p3)
	}
	if len(p5) != 1 || p5[0].WidthPt != 635 || p5[0].Rotation != 180 {
		t.Fatalf("unexpected split_separated p5: %#v", p5)
	}
}

func TestMergeOverMaxSourcesBatchingUnder5Seconds(t *testing.T) {
	qpdfPath := resolveQpdfPath()
	if qpdfPath == "" {
		t.Skip("qpdf.exe tidak ditemukan pada environment test")
	}

	tmpDir := t.TempDir()
	// 180 input PDFs exercises chunked parallel QPDF batching (> qpdfMaxSourcesPerCall = 150)
	const count = 180
	initialFiles := make([]appModel.InputFile, 0, count)
	inputIDs := make([]string, 0, count)
	for i := 0; i < count; i++ {
		name := fmt.Sprintf("f_%03d.pdf", i)
		p := writeTestPdf(t, tmpDir, name, 1, name)
		id := fmt.Sprintf("id_%d", i)
		initialFiles = append(initialFiles, appModel.InputFile{ID: id, Path: p})
		inputIDs = append(inputIDs, id)
	}

	outDir := filepath.Join(tmpDir, "merged_many")
	start := time.Now()
	res, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: initialFiles,
		OutputDir:    outDir,
		Steps: []appModel.WorkflowStep{
			{
				Action:    "merge",
				OutputId:  "many_out",
				InputIds:  inputIDs,
				Rotations: map[int]int{1: 90, 180: 180},
			},
		},
	})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("180-file merge failed: %v", err)
	}
	t.Logf("180-file chunked merge completed in %v", elapsed)
	if elapsed >= 5*time.Second {
		t.Fatalf("180-file merge took too long: %v (limit 5s)", elapsed)
	}

	pages := inspectPdfWithQpdf(t, qpdfPath, res.Files[0])
	if len(pages) != count {
		t.Fatalf("expected %d merged pages, got %d", count, len(pages))
	}
	if pages[0].Rotation != 90 || pages[count-1].Rotation != 180 {
		t.Fatalf("expected rotations (90, 180) on first/last page, got (%d, %d)", pages[0].Rotation, pages[count-1].Rotation)
	}
}

func TestRealLargeSamplePdfsAllPoolsUnder5Seconds(t *testing.T) {
	if resolveQpdfPath() == "" {
		t.Skip("qpdf.exe tidak ditemukan pada environment test")
	}

	sampleDir := filepath.Join("..", "..", "..", "sample_files", "pdf")
	jurnalPath := filepath.Join(sampleDir, "jurnal1.pdf")
	if _, err := os.Stat(jurnalPath); err != nil {
		t.Skipf("sample PDFs not found at %s", sampleDir)
	}

	file1Path := filepath.Join(sampleDir, "file1.pdf")
	file2Path := filepath.Join(sampleDir, "file2.pdf")
	file3Path := filepath.Join(sampleDir, "file3.pdf")
	tmpDir := t.TempDir()

	// 1. Split Pool 1-20 on 15.6MB jurnal1.pdf
	var pages1to20 []int
	for i := 1; i <= 20; i++ {
		pages1to20 = append(pages1to20, i)
	}
	start := time.Now()
	splitRes, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{{ID: "j1", Path: jurnalPath}},
		OutputDir:    filepath.Join(tmpDir, "split_1_20"),
		Steps: []appModel.WorkflowStep{
			{
				Action:    "split",
				OutputId:  "split_out",
				Splits:    []appModel.MultipleSplitRule{{SourceId: "j1", Pages: pages1to20}},
				Rotations: map[int]int{1: 90, 20: 180},
			},
		},
	})
	splitElapsed := time.Since(start)
	if err != nil {
		t.Fatalf("real split failed: %v", err)
	}
	t.Logf("jurnal1.pdf Split 1-20 elapsed: %v", splitElapsed)
	if splitElapsed >= 5*time.Second {
		t.Fatalf("Split Pool exceeded 5s limit: %v", splitElapsed)
	}
	if n, err := api.PageCountFile(splitRes.Files[0]); err != nil || n != 20 {
		t.Fatalf("expected 20 pages in split_out, got %d (err=%v)", n, err)
	}

	// 2. Split Separate Pool 1-20 on 15.6MB jurnal1.pdf
	sepDir := filepath.Join(tmpDir, "split_sep_1_20")
	start = time.Now()
	_, err = ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{{ID: "j1", Path: jurnalPath}},
		OutputDir:    sepDir,
		Steps: []appModel.WorkflowStep{
			{
				Action:    "split_separated",
				TargetId:  "j1",
				OutputId:  "sep",
				Pages:     pages1to20,
				Rotations: map[int]int{5: 90},
			},
		},
	})
	sepElapsed := time.Since(start)
	if err != nil {
		t.Fatalf("real split_separated failed: %v", err)
	}
	t.Logf("jurnal1.pdf Split Separate 1-20 elapsed: %v", sepElapsed)
	if sepElapsed >= 5*time.Second {
		t.Fatalf("Split Separate Pool exceeded 5s limit: %v", sepElapsed)
	}
	for _, p := range pages1to20 {
		part := filepath.Join(sepDir, fmt.Sprintf("sep_p%d.pdf", p))
		if info, err := os.Stat(part); err != nil || info.Size() <= 0 {
			t.Fatalf("missing split_separated page %d: %v", p, err)
		}
	}

	// 3. Reorder Pool (reverse 20..1) on 15.6MB jurnal1.pdf
	rev := make([]int, 0, 20)
	for i := 20; i >= 1; i-- {
		rev = append(rev, i)
	}
	start = time.Now()
	reordRes, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
		InitialFiles: []appModel.InputFile{{ID: "j1", Path: jurnalPath}},
		OutputDir:    filepath.Join(tmpDir, "reorder_20_1"),
		Steps: []appModel.WorkflowStep{
			{
				Action:   "reorder",
				OutputId: "reorder_out",
				Reorders: []appModel.MultipleReorderRule{{SourceId: "j1", NewOrder: rev}},
			},
		},
	})
	reordElapsed := time.Since(start)
	if err != nil {
		t.Fatalf("real reorder failed: %v", err)
	}
	t.Logf("jurnal1.pdf Reorder 20-1 elapsed: %v", reordElapsed)
	if reordElapsed >= 5*time.Second {
		t.Fatalf("Reorder Pool exceeded 5s limit: %v", reordElapsed)
	}
	if n, err := api.PageCountFile(reordRes.Files[0]); err != nil || n != 20 {
		t.Fatalf("expected 20 pages in reorder_out, got %d (err=%v)", n, err)
	}

	// 4. Merge Pool across file1 + file2 + file3 + jurnal1 (~47 MB)
	if _, err := os.Stat(file1Path); err == nil {
		if _, err := os.Stat(file2Path); err == nil {
			if _, err := os.Stat(file3Path); err == nil {
				start = time.Now()
				_, err := ExecutePdfWorkflowDetailed(appModel.PdfWorkflowRequest{
					InitialFiles: []appModel.InputFile{
						{ID: "f1", Path: file1Path},
						{ID: "f2", Path: file2Path},
						{ID: "f3", Path: file3Path},
						{ID: "j1", Path: jurnalPath},
					},
					OutputDir: filepath.Join(tmpDir, "merge_47mb"),
					Steps: []appModel.WorkflowStep{
						{
							Action:   "merge",
							OutputId: "merge_out",
							InputIds: []string{"f1", "f2", "f3", "j1"},
						},
					},
				})
				mergeElapsed := time.Since(start)
				if err != nil {
					t.Fatalf("real 47MB merge failed: %v", err)
				}
				t.Logf("4-file 47MB Merge elapsed: %v", mergeElapsed)
				if mergeElapsed >= 5*time.Second {
					t.Fatalf("Merge Pool 47MB exceeded 5s limit: %v", mergeElapsed)
				}
			}
		}
	}
}
