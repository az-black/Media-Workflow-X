# Real-ESRGAN NCNN Vulkan AI Upscaler

Folder ini berisi binary portable **Real-ESRGAN NCNN Vulkan** dan model deep-learning untuk peningkatan resolusi gambar (*AI super-resolution* / *upscaling*).

---

## 📌 Peran dalam Sistem Backend
Real-ESRGAN digunakan oleh Backend pada mode:
1. **Action `upscale_ai` (Foto/Anime)**: Memperbesar dimensi dan ketajaman gambar 2x, 3x, atau 4x tanpa pecah/buram.
2. **Raster AI PDF Upscale**: Merender dokumen PDF dengan mode raster, memperjelas setiap halaman gambar menggunakan model deep learning secara paralel, lalu mengemasnya kembali menjadi PDF/JPEG HD.

Backend mengeksekusi binary ini melalui:
- Path executable: `tools/realesrgan/realesrgan-ncnn-vulkan.exe`
- Direktori model default: `tools/realesrgan/models/`

---

## 📂 Struktur Folder yang Diharapkan

Setelah diinstal, struktur folder `tools/realesrgan` harus tampak seperti ini:

```
tools/realesrgan/
├── models/
│   ├── .gitkeep
│   ├── realesr-animevideov3-x2.bin
│   ├── realesr-animevideov3-x2.param
│   ├── realesr-animevideov3-x3.bin
│   ├── realesr-animevideov3-x3.param
│   ├── realesr-animevideov3-x4.bin
│   ├── realesr-animevideov3-x4.param
│   ├── realesrgan-x4plus.bin           <-- Model foto umum (Sangat Direkomendasikan)
│   ├── realesrgan-x4plus.param         <-- Model parameter foto
│   ├── realesrgan-x4plus-anime.bin     <-- Model ilustrasi/anime
│   └── realesrgan-x4plus-anime.param
├── realesrgan-ncnn-vulkan.exe           <-- Executable utama portable (WAJIB)
├── vcomp140.dll                        <-- OpenMP runtime library (WAJIB)
├── vcomp140d.dll
├── README.md
└── README_windows.md
```

> **Catatan:** File `.exe`, `.dll`, `.bin`, dan `.param` diabaikan oleh `.gitignore` karena total ukuran bobot model AI mencapai ratusan MB.

---

## ⚡ Cara Instalasi Otomatis

Anda dapat mengunduh dan mengekstrak seluruh binary dan model AI secara otomatis menggunakan script PowerShell:

```powershell
# Jalankan dari folder Backend/
powershell -ExecutionPolicy Bypass -File .\tools\download_tools.ps1
```

Atau jalankan one-liner PowerShell khusus Real-ESRGAN berikut:

```powershell
$url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip"
$zip = "$env:TEMP\realesrgan.zip"
Invoke-WebRequest -Uri $url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath "$env:TEMP\realesrgan_temp" -Force
Copy-Item "$env:TEMP\realesrgan_temp\*" -Destination ".\tools\realesrgan\" -Recurse -Force
Remove-Item $zip, "$env:TEMP\realesrgan_temp" -Recurse -Force
```

---

## 🛠️ Cara Instalasi Manual

Jika ingin mengunduh secara manual:

1. Buka halaman rilis resmi Real-ESRGAN di GitHub:  
   👉 **[https://github.com/xinntao/Real-ESRGAN/releases](https://github.com/xinntao/Real-ESRGAN/releases)**
2. Cari rilis versi Windows portable, misalnya:  
   `realesrgan-ncnn-vulkan-20220424-windows.zip`
3. Ekstrak file zip tersebut.
4. Salin semua file hasil ekstrak:
   - `realesrgan-ncnn-vulkan.exe`
   - File `.dll` (`vcomp140.dll`, dsb.)
   - Folder `models/` beserta seluruh file `.bin` dan `.param` di dalamnya
5. Tempelkan semuanya ke dalam direktori:  
   `Backend/tools/realesrgan/`

---

## 🔍 Verifikasi Instalasi

Untuk memastikan binary Real-ESRGAN dan driver GPU Vulkan Anda terdeteksi dengan baik, jalankan:

```powershell
.\tools\realesrgan\realesrgan-ncnn-vulkan.exe -h
```

Jika output menampilkan daftar parameter (`-i`, `-o`, `-n`, `-s`, `-g`), maka instalasi telah berhasil!

