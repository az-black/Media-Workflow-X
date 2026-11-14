# Native C++ PDF Compressor (OpenCV + QPDF)

Direktori ini berisi kode sumber C++ (`compress.cpp`) dan konfigurasi CMake untuk membangun executable native berkecepatan tinggi: **`pdf_compressor.exe`**.

---

## 📌 Peran dalam Sistem Backend
Mesin C++ ini adalah inti dari kompresi PDF berbasis target ukuran (KB) dengan karakteristik:
1. **Preservasi Transparansi & Vektor**: Tidak menghapus atau merusak `/SMask` (soft mask / alpha channel stempel & tanda tangan) dan mengabaikan `/ImageMask` (stencil masks) sehingga layout dokumen tidak rusak.
2. **Binary Search Quality Optimization**: Melakukan pencarian biner tingkat kualitas JPEG ($30\% - 100\%$) untuk menemukan kompresi tertinggi yang pas di bawah `target_kb`.
3. **Resolution Downscaling Fallback**: Jika kualitas 30% masih melebihi target, resolusi diturunkan secara bertahap ($3200\text{px} \to 2400 \to 1800 \to 1200 \to 800 \to 500\text{px}$) pada kualitas 80%.
4. **Structured Exception Handling (SEH)**: Dilengkapi proteksi Windows SEH (`__try / __except`) agar tidak *crash* jika menemukan stream PDF yang *corrupted*.

Backend mencari biner ini pada urutan prioritas:
1. `tools/pdf_compressor/build/Release/pdf_compressor.exe`
2. `tools/pdf_compressor/build/Debug/pdf_compressor.exe`
3. `tools/pdf_compressor/build/pdf_compressor.exe`

---

## 📂 Struktur Folder yang Diharapkan

```
tools/pdf_compressor/
├── build/
│   ├── .gitkeep
│   ├── pdf_compressor.exe       <-- Hasil kompilasi (WAJIB)
│   ├── qpdf30.dll               <-- DLL dependensi runtime vcpkg
│   ├── opencv_core4.dll
│   ├── opencv_imgproc4.dll
│   ├── opencv_imgcodecs4.dll
│   ├── turbojpeg.dll
│   └── ... (DLL vcpkg lainnya)
├── CMakeLists.txt               <-- Konfigurasi build CMake
├── compress.cpp                 <-- Source code utama C++
└── README.md
```

> **Catatan:** Seluruh isi folder `build/` (termasuk `.exe`, `.obj`, `.dll`, dan cache CMake) diabaikan oleh `.gitignore`.

---

## 🛠️ Panduan Kompilasi (Build Manual)

Untuk membangun `pdf_compressor.exe` dari source code di Windows:

### 1. Prasyarat Sistem
- **CMake** (versi $\ge 3.15$): unduh dari [cmake.org](https://cmake.org/download/) atau install via winget:
  ```powershell
  winget install Kitware.CMake
  ```
- **Visual Studio 2019 / 2022** (dengan workload *Desktop development with C++*).
- **vcpkg** (Microsoft C++ Library Package Manager).

---

### 2. Instalasi Dependensi via vcpkg

Jika belum memiliki vcpkg di `C:\vcpkg`:

```powershell
# 1. Clone repository vcpkg
git clone https://github.com/microsoft/vcpkg.git C:\vcpkg

# 2. Bootstrap vcpkg
cd C:\vcpkg
.\bootstrap-vcpkg.bat

# 3. Install OpenCV4 dan QPDF untuk arsitektur x64-windows
.\vcpkg.exe install opencv4:x64-windows qpdf:x64-windows
```

> Jika Anda menginstal vcpkg di direktori lain selain `C:/vcpkg/installed/x64-windows`, sesuaikan variabel `VCPKG_ROOT` pada file `CMakeLists.txt`.

---

### 3. Kompilasi Menggunakan CMake

Buka terminal PowerShell di folder `Backend/tools/pdf_compressor`:

```powershell
# Masuk ke folder pdf_compressor
cd c:\projects\app_pengompres_gambar_pdf\Backend\tools\pdf_compressor

# Generate build files
cmake -B build -S .

# Compile target Release
cmake --build build --config Release
```

---

### 4. Menyalin DLL Dependensi ke Folder Build

Jika CMake tidak otomatis menyalin DLL saat build, salin seluruh file `.dll` dari folder instalasi vcpkg ke folder tempat `pdf_compressor.exe` berada:

```powershell
# Salin runtime DLL dari vcpkg ke folder build
Copy-Item "C:\vcpkg\installed\x64-windows\bin\*.dll" -Destination ".\build\" -Force
```

---

## 🔍 Uji Coba Executable

Jalankan perintah berikut untuk menguji executable:

```powershell
.\build\pdf_compressor.exe "input.pdf" "output.pdf" 500
```
*(Argumen: `<input_path> <output_path> <target_kb>`)*

