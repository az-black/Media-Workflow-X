package service

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	wordMutex     sync.Mutex
	wordAvailMu   sync.Mutex
	wordAvailable *bool

	libreMutex sync.Mutex
)

// WarmupDocEngine memanaskan / memverifikasi engine dokumen (word / libreoffice) saat startup aplikasi
func WarmupDocEngine(engineChoice string) error {
	norm := strings.ToLower(strings.TrimSpace(engineChoice))
	if norm == "libreoffice" {
		exe := findLibreOfficeExe()
		if _, err := os.Stat(exe); err != nil && exe == "soffice" {
			if _, lookErr := exec.LookPath("soffice"); lookErr != nil {
				return fmt.Errorf("LibreOffice soffice.exe tidak ditemukan di sistem")
			}
		}
		return nil
	}

	// Default: Microsoft Word
	if !isMSWordAvailable() {
		return fmt.Errorf("Microsoft Word tidak terdeteksi di sistem")
	}

	// Pastikan opsi registry Office disiapkan di awal
	script := `$ErrorActionPreference = 'SilentlyContinue'
foreach ($ver in @('16.0', '15.0', '14.0')) {
    $optPath = 'HKCU:\Software\Microsoft\Office\' + $ver + '\Word\Options'
    if (-not (Test-Path $optPath)) { try { New-Item -Path $optPath -Force | Out-Null } catch {} }
    try {
        Set-ItemProperty -Path $optPath -Name 'DisablePromptForPDF' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $optPath -Name 'NoPromptForPDF' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    } catch {}
}`
	cmd := exec.Command("powershell", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-Command", script)
	_ = cmd.Run()
	return nil
}

// ConvertDocxToPdf menerima parameter `engineChoice` ("word", "libreoffice", atau "")
func ConvertDocxToPdf(inputPath string, outputPath string, engineChoice string) error {
	absInput, err := filepath.Abs(inputPath)
	if err != nil {
		return fmt.Errorf("gagal mendapatkan absolute path input: %w", err)
	}
	absOutput, err := filepath.Abs(outputPath)
	if err != nil {
		return fmt.Errorf("gagal mendapatkan absolute path output: %w", err)
	}

	if _, err := os.Stat(absInput); os.IsNotExist(err) {
		return fmt.Errorf("file input tidak ditemukan: %s", absInput)
	}

	outputDir := filepath.Dir(absOutput)
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	engineChoice = strings.ToLower(strings.TrimSpace(engineChoice))

	// SKENARIO 1: Pengguna memaksa menggunakan LibreOffice
	if engineChoice == "libreoffice" {
		fmt.Println("[INFO] Engine dipilih manual: LibreOffice...")
		return runLibreOfficeConversion(absInput, absOutput, outputDir)
	}

	// SKENARIO 2: Pengguna memaksa menggunakan Microsoft Word
	if engineChoice == "word" {
		if !isMSWordAvailable() {
			return fmt.Errorf("microsoft word dipilih, tetapi tidak tersedia di sistem")
		}
		fmt.Println("[INFO] Engine dipilih manual: Microsoft Word...")
		return convertWithMSWordCOM(absInput, absOutput)
	}

	// SKENARIO 3: Auto / Hybrid (Utamakan MS Word untuk akurasi 100%)
	if isMSWordAvailable() {
		fmt.Println("[INFO] Auto Mode: Menggunakan Microsoft Word (Primary)...")
		err := convertWithMSWordCOM(absInput, absOutput)
		if err == nil {
			if _, statErr := os.Stat(absOutput); statErr == nil {
				return nil
			}
		}
		fmt.Printf("[WARN] Word gagal (%v). Beralih ke LibreOffice Fallback...\n", err)
	} else {
		fmt.Println("[INFO] Microsoft Word tidak terdeteksi. Menggunakan LibreOffice...")
	}

	return runLibreOfficeConversion(absInput, absOutput, outputDir)
}

func escapePowerShellString(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

func waitForFileReady(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if fi, err := os.Stat(path); err == nil && fi.Size() > 0 {
			f, err := os.OpenFile(path, os.O_RDWR, 0666)
			if err == nil {
				_ = f.Close()
				return nil
			}
		}
		time.Sleep(80 * time.Millisecond)
	}
	return nil
}

func convertDocxToPdfDirectWordCOM(absInput, absOutput string) error {
	escIn := escapePowerShellString(absInput)
	escOut := escapePowerShellString(absOutput)
	script := fmt.Sprintf(`$ErrorActionPreference = 'Stop'
foreach ($ver in @('16.0', '15.0', '14.0')) {
    $optPath = 'HKCU:\Software\Microsoft\Office\' + $ver + '\Word\Options'
    if (-not (Test-Path $optPath)) { try { New-Item -Path $optPath -Force | Out-Null } catch {} }
    try {
        Set-ItemProperty -Path $optPath -Name 'DisablePromptForPDF' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $optPath -Name 'NoPromptForPDF' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    } catch {}
}
$existingPids = @(Get-Process -Name WINWORD -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$word = $null
$doc = $null
$newProc = $null
try {
    $word = New-Object -ComObject Word.Application
    $newProc = Get-Process -Name WINWORD -ErrorAction SilentlyContinue | Where-Object { $existingPids -notcontains $_.Id } | Select-Object -First 1
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $word.ScreenUpdating = $true
    $word.Options.BackgroundSave = $false
    $word.Options.SavePropertiesPrompt = $false
    $word.Options.SaveNormalPrompt = $false
    $doc = $word.Documents.Open('%s', $false, $true, $false)
    if ($null -eq $doc -and $word.Documents.Count -gt 0) { $doc = $word.ActiveDocument }
    if ($null -eq $doc) { throw 'Dokumen tidak dapat dibuka oleh Microsoft Word' }
    $doc.ExportAsFixedFormat('%s', 17, $false, 0, 0, 1, 1, 0, $true, $true, 0, $true, $true, $false)
} finally {
    if ($null -ne $doc) { 
        try { $doc.Close($false) } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($doc) | Out-Null } catch {}
        $doc = $null
    }
    if ($null -ne $word) { 
        try { $word.Quit() } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null } catch {}
        $word = $null
    }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    if ($null -ne $newProc) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Get-Process -Id $newProc.Id -ErrorAction SilentlyContinue) -and ($sw.ElapsedMilliseconds -lt 3500)) {
            Start-Sleep -Milliseconds 50
        }
        if (Get-Process -Id $newProc.Id -ErrorAction SilentlyContinue) {
            Stop-Process -Id $newProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}`, escIn, escOut)

	cmd := exec.Command("powershell", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-Command", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("direct word com export error: %v (output: %s)", err, string(out))
	}
	return nil
}

func convertWithMSWordCOM(inputPath, outputPath string) error {
	wordMutex.Lock()
	defer wordMutex.Unlock()

	if err := convertDocxToPdfDirectWordCOM(inputPath, outputPath); err != nil {
		return err
	}
	_ = waitForFileReady(outputPath, 4*time.Second)
	if fi, statErr := os.Stat(outputPath); statErr != nil || fi.Size() == 0 {
		return fmt.Errorf("file output PDF tidak ditemukan atau kosong: %s", outputPath)
	}
	return nil
}

func buildLibreOfficeProfileArg() (string, string) {
	profDir, err := os.MkdirTemp("", "mwx_lo_prof_*")
	if err != nil {
		return "", ""
	}
	uri := "file:///" + strings.ReplaceAll(filepath.ToSlash(profDir), " ", "%20")
	return "-env:UserInstallation=" + uri, profDir
}

func runLibreOfficeConversion(absInput, absOutput, outputDir string) error {
	libreMutex.Lock()
	defer libreMutex.Unlock()

	exeToUse := findLibreOfficeExe()
	pdfFilterData := "{\"SelectPdfVersion\":{\"type\":\"long\",\"value\":\"0\"}}"

	args := []string{
		"--headless",
		"--invisible",
		"--nodefault",
		"--nolockcheck",
		"--nologo",
		"--norestore",
	}
	if profArg, profDir := buildLibreOfficeProfileArg(); profArg != "" {
		defer os.RemoveAll(profDir)
		args = append(args, profArg)
	}
	args = append(args,
		"--convert-to", fmt.Sprintf("pdf:writer_pdf_Export:%s", pdfFilterData),
		absInput,
		"--outdir", outputDir,
	)

	cmd := exec.Command(exeToUse, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("libreoffice conversion error: %v (output: %s)", err, string(output))
	}

	return nil
}

// isMSWordAvailable memeriksa instalasi MS Word tanpa overhead cold launch COM WINWORD.EXE.
func isMSWordAvailable() bool {
	wordAvailMu.Lock()
	if wordAvailable != nil {
		v := *wordAvailable
		wordAvailMu.Unlock()
		return v
	}
	wordAvailMu.Unlock()

	pf := os.Getenv("ProgramFiles")
	if pf == "" {
		pf = `C:\Program Files`
	}
	pfx86 := os.Getenv("ProgramFiles(x86)")
	if pfx86 == "" {
		pfx86 = `C:\Program Files (x86)`
	}

	candidates := []string{
		filepath.Join(pf, "Microsoft Office", "root", "Office16", "WINWORD.EXE"),
		filepath.Join(pfx86, "Microsoft Office", "root", "Office16", "WINWORD.EXE"),
		filepath.Join(pf, "Microsoft Office", "Office16", "WINWORD.EXE"),
		filepath.Join(pfx86, "Microsoft Office", "Office16", "WINWORD.EXE"),
		filepath.Join(pf, "Microsoft Office", "Office15", "WINWORD.EXE"),
		filepath.Join(pfx86, "Microsoft Office", "Office15", "WINWORD.EXE"),
	}

	found := false
	for _, p := range candidates {
		if info, err := os.Stat(p); err == nil && !info.IsDir() {
			found = true
			break
		}
	}

	if !found {
		cmd := exec.Command("reg", "query", `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Winword.exe`, "/ve")
		if err := cmd.Run(); err == nil {
			found = true
		}
	}

	wordAvailMu.Lock()
	wordAvailable = &found
	wordAvailMu.Unlock()
	return found
}

func findLibreOfficeExe() string {
	localPortable := filepath.Join("tools", "docx2pdf", "libreoffice", "program", "soffice.exe")
	if _, err := os.Stat(localPortable); err == nil {
		return localPortable
	}

	if path, err := exec.LookPath("soffice"); err == nil {
		return path
	}

	commonPaths := []string{
		`C:\Program Files\LibreOffice\program\soffice.exe`,
		`C:\Program Files (x86)\LibreOffice\program\soffice.exe`,
	}

	for _, p := range commonPaths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}

	return "soffice"
}

// Helper untuk menyalin file secara aman (mencegah error cross-device / file lock di os.Rename)
func copyAndRemoveFile(src, dst string) error {
	input, err := os.Open(src)
	if err != nil {
		return err
	}
	defer input.Close()

	output, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer output.Close()

	if _, err = io.Copy(output, input); err != nil {
		return err
	}

	input.Close()
	return os.Remove(src)
}