import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../shared/widgets/app_action_button.dart';
import '../../../../shared/widgets/app_toast.dart';
import '../../../../shared/widgets/custom_dropdown.dart';
import '../../../../shared/widgets/file_type_badge.dart';
import '../../../../shared/widgets/save_folder_dialog.dart';
import '../../../../shared/widgets/status_progress_bar.dart';
import 'ai_model_scale_dropdown.dart';
import 'media_file_dropzone_box.dart';

class UpscaleAiView extends StatefulWidget {
  const UpscaleAiView({super.key});

  @override
  State<UpscaleAiView> createState() => _UpscaleAiViewState();
}

class _UpscaleAiViewState extends State<UpscaleAiView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();

  String get selectedFormat => _appState.upscaleFormat;
  set selectedFormat(String val) => _appState.setUpscaleOptions(format: val);

  String get selectedModel => _appState.upscaleModel;
  set selectedModel(String val) => _appState.setUpscaleOptions(model: val);

  int get selectedScale => _appState.upscaleScale;
  List<String> get availableModels => _appState.availableUpscaleModels;
  Map<String, int> get modelScales => _appState.upscaleModelScales;

  List<MediaFileEntry> get _selectedEntries => _appState.upscaleEntries;
  List<String> get _selectedFiles => _appState.upscaleFiles;
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
      label: 'images and pdf',
      extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'pdf'],
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
      _appState.addUpscaleEntries(entries);
    }
  }

  void _removeFile(int index) {
    _appState.removeUpscaleFile(index);
  }

  Future<void> _startProcess() async {
    if (_isProcessing) return;
    if (_selectedEntries.isEmpty) {
      AppToast.showWarning(
        context,
        title: 'Belum Ada Gambar',
        message: 'Pilih setidaknya satu file gambar terlebih dahulu!',
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
          'Meningkatkan resolusi AI ${entriesSnapshot.length} file ($selectedModel • ${selectedScale}x)...';
    });

    try {
      final batchResult = await _backend.compressBatch(
        entries: entriesSnapshot,
        action: 'upscale_ai',
        targetFormat: selectedFormat,
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: selectedModel,
        scale: selectedScale,
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
            customSuffix: 'upscaled',
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
            '${batchResult.files.length} file output selesai di-upscale (${selectedScale}x • $selectedFormat)';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });

      final outputItems = batchResult.files
          .map(
            (sf) => SaveOutputItem(
              sourceFileName: sf.sourceFileName,
              outputFileName: sf.suggestedFileName,
              taskType: 'Upscale AI',
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
        taskTitle: 'Upscale AI ($selectedModel • ${selectedScale}x)',
        summaryNote:
            'Model AI: $selectedModel (${selectedScale}x) • Format Output: $selectedFormat • Akselerasi GPU: ${_appState.enableGpuAcceleration ? "Aktif" : "Non-aktif"}',
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (savedFolder) {
          if (!mounted) return;
          AppToast.showSuccess(
            context,
            title: 'Upscale AI Berhasil',
            badgeLabel: '${selectedScale}x $selectedFormat',
            message:
                '${entriesSnapshot.length} file berhasil ditingkatkan ($selectedModel • ${selectedScale}x).',
            folderPath: savedFolder,
          );
          if (_appState.autoClearQueue) {
            _appState.clearUpscaleFiles();
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
        message: 'Proses Upscale AI dibatalkan oleh pengguna.',
        source: 'CONVERTER',
      );
      AppToast.showWarning(
        context,
        title: 'Upscale AI Dibatalkan',
        message: 'Proses Upscale AI dibatalkan.',
      );
    } catch (e) {
      if (!mounted) return;
      _processStopwatch.stop();
      setState(() {
        _isProcessing = false;
        _hasError = true;
        _wasCancelled = false;
        _lastElapsed = _processStopwatch.elapsed;
        _errorMessage = 'Upscale AI gagal: $e';
        _processingMessage = null;
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'ERROR',
        message: 'Upscale AI gagal: $e',
        source: 'CONVERTER',
      );
      AppToast.showError(
        context,
        title: 'Upscale AI Gagal',
        message: 'Upscale AI gagal: $e',
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
    _appState.clearUpscaleFiles();
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
            contextTitle: 'Upscale AI',
            selectedCountLabel: '${_selectedFiles.length} File Gambar Terpilih',
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
                cardColor: Color(0xFFC62828),
                textColor: Colors.white,
              ),
            ],
            emptyTitle: 'Seret atau klik untuk memilih file',
            emptySubtitle:
                'Tingkatkan resolusi gambar tanpa kehilangan ketajaman (Super Resolution AI)',
            onPickFiles: _pickFiles,
            onRemoveFile: _removeFile,
            onClearAll: () => _appState.clearUpscaleFiles(),
          ),
        ),
        const SizedBox(height: 12),

        // Row with Target Format and Model AI
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
            const SizedBox(width: 14),
            Expanded(
              child: AiModelScaleDropdown(
                height: 44,
                models: availableModels,
                selectedModel: selectedModel,
                modelScales: modelScales,
                onModelSelected: (val) => selectedModel = val,
                onModelScaleChanged: (model, scale) =>
                    _appState.setUpscaleModelScale(model, scale),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Status / Progress Bar Capsule
        StatusProgressBar(
          isProcessing: _isProcessing,
          progress: _progress,
          stageLabel: 'UPSCALE AI',
          detailText: '$selectedModel (${selectedScale}x) • $selectedFormat',
          completedItems: _completedItems,
          totalItems: _totalItems,
          idleMessage: _selectedFiles.isEmpty
              ? 'Pilih gambar untuk memulai peningkatan resolusi AI'
              : '${_selectedFiles.length} gambar siap diproses menggunakan $selectedModel (${selectedScale}x)',
          processingMessage:
              _processingMessage ??
              'Meningkatkan resolusi AI ($selectedModel • ${selectedScale}x)...',
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
