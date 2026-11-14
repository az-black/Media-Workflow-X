# build.ps1 - Skrip Otomatis Build & Bundle Smart Compressor Backend

Write-Host "1. Memulai proses build Go backend..." -ForegroundColor Cyan
go build -o dist/smart_compress_backend.exe main.go
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build Go gagal!" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "2. Menyiapkan struktur folder tools di dalam dist..." -ForegroundColor Cyan
if (!(Test-Path "dist/tools/pdf_compressor/build")) {
    New-Item -ItemType Directory -Force -Path "dist/tools/pdf_compressor/build" | Out-Null
}

# Salin isi dari folder build C++ secara presisi ke target dist
Write-Host "Menyalin biner C++ Compressor..." -ForegroundColor Yellow
if (Test-Path "tools/pdf_compressor/build") {
    Copy-Item -Path "tools/pdf_compressor/build/*" -Destination "dist/tools/pdf_compressor/build" -Recurse -Force
}

Write-Host "Menyalin QPDF dan Real-ESRGAN..." -ForegroundColor Yellow
if (Test-Path "tools/qpdf") {
    Copy-Item -Path "tools/qpdf" -Destination "dist/tools/qpdf" -Recurse -Force
}
if (Test-Path "tools/realesrgan") {
    Copy-Item -Path "tools/realesrgan" -Destination "dist/tools/realesrgan" -Recurse -Force
}

Write-Host "SUKSES! Seluruh backend dan tools berhasil disatukan di folder 'dist/'." -ForegroundColor Green