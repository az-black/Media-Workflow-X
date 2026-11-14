package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func convertPdfToDocxDirectWordCOM(absInput, absOutput string) error {
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
    try {
        $doc = $word.Documents.Open('%s', $false, $true, $false)
    } catch {
        $doc = $word.Documents.OpenNoRepairDialog('%s', $false, $true, $false)
    }
    if ($null -eq $doc -and $word.Documents.Count -gt 0) { $doc = $word.ActiveDocument }
    if ($null -eq $doc) { throw 'Dokumen PDF tidak dapat dibuka oleh Microsoft Word' }
    try {
        if ($doc.ActiveWindow) {
            $doc.ActiveWindow.View.Type = 3
        }
        $doc.Repaginate()
    } catch {}
    try {
        $doc.SaveAs2('%s', 16)
    } catch {
        $doc.SaveAs('%s', 16)
    }
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
}`, escIn, escIn, escOut, escOut)

	cmd := exec.Command("powershell", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-Command", script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("direct word com save docx error: %v (output: %s)", err, string(out))
	}
	return nil
}

// ConvertPdfToDocx mengonversi PDF ke DOCX menggunakan Microsoft Word COM terisolasi (1-shot)
// yang selalu menutup dokumen, keluar dari Word (Quit), dan membersihkan objek COM agar tidak
// menyisakan proses background yang dapat membekukan tampilan (blank page) saat file dibuka oleh pengguna.
func ConvertPdfToDocx(inputPDF, outputDOCX string) error {
	wordMutex.Lock()
	defer wordMutex.Unlock()

	absInput, err := filepath.Abs(inputPDF)
	if err != nil {
		return fmt.Errorf("gagal mendapatkan path input: %w", err)
	}
	absOutput, err := filepath.Abs(outputDOCX)
	if err != nil {
		return fmt.Errorf("gagal mendapatkan path output: %w", err)
	}

	if _, err := os.Stat(absInput); os.IsNotExist(err) {
		return fmt.Errorf("file input PDF tidak ditemukan: %s", absInput)
	}

	if err := os.MkdirAll(filepath.Dir(absOutput), 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	if err := convertPdfToDocxDirectWordCOM(absInput, absOutput); err != nil {
		return err
	}

	_ = waitForFileReady(absOutput, 4*time.Second)

	if fi, statErr := os.Stat(absOutput); statErr != nil || fi.Size() == 0 {
		return fmt.Errorf("file output DOCX tidak ditemukan atau kosong: %s", absOutput)
	}

	return nil
}

// ConvertPdfToDocxLibreOffice mengonversi PDF ke DOCX menggunakan LibreOffice (Alternatif 100% Headless)
func ConvertPdfToDocxLibreOffice(inputPDF, outputDir string) error {
	absInput, err := filepath.Abs(inputPDF)
	if err != nil {
		return fmt.Errorf("gagal mendapatkan path input: %w", err)
	}

	if _, err := os.Stat(absInput); os.IsNotExist(err) {
		return fmt.Errorf("file input PDF tidak ditemukan: %s", absInput)
	}

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return fmt.Errorf("gagal membuat direktori output: %w", err)
	}

	libreMutex.Lock()
	defer libreMutex.Unlock()

	exeToUse := findLibreOfficeExe()
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
		"--infilter=writer_pdf_import",
		"--convert-to", "docx",
		absInput,
		"--outdir", outputDir,
	)

	cmd := exec.Command(exeToUse, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("libreoffice error: %v (output: %s)", err, string(output))
	}

	return nil
}