import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../shared/widgets/app_action_button.dart';
import '../../../../shared/widgets/app_toast.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final AppStateService _appState = AppStateService();

  @override
  void initState() {
    super.initState();
    _appState.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _appState.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickOutputDirectory() async {
    final String? selectedDirectory = await getDirectoryPath();
    if (selectedDirectory != null && mounted) {
      _appState.setOutputDirectory(selectedDirectory);
      AppToast.showSuccess(
        context,
        title: 'Folder Penyimpanan Diperbarui',
        message: 'Folder penyimpanan default telah diperbarui.',
        folderPath: selectedDirectory,
      );
    }
  }

  void _saveSettings() {
    AppToast.showSuccess(
      context,
      title: 'Pengaturan Disimpan',
      message: 'Seluruh konfigurasi sistem berhasil disimpan!',
      duration: const Duration(seconds: 2),
    );
  }

  void _resetDefaults() {
    _appState.resetSettingsToDefault();
    AppToast.showWarning(
      context,
      title: 'Reset ke Default',
      message: 'Pengaturan berhasil dikembalikan ke standar awal.',
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Output Directory Settings Card
          _buildCard(
            title: 'Folder Penyimpanan & Hasil Konversi',
            icon: Icons.folder_special_outlined,
            children: [
              const Text(
                'Tentukan folder default maupun format pemilihan folder tempat file hasil konversi Word, PDF, gambar, dan kompresi disimpan:',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white12),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: [
                          const Icon(Icons.folder_outlined, color: AppColors.primaryCyan, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _appState.outputDirectory,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  AppActionButton(
                    label: 'Jelajahi...',
                    icon: Icons.drive_file_move_outlined,
                    isPrimary: true,
                    onPressed: _pickOutputDirectory,
                  ),
                  const SizedBox(width: 8),
                  AppActionButton(
                    label: 'Buka Folder',
                    icon: Icons.open_in_new_rounded,
                    isPrimary: false,
                    onPressed: () async {
                      final dirPath = _appState.outputDirectory.trim();
                      if (!BackendService.isRunningUnderFlutterTest() &&
                          dirPath.isNotEmpty) {
                        try {
                          final dir = Directory(dirPath);
                          if (!await dir.exists()) {
                            await dir.create(recursive: true);
                          }
                        } catch (_) {}
                      }
                      final opened =
                          await BackendService().openInExplorer(dirPath);
                      if (!context.mounted) return;
                      if (!opened) {
                        AppToast.showInfo(
                          context,
                          title: 'Direktori Output',
                          message:
                              'Membuka direktori: ${_appState.outputDirectory}',
                        );
                      }
                    },
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 22),
              const Text(
                'Format Penentuan Folder Simpan',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                'Pilih apakah aplikasi bertanya dulu folder tujuan melalui pop-up setiap selesai proses atau langsung menyimpan ke folder default di atas:',
                style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _buildSaveModeOptionCard(
                      mode: SaveLocationMode.askEveryTime,
                      icon: Icons.create_new_folder_outlined,
                      title: 'Tanya Dulu Mau Simpan Folder Dimana',
                      badge: 'Pop-up Simpan',
                      subtitle:
                          'Munculkan pop-up pilihan folder tujuan setiap proses selesai di seluruh fitur.',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildSaveModeOptionCard(
                      mode: SaveLocationMode.autoDefaultFolder,
                      icon: Icons.folder_copy_outlined,
                      title: 'Langsung Simpan ke Folder Default',
                      badge: 'Otomatis',
                      subtitle:
                          'Simpan otomatis seluruh hasil ke folder default tanpa menampilkan pop-up.',
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 2. File Naming & Conflict Resolution
          _buildCard(
            title: 'Format Penamaan & Penanganan Duplikasi File',
            icon: Icons.drive_file_rename_outline,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Pola Penamaan Nama File Hasil',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Format penambahan sufiks nama pada file output.',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.primaryCyan.withValues(alpha: 0.4)),
                    ),
                    child: DropdownButton<String>(
                      value: _appState.fileNamingPattern,
                      dropdownColor: AppColors.surface,
                      underline: const SizedBox(),
                      style: const TextStyle(color: AppColors.primaryCyan, fontSize: 11.5, fontWeight: FontWeight.bold),
                      items: const [
                        DropdownMenuItem(
                          value: '[original]_converted',
                          child: Text('[nama_asli]_converted'),
                        ),
                        DropdownMenuItem(
                          value: '[original]_[engine]',
                          child: Text('[nama_asli]_[engine]'),
                        ),
                        DropdownMenuItem(
                          value: '[original]',
                          child: Text('[nama_asli] (Tanpa Sufiks)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) _appState.setFileNamingPattern(val);
                      },
                    ),
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 16),
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.primaryCyan,
                  title: const Text(
                    'Timpah File yang Ada (Overwrite)',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Jika non-aktif, sistem akan otomatis menambahkan nomor seri unik (_1, _2) untuk mencegah kehilangan file lama.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                  ),
                  value: _appState.overwriteExisting,
                  onChanged: (val) => _appState.setOverwriteExisting(val),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 3. Performance & Concurrency
          _buildCard(
            title: 'Performa Mesin & Multi-Threading',
            icon: Icons.speed_rounded,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Maksimal Worker Thread Paralel',
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Jumlah berkas yang diproses secara simultan: ${_appState.maxWorkerThreads} Thread CPU',
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.primaryCyan.withValues(alpha: 0.4)),
                    ),
                    child: DropdownButton<int>(
                      value: _appState.maxWorkerThreads,
                      dropdownColor: AppColors.surface,
                      underline: const SizedBox(),
                      style: const TextStyle(color: AppColors.primaryCyan, fontSize: 11.5, fontWeight: FontWeight.bold),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 Thread (Hemat Daya)')),
                        DropdownMenuItem(value: 2, child: Text('2 Thread')),
                        DropdownMenuItem(value: 4, child: Text('4 Thread (Rekomendasi)')),
                        DropdownMenuItem(value: 8, child: Text('8 Thread (Performa Tinggi)')),
                      ],
                      onChanged: (val) {
                        if (val != null) _appState.setMaxWorkerThreads(val);
                      },
                    ),
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 16),
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.primaryCyan,
                  title: const Text(
                    'Akselerasi Perangkat Keras GPU (DirectML / CUDA)',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Memanfaatkan GPU untuk pemrosesan AI Upscaling gambar dan rendering grafis dokumen beresolusi tinggi.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                  ),
                  value: _appState.enableGpuAcceleration,
                  onChanged: (val) => _appState.setEnableGpuAcceleration(val),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 4. Workflow Preferences
          _buildCard(
            title: 'Preferensi Antarmuka & Notifikasi',
            icon: Icons.notifications_active_outlined,
            children: [
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.primaryCyan,
                  title: const Text(
                    'Bersihkan Daftar Antrean Otomatis',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Otomatis mengosongkan daftar file pada dropzone setelah proses konversi sukses 100%.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                  ),
                  value: _appState.autoClearQueue,
                  onChanged: (val) => _appState.setAutoClearQueue(val),
                ),
              ),
              const Divider(color: Colors.white10, height: 16),
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.primaryCyan,
                  title: const Text(
                    'Suara & Efek Notifikasi Sukses',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Memutar indikator suara lembut saat batch eksekusi selesai diproses di latar belakang.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                  ),
                  value: _appState.playNotificationSound,
                  onChanged: (val) => _appState.setPlayNotificationSound(val),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // 5. Bottom Save & Reset Actions
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AppActionButton(
                label: 'Reset ke Default',
                icon: Icons.restore_rounded,
                isPrimary: false,
                onPressed: _resetDefaults,
              ),
              const SizedBox(width: 12),
              AppActionButton(
                label: 'Simpan Pengaturan',
                icon: Icons.save_rounded,
                isPrimary: true,
                onPressed: _saveSettings,
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildSaveModeOptionCard({
    required SaveLocationMode mode,
    required IconData icon,
    required String title,
    required String badge,
    required String subtitle,
  }) {
    final isSelected = _appState.saveLocationMode == mode;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            _appState.setSaveLocationMode(mode);
            AppToast.showInfo(
              context,
              title: 'Format Penyimpanan Diperbarui',
              badgeLabel: badge,
              message: 'Format penyimpanan diubah ke: $title',
              duration: const Duration(seconds: 2),
            );
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.surfaceLight.withValues(alpha: 0.65)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isSelected ? AppColors.primaryCyan : Colors.white12,
                width: isSelected ? 1.8 : 1,
              ),
              boxShadow: isSelected ? AppColors.cyanGlowShadow : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: (isSelected ? AppColors.primaryCyan : Colors.white54)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    icon,
                    color: isSelected ? AppColors.primaryCyan : Colors.white70,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppColors.primaryCyan.withValues(alpha: 0.2)
                                  : Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                color: isSelected
                                    ? AppColors.primaryCyan
                                    : Colors.white54,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 10,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? AppColors.primaryCyan : Colors.white38,
                      width: 1.8,
                    ),
                    color: isSelected ? AppColors.primaryCyan : Colors.transparent,
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.black, size: 12)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
        boxShadow: AppColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primaryCyan, size: 18),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
