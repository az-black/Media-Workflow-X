# QPDF Tool Directory

Folder ini berisi binary portable dan pustaka dinamis (DLL) dari **QPDF** untuk platform Windows x64.

---

## 📌 Peran dalam Sistem Backend
QPDF digunakan oleh Backend untuk operasi tingkat lanjut pada file PDF:
1. **Recompress Flate Streams**: Mengompresi ulang stream data dalam PDF dengan kompresi zlib/flate maksimal.
2. **Object Streams Generation**: Mengelompokkan objek PDF ke dalam object streams (`--object-streams=generate`) guna menghemat ruang penyimpanan.
3. **Linearization & Fixer**: Memperbaiki struktur PDF yang rusak (*damaged/corrupted*) dan melakukan linearisasi (*fast web view*).

Backend memanggil executable ini melalui:
- Jalur fallback Go: `tools/qpdf/bin/qpdf.exe`
- Perintah CLI internal: `qpdf --compress-streams=y --object-streams=generate --recompress-flate input.pdf output.pdf`

---

## 📂 Struktur Folder yang Diharapkan

Setelah diinstal, struktur folder `tools/qpdf` harus tampak seperti ini:

```
tools/qpdf/
├── bin/
│   ├── .gitkeep
│   ├── qpdf.exe                 <-- Executable utama (WAJIB)
│   ├── qpdf30.dll               <-- Dynamic link library utama (WAJIB)
│   ├── fix-qdf.exe
│   ├── zlib-flate.exe
│   ├── msvcp140.dll
│   ├── vcruntime140.dll
│   └── ... (DLL runtime pendukung lainnya)
└── README.md
```

> **Catatan:** File `.exe` dan `.dll` sengaja diabaikan oleh `.gitignore` karena berukuran biner besar.

---

## ⚡ Cara Instalasi Otomatis

Anda dapat mengunduh dan mengekstrak QPDF secara otomatis menggunakan script PowerShell:

```powershell
# Jalankan dari folder Backend/
powershell -ExecutionPolicy Bypass -File .\tools\download_tools.ps1
```

Atau jalankan one-liner PowerShell khusus QPDF berikut:

```powershell
$url = "https://github.com/qpdf/qpdf/releases/download/v11.9.1/qpdf-11.9.1-bin-msvc64.zip"
$zip = "$env:TEMP\qpdf.zip"
Invoke-WebRequest -Uri $url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath "$env:TEMP\qpdf_temp" -Force
$bin = Get-ChildItem "$env:TEMP\qpdf_temp" -Recurse -Directory | Where-Object { $_.Name -eq "bin" } | Select-Object -First 1
Copy-Item "$($bin.FullName)\*" -Destination ".\tools\qpdf\bin\" -Recurse -Force
Remove-Item $zip, "$env:TEMP\qpdf_temp" -Recurse -Force
```

---

## 🛠️ Cara Instalasi Manual

Jika ingin mengunduh secara manual:

1. Buka laman rilis resmi QPDF di GitHub:  
   👉 **[https://github.com/qpdf/qpdf/releases](https://github.com/qpdf/qpdf/releases)**
2. Unduh paket zip biner Windows 64-bit MSVC, contoh:  
   `qpdf-<versi>-bin-msvc64.zip` (misalnya versi `11.9.1` atau yang lebih baru).
3. Ekstrak file zip tersebut.
4. Buka folder hasil ekstrak, masuk ke dalam folder `bin/`.
5. Salin seluruh file di dalam `bin/` (`qpdf.exe`, `qpdf30.dll`, dan seluruh DLL terkait) ke dalam folder:  
   `Backend/tools/qpdf/bin/`

---

## 🔍 Verifikasi Instalasi

Untuk memastikan QPDF dapat dijalankan dengan benar oleh Backend, jalankan perintah:

```powershell
.\tools\qpdf\bin\qpdf.exe --version
```

Output yang diharapkan adalah versi QPDF yang terpasang (misal `qpdf version 11.9.1`).

