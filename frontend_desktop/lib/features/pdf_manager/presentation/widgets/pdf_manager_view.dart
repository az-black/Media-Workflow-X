import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../core/services/pdf_inspector_service.dart';
import '../../../../shared/widgets/app_action_button.dart';
import '../../../../shared/widgets/app_toast.dart';
import '../../../../shared/widgets/dashed_container.dart';
import '../../../../shared/widgets/save_folder_dialog.dart';
import '../../../../shared/widgets/status_progress_bar.dart';
import 'merge_pool_view.dart';
import 'pdf_card_components.dart';
import 'reorder_pool_view.dart';
import 'split_pool_view.dart';

export '../../../../core/models/pdf_models.dart';

class PdfManagerView extends StatefulWidget {
  final ValueChanged<String>? onNavigateToPool;

  const PdfManagerView({
    super.key,
    this.onNavigateToPool,
  });

  @override
  State<PdfManagerView> createState() => _PdfManagerViewState();
}

class _PdfManagerViewState extends State<PdfManagerView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  final Set<String> _inspectingSlotIds = {};
  final Stopwatch _processStopwatch = Stopwatch();
  BackendCancellationToken? _cancelToken;

  bool get _isProcessing => _appState.isPdfProcessing;
  double get _progress => _appState.pdfProgress;
  String get _statusMessage => _appState.pdfStatusMessage;
  set _statusMessage(String val) => _appState.setPdfProcessing(
        isProcessing: _appState.isPdfProcessing,
        message: val,
      );

  PdfViewMode get _currentViewMode => _appState.pdfViewMode;
  set _currentViewMode(PdfViewMode mode) => _appState.setPdfViewMode(mode);

  int get _activePoolIndex => _appState.activePdfPoolIndex;
  set _activePoolIndex(int idx) =>
      _appState.setActivePdfPool(idx, _appState.activePdfSlotIndex);

  int get _activeSlotIndex => _appState.activePdfSlotIndex;
  set _activeSlotIndex(int idx) =>
      _appState.setActivePdfPool(_appState.activePdfPoolIndex, idx);

  PoolSectionData? get _activePool =>
      (_activePoolIndex >= 0 && _activePoolIndex < _pools.length)
          ? _pools[_activePoolIndex]
          : (_pools.isNotEmpty ? _pools[0] : null);

  List<PoolSectionData> get _pools => _appState.pdfPools;

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

  void _updateInheritedSlots() {
    _appState.updatePdfInheritedSlots();
  }

  void _reorderSlotInPool(int poolIndex, int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final pool = _pools[poolIndex];
      final movedSlot = pool.slots.removeAt(oldIndex);
      pool.slots.insert(newIndex, movedSlot);
      _updateInheritedSlots();
    });
  }

  void _reorderPools(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final movedPool = _pools.removeAt(oldIndex);
      _pools.insert(newIndex, movedPool);
      _updateInheritedSlots();
    });

    AppToast.showInfo(
      context,
      title: 'Pipeline Diperbarui',
      message:
          'Urutan pipeline pool diperbarui: ${_pools.map((p) => p.title).join(' ➔ ')}',
      duration: const Duration(seconds: 2),
    );
  }

  void _transferSlotBetweenPools(
    int sourcePoolIdx,
    int sourceSlotIdx,
    int targetPoolIdx,
    int targetSlotIdx,
  ) {
    if (sourcePoolIdx == targetPoolIdx) return;
    final sourceSlot = _pools[sourcePoolIdx].slots[sourceSlotIdx];
    final fileName = sourceSlot.fileName;

    setState(() {
      final targetPool = _pools[targetPoolIdx];
      if (sourceSlot.hasFile) {
        if (targetSlotIdx < targetPool.slots.length &&
            !targetPool.slots[targetSlotIdx].isInherited &&
            !targetPool.slots[targetSlotIdx].hasFile) {
          targetPool.slots[targetSlotIdx].fileName = sourceSlot.fileName;
          targetPool.slots[targetSlotIdx].filePath = sourceSlot.filePath;
          targetPool.slots[targetSlotIdx].pageCount = sourceSlot.pageCount;
          targetPool.slots[targetSlotIdx].pageRotations =
              Map<int, int>.from(sourceSlot.pageRotations);
          targetPool.slots[targetSlotIdx].label =
              targetPool.labelForSlot(targetPool.slots[targetSlotIdx]);
        } else {
          targetPool.slots.add(
            PoolSlot(
              id: UniqueKey().toString(),
              label: targetPool.defaultSlotLabel,
              fileName: sourceSlot.fileName,
              filePath: sourceSlot.filePath,
              pageCount: sourceSlot.pageCount,
              pageRotations: Map<int, int>.from(sourceSlot.pageRotations),
            ),
          );
        }
        _updateInheritedSlots();
      }
    });

    if (fileName != null) {
      AppToast.showSuccess(
        context,
        title: 'File Disalin',
        message:
            'File "$fileName" disalin dari ${_pools[sourcePoolIdx].title} ke ${_pools[targetPoolIdx].title}',
        duration: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _pickFileForSlot(int poolIndex, int slotIndex) async {
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'pdf',
      extensions: <String>['pdf'],
    );

    final List<XFile> files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );

    if (files.isEmpty) return;

    final updatedSlots = <PoolSlot>[];
    setState(() {
      final pool = _pools[poolIndex];
      // Isi slot yang diklik dengan file pertama
      pool.slots[slotIndex].fileName = files[0].name;
      pool.slots[slotIndex].filePath = files[0].path;
      pool.slots[slotIndex].pageCount = null;
      pool.slots[slotIndex].pageRotations.clear();
      updatedSlots.add(pool.slots[slotIndex]);
      _inspectingSlotIds.add(pool.slots[slotIndex].id);

      // Jika memilih banyak file sekaligus, isi slot kosong berikutnya atau tambahkan slot baru
      for (int i = 1; i < files.length; i++) {
        final nextIdx = slotIndex + i;
        if (nextIdx < pool.slots.length &&
            !pool.slots[nextIdx].isInherited &&
            !pool.slots[nextIdx].hasFile) {
          pool.slots[nextIdx].fileName = files[i].name;
          pool.slots[nextIdx].filePath = files[i].path;
          pool.slots[nextIdx].pageCount = null;
          pool.slots[nextIdx].pageRotations.clear();
          updatedSlots.add(pool.slots[nextIdx]);
          _inspectingSlotIds.add(pool.slots[nextIdx].id);
        } else {
          final addedSlot = PoolSlot(
            id: UniqueKey().toString(),
            label: pool.defaultSlotLabel,
            fileName: files[i].name,
            filePath: files[i].path,
          );
          pool.slots.add(addedSlot);
          updatedSlots.add(addedSlot);
          _inspectingSlotIds.add(addedSlot.id);
        }
      }

      if (!_isProcessing) {
        _appState.setPdfProcessing(
          isProcessing: false,
          progress: 0.0,
          message: files.length == 1
              ? 'Memuat & memindai halaman "${files[0].name}"...'
              : 'Memuat & memindai ${files.length} file PDF...',
          completedSteps: 0,
          totalSteps: 0,
          clearElapsed: true,
          clearStartedAt: true,
          hasError: false,
          wasCancelled: false,
        );
      }
      _updateInheritedSlots();
    });

    // Baca jumlah halaman PDF sebenarnya di latar belakang secara paralel terbatas (4 per batch)
    final inspector = PdfInspectorService();
    const int batchSize = 4;
    for (int start = 0; start < updatedSlots.length; start += batchSize) {
      if (!mounted) break;
      final end = (start + batchSize < updatedSlots.length)
          ? start + batchSize
          : updatedSlots.length;
      await Future.wait([
        for (int i = start; i < end; i++)
          () async {
            final slot = updatedSlots[i];
            final picked = files[i];
            try {
              final info = await inspector.inspectFile(
                fileName: picked.name,
                filePath: picked.path,
              );
              if (!mounted) return;
              if (slot.filePath == picked.path && slot.fileName == picked.name) {
                slot.pageCount = info.pageCount;
              }
            } finally {
              _inspectingSlotIds.remove(slot.id);
            }
          }(),
      ]);
      if (mounted) {
        setState(() => _updateInheritedSlots());
      }
    }
    if (mounted) {
      setState(() {
        if (!_isProcessing && _inspectingSlotIds.isEmpty) {
          _statusMessage = 'Siap! ${files.length} file PDF berhasil dimuat';
        }
      });
    }

    if (mounted) {
      AppToast.showSuccess(
        context,
        title: 'File Ditambahkan',
        badgeLabel: 'PDF',
        message: files.length == 1
            ? 'File "${files[0].name}" berhasil ditambahkan ke ${_pools[poolIndex].slots[slotIndex].label}!'
            : '${files.length} file PDF berhasil ditambahkan ke ${_pools[poolIndex].title}',
        duration: const Duration(seconds: 2),
      );
    }
  }

  void _addSlotToPool(int poolIndex) {
    setState(() {
      final pool = _pools[poolIndex];
      pool.slots.add(
        PoolSlot(
          id: UniqueKey().toString(),
          label: pool.defaultSlotLabel,
        ),
      );
      _updateInheritedSlots();
    });

    AppToast.showInfo(
      context,
      title: 'Kotak Baru Ditambahkan',
      message:
          'Kotak baru (${_pools[poolIndex].defaultSlotLabel}) berhasil ditambahkan',
      duration: const Duration(milliseconds: 1400),
    );
  }

  void _deleteSlot(int poolIndex, int slotIndex) {
    final pool = _pools[poolIndex];
    if (slotIndex < 0 || slotIndex >= pool.slots.length) return;

    final slot = pool.slots[slotIndex];
    if (slot.isInherited) return;

    final normalSlots = pool.slots.where((s) => !s.isInherited).toList();
    final isFirstNormalSlot = normalSlots.isNotEmpty && normalSlots.first == slot;

    // Jika ini adalah kotak nomor 1:
    // Kotak TIDAK boleh hilang, tetapi file di dalamnya dihilangkan!
    if (isFirstNormalSlot) {
      final oldFileName = slot.fileName;
      setState(() {
        slot.fileName = null;
        slot.filePath = null;
        slot.pageRange = null;
        slot.pageCount = null;
        slot.pageRotations.clear();
        slot.label = pool.defaultSlotLabel;
        _updateInheritedSlots();
      });

      AppToast.showInfo(
        context,
        title: 'File Dihapus dari Kotak',
        message: oldFileName != null && oldFileName.isNotEmpty
            ? 'File "$oldFileName" berhasil dihilangkan dari kotak nomor 1.'
            : 'Kotak nomor 1 berhasil dikosongkan.',
        duration: const Duration(milliseconds: 1500),
      );
      return;
    }

    // Untuk kotak nomor 2 dan seterusnya: hapus kotaknya
    setState(() {
      pool.slots.removeAt(slotIndex);
      _updateInheritedSlots();
    });

    AppToast.showWarning(
      context,
      title: 'Kotak Dihapus',
      message: 'Kotak berhasil dihapus.',
      duration: const Duration(milliseconds: 1200),
    );
  }

  void _showInheritedFilesDialog(int poolIndex, PoolSlot slot) {
    final previousPool = poolIndex > 0 ? _pools[poolIndex - 1] : null;
    final inheritedFiles = slot.inheritedFiles;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.primaryCyan, width: 1.5),
        ),
        title: Row(
          children: [
            const Icon(Icons.layers_rounded, color: AppColors.primaryCyan),
            const SizedBox(width: 8),
            Text(
              slot.label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                previousPool != null
                    ? 'File yang diwariskan dari "${previousPool.title}" ke "${_pools[poolIndex].title}" untuk digabungkan:'
                    : 'File dari pool diatas:',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              if (inheritedFiles.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.info_outline, color: Colors.amber, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Belum ada file di pool diatas. Pilih file pada slot di pool atas untuk otomatis menggabungkannya ke pool ini.',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: inheritedFiles.length,
                    separatorBuilder: (_, _) =>
                        const Divider(color: Colors.white12, height: 8),
                    itemBuilder: (context, idx) {
                      return Row(
                        children: [
                          const Icon(
                            Icons.picture_as_pdf,
                            color: AppColors.primaryCyan,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              inheritedFiles[idx],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  AppColors.primaryCyan.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'Dari Atas',
                              style: TextStyle(
                                color: AppColors.primaryCyan,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Tutup',
              style: TextStyle(
                color: AppColors.primaryCyan,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _changePoolType(int poolIndex, String newType) {
    setState(() {
      final pool = _pools[poolIndex];
      pool.title = newType;
      // Perbarui label seluruh kotak non-inherited agar mengikuti jenis pool terbaru
      pool.syncSlotLabelsToType();
      _updateInheritedSlots();
    });

    AppToast.showInfo(
      context,
      title: 'Tipe Pool Diubah',
      message: 'Pool #${poolIndex + 1} diubah menjadi $newType',
      duration: const Duration(milliseconds: 1400),
    );
  }

  void _addNewPool() {
    setState(() {
      final previousPool = _pools.isNotEmpty ? _pools.last : null;
      String nextTitle = 'Merge Pool';
      String nextSlotLabel = 'Merge Number';

      if (previousPool != null) {
        if (previousPool.title == 'Split Pool' ||
            previousPool.title == 'Split Separate Pool') {
          nextTitle = 'Reorder Pool';
          nextSlotLabel = 'Order Number';
        } else if (previousPool.title == 'Reorder Pool') {
          nextTitle = 'Merge Pool';
          nextSlotLabel = 'Merge Number';
        } else {
          nextTitle = 'Reorder Pool';
          nextSlotLabel = 'Order Number';
        }
      }

      final newPool = PoolSectionData(
        id: UniqueKey().toString(),
        title: nextTitle,
        slots: [
          if (previousPool != null)
            PoolSlot(
              id: UniqueKey().toString(),
              label: '${previousPool.title} File',
              isInherited: true,
              inheritedFiles: previousPool.getAllFileNames(),
              inheritedFileRefs: previousPool.getAllFileRefs(),
            ),
          PoolSlot(
            id: UniqueKey().toString(),
            label: nextSlotLabel,
          ),
        ],
      );
      _pools.add(newPool);
      _updateInheritedSlots();
    });

    AppToast.showSuccess(
      context,
      title: 'Target Pool Ditambahkan',
      message: 'Target pool baru berhasil ditambahkan!',
      duration: const Duration(seconds: 2),
    );
  }

  void _removePool(int poolIndex) {
    if (_pools.length <= 1) return;
    setState(() {
      _pools.removeAt(poolIndex);
      _updateInheritedSlots();
    });

    AppToast.showWarning(
      context,
      title: 'Pool Dihapus',
      message: 'Pool berhasil dihapus',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _startProcess() async {
    if (_isProcessing) return;

    final allFiles = <String>[];
    for (final pool in _pools) {
      allFiles.addAll(pool.getAllFileNames());
    }

    if (allFiles.isEmpty) {
      AppToast.showWarning(
        context,
        title: 'Belum Ada File PDF',
        message:
            'Silakan pilih file PDF pada slot (+) terlebih dahulu sebelum memulai proses.',
      );
      return;
    }

    final poolsSnapshot = List<PoolSectionData>.from(_pools);
    final pipelineDesc =
        poolsSnapshot.map((p) => p.title.replaceAll(' Pool', '')).join(' ➔ ');
    final token = BackendCancellationToken();
    _cancelToken = token;
    _processStopwatch
      ..reset()
      ..start();

    _appState.setPdfProcessing(
      isProcessing: true,
      progress: 0.08,
      message: 'Memulai proses pipeline PDF ($pipelineDesc)...',
      completedSteps: 0,
      totalSteps: poolsSnapshot.length,
      clearElapsed: true,
      startedAt: DateTime.now(),
      hasError: false,
      wasCancelled: false,
    );

    try {
      final batchResult = await _backend.executePdfWorkflow(
        pools: poolsSnapshot,
        taskModeLabel: 'PDF Manager ($pipelineDesc)',
        outputSuffix: 'workflow',
        timeoutSeconds: _appState.engineTimeoutSeconds,
        cancelToken: token,
        onProgress: (stepIdx, totalSteps, msg) {
          if (!mounted) return;
          final frac = totalSteps > 0
              ? (0.15 + 0.78 * (stepIdx / totalSteps)).clamp(0.15, 0.94)
              : 0.5;
          _appState.setPdfProcessing(
            isProcessing: true,
            progress: frac,
            message: msg,
            completedSteps: stepIdx,
            totalSteps: totalSteps,
          );
        },
      );

      if (!mounted) {
        _processStopwatch.stop();
        await batchResult.cleanupStaging();
        return;
      }

      _processStopwatch.stop();
      final elapsed = _processStopwatch.elapsed;
      final finalTotal = _appState.pdfTotalSteps > 0
          ? _appState.pdfTotalSteps
          : poolsSnapshot.length;
      if (identical(_cancelToken, token)) _cancelToken = null;
      _appState.setPdfProcessing(
        isProcessing: false,
        progress: 1.0,
        message:
            'Workflow selesai! ${batchResult.files.length} file hasil siap disimpan.',
        completedSteps: finalTotal,
        totalSteps: finalTotal,
        elapsedDuration: elapsed,
        clearStartedAt: true,
        hasError: false,
        wasCancelled: false,
      );

      final summaryLines = <String>[];
      for (int i = 0; i < poolsSnapshot.length; i++) {
        final pool = poolsSnapshot[i];
        final files = pool.getAllFileNames();
        summaryLines.add(
          '${i + 1}. ${pool.title}: ${files.isEmpty ? "Mengalirkan dari pool atas" : "${files.length} file (${files.join(", ")})"}',
        );
      }

      final outputItems = batchResult.files
          .map(
            (sf) => SaveOutputItem(
              sourceFileName: sf.sourceFileName,
              outputFileName: sf.suggestedFileName,
              taskType: 'PDF Manager ($pipelineDesc)',
              targetFormat: sf.targetFormat.toUpperCase(),
              engineUsed: sf.engineUsed,
              originalSize: BackendService.formatBytes(sf.originalBytes),
              resultSize: BackendService.formatBytes(sf.resultBytes),
              durationMs: sf.durationMs,
              stagedFilePath:
                  sf.stagedFilePath.trim().isEmpty ? null : sf.stagedFilePath,
              sourceGroupName: sf.groupFileName,
            ),
          )
          .toList();

      final askEachTime = _appState.askSaveFolderEachTime;
      final savedFolder = await SaveDestinationHelper.handleProcessCompletion(
        context,
        taskTitle: 'PDF Manager Workflow ($pipelineDesc)',
        summaryNote:
            'Alur penggabungan file antar-pool telah selesai diproses (${outputItems.length} file hasil):\n${summaryLines.join('\n')}',
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (folder) {
          if (!mounted) return;
          _appState.setPdfProcessing(
            isProcessing: false,
            message: 'Selesai! Hasil workflow disimpan di: $folder',
          );
          AppToast.showSuccess(
            context,
            title: 'Workflow PDF Selesai',
            badgeLabel: 'PDF',
            message:
                '${outputItems.length} file hasil workflow ($pipelineDesc) telah disimpan.',
            folderPath: folder,
          );
        },
      );

      if (savedFolder != null && !askEachTime && mounted) {
        _showProcessSuccessDialog(savedFolder);
      }
    } on BackendCancelledException {
      if (!mounted) return;
      _processStopwatch.stop();
      if (identical(_cancelToken, token)) _cancelToken = null;
      _appState.setPdfProcessing(
        isProcessing: false,
        message: 'Proses pipeline dibatalkan oleh pengguna.',
        elapsedDuration: _processStopwatch.elapsed,
        clearStartedAt: true,
        wasCancelled: true,
        hasError: false,
      );
      _appState.addSystemLog(
        level: 'WARN',
        message: 'Pipeline PDF Manager dibatalkan oleh pengguna.',
        source: 'PIPELINE',
      );
      AppToast.showWarning(
        context,
        title: 'Pipeline Dibatalkan',
        message: 'Proses pipeline PDF dibatalkan.',
      );
    } catch (e) {
      if (!mounted) return;
      _processStopwatch.stop();
      if (identical(_cancelToken, token)) _cancelToken = null;
      _appState.setPdfProcessing(
        isProcessing: false,
        message: 'Gagal menjalankan pipeline PDF: $e',
        elapsedDuration: _processStopwatch.elapsed,
        clearStartedAt: true,
        hasError: true,
        wasCancelled: false,
      );
      _appState.addSystemLog(
        level: 'ERROR',
        message: 'PDF Manager Workflow gagal: $e',
        source: 'PIPELINE',
      );
      AppToast.showError(
        context,
        title: 'Workflow PDF Gagal',
        message: 'Proses PDF Manager gagal: $e',
      );
    }
  }

  void _cancelProcess() {
    if (_isProcessing) {
      _cancelToken?.cancel();
      _cancelToken = null;
      _processStopwatch.stop();
      _appState.setPdfProcessing(
        isProcessing: false,
        message: 'Proses pipeline dibatalkan oleh pengguna.',
        elapsedDuration: _processStopwatch.elapsed,
        clearStartedAt: true,
        wasCancelled: true,
        hasError: false,
      );
      AppToast.showWarning(
        context,
        title: 'Pipeline Dibatalkan',
        message: 'Proses pipeline PDF dibatalkan.',
      );
      return;
    }

    _processStopwatch.reset();
    setState(() {
      for (final pool in _pools) {
        for (final slot in pool.slots) {
          slot.fileName = null;
          slot.filePath = null;
          slot.pageCount = null;
          slot.pageRange = null;
          slot.pageRotations.clear();
          slot.inheritedPageRotations.clear();
        }
      }
      _updateInheritedSlots();
    });
    _appState.setPdfProcessing(
      isProcessing: false,
      progress: 0.0,
      message: 'Pilih file pada slot (+) untuk memulai workflow',
      completedSteps: 0,
      totalSteps: 0,
      clearElapsed: true,
      clearStartedAt: true,
      hasError: false,
      wasCancelled: false,
    );

    AppToast.showWarning(
      context,
      title: 'Antrean Dibersihkan',
      message: 'Seluruh antrean file pool telah dibersihkan.',
    );
  }

  void _showProcessSuccessDialog(String savedFolder) {
    Offset dragOffset = Offset.zero;
    bool isDragging = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          void onPanUpdate(DragUpdateDetails details) {
            setDialogState(() {
              final newOffset = dragOffset + details.delta;
              final size = MediaQuery.maybeOf(context)?.size;
              if (size != null && size.width > 0 && size.height > 0) {
                final maxDx = (size.width / 2) - 80;
                final minDx = -maxDx;
                final maxDy = (size.height / 2) - 60;
                final minDy = -((size.height / 2) - 40);
                dragOffset = Offset(
                  newOffset.dx.clamp(minDx, maxDx),
                  newOffset.dy.clamp(minDy, maxDy),
                );
              } else {
                dragOffset = newOffset;
              }
            });
          }

          return Transform.translate(
            offset: dragOffset,
            child: AlertDialog(
              backgroundColor: AppColors.cardBackground,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: isDragging
                      ? AppColors.primaryCyan
                      : AppColors.primaryCyan.withValues(alpha: 0.85),
                  width: isDragging ? 2.4 : 2,
                ),
              ),
              title: MouseRegion(
                cursor: isDragging
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () =>
                      setDialogState(() => dragOffset = Offset.zero),
                  onPanStart: (_) =>
                      setDialogState(() => isDragging = true),
                  onPanUpdate: onPanUpdate,
                  onPanEnd: (_) =>
                      setDialogState(() => isDragging = false),
                  onPanCancel: () =>
                      setDialogState(() => isDragging = false),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: Color(0xFF00E676), size: 28),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Workflow Berhasil Dieksekusi!',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message:
                            'Tahan dan geser untuk memindahkan dialog\n(Klik dua kali untuk kembalikan ke tengah)',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDragging
                                ? AppColors.primaryCyan.withValues(alpha: 0.25)
                                : Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isDragging
                                  ? AppColors.primaryCyan
                                  : AppColors.primaryCyan.withValues(alpha: 0.35),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.drag_indicator_rounded,
                                size: 15,
                                color: isDragging
                                    ? AppColors.primaryCyan
                                    : AppColors.primaryCyan.withValues(alpha: 0.85),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'Geser',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: isDragging
                                      ? AppColors.primaryCyan
                                      : AppColors.primaryCyan.withValues(alpha: 0.85),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tersimpan otomatis ke folder: $savedFolder',
                      style: const TextStyle(
                        color: AppColors.primaryCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Alur penggabungan file antar-pool telah selesai diproses:',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    ...List.generate(_pools.length, (idx) {
                      final pool = _pools[idx];
                      final files = pool.getAllFileNames();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              Text(
                                '${idx + 1}. ${pool.title}:',
                                style: const TextStyle(
                                  color: AppColors.primaryCyan,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  files.isEmpty
                                      ? 'Tidak ada file tambahan'
                                      : '${files.length} file tergabung (${files.join(", ")})',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    'Selesai',
                    style: TextStyle(
                      color: AppColors.primaryCyan,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openPoolDetail(int poolIndex, int slotIndex) {
    final pool = _pools[poolIndex];
    widget.onNavigateToPool?.call(pool.title);
    setState(() {
      _activePoolIndex = poolIndex;
      _activeSlotIndex = slotIndex;
      switch (pool.title) {
        case 'Split Pool':
          _currentViewMode = PdfViewMode.splitPool;
          break;
        case 'Split Separate Pool':
          _currentViewMode = PdfViewMode.splitSeparatePool;
          break;
        case 'Reorder Pool':
          _currentViewMode = PdfViewMode.reorderPool;
          break;
        case 'Merge Pool':
          _currentViewMode = PdfViewMode.mergePool;
          break;
        default:
          _currentViewMode = PdfViewMode.splitPool;
          break;
      }
    });
  }

  void _switchDetailPool(String newTitle) {
    setState(() {
      final idx = _pools.indexWhere((p) => p.title == newTitle);
      if (idx != -1) {
        _activePoolIndex = idx;
        _activeSlotIndex = 0;
      } else if (_activePool != null) {
        _activePool!.title = newTitle;
        _activePool!.syncSlotLabelsToType();
        _updateInheritedSlots();
      }
      switch (newTitle) {
        case 'Split Pool':
          _currentViewMode = PdfViewMode.splitPool;
          break;
        case 'Split Separate Pool':
          _currentViewMode = PdfViewMode.splitSeparatePool;
          break;
        case 'Reorder Pool':
          _currentViewMode = PdfViewMode.reorderPool;
          break;
        case 'Merge Pool':
          _currentViewMode = PdfViewMode.mergePool;
          break;
        default:
          _currentViewMode = PdfViewMode.splitPool;
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_currentViewMode) {
      case PdfViewMode.splitPool:
        return SplitPoolView(
          key: ValueKey('split_${_activePoolIndex}_0'),
          title: 'Split Pool',
          initialMode: 0,
          poolIndex: _activePoolIndex,
          onGoToPool: () => setState(() {
            _updateInheritedSlots();
            _currentViewMode = PdfViewMode.overview;
          }),
          onSwitchPool: _switchDetailPool,
          initialCardIndex: _activeSlotIndex,
          poolSlots: _activePool?.slots ?? [],
          onSlotsChanged: () => setState(() => _updateInheritedSlots()),
        );
      case PdfViewMode.splitSeparatePool:
        return SplitPoolView(
          key: ValueKey('split_${_activePoolIndex}_1'),
          title: 'Split Separate Pool',
          initialMode: 1,
          poolIndex: _activePoolIndex,
          onGoToPool: () => setState(() {
            _updateInheritedSlots();
            _currentViewMode = PdfViewMode.overview;
          }),
          onSwitchPool: _switchDetailPool,
          initialCardIndex: _activeSlotIndex,
          poolSlots: _activePool?.slots ?? [],
          onSlotsChanged: () => setState(() => _updateInheritedSlots()),
        );
      case PdfViewMode.reorderPool:
        return ReorderPoolView(
          key: ValueKey('reorder_$_activePoolIndex'),
          poolIndex: _activePoolIndex,
          onGoToPool: () => setState(() {
            _updateInheritedSlots();
            _currentViewMode = PdfViewMode.overview;
          }),
          onSwitchPool: _switchDetailPool,
          initialCardIndex: _activeSlotIndex,
          poolSlots: _activePool?.slots ?? [],
          onSlotsChanged: () => setState(() => _updateInheritedSlots()),
        );
      case PdfViewMode.mergePool:
        return MergePoolView(
          key: ValueKey('merge_$_activePoolIndex'),
          poolIndex: _activePoolIndex,
          onGoToPool: () => setState(() {
            _updateInheritedSlots();
            _currentViewMode = PdfViewMode.overview;
          }),
          onSwitchPool: _switchDetailPool,
          initialCardIndex: _activeSlotIndex,
          poolSlots: _activePool?.slots ?? [],
          onSlotsChanged: () => setState(() => _updateInheritedSlots()),
        );
      case PdfViewMode.overview:
        return _buildOverview();
    }
  }

  Widget _buildOverview() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          // Dynamic Pool Sections with Drag & Drop Reordering
          ...List.generate(_pools.length, (poolIndex) {
            final pool = _pools[poolIndex];
            return DragTarget<PoolDragData>(
              hitTestBehavior: HitTestBehavior.opaque,
              onWillAcceptWithDetails: (details) =>
                  details.data.poolIndex != poolIndex,
              onAcceptWithDetails: (details) =>
                  _reorderPools(details.data.poolIndex, poolIndex),
              builder: (context, candidateData, rejectedData) {
                final isDropTarget = candidateData.isNotEmpty;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.only(bottom: 12.0),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: isDropTarget
                        ? Border.all(color: AppColors.primaryCyan, width: 2.5)
                        : null,
                    boxShadow: isDropTarget
                        ? [
                            BoxShadow(
                              color:
                                  AppColors.primaryCyan.withValues(alpha: 0.6),
                              blurRadius: 16,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (isDropTarget)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            vertical: 5,
                            horizontal: 12,
                          ),
                          decoration: BoxDecoration(
                            color:
                                AppColors.primaryCyan.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: AppColors.primaryCyan,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.swap_vert_rounded,
                                color: AppColors.primaryCyan,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Lepaskan di sini untuk memindahkan ke Posisi #${poolIndex + 1}',
                                style: const TextStyle(
                                  color: AppColors.primaryCyan,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      _buildPoolSection(
                        poolIndex: poolIndex,
                        pool: pool,
                      ),
                    ],
                  ),
                );
              },
            );
          }),

          const SizedBox(height: 2),

          // Bottom Add Container (+) to add a new pool to pipeline
          Tooltip(
            message: 'Tambah Target Pool Baru',
            child: DashedContainer(
              height: 50,
              width: double.infinity,
              borderRadius: 8,
              borderWidth: 1.5,
              borderColor: AppColors.borderCyan,
              fillColor: AppColors.cardBackground,
              hoverFillColor: AppColors.cardHover,
              onTap: _addNewPool,
              child: const Center(
                child: Icon(Icons.add, color: Colors.white, size: 32),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Status / Progress Bar Capsule
          StatusProgressBar(
            isProcessing: _isProcessing,
            progress: _progress,
            stageLabel: 'PDF MANAGER',
            detailText:
                _pools.map((p) => p.title.replaceAll(' Pool', '')).join(' ➔ '),
            completedItems: _appState.pdfCompletedSteps,
            totalItems: _appState.pdfTotalSteps,
            itemUnitLabel: 'pool',
            idleMessage: _statusMessage,
            processingMessage: _statusMessage,
            completedMessage: _statusMessage,
            hasError: _appState.pdfHasError,
            errorMessage: _statusMessage,
            wasCancelled: _appState.pdfWasCancelled,
            cancelledMessage: _statusMessage,
            elapsedOverride: _appState.pdfElapsedDuration,
            startedAt: _appState.pdfProcessStartedAt,
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
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildPoolSection({
    required int poolIndex,
    required PoolSectionData pool,
  }) {
    final labels = pool.slots.map((s) => s.label).toList();
    final subLabels = pool.slots.map((s) => s.subLabel).toList();
    final fileNames = pool.slots.map((s) => s.fileName).toList();
    final isInheritedList = pool.slots.map((s) => s.isInherited).toList();
    final inheritedCounts =
        pool.slots.map((s) => s.inheritedFiles.length).toList();
    final inheritedFilesList =
        pool.slots.map((s) => s.inheritedFiles).toList();
    final isLoadingList =
        pool.slots.map((s) => _inspectingSlotIds.contains(s.id)).toList();

    return Column(
      children: [
        // Header Bar: Cyan container with Title & Dropdown menu to change type
        Container(
          height: 34,
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.primaryCyan,
            borderRadius: BorderRadius.circular(5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Left: Reorder Handle (⠿ #1) & Quick Move Up/Down (▲/▼)
              if (_pools.length > 1)
                Positioned(
                  left: 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag Handle with Pool Badge
                      Draggable<PoolDragData>(
                        data: PoolDragData(poolIndex: poolIndex),
                        dragAnchorStrategy: childDragAnchorStrategy,
                        feedback: IgnorePointer(
                          child: Material(
                            color: Colors.transparent,
                            child: Opacity(
                              opacity: 0.95,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryCyan,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primaryCyan
                                          .withValues(alpha: 0.6),
                                      blurRadius: 16,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.drag_indicator,
                                      color: Colors.black,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Pool #${poolIndex + 1}: ${pool.title}',
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        childWhenDragging: const Opacity(
                          opacity: 0.3,
                          child: Icon(
                            Icons.drag_indicator,
                            color: Colors.black45,
                            size: 18,
                          ),
                        ),
                        child: Tooltip(
                          message: 'Tahan dan geser untuk mengatur urutan pool',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.drag_indicator,
                                    color: Colors.black87,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '#${poolIndex + 1}',
                                    style: const TextStyle(
                                      color: Colors.black87,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),

                      // Fast 1-Click Move Up Button (▲)
                      if (poolIndex > 0)
                        Tooltip(
                          message: 'Pindah ke atas (Posisi #$poolIndex)',
                          child: InkWell(
                            onTap: () =>
                                _reorderPools(poolIndex, poolIndex - 1),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              child: const Icon(
                                Icons.arrow_drop_up_rounded,
                                color: Colors.black87,
                                size: 20,
                              ),
                            ),
                          ),
                        ),

                      // Fast 1-Click Move Down Button (▼)
                      if (poolIndex < _pools.length - 1)
                        Tooltip(
                          message:
                              'Pindah ke bawah (Posisi #${poolIndex + 2})',
                          child: InkWell(
                            onTap: () =>
                                _reorderPools(poolIndex, poolIndex + 1),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              child: const Icon(
                                Icons.arrow_drop_down_rounded,
                                color: Colors.black87,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

              // Center: PopupMenu to choose Pool Type
              PopupMenuButton<String>(
                tooltip: 'Ubah Jenis Pool',
                color: AppColors.surface,
                position: PopupMenuPosition.under,
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side:
                      const BorderSide(color: AppColors.borderCyan, width: 1.5),
                ),
                onSelected: (newType) => _changePoolType(poolIndex, newType),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'Split Pool',
                    child: Text(
                      'Split Pool',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'Split Separate Pool',
                    child: Text(
                      'Split Separate Pool',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'Reorder Pool',
                    child: Text(
                      'Reorder Pool',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'Merge Pool',
                    child: Text(
                      'Merge Pool',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        pool.title,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.arrow_drop_down,
                        color: Colors.black,
                        size: 24,
                      ),
                    ],
                  ),
                ),
              ),

              // Right: Optional delete button if more than 1 pool exists
              if (_pools.length > 1)
                Positioned(
                  right: 4,
                  child: IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.black87,
                      size: 18,
                    ),
                    splashRadius: 16,
                    tooltip: 'Hapus Pool Ini',
                    onPressed: () => _removePool(poolIndex),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Thumbnail cards row with horizontal scrolling, file slots, and inheritance
        PoolThumbnailRow(
          poolIndex: poolIndex,
          labels: labels,
          subLabels: subLabels,
          selectedIndex: -1,
          fileNames: fileNames,
          isInheritedList: isInheritedList,
          inheritedCounts: inheritedCounts,
          inheritedFilesList: inheritedFilesList,
          isLoadingList: isLoadingList,
          onReorder: (oldIdx, newIdx) =>
              _reorderSlotInPool(poolIndex, oldIdx, newIdx),
          onTransferSlot: _transferSlotBetweenPools,
          onAddTap: () => _addSlotToPool(poolIndex),
          onSelectCard: (slotIndex) {
            final slot = pool.slots[slotIndex];
            if (slot.isInherited) {
              if (slot.resolvedInheritedRefs.isNotEmpty) {
                _openPoolDetail(poolIndex, slotIndex);
              } else {
                _showInheritedFilesDialog(poolIndex, slot);
              }
            } else if (slot.hasFile) {
              _openPoolDetail(poolIndex, slotIndex);
            } else {
              _pickFileForSlot(poolIndex, slotIndex);
            }
          },
          onSelectLabel: (slotIndex) => _openPoolDetail(poolIndex, slotIndex),
          onRemoveCard: (slotIndex) => _deleteSlot(poolIndex, slotIndex),
        ),
      ],
    );
  }
}
