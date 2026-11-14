# =============================================================================
# Media Workflow X - All-in-One Setup & Tool Downloader
# Mengunduh dependensi biner eksternal (QPDF, Real-ESRGAN AI), membangun
# backend Go, menyinkronkan runtime tools ke frontend desktop, dan menyiapkan
# lingkungan pengembangan secara otomatis.
# =============================================================================

[CmdletBinding()]
param (
    [switch]$SkipQPDF,
    [switch]$SkipRealESRGAN,
    [switch]$SkipBackendBuild,
    [switch]$Force
)

$ErrorActionPreference = "Continue"

$RootDir = $PSScriptRoot
$BackendDir = Join-Path $RootDir "Backend"
$BackendToolsDir = Join-Path $BackendDir "tools"
$FrontendDir = Join-Path $RootDir "frontend_desktop"
$FrontendEngineDir = Join-Path $FrontendDir "assets\engine"
$TempDir = Join-Path $env:TEMP "media_workflow_x_setup"

if (-not (Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

function Write-Header {
    param ([string]$Text)
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "   $Text" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
}

function Write-Step {
    param ([string]$Step, [string]$Title)
    Write-Host "`n[$Step] $Title" -ForegroundColor Yellow
}

function Write-Success {
    param ([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Info {
    param ([string]$Text)
    Write-Host "  [INFO] $Text" -ForegroundColor Gray
}

function Write-Warn {
    param ([string]$Text)
    Write-Host "  [PERHATIAN] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param ([string]$Text)
    Write-Host "  [GAGAL] $Text" -ForegroundColor Red
}

Write-Header "MEDIA WORKFLOW X - OTOMATISASI SETUP & DOWNLOAD TOOLS"
Write-Info "Direktori Utama : $RootDir"
Write-Info "Temp Direktori   : $TempDir"

# -----------------------------------------------------------------------------
# 1. Menyiapkan Struktur Direktori
# -----------------------------------------------------------------------------
Write-Step "1/5" "Memverifikasi struktur direktori penyimpanan..."

$Dirs = @(
    (Join-Path $BackendToolsDir "qpdf\bin"),
    (Join-Path $BackendToolsDir "realesrgan\models"),
    (Join-Path $BackendToolsDir "pdf_compressor\build"),
    (Join-Path $BackendDir "dist\tools\pdf_compressor\build"),
    (Join-Path $FrontendEngineDir "tools\qpdf\bin"),
    (Join-Path $FrontendEngineDir "tools\realesrgan\models"),
    (Join-Path $FrontendEngineDir "tools\pdf_compressor")
)

foreach ($dir in $Dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}
Write-Success "Struktur folder tools siap."

# -----------------------------------------------------------------------------
# 2. Download & Setup QPDF (Windows x64 MSVC)
# -----------------------------------------------------------------------------
Write-Step "2/5" "Memeriksa QPDF (PDF Stream Optimizer & Linearizer)..."
$QpdfExeBackend = Join-Path $BackendToolsDir "qpdf\bin\qpdf.exe"
$QpdfExeFrontend = Join-Path $FrontendEngineDir "tools\qpdf\bin\qpdf.exe"

if ($SkipQPDF) {
    Write-Warn "QPDF dilewati sesuai parameter -SkipQPDF."
} elseif ((Test-Path $QpdfExeBackend) -and -not $Force) {
    Write-Success "QPDF sudah terpasang di: $QpdfExeBackend"
} else {
    Write-Info "Mengunduh QPDF v11.9.1 (Windows MSVC 64-bit)..."
    $QpdfUrl = "https://github.com/qpdf/qpdf/releases/download/v11.9.1/qpdf-11.9.1-msvc64.zip"
    $QpdfZip = Join-Path $TempDir "qpdf.zip"
    $QpdfExtract = Join-Path $TempDir "qpdf_extracted"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Info "URL: $QpdfUrl"
        Invoke-WebRequest -Uri $QpdfUrl -OutFile $QpdfZip -UseBasicParsing

        Write-Info "Mengekstrak paket QPDF..."
        if (Test-Path $QpdfExtract) { Remove-Item $QpdfExtract -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -Path $QpdfZip -DestinationPath $QpdfExtract -Force

        $ExtractedBin = Get-ChildItem -Path $QpdfExtract -Recurse -Directory | Where-Object { $_.Name -eq "bin" } | Select-Object -First 1

        if ($ExtractedBin) {
            $TargetBin = Join-Path $BackendToolsDir "qpdf\bin"
            Copy-Item -Path "$($ExtractedBin.FullName)\*" -Destination $TargetBin -Recurse -Force
            Write-Success "QPDF berhasil dipasang ke: $TargetBin"
        } else {
            Write-Warn "Folder 'bin' tidak ditemukan di dalam paket QPDF yang diekstrak."
        }
    } catch {
        Write-Fail "Gagal mengunduh QPDF secara otomatis: $_"
        Write-Info "Anda dapat mengunduh manual dari https://github.com/qpdf/qpdf/releases dan letakkan di Backend\tools\qpdf\bin"
    } finally {
        if (Test-Path $QpdfZip) { Remove-Item $QpdfZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $QpdfExtract) { Remove-Item $QpdfExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Sinkronkan QPDF ke Frontend assets/engine
if (Test-Path $QpdfExeBackend) {
    Copy-Item -Path (Join-Path $BackendToolsDir "qpdf\bin\*") -Destination (Join-Path $FrontendEngineDir "tools\qpdf\bin") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Success "QPDF disinkronkan ke frontend assets/engine."
}

# -----------------------------------------------------------------------------
# 3. Download & Setup Real-ESRGAN (NCNN Vulkan Portable AI)
# -----------------------------------------------------------------------------
Write-Step "3/5" "Memeriksa Real-ESRGAN AI Super-Resolution Portable..."
$EsrganExeBackend = Join-Path $BackendToolsDir "realesrgan\realesrgan-ncnn-vulkan.exe"
$EsrganDir = Join-Path $BackendToolsDir "realesrgan"

if ($SkipRealESRGAN) {
    Write-Warn "Real-ESRGAN dilewati sesuai parameter -SkipRealESRGAN."
} elseif ((Test-Path $EsrganExeBackend) -and -not $Force) {
    Write-Success "Real-ESRGAN sudah terpasang di: $EsrganExeBackend"
} else {
    Write-Info "Mengunduh Real-ESRGAN NCNN Vulkan v0.2.5.0 Portable..."
    $EsrganUrl = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip"
    $EsrganZip = Join-Path $TempDir "realesrgan.zip"
    $EsrganExtract = Join-Path $TempDir "realesrgan_extracted"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Info "URL: $EsrganUrl"
        Invoke-WebRequest -Uri $EsrganUrl -OutFile $EsrganZip -UseBasicParsing

        Write-Info "Mengekstrak paket & bobot model AI Real-ESRGAN..."
        if (Test-Path $EsrganExtract) { Remove-Item $EsrganExtract -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -Path $EsrganZip -DestinationPath $EsrganExtract -Force

        Get-ChildItem -Path $EsrganExtract -Recurse | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
            $Relative = $_.FullName.Substring($EsrganExtract.Length).TrimStart('\', '/')
            $Parts = $Relative.Split('\')
            if ($Parts.Length -gt 1 -and $Parts[0] -like "*realesrgan*") {
                $DestinationRel = ($Parts[1..($Parts.Length - 1)]) -join '\'
            } else {
                $DestinationRel = $Relative
            }

            $DestFile = Join-Path $EsrganDir $DestinationRel
            $DestParent = Split-Path -Parent $DestFile
            if (-not (Test-Path $DestParent)) {
                New-Item -ItemType Directory -Path $DestParent -Force | Out-Null
            }
            Copy-Item -Path $_.FullName -Destination $DestFile -Force
        }

        Write-Success "Real-ESRGAN Portable AI & model bobot berhasil dipasang."
    } catch {
        Write-Fail "Gagal mengunduh Real-ESRGAN secara otomatis: $_"
        Write-Info "Unduh manual dari https://github.com/xinntao/Real-ESRGAN/releases dan letakkan di Backend\tools\realesrgan"
    } finally {
        if (Test-Path $EsrganZip) { Remove-Item $EsrganZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $EsrganExtract) { Remove-Item $EsrganExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Sinkronkan Real-ESRGAN ke Frontend assets/engine
if (Test-Path $EsrganExeBackend) {
    Copy-Item -Path "$EsrganDir\*" -Destination (Join-Path $FrontendEngineDir "tools\realesrgan") -Recurse -Force -ErrorAction SilentlyContinue
    Write-Success "Real-ESRGAN disinkronkan ke frontend assets/engine."
}

# -----------------------------------------------------------------------------
# 4. Verifikasi C++ Native Engine (pdf_compressor.exe)
# -----------------------------------------------------------------------------
Write-Step "4/5" "Memeriksa status modul kompresi C++ Native (pdf_compressor.exe)..."
$CppExeCandidates = @(
    (Join-Path $BackendToolsDir "pdf_compressor\build\Release\pdf_compressor.exe"),
    (Join-Path $BackendToolsDir "pdf_compressor\build\pdf_compressor.exe"),
    (Join-Path $BackendToolsDir "pdf_compressor\build_compressor\Release\pdf_compressor.exe"),
    (Join-Path $FrontendEngineDir "tools\pdf_compressor\pdf_compressor.exe")
)

$CppExeFound = $null
foreach ($cand in $CppExeCandidates) {
    if (Test-Path $cand) {
        $CppExeFound = $cand
        break
    }
}

if ($CppExeFound) {
    Write-Success "pdf_compressor.exe ditemukan di: $CppExeFound"
    
    # Salin ke Backend/dist dan frontend assets jika belum ada
    $CppDestFrontend = Join-Path $FrontendEngineDir "tools\pdf_compressor"
    $CppDestBackendDist = Join-Path $BackendDir "dist\tools\pdf_compressor\build"
    
    Copy-Item -Path $CppExeFound -Destination (Join-Path $CppDestFrontend "pdf_compressor.exe") -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $CppExeFound -Destination (Join-Path $CppDestBackendDist "pdf_compressor.exe") -Force -ErrorAction SilentlyContinue
    
    # Salin juga runtime DLL di sekitar exe jika ada
    $CppExeParent = Split-Path -Parent $CppExeFound
    Get-ChildItem -Path $CppExeParent -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $CppDestFrontend -Force -ErrorAction SilentlyContinue
        Copy-Item -Path $_.FullName -Destination $CppDestBackendDist -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Warn "pdf_compressor.exe belum dikompilasi."
    Write-Info "Untuk mengompilasi dari C++ source code (menggunakan CMake & vcpkg):"
    Write-Info "  1. vcpkg install qpdf:x64-windows opencv4:x64-windows"
    Write-Info "  2. cd Backend\tools\pdf_compressor"
    Write-Info "  3. cmake -B build -S . && cmake --build build --config Release"
    Write-Info "Lihat panduan lengkap di: Backend/tools/pdf_compressor/README.md"
}

# -----------------------------------------------------------------------------
# 5. Build Backend Go & Konfigurasi Flutter
# -----------------------------------------------------------------------------
Write-Step "5/5" "Membangun Backend Go & Memverifikasi Flutter..."

$GoInstalled = $null
try {
    $GoInstalled = & go version 2>$null
} catch {}

if ($SkipBackendBuild) {
    Write-Warn "Build backend Go dilewati sesuai parameter -SkipBackendBuild."
} elseif ($GoInstalled) {
    Write-Success "Go terdeteksi: $GoInstalled"
    Write-Info "Mengunduh dependensi modul Go (go mod download)..."
    Push-Location $BackendDir
    try {
        & go mod download
        Write-Info "Mengompilasi Go backend (dist/smart_compress_backend.exe)..."
        $DistDir = Join-Path $BackendDir "dist"
        if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir -Force | Out-Null }
        
        $BackendBinary = Join-Path $DistDir "smart_compress_backend.exe"
        & go build -o $BackendBinary main.go
        
        if ($LASTEXITCODE -eq 0 -and (Test-Path $BackendBinary)) {
            Write-Success "Backend Go berhasil dikompilasi: $BackendBinary"
            Copy-Item -Path $BackendBinary -Destination (Join-Path $FrontendEngineDir "smart_compress_backend.exe") -Force
            Write-Success "Binary backend disalin ke frontend assets/engine/."
        } else {
            Write-Fail "Kompilasi backend Go menghasilkan kode keluar: $LASTEXITCODE"
        }
    } catch {
        Write-Fail "Terjadi error saat build Go: $_"
    } finally {
        Pop-Location
    }
} else {
    Write-Warn "Go (Golang) tidak ditemukan di PATH sistem. Unduh di https://go.dev/dl/ untuk mengompilasi backend."
}

# Flutter Dependency Check
$FlutterInstalled = $null
try {
    $FlutterInstalled = & flutter --version 2>$null | Select-Object -First 1
} catch {}

if ($FlutterInstalled) {
    Write-Success "Flutter terdeteksi: $FlutterInstalled"
    Write-Info "Menjalankan 'flutter pub get' di frontend_desktop..."
    Push-Location $FrontendDir
    try {
        & flutter pub get
        Write-Success "Dependensi Flutter berhasil dimuat."
    } catch {
        Write-Warn "Gagal menjalankan flutter pub get: $_"
    } finally {
        Pop-Location
    }
} else {
    Write-Info "Flutter CLI tidak ditemukan di PATH. Jika Anda ingin memodifikasi frontend, pasang Flutter dari https://flutter.dev"
}

# -----------------------------------------------------------------------------
# RINGKASAN STATUS KELENGKAPAN SISTEM
# -----------------------------------------------------------------------------
Write-Header "RINGKASAN STATUS SISTEM MEDIA WORKFLOW X"

$CheckBackendExe = Test-Path (Join-Path $FrontendEngineDir "smart_compress_backend.exe")
$CheckQpdf       = Test-Path (Join-Path $FrontendEngineDir "tools\qpdf\bin\qpdf.exe")
$CheckEsrgan     = Test-Path (Join-Path $FrontendEngineDir "tools\realesrgan\realesrgan-ncnn-vulkan.exe")
$CheckCpp        = Test-Path (Join-Path $FrontendEngineDir "tools\pdf_compressor\pdf_compressor.exe")

$FormatStatus = {
    param ($Condition, $Label)
    if ($Condition) {
        Write-Host "  [READY]       " -ForegroundColor Green -NoNewline
    } else {
        Write-Host "  [MISSING]     " -ForegroundColor Yellow -NoNewline
    }
    Write-Host $Label
}

& $FormatStatus $CheckBackendExe "Backend Engine (smart_compress_backend.exe)"
& $FormatStatus $CheckQpdf       "QPDF Stream Optimizer (qpdf.exe)"
& $FormatStatus $CheckEsrgan     "Real-ESRGAN AI Super-Resolution Portable"
& $FormatStatus $CheckCpp        "C++ Native PDF Quality Compressor (pdf_compressor.exe)"

Write-Host ""
if ($CheckBackendExe -and $CheckQpdf -and $CheckEsrgan) {
    Write-Host "SELURUH TOOLS UTAMA SUDAH LENGKAP & SIAP DIJALANKAN!" -ForegroundColor Green
    Write-Host "Untuk menjalankan aplikasi:" -ForegroundColor Cyan
    Write-Host "  1. Mode GUI Desktop  : Masuk ke folder 'frontend_desktop' lalu jalankan 'flutter run -d windows'" -ForegroundColor Gray
    Write-Host "  2. Mode Standalone   : Bangun installer menggunakan installer\MediaWorkflowX_Setup.iss" -ForegroundColor Gray
    Write-Host "  3. Mode Server REST  : Jalankan 'go run main.go' di folder Backend" -ForegroundColor Gray
} else {
    Write-Host "Beberapa komponen opsional masih belum lengkap (lihat status di atas)." -ForegroundColor Yellow
}
Write-Host "==================================================================" -ForegroundColor Cyan
