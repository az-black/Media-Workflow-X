import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../shared/widgets/app_action_button.dart';
import '../../../../shared/widgets/app_toast.dart';

class LogsHistoryView extends StatefulWidget {
  const LogsHistoryView({super.key});

  @override
  State<LogsHistoryView> createState() => _LogsHistoryViewState();
}

class _LogsHistoryViewState extends State<LogsHistoryView> {
  final AppStateService _appState = AppStateService();
  int _selectedTab = 0; // 0: Task History, 1: System Console
  String _searchQuery = '';
  String _selectedFilter = 'Semua';

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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 1. Top Metrics Summary Row
        _buildMetricsRow(),
        const SizedBox(height: 12),

        // 2. Segmented Pill Tab Bar (Task History vs System Logs)
        _buildSegmentedTabBar(),
        const SizedBox(height: 12),

        // 3. Tab Body
        Expanded(
          child: _selectedTab == 0
              ? _buildTaskHistoryTab()
              : _buildSystemConsoleTab(),
        ),
      ],
    );
  }

  Widget _buildMetricsRow() {
    final history = _appState.history;
    final total = history.length;
    final successCount = history.where((h) => h.status == 'Sukses').length;
    final successRate = total > 0 ? ((successCount / total) * 100).toStringAsFixed(1) : '100';

    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            label: 'Total Tugas Diproses',
            value: '$total File',
            icon: Icons.layers_outlined,
            color: AppColors.primaryCyan,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildMetricCard(
            label: 'Tingkat Keberhasilan',
            value: '$successRate%',
            icon: Icons.check_circle_outline,
            color: const Color(0xFF00E676),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildMetricCard(
            label: 'Engine Konversi Aktif',
            value: _appState.engineShortName,
            icon: Icons.memory_rounded,
            color: const Color(0xFF29B6F6),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildMetricCard(
            label: 'Total Log Sistem',
            value: '${_appState.systemLogs.length} Baris',
            icon: Icons.terminal_rounded,
            color: const Color(0xFFAB47BC),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
        boxShadow: AppColors.cardShadow,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentedTabBar() {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildTabButton(
              index: 0,
              icon: Icons.history_rounded,
              label: 'Riwayat Tugas (${_appState.history.length})',
            ),
          ),
          Expanded(
            child: _buildTabButton(
              index: 1,
              icon: Icons.terminal_rounded,
              label: 'Konsol Log Sistem (${_appState.systemLogs.length})',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryCyan : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? Colors.black : Colors.white70,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.white70,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== TAB 1: TASK HISTORY ====================
  Widget _buildTaskHistoryTab() {
    final filtered = _appState.history.where((item) {
      if (_searchQuery.isNotEmpty &&
          !item.fileName.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      if (_selectedFilter != 'Semua' && !item.taskType.contains(_selectedFilter)) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        // Search & Filter controls
        Row(
          children: [
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.cardBackground,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.white38, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Cari nama file di riwayat...',
                          hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.cardBackground,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white12),
              ),
              child: DropdownButton<String>(
                value: _selectedFilter,
                dropdownColor: AppColors.surface,
                underline: const SizedBox(),
                style: const TextStyle(color: AppColors.primaryCyan, fontSize: 11, fontWeight: FontWeight.bold),
                items: const [
                  DropdownMenuItem(value: 'Semua', child: Text('Semua Jenis Tugas')),
                  DropdownMenuItem(value: 'Word', child: Text('Word ke PDF / PDF ke Word')),
                  DropdownMenuItem(value: 'Convert', child: Text('Convert Only')),
                  DropdownMenuItem(value: 'Compress', child: Text('Compress & Convert')),
                  DropdownMenuItem(value: 'Upscale', child: Text('Upscale AI')),
                  DropdownMenuItem(value: 'PDF Manager', child: Text('PDF Manager')),
                ],
                onChanged: (val) {
                  if (val != null) setState(() => _selectedFilter = val);
                },
              ),
            ),
            const SizedBox(width: 10),
            AppActionButton(
              label: 'Bersihkan Riwayat',
              icon: Icons.delete_sweep_outlined,
              isPrimary: false,
              onPressed: () {
                _appState.clearHistory();
                AppToast.showWarning(
                  context,
                  title: 'Riwayat Dikosongkan',
                  message: 'Riwayat pemrosesan file berhasil dikosongkan.',
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 10),

        // List of history items
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.inbox_outlined, color: Colors.white24, size: 40),
                      SizedBox(height: 8),
                      Text(
                        'Belum ada riwayat tugas yang sesuai',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: filtered.length,
                  itemBuilder: (context, idx) {
                    final item = filtered[idx];
                    return _buildHistoryCard(item);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHistoryCard(TaskHistoryItem item) {
    final bool isSuccess = item.status == 'Sukses';
    final timeStr =
        '${item.timestamp.hour.toString().padLeft(2, '0')}:${item.timestamp.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          // Icon badge
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primaryCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              item.targetFormat.toUpperCase() == 'PDF'
                  ? Icons.picture_as_pdf_rounded
                  : (item.targetFormat.toUpperCase() == 'DOCX'
                      ? Icons.description_rounded
                      : Icons.image_rounded),
              color: AppColors.primaryCyan,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),

          // File name and meta
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.fileName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isSuccess
                            ? const Color(0xFF00E676).withValues(alpha: 0.15)
                            : Colors.redAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isSuccess ? const Color(0xFF00E676) : Colors.redAccent,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        item.status.toUpperCase(),
                        style: TextStyle(
                          color: isSuccess ? const Color(0xFF00E676) : Colors.redAccent,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Tugas: ${item.taskType} ➔ ${item.targetFormat}',
                      style: const TextStyle(color: AppColors.primaryCyan, fontSize: 10),
                    ),
                    const Text('•', style: TextStyle(color: Colors.white30, fontSize: 10)),
                    Text(
                      'Engine: ${item.engineUsed}',
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                    const Text('•', style: TextStyle(color: Colors.white30, fontSize: 10)),
                    Text(
                      '${item.originalSize} ➔ ${item.resultSize} (${item.durationMs}ms)',
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                    const Text('•', style: TextStyle(color: Colors.white30, fontSize: 10)),
                    Text(
                      timeStr,
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Actions
          Tooltip(
            message: 'Buka Lokasi Hasil File',
            child: IconButton(
              icon: const Icon(Icons.folder_open_outlined, color: Colors.white70, size: 18),
              onPressed: () async {
                final opened = await BackendService().openInExplorer(item.outputPath);
                if (!mounted) return;
                if (!opened) {
                  AppToast.showInfo(
                    context,
                    title: 'Lokasi Output File',
                    message: 'Lokasi File: ${item.outputPath}',
                  );
                }
              },
            ),
          ),
          Tooltip(
            message: 'Hapus dari Riwayat',
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 16),
              onPressed: () => _appState.removeHistoryItem(item.id),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== TAB 2: SYSTEM CONSOLE ====================
  Widget _buildSystemConsoleTab() {
    final logs = _appState.systemLogs;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF030A10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primaryCyan.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          // Console header with actions
          Row(
            children: [
              const Icon(Icons.terminal, color: AppColors.primaryCyan, size: 16),
              const SizedBox(width: 8),
              const Text(
                'LIVE SYSTEM LOGS (TERMINAL)',
                style: TextStyle(
                  color: AppColors.primaryCyan,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  final text = logs.map((l) => '[${l.timestamp.toIso8601String()}] [${l.level}] [${l.source}] ${l.message}').join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  AppToast.showSuccess(
                    context,
                    title: 'Logs Disalin',
                    badgeLabel: 'CLIPBOARD',
                    message: 'Seluruh logs sistem berhasil disalin ke Clipboard!',
                    duration: const Duration(seconds: 2),
                  );
                },
                child: Row(
                  children: const [
                    Icon(Icons.copy_rounded, color: Colors.white70, size: 13),
                    SizedBox(width: 4),
                    Text(
                      'Salin Semua',
                      style: TextStyle(color: Colors.white70, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              InkWell(
                onTap: () => _appState.clearSystemLogs(),
                child: Row(
                  children: const [
                    Icon(Icons.delete_outline, color: Colors.redAccent, size: 13),
                    SizedBox(width: 4),
                    Text(
                      'Bersihkan',
                      style: TextStyle(color: Colors.redAccent, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white12, height: 16),

          // Monospaced Log lines
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      'Konsol log sistem kosong.',
                      style: TextStyle(color: Colors.white30, fontFamily: 'monospace', fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: logs.length,
                    itemBuilder: (context, idx) {
                      final log = logs[idx];
                      Color levelColor;
                      switch (log.level) {
                        case 'SUCCESS':
                          levelColor = const Color(0xFF00E676);
                          break;
                        case 'WARN':
                          levelColor = Colors.orangeAccent;
                          break;
                        case 'ERROR':
                          levelColor = Colors.redAccent;
                          break;
                        default:
                          levelColor = AppColors.primaryCyan;
                      }

                      final time =
                          '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}';

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '[$time] ',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                              decoration: BoxDecoration(
                                color: levelColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                log.level,
                                style: TextStyle(
                                  color: levelColor,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '[${log.source}] ',
                              style: const TextStyle(
                                color: Color(0xFFAB47BC),
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                              ),
                            ),
                            Expanded(
                              child: Text(
                                log.message,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10.5,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
