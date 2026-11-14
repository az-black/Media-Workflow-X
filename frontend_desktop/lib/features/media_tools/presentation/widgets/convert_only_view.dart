import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../shared/widgets/app_action_button.dart';
import '../../../../shared/widgets/app_toast.dart';
import '../../../../shared/widgets/custom_dropdown.dart';
import '../../../../shared/widgets/file_type_badge.dart';
import '../../../../shared/widgets/save_folder_dialog.dart';
import '../../../../shared/widgets/status_progress_bar.dart';
import 'media_file_dropzone_box.dart';

class ConvertOnlyView extends StatefulWidget {
  const ConvertOnlyView({super.key});

  @override
  State<ConvertOnlyView> createState() => _ConvertOnlyViewState();
}

class _ConvertOnlyViewState extends State<ConvertOnlyView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  String get selectedFormat => _appState.convertOnlyFormat;
  set selectedFormat(String val) => _appState.setConvertOnlyFormat(val);

  List<MediaFileEntry> get _selectedEntries => _appState.convertOnlyEntries;
  List<String> get _selectedFiles => _appState.convertOnlyFiles;
  bool _isProcessing = false;
  double _progress = 0.0;
  String? _processingMessage;
  String? _completedMessage;
  int _completedItems = 0;
  int _totalItems = 0;
  Duration? _lastElapsed;
  String? _lastUsedEngineLabel;
  bool _wasCancelled = false;
  bool _hasError = false;
  String? _errorMessage;
  final Stopwatch _processStopwatch = Stopwatch();
  BackendCancellationToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _appState.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _appState.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickFiles() async {
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'documents and images',
      extensions: <String>['jpg', 'jpeg', 'png', 'pdf', 'docx', 'doc'],
    );

    final List<XFile> files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );

    if (files.isNotEmpty) {
      final entries = <MediaFileEntry>[];
      for (final f in files) {
        int? sizeBytes;
        try {
          sizeBytes = await f.length();
        } catch (_) {}
        entries.add(
          MediaFileEntry(
            name: f.name,
            path: f.path,
            sizeBytes: sizeBytes,
          ),
        );
      }
      _appState.addConvertOnlyEntries(entries);
    }
  }

  void _removeFile(int index) {
    _appState.removeConvertOnlyFile(index);
  }

  Future<void> _startProcess() async {
    if (_isProcessing) return;
    if (_selectedEntries.isEmpty) {
      AppToast.showWarning(
        context,
        title: 'Belum Ada File',
        message: 'Pilih setidaknya satu file terlebih dahulu!',
      );
      return;
    }

    final entriesSnapshot = List<MediaFileEntry>.from(_selectedEntries);
    final token = BackendCancellationToken();
    _cancelToken = token;
    _processStopwatch
      ..reset()
      ..start();

    setState(() {
      _isProcessing = true;
      _progress = 0.08;
      _completedItems = 0;
      _totalItems = entriesSnapshot.length;
      _completedMessage = null;
      _lastElapsed = null;
      _lastUsedEngineLabel = null;
      _wasCancelled = false;
      _hasError = false;
      _errorMessage = null;
      _processingMessage = _isDocumentConversion
          ? 'Mengonversi ${entriesSnapshot.length} file ke $selectedFormat via ${_appState.engineDisplayName}...'
          : 'Mengonversi ${entriesSnapshot.length} file ke $selectedFormat...';
    });

    try {
      final batchResult = await _backend.compressBatch(
        entries: entriesSnapshot,
        action: 'convert_only',
        targetFormat: selectedFormat,
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: null,
        engine: _appState.selectedEngine == DocEngineType.libreOffice
            ? 'libreoffice'
            : 'word',
        autoFallback: _appState.autoFallback,
        timeoutSeconds: _appState.engineTimeoutSeconds,
        cancelToken: token,
        buildOutputName: (
          inputName,
          actualExt, {
          required int partIndex,
          required int totalParts,
        }) {
          final base = _appState.buildOutputFileName(inputName, actualExt);
          if (totalParts <= 1) return base;
          final dot = base.lastIndexOf('.');
          final stem = dot > 0 ? base.substring(0, dot) : base;
          final ext = dot > 0 ? base.substring(dot) : '';
          return '${stem}_hal${partIndex + 1}$ext';
        },
        onProgress: (completed, total, message) {
          if (!mounted) return;
          final fraction = total > 0
              ? (0.12 + 0.82 * (completed / total)).clamp(0.12, 0.94)
              : 0.5;
          setState(() {
            _progress = fraction;
            _completedItems = completed;
            _totalItems = total;
            _processingMessage = message;
          });
        },
      );

      if (!mounted) {
        _processStopwatch.stop();
        await batchResult.cleanupStaging();
        return;
      }

      _processStopwatch.stop();
      final elapsed = _processStopwatch.elapsed;

      final outputItems = batchResult.files.map((sf) {
        final lower = sf.sourceFileName.toLowerCase();
        final isWordSource =
            lower.endsWith('.docx') || lower.endsWith('.doc');
        final isPdfSource = lower.endsWith('.pdf');
        final upperTarget = sf.targetFormat.toUpperCase();

        String taskType = 'Convert $upperTarget';
        if (isWordSource && upperTarget == 'PDF') {
          taskType = 'Word ke PDF';
        } else if (isPdfSource && upperTarget == 'DOCX') {
          taskType = 'PDF ke Word';
        }

        return SaveOutputItem(
          sourceFileName: sf.sourceFileName,
          outputFileName: sf.suggestedFileName,
          taskType: taskType,
          targetFormat: upperTarget,
          engineUsed: sf.engineUsed,
          originalSize: BackendService.formatBytes(sf.originalBytes),
          resultSize: BackendService.formatBytes(sf.resultBytes),
          durationMs: sf.durationMs,
          stagedFilePath:
              sf.stagedFilePath.trim().isEmpty ? null : sf.stagedFilePath,
        );
      }).toList();

      String? actualEngineLabel;
      if (outputItems.isNotEmpty &&
          outputItems.first.engineUsed.isNotEmpty) {
        actualEngineLabel = outputItems.first.engineUsed;
      }

      final fallbackOccurred = _isDocumentConversion &&
          actualEngineLabel != null &&
          ((_appState.selectedEngine == DocEngineType.msWord &&
                  actualEngineLabel.toLowerCase().contains('libreoffice')) ||
              (_appState.selectedEngine == DocEngineType.libreOffice &&
                  actualEngineLabel.toLowerCase().contains('word')));

      if (fallbackOccurred) {
        _appState.addSystemLog(
          level: 'WARN',
          message:
              'Auto-fallback engine: Konversi menggunakan $actualEngineLabel.',
          source: 'CONVERTER',
        );
      }

      final effectiveEngine = actualEngineLabel ?? _appState.engineDisplayName;
      final engineMsg = _isDocumentConversion
          ? ' menggunakan $effectiveEngine'
          : '';

      setState(() {
        _isProcessing = false;
        _progress = 1.0;
        _completedItems = entriesSnapshot.length;
        _totalItems = entriesSnapshot.length;
        _lastElapsed = elapsed;
        _lastUsedEngineLabel = actualEngineLabel;
        _processingMessage = null;
        _completedMessage =
            '${batchResult.files.length} file output dari ${entriesSnapshot.length} input selesai dikonversi ke $selectedFormat';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });

      await SaveDestinationHelper.handleProcessCompletion(
        context,
        taskTitle: 'Convert Only (Target: $selectedFormat)$engineMsg',
        summaryNote:
            '${outputItems.length} file hasil dari ${entriesSnapshot.length} file input telah selesai dikonversi ke format $selectedFormat$engineMsg.',
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (savedFolder) {
          if (!mounted) return;
          AppToast.showSuccess(
            context,
            title: 'Konversi Berhasil',
            badgeLabel: selectedFormat,
            message:
                '${entriesSnapshot.length} file berhasil dikonversi ke format $selectedFormat$engineMsg.',
            folderPath: savedFolder,
          );
          if (_appState.autoClearQueue) {
            _appState.clearConvertOnlyFiles();
          }
        },
      );
    } on BackendCancelledException {
      if (!mounted) return;
      _processStopwatch.stop();
      setState(() {
        _isProcessing = false;
        _wasCancelled = true;
        _hasError = false;
        _lastElapsed = _processStopwatch.elapsed;
        _processingMessage = null;
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'WARN',
        message: 'Proses Convert Only dibatalkan oleh pengguna.',
        source: 'CONVERTER',
      );
      AppToast.showWarning(
        context,
        title: 'Konversi Dibatalkan',
        message: 'Proses konversi dibatalkan.',
      );
    } catch (e) {
      if (!mounted) return;
      _processStopwatch.stop();
      setState(() {
        _isProcessing = false;
        _hasError = true;
        _wasCancelled = false;
        _lastElapsed = _processStopwatch.elapsed;
        _errorMessage = 'Konversi gagal: $e';
        _processingMessage = null;
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'ERROR',
        message: 'Convert Only gagal: $e',
        source: 'CONVERTER',
      );
      AppToast.showError(
        context,
        title: 'Konversi Gagal',
        message: 'Konversi gagal: $e',
      );
    }
  }

  bool get _isDocumentConversion {
    final hasWord = _selectedFiles.any((f) =>
        f.toLowerCase().endsWith('.docx') || f.toLowerCase().endsWith('.doc'));
    final hasPdf = _selectedFiles.any((f) => f.toLowerCase().endsWith('.pdf'));
    return (hasWord && selectedFormat == 'PDF') ||
        (hasPdf && selectedFormat == 'DOCX') ||
        selectedFormat == 'DOCX' ||
        selectedFormat == 'PDF';
  }

  void _cancelProcess() {
    if (_isProcessing) {
      _cancelToken?.cancel();
      _cancelToken = null;
      _processStopwatch.stop();
      setState(() {
        _isProcessing = false;
        _wasCancelled = true;
        _hasError = false;
        _lastElapsed = _processStopwatch.elapsed;
        _processingMessage = null;
      });
      return;
    }
    _appState.clearConvertOnlyFiles();
    setState(() {
      _isProcessing = false;
      _progress = 0.0;
      _completedItems = 0;
      _totalItems = 0;
      _lastElapsed = null;
      _lastUsedEngineLabel = null;
      _completedMessage = null;
      _wasCancelled = false;
      _hasError = false;
      _errorMessage = null;
      _processingMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Dropzone Area
        Expanded(
          child: MediaFileDropzoneBox(
            entries: _selectedEntries,
            contextTitle: 'Convert Only',
            selectedCountLabel: '${_selectedFiles.length} File Terpilih',
            emptyBadges: const [
              FileTypeBadge(
                label: 'JPG',
                cardColor: Color(0xFFC62828),
                textColor: Colors.white,
              ),
              FileTypeBadge(
                label: 'PNG',
                cardColor: Colors.white,
                textColor: Color(0xFFC62828),
              ),
              FileTypeBadge(
                label: 'PDF',
                cardColor: Color(0xFFD32F2F),
                textColor: Colors.white,
              ),
              FileTypeBadge(
                label: 'DOCX',
                cardColor: Color(0xFF1976D2),
                textColor: Colors.white,
              ),
            ],
            emptyTitle: 'Seret atau klik untuk memilih file',
            emptySubtitle: 'Mendukung format JPG, PNG, PDF, dan DOCX',
            onPickFiles: _pickFiles,
            onRemoveFile: _removeFile,
            onClearAll: () => _appState.clearConvertOnlyFiles(),
          ),
        ),
        const SizedBox(height: 12),

        // Target Format Dropdown (Centered)
        Center(
          child: CustomDropdown(
            width: 220,
            height: 44,
            icon: Icons.sync_alt,
            label: 'Target Format',
            value: selectedFormat,
            items: const ['PNG', 'JPG', 'JPEG', 'PDF', 'DOCX'],
            onChanged: (val) {
              if (val != null) setState(() => selectedFormat = val);
            },
            showSelectedSubtitle: true,
          ),
        ),
        const SizedBox(height: 8),

        // Active Engine Indicator Pill (Word / LibreOffice)
        _buildEngineIndicatorPill(),
        const SizedBox(height: 8),

        // Status / Progress Bar Capsule
        StatusProgressBar(
          isProcessing: _isProcessing,
          progress: _progress,
          stageLabel: 'CONVERT ONLY',
          detailText: _isDocumentConversion
              ? '$selectedFormat • ${_lastUsedEngineLabel ?? _appState.engineDisplayName}'
              : 'Target $selectedFormat',
          completedItems: _completedItems,
          totalItems: _totalItems,
          idleMessage: _selectedFiles.isEmpty
              ? 'Pilih file untuk memulai konversi'
              : '${_selectedFiles.length} file siap dikonversi ke $selectedFormat',
          processingMessage: _processingMessage ??
              (_isDocumentConversion
                  ? 'Mengonversi ke $selectedFormat via ${_appState.engineDisplayName}...'
                  : 'Mengonversi ke $selectedFormat...'),
          completedMessage: _completedMessage,
          wasCancelled: _wasCancelled,
          hasError: _hasError,
          errorMessage: _errorMessage,
          elapsedOverride: _lastElapsed,
        ),
        const SizedBox(height: 10),

        // Action Buttons: Mulai Proses & Batal
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppActionButton(
              label: 'Mulai Proses',
              icon: Icons.play_arrow_rounded,
              isPrimary: true,
              onPressed: _startProcess,
            ),
            const SizedBox(width: 14),
            AppActionButton(
              label: 'Batal',
              icon: Icons.close_rounded,
              isPrimary: false,
              onPressed: _cancelProcess,
            ),
          ],
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildEngineIndicatorPill() {
    final isWord = _appState.selectedEngine == DocEngineType.msWord;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isWord ? const Color(0xFF29B6F6) : const Color(0xFF00E676),
          width: 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isWord ? Icons.description_rounded : Icons.article_rounded,
            size: 15,
            color: isWord ? const Color(0xFF29B6F6) : const Color(0xFF00E676),
          ),
          const SizedBox(width: 7),
          Text(
            'Engine Dokumen: ${_appState.engineDisplayName}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          if (_appState.isEngineConnecting)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.orangeAccent,
                  ),
                ),
                SizedBox(width: 4),
                Text(
                  'Menyiapkan...',
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          else if (_appState.isEngineOnline)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 13,
                  color: Color(0xFF00E676),
                ),
                SizedBox(width: 3),
                Text(
                  'Siap',
                  style: TextStyle(
                    color: Color(0xFF00E676),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            )
          else
            const Icon(
              Icons.error_outline_rounded,
              size: 13,
              color: Colors.redAccent,
            ),
          const SizedBox(width: 8),
          PopupMenuButton<DocEngineType>(
            tooltip: 'Ganti Engine Konversi Dokumen',
            color: AppColors.surface,
            position: PopupMenuPosition.under,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: AppColors.primaryCyan, width: 1.2),
            ),
            onSelected: (engine) {
              _appState.setSelectedEngine(engine);
              unawaited(BackendService().warmupEngine(
                engine == DocEngineType.libreOffice ? 'libreoffice' : 'word',
              ));
              AppToast.showInfo(
                context,
                title: 'Engine Dokumen Diperbarui',
                badgeLabel: _appState.engineShortName,
                message: 'Engine aktif diubah ke: ${_appState.engineDisplayName}',
                duration: const Duration(seconds: 2),
              );
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: DocEngineType.msWord,
                child: Row(
                  children: [
                    Icon(Icons.description_rounded, color: Color(0xFF29B6F6), size: 16),
                    SizedBox(width: 8),
                    Text(
                      'Microsoft Word (MS Word)',
                      style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: DocEngineType.libreOffice,
                child: Row(
                  children: [
                    Icon(Icons.article_rounded, color: Color(0xFF00E676), size: 16),
                    SizedBox(width: 8),
                    Text(
                      'LibreOffice (Libre)',
                      style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.primaryCyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Ubah Engine',
                    style: TextStyle(
                      color: AppColors.primaryCyan,
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, color: AppColors.primaryCyan, size: 14),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
