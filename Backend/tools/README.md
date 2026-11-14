# External Tools Directory (`Backend/tools`)

Direktori ini berisi seluruh *external binaries*, *native engines*, pustaka runtime, dan model AI yang digunakan oleh Backend aplikasi pengompres gambar dan PDF.

---

## 🚀 Setup Cepat (Otomatis)

Semua dependensi biner pihak ketiga yang berukuran besar (seperti QPDF dan Real-ESRGAN portable) dapat diunduh dan diekstrak secara otomatis dengan satu perintah:

```powershell
# Jalankan script ini dari folder Backend/
powershell -ExecutionPolicy Bypass -File .\tools\download_tools.ps1
```

Script di atas akan:
1. Memeriksa keberadaan direktori yang diperlukan.
2. Mengunduh paket resmi **QPDF** (Windows x64 MSVC) dan mengekstraknya ke `tools/qpdf/bin/`.
3. Mengunduh paket resmi **Real-ESRGAN NCNN Vulkan** beserta seluruh bobot model AI (`*.bin` & `*.param`) dan mengekstraknya ke `tools/realesrgan/`.
4. Memeriksa status biner C++ native `pdf_compressor.exe` di `tools/pdf_compressor/build/`.

---

## 📂 Ringkasan Sub-Folder Tools

| Folder | Komponen | Peran & Deskripsi | Panduan Detail |
| :--- | :--- | :--- | :--- |
| [`qpdf/`](./qpdf/) | **QPDF Binaries** | Utilitas stream flate recompression, regenerasi object streams, dan penataan ulang biner PDF. | [README QPDF](./qpdf/README.md) |
| [`realesrgan/`](./realesrgan/) | **Real-ESRGAN AI** | Engine deep learning NCNN Vulkan portable untuk upscaling 2x/3x/4x dan penjernihan gambar/PDF raster. | [README Real-ESRGAN](./realesrgan/README.md) |
| [`pdf_compressor/`](./pdf_compressor/) | **C++ Native Engine** | Mesin kompresi PDF berkecepatan tinggi berbasis OpenCV & QPDF C++ SDK dengan perlindungan alpha transparansi (`/SMask`). | [README C++ Engine](./pdf_compressor/README.md) |

---

## 🔒 Kebijakan `.gitignore`

File-file berikut **sengaja diabaikan** dari git tracking:
- Seluruh file biner executables (`*.exe`)
- Pustaka dinamis runtime (`*.dll`, `*.so`, `*.dylib`)
- Bobot model AI berukuran besar (`*.bin`, `*.param`)
- Artefak dan cache build C++ (`build/`, `*.obj`, `*.lib`, `*.pdb`)

Setiap folder mempertahankan struktur direktorinya di git melalui file `.gitkeep` dan dokumentasi `README.md`.

