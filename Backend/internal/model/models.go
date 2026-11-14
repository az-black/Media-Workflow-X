package model

type CompressRequest struct {
	TargetKB        int64    `json:"targetKB,omitempty"`
	OutputDir       string   `json:"outputDir"`
	Files           []string `json:"files"`
	TargetFormat    string   `json:"target_format,omitempty"`
	Action          string   `json:"action"`
	Scale           int      `json:"scale,omitempty"`
	Model           string   `json:"model,omitempty"` // <-- Tambahkan baris ini untuk fleksibilitas model AI
	IsTargetPerPage bool     `json:"is_target_per_page,omitempty"`
	CompressionType string   `json:"compression_type,omitempty"`
	Engine          string   `json:"engine,omitempty"`
}

type CompressResponse struct {
	Success          bool     `json:"success"`
	Message          string   `json:"message"`
	Files            []string `json:"files"`
	TargetFormat     string   `json:"target_format,omitempty"`
	TotalFiles       int      `json:"total_files,omitempty"`
	RotationsApplied bool     `json:"rotations_applied,omitempty"`
}

type MergeRequest struct {
	Files     []string `json:"files"`
	OutputDir string   `json:"outputDir"`
}

type SplitRequest struct {
	File      string   `json:"file"`
	Pages     []int    `json:"pages"`
	OutputDir string   `json:"outputDir"`
}

type ReorderRequest struct {
	File      string   `json:"file"`
	NewOrder  []int    `json:"newOrder"`
	OutputDir string   `json:"outputDir"`
}

// =========================================================================
// MODEL PIPELINE WORKFLOW (BERSIH & MODULAR)
// =========================================================================

type InputFile struct {
	ID   string `json:"id"`   // ID file awal, misal: "docA", "docB"
	Path string `json:"path"` // Path absolut file PDF
}

// Rule untuk aksi multiple file
type MultipleSplitRule struct {
	SourceId string `json:"sourceId"` // File ID sumber untuk slot ini
	Pages    []int  `json:"pages"`    // Halaman yang diambil
}

type MultipleReorderRule struct {
	SourceId string `json:"sourceId"` // File ID sumber untuk slot ini
	NewOrder []int  `json:"newOrder"` // Urutan halaman baru
}

type WorkflowStep struct {
	Action       string                `json:"action"`             // "split_single", "split_multiple", "reorder_single", "reorder_multiple", "merge", "split_separated"
	TargetId     string                `json:"targetId,omitempty"` // Digunakan untuk mode Single (1 file acuan)
	InputIds     []string              `json:"inputIds,omitempty"` // Digunakan untuk aksi "merge" atau menyambung pool sebelumnya
	OutputId     string                `json:"outputId"`           // ID hasil keluaran step (bisa dipakai sebagai input step berikutnya)

	// Parameter untuk Split / Reorder Single (Array slot halaman)
	Ranges       [][]int               `json:"ranges,omitempty"`   // Untuk split_single (banyak rentang halaman slot)
	NewOrder     []int                 `json:"newOrder,omitempty"` // Untuk reorder_single (1 urutan halaman utuh)

	// Parameter untuk Split / Reorder Multiple (Beda-beda file per slot)
	Splits       []MultipleSplitRule   `json:"splits,omitempty"`   // Untuk split_multiple
	Reorders     []MultipleReorderRule `json:"reorders,omitempty"` // Untuk reorder_multiple

	// Parameter khusus jika ingin memecah file jadi file-file terpisah fisik (tanpa auto-merge)
	Pages        []int                 `json:"pages,omitempty"`    // Untuk split_separated

	// Opsional: rotasi relatif searah jarum jam (+90/+180/+270) keyed by nomor halaman output 1-based
	Rotations    map[int]int           `json:"rotations,omitempty"`
}

type PdfWorkflowRequest struct {
	InitialFiles []InputFile    `json:"initialFiles"`
	OutputDir    string         `json:"outputDir"`
	Steps        []WorkflowStep `json:"steps"`
}