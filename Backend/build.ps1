# =============================================================================
# build.ps1 - Skrip Otomatis Build & Bundle Smart Compressor Backend
# Mengompilasi binary Go dan menyinkronkan seluruh runtime tools ke:
# 1. Backend/dist/ (paket standalone server)
# 2. frontend_desktop/assets/engine/ (runtime siap pakai aplikasi desktop)
# =============================================================================

[CmdletBinding()]
param (
    [switch]$SkipToolsSync
)

$ErrorActionPreference = "Stop"

# 1. Tentukan path direktori secara dinamis & konsisten
$BackendDir = $PSScriptRoot
if (-not $BackendDir) {
    $BackendDir = (Get-Item .).FullName
}
$RootDir = Split-Path -Parent $BackendDir
$DistDir = Join-Path $BackendDir "dist"
$ToolsDir = Join-Path $BackendDir "tools"
$FrontendEngineDir = Join-Path $RootDir "frontend_desktop\assets\engine"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   BUILD & BUNDLE ENGINE BACKEND (MEDIA WORKFLOW X)               " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Backend Root    : $BackendDir" -ForegroundColor Gray
Write-Host "Backend Dist    : $DistDir" -ForegroundColor Gray
Write-Host "Frontend Target : $FrontendEngineDir" -ForegroundColor Gray
Write-Host ""

# Pastikan eksekusi berjalan di folder Backend
Push-Location $BackendDir

try {
    # -------------------------------------------------------------------------
    # 2. Pastikan Folder Target Ada
    # -------------------------------------------------------------------------
    $TargetFolders = @(
        $DistDir,
        (Join-Path $DistDir "tools\pdf_compressor\build"),
        $FrontendEngineDir,
        (Join-Path $FrontendEngineDir "tools\pdf_compressor\build"),
        (Join-Path $FrontendEngineDir "tools\qpdf\bin"),
        (Join-Path $FrontendEngineDir "tools\realesrgan\models")
    )
    foreach ($folder in $TargetFolders) {
        if (-not (Test-Path $folder)) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
        }
    }

    # -------------------------------------------------------------------------
    # 3. Cek & Unduh Otomatis External Tools jika Belum Ada
    # -------------------------------------------------------------------------
    $QpdfExe = Join-Path $ToolsDir "qpdf\bin\qpdf.exe"
    $EsrganExe = Join-Path $ToolsDir "realesrgan\realesrgan-ncnn-vulkan.exe"
    $DownloadScript = Join-Path $ToolsDir "download_tools.ps1"

    if ((-not (Test-Path $QpdfExe) -or -not (Test-Path $EsrganExe)) -and (Test-Path $DownloadScript)) {
        Write-Host "--> External tools (QPDF / Real-ESRGAN) belum lengkap." -ForegroundColor Yellow
        Write-Host "    Menjalankan otomatisasi unduhan tools..." -ForegroundColor Cyan
        & powershell.exe -ExecutionPolicy Bypass -File $DownloadScript
    }

    # -------------------------------------------------------------------------
    # 4. Kompilasi Go Backend
    # -------------------------------------------------------------------------
    Write-Host "`n[1/3] Mengompilasi Go Backend (smart_compress_backend.exe)..." -ForegroundColor Yellow
    $BackendExeTarget = Join-Path $DistDir "smart_compress_backend.exe"
    
    go build -o $BackendExeTarget main.go
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $BackendExeTarget)) {
        Write-Host "[ERROR] Kompilasi Go gagal dengan kode keluar: $LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "  [OK] Berhasil di-build ke: $BackendExeTarget" -ForegroundColor Green

    # Salin biner Go langsung ke frontend_desktop/assets/engine
    $FrontendBackendExe = Join-Path $FrontendEngineDir "smart_compress_backend.exe"
    Copy-Item -Path $BackendExeTarget -Destination $FrontendBackendExe -Force
    Write-Host "  [OK] Biner Go disalin ke: $FrontendBackendExe" -ForegroundColor Green

    # -------------------------------------------------------------------------
    # 5. Menyalin & Menyinkronkan External Tools
    # -------------------------------------------------------------------------
    if ($SkipToolsSync) {
        Write-Host "`n[SKIP] Sinkronisasi tools eksternal dilewati." -ForegroundColor Yellow
    } else {
        Write-Host "`n[2/3] Menyinkronkan biner C++ Compressor (pdf_compressor)..." -ForegroundColor Yellow
        
        # Cari file executable C++ (Release / build / build_compressor)
        $CppCandidates = @(
            (Join-Path $ToolsDir "pdf_compressor\build\Release\pdf_compressor.exe"),
            (Join-Path $ToolsDir "pdf_compressor\build\pdf_compressor.exe"),
            (Join-Path $ToolsDir "pdf_compressor\build_compressor\Release\pdf_compressor.exe")
        )
        $CppSourceExe = $null
        foreach ($c in $CppCandidates) {
            if (Test-Path $c) {
                $CppSourceExe = $c
                break
            }
        }

        $DistCppBuild = Join-Path $DistDir "tools\pdf_compressor\build"
        $FrontendCppRoot = Join-Path $FrontendEngineDir "tools\pdf_compressor"
        $FrontendCppBuild = Join-Path $FrontendEngineDir "tools\pdf_compressor\build"

        if ($CppSourceExe) {
            $CppSourceDir = Split-Path -Parent $CppSourceExe
            Write-Host "  [OK] Ditemukan pdf_compressor.exe di: $CppSourceExe" -ForegroundColor Green

            # Salin exe ke dist dan frontend (root & build)
            Copy-Item -Path $CppSourceExe -Destination (Join-Path $DistCppBuild "pdf_compressor.exe") -Force
            Copy-Item -Path $CppSourceExe -Destination (Join-Path $FrontendCppRoot "pdf_compressor.exe") -Force
            Copy-Item -Path $CppSourceExe -Destination (Join-Path $FrontendCppBuild "pdf_compressor.exe") -Force

            # Salin seluruh DLL dependensi C++ (OpenCV & QPDF runtime)
            $DllList = Get-ChildItem -Path $CppSourceDir -Filter "*.dll" -ErrorAction SilentlyContinue
            if (($null -eq $DllList -or $DllList.Count -eq 0) -and (Test-Path (Join-Path $ToolsDir "pdf_compressor\build"))) {
                $DllList = Get-ChildItem -Path (Join-Path $ToolsDir "pdf_compressor\build") -Filter "*.dll" -ErrorAction SilentlyContinue
            }

            if ($DllList) {
                foreach ($dll in $DllList) {
                    Copy-Item -Path $dll.FullName -Destination $DistCppBuild -Force
                    Copy-Item -Path $dll.FullName -Destination $FrontendCppRoot -Force
                    Copy-Item -Path $dll.FullName -Destination $FrontendCppBuild -Force
                }
                Write-Host "  [OK] pdf_compressor.exe beserta $($DllList.Count) runtime DLL disinkronkan." -ForegroundColor Green
            }
        } else {
            Write-Host "  [INFO] pdf_compressor.exe belum dikompilasi (opsional jika menggunakan kompresi Go murni)." -ForegroundColor Gray
        }

        Write-Host "`n[3/3] Menyinkronkan QPDF dan Real-ESRGAN Portable AI..." -ForegroundColor Yellow

        # Sinkronkan QPDF
        $QpdfSrc = Join-Path $ToolsDir "qpdf"
        if (Test-Path (Join-Path $QpdfSrc "bin\qpdf.exe")) {
            Copy-Item -Path $QpdfSrc -Destination (Join-Path $DistDir "tools") -Recurse -Force
            Copy-Item -Path $QpdfSrc -Destination (Join-Path $FrontendEngineDir "tools") -Recurse -Force
            Write-Host "  [OK] QPDF berhasil disinkronkan ke dist/ dan frontend assets/engine." -ForegroundColor Green
        } else {
            Write-Host "  [PERINGATAN] QPDF belum ditemukan di $QpdfSrc." -ForegroundColor Yellow
        }

        # Sinkronkan Real-ESRGAN
        $EsrganSrc = Join-Path $ToolsDir "realesrgan"
        if (Test-Path (Join-Path $EsrganSrc "realesrgan-ncnn-vulkan.exe")) {
            Copy-Item -Path $EsrganSrc -Destination (Join-Path $DistDir "tools") -Recurse -Force
            Copy-Item -Path $EsrganSrc -Destination (Join-Path $FrontendEngineDir "tools") -Recurse -Force
            Write-Host "  [OK] Real-ESRGAN berhasil disinkronkan ke dist/ dan frontend assets/engine." -ForegroundColor Green
        } else {
            Write-Host "  [PERINGATAN] Real-ESRGAN belum ditemukan di $EsrganSrc." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "   SUKSES! BACKEND & SELURUH RUNTIME TOOLS SIAP DIGUNAKAN         " -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "Lokasi runtime frontend : $FrontendEngineDir" -ForegroundColor Cyan
    Write-Host "Aplikasi desktop sekarang otomatis SIAP DIJALANKAN:" -ForegroundColor Cyan
    Write-Host "  cd ..\frontend_desktop" -ForegroundColor Gray
    Write-Host "  flutter run -d windows" -ForegroundColor Gray
    Write-Host "==================================================================" -ForegroundColor Green
} finally {
    Pop-Location
}
