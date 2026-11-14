import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../shared/widgets/app_action_button.dart';
import '../../../../shared/widgets/app_toast.dart';

class EngineConfigView extends StatefulWidget {
  const EngineConfigView({super.key});

  @override
  State<EngineConfigView> createState() => _EngineConfigViewState();
}

class _EngineConfigViewState extends State<EngineConfigView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  bool _isTestingConnection = false;
  bool _isRestartingBackend = false;

  @override
  void initState() {
    super.initState();
    _appState.addListener(_onStateChanged);
    _backend.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _appState.removeListener(_onStateChanged);
    _backend.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _runConnectionTest() async {
    if (_isTestingConnection) return;
    setState(() => _isTestingConnection = true);

    final ok = await _appState.testEngineConnection();

    if (!mounted) return;
    setState(() => _isTestingConnection = false);

    final msg = ok
        ? 'Koneksi ${_appState.engineDisplayName} (${BackendService.baseUrl}) berhasil! Respon: ${_appState.lastLatencyMs}ms.'
        : (_backend.lastError ??
            'Backend Go tidak merespons di ${BackendService.baseUrl}.');

    if (ok) {
      AppToast.showSuccess(
        context,
        title: 'Koneksi Engine Terhubung',
        badgeLabel: '${_appState.lastLatencyMs}ms',
        message: msg,
        duration: const Duration(seconds: 3),
      );
    } else {
      AppToast.showError(
        context,
        title: 'Koneksi Engine Gagal',
        message: msg,
        duration: const Duration(seconds: 4),
      );
    }
  }

  Future<void> _restartBackend() async {
    if (_isRestartingBackend) return;
    setState(() => _isRestartingBackend = true);

    final ok = await _backend.restartBackend();
    if (!mounted) return;
    setState(() => _isRestartingBackend = false);

    if (ok) {
      AppToast.showSuccess(
        context,
        title: 'Backend Engine Aktif Kembali',
        badgeLabel: '${_backend.lastPingLatencyMs}ms',
        message:
            'Backend engine Go berhasil dijalankan ulang (${_backend.lastPingLatencyMs}ms).',
        duration: const Duration(seconds: 3),
      );
    } else {
      AppToast.showError(
        context,
        title: 'Gagal Memulai Ulang Backend',
        message: _backend.lastError ?? 'Gagal memulai ulang backend engine.',
        duration: const Duration(seconds: 4),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Header Banner / Status Ringkasan
          _buildStatusBanner(),
          const SizedBox(height: 16),

          // 2. Pemilihan Dua Mesin Utama: Word vs LibreOffice
          const Text(
            'Pilih Engine Dokumen Utama',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Engine ini digunakan oleh modul Convert Only untuk konversi Word (.docx) ke PDF dan PDF ke Word.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              // Card Microsoft Word
              Expanded(
                child: _buildEngineCard(
                  type: DocEngineType.msWord,
                  title: 'Microsoft Word (MS Word)',
                  subtitle: 'Direct COM Automation API',
                  icon: Icons.description_rounded,
                  accentColor: const Color(0xFF2B579A),
                  version: _appState.msWordVersion,
                  path: _appState.msWordPath,
                  isInstalled: _appState.isMsWordInstalled,
                  isSelected: _appState.selectedEngine == DocEngineType.msWord,
                  badges: const ['Presisi Format 100%', 'Tabel & Header Native', 'Sangat Cepat'],
                  description:
                      'Menggunakan instalasi resmi Microsoft Word di Windows untuk hasil konversi paling akurat, menjaga font dan tata letak tabel kompleks secara sempurna.',
                  onSelect: () {
                    _appState.setSelectedEngine(DocEngineType.msWord);
                    unawaited(BackendService().warmupEngine('word'));
                  },
                ),
              ),
              const SizedBox(width: 14),

              // Card LibreOffice
              Expanded(
                child: _buildEngineCard(
                  type: DocEngineType.libreOffice,
                  title: 'LibreOffice (Libre)',
                  subtitle: 'Headless CLI / UNO Pipeline',
                  icon: Icons.article_rounded,
                  accentColor: const Color(0xFF1B7E5A),
                  version: _appState.libreVersion,
                  path: _appState.librePath,
                  isInstalled: _appState.isLibreInstalled,
                  isSelected: _appState.selectedEngine == DocEngineType.libreOffice,
                  badges: const ['Open-Source', 'Multi-Format Luas', 'Tanpa Lisensi Office'],
                  description:
                      'Menggunakan mesin LibreOffice Headless via background process. Andal untuk konversi batch tanpa bergantung pada lisensi Microsoft 365.',
                  onSelect: () {
                    _appState.setSelectedEngine(DocEngineType.libreOffice);
                    unawaited(BackendService().warmupEngine('libreoffice'));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // 3. Konfigurasi Lanjutan Engine
          _buildAdvancedSettingsCard(),
          const SizedBox(height: 16),

          // 4. Diagnostik & Tes Koneksi
          _buildDiagnosticsSection(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    final isOnline = _appState.isEngineOnline;
    final isConnecting =
        _appState.isEngineConnecting || _isTestingConnection || _isRestartingBackend;
    final statusColor = isOnline
        ? const Color(0xFF00E676)
        : (isConnecting ? Colors.amberAccent : Colors.redAccent);
    final statusLabel = isOnline
        ? 'ONLINE'
        : (isConnecting ? 'MEMULAI...' : 'OFFLINE');
    final statusDetail = isOnline
        ? 'Backend Go aktif di ${BackendService.baseUrl} • Latensi ${_appState.lastLatencyMs}ms • Engine Dokumen: ${_appState.engineDisplayName}.'
        : (isConnecting
            ? 'Menghubungkan ke backend engine Go (${BackendService.baseUrl})...'
            : (_backend.lastError ??
                'Backend engine belum aktif di ${BackendService.baseUrl}. Klik Uji Koneksi atau Restart untuk menghubungkan.'));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primaryCyan.withValues(alpha: 0.4), width: 1.2),
        boxShadow: AppColors.cardShadow,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primaryCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.tune_rounded,
              color: AppColors.primaryCyan,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Status Engine Dokumen: ',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      _appState.engineDisplayName,
                      style: const TextStyle(
                        color: AppColors.primaryCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: statusColor, width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isConnecting)
                            SizedBox(
                              width: 8,
                              height: 8,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: statusColor,
                              ),
                            )
                          else if (isOnline)
                            Icon(
                              Icons.check_circle_rounded,
                              size: 10,
                              color: statusColor,
                            )
                          else
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          const SizedBox(width: 4),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  statusDetail,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AppActionButton(
            label: _isRestartingBackend ? 'Restart...' : 'Restart',
            icon: Icons.refresh_rounded,
            isPrimary: false,
            onPressed: (_isRestartingBackend || _isTestingConnection)
                ? null
                : _restartBackend,
          ),
          const SizedBox(width: 8),
          AppActionButton(
            label: _isTestingConnection ? 'Memeriksa...' : 'Uji Koneksi',
            icon: Icons.bolt_rounded,
            isPrimary: true,
            onPressed: (_isTestingConnection || _isRestartingBackend)
                ? null
                : () => _runConnectionTest(),
          ),
        ],
      ),
    );
  }

  Widget _buildEngineCard({
    required DocEngineType type,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required String version,
    required String path,
    required bool isInstalled,
    required bool isSelected,
    required List<String> badges,
    required String description,
    required VoidCallback onSelect,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onSelect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.surfaceLight.withValues(alpha: 0.6)
                : AppColors.cardBackground,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppColors.primaryCyan : Colors.white12,
              width: isSelected ? 2 : 1,
            ),
            boxShadow: isSelected ? AppColors.cyanGlowShadow : AppColors.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: Icon, Title, Radio selection
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: accentColor.withValues(alpha: 0.6)),
                    ),
                    child: Icon(icon, color: accentColor, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? AppColors.primaryCyan : Colors.white38,
                        width: 2,
                      ),
                      color: isSelected ? AppColors.primaryCyan : Colors.transparent,
                    ),
                    child: isSelected
                        ? const Center(
                            child: Icon(
                              Icons.check,
                              color: Colors.black,
                              size: 13,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Badges
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: badges.map((badge) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),

              // Description
              Text(
                description,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 12),
              const Divider(color: Colors.white10, height: 1),
              const SizedBox(height: 10),

              // Executable & Detection Path
              Row(
                children: [
                  const Icon(Icons.folder_outlined, color: Colors.white38, size: 13),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 9.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    isInstalled ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                    color: isInstalled ? const Color(0xFF00E676) : Colors.orangeAccent,
                    size: 13,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      version,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isInstalled
                            ? const Color(0xFF00E676)
                            : Colors.orangeAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: (isInstalled
                              ? const Color(0xFF00E676)
                              : Colors.orangeAccent)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: (isInstalled
                                ? const Color(0xFF00E676)
                                : Colors.orangeAccent)
                            .withValues(alpha: 0.6),
                      ),
                    ),
                    child: Text(
                      isInstalled ? 'TERDETEKSI' : 'BELUM ADA',
                      style: TextStyle(
                        color: isInstalled
                            ? const Color(0xFF00E676)
                            : Colors.orangeAccent,
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedSettingsCard() {
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
            children: const [
              Icon(Icons.tune, color: AppColors.primaryCyan, size: 18),
              SizedBox(width: 8),
              Text(
                'Pengaturan Aturan Mesin & Keandalan (Failover)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Auto-fallback toggle
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppColors.primaryCyan,
              title: const Text(
                'Auto-Fallback Engine',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Otomatis beralih ke LibreOffice jika Microsoft Word sibuk atau mengalami crash pada file tertentu.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
              ),
              value: _appState.autoFallback,
              onChanged: (val) => _appState.setAutoFallback(val),
            ),
          ),
          const Divider(color: Colors.white10, height: 1),

          // High DPI Rendering
          Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppColors.primaryCyan,
              title: const Text(
                'High-DPI PDF Rendering (300 DPI)',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Menjaga resolusi gambar di dalam dokumen Word tetap tajam dan jernih pada file PDF hasil konversi.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
              ),
              value: _appState.highDpiRendering,
              onChanged: (val) => _appState.setHighDpiRendering(val),
            ),
          ),
          const Divider(color: Colors.white10, height: 1),

          // Timeout slider
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Batas Waktu Eksekusi (Timeout)',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _appState.hasNoEngineTimeout
                            ? 'Maksimal durasi proses dokumen per file: No Time (dibiarkan selesai tanpa batas timeout)'
                            : 'Maksimal durasi proses dokumen per file sebelum dianggap hang: ${_appState.engineTimeoutSeconds} Detik',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.primaryCyan.withValues(alpha: 0.5)),
                  ),
                  child: DropdownButton<int>(
                    value: const [30, 45, 60, 120, 0]
                            .contains(_appState.engineTimeoutSeconds)
                        ? _appState.engineTimeoutSeconds
                        : 45,
                    dropdownColor: AppColors.surface,
                    underline: const SizedBox(),
                    style: const TextStyle(color: AppColors.primaryCyan, fontSize: 12, fontWeight: FontWeight.bold),
                    items: const [
                      DropdownMenuItem(value: 30, child: Text('30 Detik')),
                      DropdownMenuItem(value: 45, child: Text('45 Detik')),
                      DropdownMenuItem(value: 60, child: Text('60 Detik')),
                      DropdownMenuItem(value: 120, child: Text('120 Detik')),
                      DropdownMenuItem(value: 0, child: Text('No Time')),
                    ],
                    onChanged: (val) {
                      if (val != null) _appState.setEngineTimeoutSeconds(val);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticsSection() {
    final caps = _backend.capabilities;
    final hasQpdf = _appState.hasQpdf || caps.hasQpdf;
    final hasPdfCompressor =
        _appState.hasPdfCompressor || caps.hasPdfCompressor;
    final hasRealEsrgan = _appState.hasRealEsrgan || caps.hasRealEsrgan;
    final hasCpp = _appState.hasCppRuntime || caps.hasVisualCppRuntime;
    final modelsCount = caps.realEsrganModels.isNotEmpty
        ? caps.realEsrganModels.length
        : _appState.realEsrganModelsCount;
    final canDocxToPdf =
        _appState.isMsWordInstalled || _appState.isLibreInstalled;

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
            children: const [
              Icon(Icons.health_and_safety_outlined, color: Color(0xFF00E676), size: 18),
              SizedBox(width: 8),
              Text(
                'Laporan Kesehatan & Kompatibilitas Sistem',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildHealthRow(
            label: 'Backend Go Daemon (smart_compress_backend.exe)',
            status: _appState.isEngineOnline
                ? 'Online di ${BackendService.baseUrl} (${_appState.lastLatencyMs}ms)'
                : (caps.hasBackendExe
                    ? 'Siap Dijalankan (Offline)'
                    : 'Executable tidak ditemukan'),
            isGood: _appState.isEngineOnline || caps.hasBackendExe,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Integrasi COM Windows API (Word)',
            status: _appState.isMsWordInstalled
                ? 'Aktif (${_appState.msWordVersion})'
                : 'Tidak terdeteksi di sistem',
            isGood: _appState.isMsWordInstalled,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Binary Headless soffice (LibreOffice)',
            status: _appState.isLibreInstalled
                ? 'Terdeteksi (${_appState.libreVersion})'
                : 'Tidak terdeteksi di Program Files',
            isGood: _appState.isLibreInstalled,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Dukungan Konversi DOCX ➔ PDF',
            status: canDocxToPdf
                ? 'Didukung (${[
                    if (_appState.isMsWordInstalled) 'MS Word',
                    if (_appState.isLibreInstalled) 'LibreOffice',
                  ].join(' & ')})'
                : 'Memerlukan MS Word atau LibreOffice',
            isGood: canDocxToPdf,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Bundle QPDF Engine (Split / Reorder / Merge / Rotate)',
            status: hasQpdf ? 'Siap (tools/qpdf/bin/qpdf.exe)' : 'Tidak ditemukan',
            isGood: hasQpdf,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Bundle PDF Compressor & Rasterizer',
            status: hasPdfCompressor
                ? 'Siap (tools/pdf_compressor/build/pdf_compressor.exe)'
                : 'Tidak ditemukan',
            isGood: hasPdfCompressor,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Bundle Real-ESRGAN AI Upscaler',
            status: hasRealEsrgan
                ? 'Siap ($modelsCount model AI terpasang)'
                : 'Tidak ditemukan',
            isGood: hasRealEsrgan,
          ),
          const SizedBox(height: 6),
          _buildHealthRow(
            label: 'Visual C++ Runtime DLL (Portabel)',
            status: hasCpp ? 'Bundled (Siap Eksekusi)' : 'Runtime Sistem',
            isGood: hasCpp,
          ),
        ],
      ),
    );
  }

  Widget _buildHealthRow({
    required String label,
    required String status,
    required bool isGood,
  }) {
    return Row(
      children: [
        Icon(
          isGood ? Icons.check_circle_outline : Icons.warning_amber_rounded,
          color: isGood ? const Color(0xFF00E676) : Colors.orangeAccent,
          size: 14,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
        const Spacer(),
        Text(
          status,
          style: TextStyle(
            color: isGood ? const Color(0xFF00E676) : Colors.orangeAccent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
