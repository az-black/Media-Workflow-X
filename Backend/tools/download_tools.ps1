# =============================================================================
# Script Otomatisasi Download & Setup External Tools untuk Backend
# Mengunduh QPDF dan Real-ESRGAN NCNN Vulkan Portable secara otomatis
# =============================================================================

[CmdletBinding()]
param (
    [switch]$SkipQPDF,
    [switch]$SkipRealESRGAN
)

$ErrorActionPreference = "Stop"

# Tentukan path direktori
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BackendRoot = Split-Path -Parent $ScriptDir
$ToolsDir = Join-Path $BackendRoot "tools"
$TempDir = Join-Path $env:TEMP "backend_tools_setup"

if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   OTOMATISASI SETUP EXTERNAL TOOLS (BACKEND)        " -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "Target Directory : $ToolsDir" -ForegroundColor Gray
Write-Host ""

# -----------------------------------------------------------------------------
# 1. SETUP FOLDER STRUKTUR
# -----------------------------------------------------------------------------
$DirsToCreate = @(
    (Join-Path $ToolsDir "qpdf\bin"),
    (Join-Path $ToolsDir "realesrgan\models"),
    (Join-Path $ToolsDir "pdf_compressor\build")
)

foreach ($dir in $DirsToCreate) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "[OK] Dibuat direktori: $dir" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# 2. DOWNLOAD & SETUP QPDF (Windows x64 MSVC)
# -----------------------------------------------------------------------------
$QpdfExeTarget = Join-Path $ToolsDir "qpdf\bin\qpdf.exe"

if ($SkipQPDF) {
    Write-Host "[SKIP] Melewati unduhan QPDF sesuai parameter." -ForegroundColor Yellow
} elseif (Test-Path $QpdfExeTarget) {
    Write-Host "[OK] QPDF sudah terpasang di: $QpdfExeTarget" -ForegroundColor Green
} else {
    Write-Host "--> [1/2] Mengunduh QPDF v11.9.1 (Windows x64)..." -ForegroundColor Yellow
    $QpdfUrl = "https://github.com/qpdf/qpdf/releases/download/v11.9.1/qpdf-11.9.1-msvc64.zip"
    $QpdfZip = Join-Path $TempDir "qpdf.zip"
    $QpdfExtractTemp = Join-Path $TempDir "qpdf_extracted"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "    Download dari: $QpdfUrl" -ForegroundColor Gray
        Invoke-WebRequest -Uri $QpdfUrl -OutFile $QpdfZip -UseBasicParsing

        Write-Host "    Mengekstrak paket QPDF..." -ForegroundColor Gray
        Expand-Archive -Path $QpdfZip -DestinationPath $QpdfExtractTemp -Force

        # Cari folder 'bin' di dalam hasil ekstrak
        $ExtractedBin = Get-ChildItem -Path $QpdfExtractTemp -Recurse -Directory | Where-Object { $_.Name -eq "bin" } | Select-Object -First 1

        if ($ExtractedBin) {
            $TargetBin = Join-Path $ToolsDir "qpdf\bin"
            Copy-Item -Path "$($ExtractedBin.FullName)\*" -Destination $TargetBin -Recurse -Force
            Write-Host "[BERHASIL] QPDF berhasil dipasang ke: $TargetBin" -ForegroundColor Green
        } else {
            Write-Warning "Folder 'bin' tidak ditemukan dalam arsip QPDF."
        }
    } catch {
        Write-Host "[GAGAL] Gagal mengunduh QPDF: $_" -ForegroundColor Red
        Write-Host "        Silakan unduh manual dari: https://github.com/qpdf/qpdf/releases" -ForegroundColor Gray
    } finally {
        if (Test-Path $QpdfZip) { Remove-Item $QpdfZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $QpdfExtractTemp) { Remove-Item $QpdfExtractTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ""

# -----------------------------------------------------------------------------
# 3. DOWNLOAD & SETUP REAL-ESRGAN (Portable NCNN Vulkan + Models)
# -----------------------------------------------------------------------------
$RealEsrganExeTarget = Join-Path $ToolsDir "realesrgan\realesrgan-ncnn-vulkan.exe"
$RealEsrganDir = Join-Path $ToolsDir "realesrgan"

if ($SkipRealESRGAN) {
    Write-Host "[SKIP] Melewati unduhan Real-ESRGAN sesuai parameter." -ForegroundColor Yellow
} elseif (Test-Path $RealEsrganExeTarget) {
    Write-Host "[OK] Real-ESRGAN sudah terpasang di: $RealEsrganExeTarget" -ForegroundColor Green
} else {
    Write-Host "--> [2/2] Mengunduh Real-ESRGAN Portable NCNN Vulkan v0.2.5.0..." -ForegroundColor Yellow
    $EsrganUrl = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip"
    $EsrganZip = Join-Path $TempDir "realesrgan.zip"
    $EsrganExtractTemp = Join-Path $TempDir "realesrgan_extracted"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "    Download dari: $EsrganUrl" -ForegroundColor Gray
        Invoke-WebRequest -Uri $EsrganUrl -OutFile $EsrganZip -UseBasicParsing

        Write-Host "    Mengekstrak binary & model AI Real-ESRGAN..." -ForegroundColor Gray
        Expand-Archive -Path $EsrganZip -DestinationPath $EsrganExtractTemp -Force

        # Salin semua isi ekstrak ke tools/realesrgan
        Get-ChildItem -Path $EsrganExtractTemp -Recurse | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
            $Relative = $_.FullName.Substring($EsrganExtractTemp.Length).TrimStart('\', '/')
            # Abaikan level folder root jika ada di dalam zip
            $Parts = $Relative.Split('\')
            if ($Parts.Length -gt 1 -and $Parts[0] -like "*realesrgan*") {
                $DestinationRel = ($Parts[1..($Parts.Length - 1)]) -join '\'
            } else {
                $DestinationRel = $Relative
            }

            $DestFile = Join-Path $RealEsrganDir $DestinationRel
            $DestParent = Split-Path -Parent $DestFile
            if (-not (Test-Path $DestParent)) {
                New-Item -ItemType Directory -Path $DestParent -Force | Out-Null
            }
            Copy-Item -Path $_.FullName -Destination $DestFile -Force
        }

        Write-Host "[BERHASIL] Real-ESRGAN dan model AI berhasil dipasang ke: $RealEsrganDir" -ForegroundColor Green
    } catch {
        Write-Host "[GAGAL] Gagal mengunduh Real-ESRGAN: $_" -ForegroundColor Red
        Write-Host "        Silakan unduh manual dari: https://github.com/xinntao/Real-ESRGAN/releases" -ForegroundColor Gray
    } finally {
        if (Test-Path $EsrganZip) { Remove-Item $EsrganZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $EsrganExtractTemp) { Remove-Item $EsrganExtractTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ""

# -----------------------------------------------------------------------------
# 4. STATUS CEK PDF COMPRESSOR NATIVE (C++)
# -----------------------------------------------------------------------------
$CppEngineTarget = Join-Path $ToolsDir "pdf_compressor\build\pdf_compressor.exe"

Write-Host "--> Status Mesin C++ Native (pdf_compressor.exe):" -ForegroundColor Yellow
if (Test-Path $CppEngineTarget) {
    Write-Host "    [OK] pdf_compressor.exe siap digunakan di: $CppEngineTarget" -ForegroundColor Green
} else {
    Write-Host "    [PERHATIAN] pdf_compressor.exe belum ditemukan di $CppEngineTarget" -ForegroundColor Yellow
    Write-Host "    Untuk mengompilasi modul ini dari source code (compress.cpp):" -ForegroundColor Cyan
    Write-Host "      1. Install vcpkg: git clone https://github.com/microsoft/vcpkg C:\vcpkg" -ForegroundColor Gray
    Write-Host "      2. Install dependencies: C:\vcpkg\vcpkg.exe install qpdf:x64-windows opencv4:x64-windows" -ForegroundColor Gray
    Write-Host "      3. Build dengan CMake:" -ForegroundColor Gray
    Write-Host "         cd tools\pdf_compressor" -ForegroundColor Gray
    Write-Host "         cmake -B build -S ." -ForegroundColor Gray
    Write-Host "         cmake --build build --config Release" -ForegroundColor Gray
    Write-Host "      (Lihat petunjuk detail di tools/pdf_compressor/README.md)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "   SETUP TOOLS SELESAI                               " -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

