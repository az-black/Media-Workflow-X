# Backend - Aplikasi Pengompres Gambar & PDF

Backend berkinerja tinggi untuk aplikasi kompresi, konversi, dan peningkatan resolusi (*AI Upscale*) dokumen PDF dan gambar (JPG, PNG). Dibangun menggunakan arsitektur *polyglot hybrid* yang menggabungkan kemudahan konkurensi **Go** dengan kecepatan komputasi grafis **C++ (OpenCV & QPDF)** serta model AI **Real-ESRGAN NCNN Vulkan**.

---

## 🚀 Fitur Utama

- **Target-Oriented PDF Compression**: Menyesuaikan ukuran dokumen PDF tepat di bawah batas target ukuran (KB) menggunakan algoritma *Binary Search Quality Tuning* ($30\% - 100\%$) dan *Resolution Downscale Fallback*.
- **Perlindungan Alpha & Vektor Dokumen**: Mempertahankan transparansi stempel/tanda tangan (`/SMask`) serta tidak merusak layout vektor/font (`/ImageMask`).
- **AI Super-Resolution (Real-ESRGAN Vulkan)**: Memperjelas dan memperbesar dimensi gambar hingga 2x, 3x, atau 4x secara *portable* tanpa memerlukan lingkungan Python/PyTorch.
- **Raster AI PDF Upscaling**: Merender halaman PDF, memperjelas setiap halaman menggunakan model deep learning secara paralel multi-core (*goroutine*), lalu menyusunnya kembali menjadi PDF berkualitas tinggi.
- **Konversi Format Fleksibel**: Mendukung konversi bolak-balik antara JPG $\leftrightarrow$ PNG $\leftrightarrow$ PDF.
- **Dual Interface**:
  - **RESTful HTTP API**: Endpoint JSON untuk integrasi web/aplikasi desktop frontend.
  - **CLI Mode**: Pemrosesan *batch* massal dan penjelajahan direktori (*directory walker*).

---

## 📋 Prasyarat Sistem

1. **Sistem Operasi**: Windows 10 / 11 64-bit.
2. **Go Environment**: Go versi 1.22+ (Proyek menggunakan Go 1.25.0).  
   👉 [Unduh Go](https://go.dev/dl/)
3. **GPU Driver (Opsional)**: Mendukung Vulkan untuk akselerasi perangkat keras Real-ESRGAN.
4. **C++ Build Tools (Opsional)**: Hanya diperlukan jika Anda ingin mengompilasi ulang `pdf_compressor.exe`:
   - Visual Studio 2019/2022 (MSVC C++17)
   - CMake $\ge 3.15$
   - vcpkg (`opencv4:x64-windows` & `qpdf:x64-windows`)

---

## ⚡ Instalasi Cepat (Otomatis)

Semua dependensi eksternal berukuran besar (binary QPDF dan portable Real-ESRGAN beserta model AI) dapat diunduh secara otomatis dengan satu script:

### 1. Jalankan Script Setup Tools
Buka PowerShell di folder `Backend/` dan jalankan:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\download_tools.ps1
```

Script ini akan otomatis:
- Mengunduh dan mengekstrak **QPDF v11.9.1 (Windows x64)** ke `tools/qpdf/bin/`.
- Mengunduh dan mengekstrak **Real-ESRGAN NCNN Vulkan v0.2.5.0 Portable** beserta model-modelnya (`models/*.bin` & `*.param`) ke `tools/realesrgan/`.
- Memeriksa status biner C++ native `pdf_compressor.exe`.

### 2. Download Dependensi Go
```powershell
go mod download
```

---

## 🛠️ Modul & External Tools yang Digunakan

Backend ini menggunakan **3 komponen alat eksternal** utama (Ghostscript **tidak digunakan / ditiadakan**):

1. **`tools/realesrgan` (Real-ESRGAN AI Super-Resolution)**:
   - **Peran**: Engine deep learning portabel untuk upscaling gambar (2x, 3x, 4x) dan peningkatan ketajaman dokumen PDF raster tanpa blur.
   - **Model AI yang Disertakan**:
     - `realesr-animevideov3` (skala x2, x3, x4)
     - `realesrgan-x4plus` (model foto umum dengan detail tajam)
     - `realesrgan-x4plus-anime` (model ilustrasi & anime)
   - **Karakteristik**: Portabel berbasis NCNN Vulkan, tidak membutuhkan runtime Python, PyTorch, atau CUDA.

2. **`tools/qpdf` (QPDF Stream Optimizer & Linearizer)**:
   - **Peran**: Rekompresi stream objek flate (`--compress-streams=y`, `--object-streams=generate`, `--recompress-flate`) serta pemulihan struktur biner PDF.
   - **Binary**: `tools/qpdf/bin/qpdf.exe` dan runtime `qpdf30.dll`.

3. **`tools/pdf_compressor` (C++ Native OpenCV + QPDF Engine)**:
   - **Peran**: Mesin kompresi PDF berbasis ukuran target (KB) menggunakan *Binary Search Quality* ($30\% - 100\%$) dan *Resolution Downscale Fallback*.
   - **Kelebihan**: Melindungi transparansi alpha (`/SMask`) dan stencil mask (`/ImageMask`) agar layout dan stempel tidak rusak.

---

## 📂 Struktur Direktori Proyek

```
Backend/
├── .gitignore                   <-- Konfigurasi pengabaian file biner besar
├── README.md                    <-- Dokumentasi utama backend
├── go.mod                       <-- Definisi modul dan dependensi Go
├── go.sum                       <-- Checksum verifikasi dependensi
├── main.go                      <-- Entry point server HTTP REST API
│
├── internal/
│   ├── handler/
│   │   └── handlers.go          <-- HTTP controller (/compress endpoint)
│   ├── model/
│   │   └── model.go             <-- DTO Request & Response JSON
│   └── service/
│       ├── orchestrator.go      <-- Routing alur bisnis, tipe file, dan aksi
│       ├── compressor.go        <-- Algoritma kompresi Go RAM & orkestrasi C++
│       └── converter.go         <-- Konverter format gambar & PDF (gopdf, fitz, pdfcpu)
│
└── tools/
    ├── README.md                <-- Dokumentasi umum external tools
    ├── download_tools.ps1       <-- Script download otomatis semua tools
    │
    ├── pdf_compressor/          <-- C++ Native Engine
    │   ├── CMakeLists.txt       <-- Konfigurasi build CMake
    │   ├── compress.cpp         <-- Source code kompresi OpenCV + QPDF
    │   ├── README.md            <-- Panduan kompilasi C++
    │   └── build/               <-- Target folder biner pdf_compressor.exe
    │
    ├── qpdf/                    <-- QPDF Binaries & DLLs
    │   ├── bin/                 <-- qpdf.exe, qpdf30.dll, dll.
    │   └── README.md
    │
    └── realesrgan/              <-- Real-ESRGAN Portable AI
        ├── realesrgan-ncnn-vulkan.exe
        ├── models/              <-- Bobot model deep learning (*.bin, *.param)
        ├── README.md
        └── README_windows.md
```

---

## 💻 Cara Menjalankan Aplikasi

### 1. Menjalankan RESTful HTTP Server

Jalankan perintah berikut di folder `Backend/`:

```powershell
go run main.go
```
*Server akan aktif dan mendengarkan request di: `http://localhost:8080`*

#### Contoh Request API (`POST /compress`)
**URL**: `http://localhost:8080/compress`  
**Header**: `Content-Type: application/json`

```json
{
  "files": [
    "C:\\Users\\Dokumen\\laporan.pdf",
    "C:\\Users\\Gambar\\foto.jpg"
  ],
  "output_dir": "C:\\Users\\HasilKompresi",
  "target_kb": 300,
  "target_format": "pdf",
  "action": "convert_compress",
  "scale": 4,
  "compression_type": "native",
  "is_target_per_page": false
}
```

**Pilihan Nilai Parameter:**
- `action`:
  - `"convert_compress"`: Kompresi file menuju `target_kb` (default).
  - `"convert_only"`: Mengubah format tanpa menurunkan kualitas gambar.
  - `"upscale_ai"`: Menjernihkan dan memperbesar gambar menggunakan Real-ESRGAN AI.
- `compression_type`:
  - `"native"`: Menggunakan stream resampling C++ (teks dan vektor tetap tajam).
  - `"raster"`: Mengubah seluruh halaman ke gambar HD, di-upscale AI, lalu di-repack ke PDF.
- `scale`: `2`, `3`, atau `4` (faktor perbesaran AI).

---

### 2. Menjalankan Mode CLI (Terminal Batch)

Untuk mengompresi langsung dari command line tanpa menyalakan web server:

```powershell
# Format umum:
# go run main.go cli.go <targetKB> <file1/folder> [file2 ...] <output_dir>

# Contoh 1: Kompresi beberapa file sekaligus ke target 200 KB
go run main.go cli.go 200 "dokumen1.pdf" "foto.jpg" ".\output"

# Contoh 2: Kompresi seluruh file di dalam folder secara rekursif
go run main.go cli.go 500 "C:\FolderSumber" "C:\FolderTujuan"
```

---

## 🔒 Kebijakan `.gitignore`

File [.gitignore](file:///.gitignore) telah dikonfigurasi untuk mengabaikan seluruh artefak berukuran besar:
- Executables & Libraries: `*.exe`, `*.dll`, `*.so`, `*.dylib`
- Model AI: `*.bin`, `*.param`, `*.onnx`
- Build Output: `tools/pdf_compressor/build/*`, `CMakeFiles/`, `*.obj`
- Output Sementara: `*.tmp`, `*.tmp.pdf`, `output/`

Seluruh struktur folder tetap dipertahankan di Git berkat keberadaan `.gitkeep` dan dokumentasi `README.md` pada setiap sub-direktori.

