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

class CompressConvertView extends StatefulWidget {
  const CompressConvertView({super.key});

  @override
  State<CompressConvertView> createState() => _CompressConvertViewState();
}

class _CompressConvertViewState extends State<CompressConvertView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  late TextEditingController _targetKbController;

  String get selectedFormat => _appState.compressFormat;
  set selectedFormat(String val) => _appState.setCompressOptions(format: val);

  String get targetPerPage => _appState.compressTargetPerPage;
  set targetPerPage(String val) => _appState.setCompressOptions(perPage: val);

  String get compressionType => _appState.compressType;
  set compressionType(String val) => _appState.setCompressOptions(type: val);

  List<MediaFileEntry> get _selectedEntries => _appState.compressEntries;
  List<String> get _selectedFiles => _appState.compressFiles;
  bool _isProcessing = false;
  double _progress = 0.0;
  String? _processingMessage;
  String? _completedMessage;
  int _completedItems = 0;
  int _totalItems = 0;
  Duration? _lastElapsed;
  bool _wasCancelled = false;
  bool _hasError = false;
  String? _errorMessage;
  final Stopwatch _processStopwatch = Stopwatch();
  BackendCancellationToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _targetKbController =
        TextEditingController(text: _appState.compressTargetKb);
    _targetKbController.addListener(() {
      _appState.setCompressOptions(kb: _targetKbController.text);
    });
    _appState.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _appState.removeListener(_onStateChanged);
    _targetKbController.dispose();
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
      _appState.addCompressEntries(entries);
    }
  }

  void _removeFile(int index) {
    _appState.removeCompressFile(index);
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

    final rawTargetText = _targetKbController.text.trim();
    final targetKbInt = int.tryParse(rawTargetText.isEmpty ? '200' : rawTargetText);
    if (targetKbInt == null || targetKbInt <= 0) {
      AppToast.showWarning(
        context,
        title: 'Target KB Tidak Valid',
        message: 'Target KB harus berupa angka lebih besar dari 0!',
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
      _wasCancelled = false;
      _hasError = false;
      _errorMessage = null;
      _processingMessage =
          'Mengompresi ${entriesSnapshot.length} file ke $selectedFormat (Target $targetKbInt KB)...';
    });

    try {
      final batchResult = await _backend.compressBatch(
        entries: entriesSnapshot,
        action: 'convert_compress',
        targetFormat: selectedFormat,
        compressionType: compressionType.toLowerCase(),
        targetKB: targetKbInt,
        targetPerPage: targetPerPage == 'True',
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
          final base = _appState.buildOutputFileName(
            inputName,
            actualExt,
            customSuffix: 'compressed',
          );
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

      setState(() {
        _isProcessing = false;
        _progress = 1.0;
        _completedItems = entriesSnapshot.length;
        _totalItems = entriesSnapshot.length;
        _lastElapsed = elapsed;
        _processingMessage = null;
        _completedMessage =
            '${batchResult.files.length} file output selesai dikompresi ke $selectedFormat ($targetKbInt KB)';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });

      final outputItems = batchResult.files
          .map(
            (sf) => SaveOutputItem(
              sourceFileName: sf.sourceFileName,
              outputFileName: sf.suggestedFileName,
              taskType: 'Compress & Convert',
              targetFormat: sf.targetFormat.toUpperCase(),
              engineUsed: sf.engineUsed,
              originalSize: BackendService.formatBytes(sf.originalBytes),
              resultSize: BackendService.formatBytes(sf.resultBytes),
              durationMs: sf.durationMs,
              stagedFilePath:
                  sf.stagedFilePath.trim().isEmpty ? null : sf.stagedFilePath,
            ),
          )
          .toList();

      await SaveDestinationHelper.handleProcessCompletion(
        context,
        taskTitle: 'Compress & Convert ($selectedFormat • $targetKbInt KB)',
        summaryNote:
            'Target Format: $selectedFormat • Target Ukuran: $targetKbInt KB • Target Per Page: $targetPerPage • Tipe PDF: $compressionType',
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (savedFolder) {
          if (!mounted) return;
          AppToast.showSuccess(
            context,
            title: 'Kompresi Berhasil',
            badgeLabel: '$selectedFormat • ${targetKbInt}KB',
            message:
                '${entriesSnapshot.length} file berhasil dikompres (Target $targetKbInt KB).',
            folderPath: savedFolder,
          );
          if (_appState.autoClearQueue) {
            _appState.clearCompressFiles();
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
        message: 'Proses Compress & Convert dibatalkan oleh pengguna.',
        source: 'CONVERTER',
      );
      AppToast.showWarning(
        context,
        title: 'Kompresi Dibatalkan',
        message: 'Proses kompresi dibatalkan.',
      );
    } catch (e) {
      if (!mounted) return;
      _processStopwatch.stop();
      setState(() {
        _isProcessing = false;
        _hasError = true;
        _wasCancelled = false;
        _lastElapsed = _processStopwatch.elapsed;
        _errorMessage = 'Kompresi gagal: $e';
        _processingMessage = null;
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'ERROR',
        message: 'Compress & Convert gagal: $e',
        source: 'CONVERTER',
      );
      AppToast.showError(
        context,
        title: 'Kompresi Gagal',
        message: 'Kompresi gagal: $e',
      );
    }
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
    _appState.clearCompressFiles();
    setState(() {
      _isProcessing = false;
      _progress = 0.0;
      _completedItems = 0;
      _totalItems = 0;
      _lastElapsed = null;
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
            contextTitle: 'Compress & Convert',
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
            ],
            emptyTitle: 'Seret atau klik untuk memilih file',
            emptySubtitle: 'Mendukung kompresi gambar & file PDF cerdas',
            onPickFiles: _pickFiles,
            onRemoveFile: _removeFile,
            onClearAll: () => _appState.clearCompressFiles(),
          ),
        ),
        const SizedBox(height: 10),

        // 2x2 Grid of Control Options
        Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: CustomDropdown(
                    height: 44,
                    icon: Icons.sync_alt,
                    label: 'Target Format',
                    value: selectedFormat,
                    items: const ['PNG', 'JPG', 'JPEG', 'PDF'],
                    onChanged: (val) {
                      if (val != null) setState(() => selectedFormat = val);
                    },
                    showSelectedSubtitle: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CustomDropdown(
                    height: 44,
                    icon: Icons.description_outlined,
                    label: 'Target Per Page',
                    value: targetPerPage,
                    items: const ['True', 'False'],
                    onChanged: (val) {
                      if (val != null) setState(() => targetPerPage = val);
                    },
                    showSelectedSubtitle: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.borderCyan,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.keyboard_double_arrow_right,
                          color: AppColors.primaryCyan,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Target KB',
                          style: TextStyle(
                            color: AppColors.textWhite,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            alignment: Alignment.centerLeft,
                            child: TextField(
                              controller: _targetKbController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                hintText: '200',
                                hintStyle: TextStyle(
                                  color: Colors.black38,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CustomDropdown(
                    height: 44,
                    icon: Icons.compress,
                    label: 'Compression Type (Only PDF)',
                    value: compressionType,
                    items: const ['Native', 'Raster'],
                    onChanged: (val) {
                      if (val != null) setState(() => compressionType = val);
                    },
                    showSelectedSubtitle: true,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Status / Progress Bar Capsule
        StatusProgressBar(
          isProcessing: _isProcessing,
          progress: _progress,
          stageLabel: 'COMPRESS & CONVERT',
          detailText:
              '$selectedFormat • Target ${_targetKbController.text.trim().isEmpty ? '200' : _targetKbController.text.trim()} KB',
          completedItems: _completedItems,
          totalItems: _totalItems,
          idleMessage: _selectedFiles.isEmpty
              ? 'Pilih file untuk memulai kompresi'
              : '${_selectedFiles.length} file siap dikompresi ke ${_targetKbController.text} KB',
          processingMessage:
              _processingMessage ?? 'Mengompresi ke format $selectedFormat...',
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
}
