import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../core/services/pdf_inspector_service.dart';
import '../../../../core/services/pdf_render_service.dart';
import '../../../../shared/widgets/app_toast.dart';
import '../../../../shared/widgets/save_folder_dialog.dart';
import '../../../../shared/widgets/status_progress_bar.dart';
import 'pdf_card_components.dart';
import 'pdf_preview_components.dart';

class MergePoolView extends StatefulWidget {
  final int poolIndex;
  final VoidCallback onGoToPool;
  final ValueChanged<String> onSwitchPool;
  final int initialCardIndex;
  final List<PoolSlot> poolSlots;
  final VoidCallback? onSlotsChanged;

  const MergePoolView({
    super.key,
    this.poolIndex = 0,
    required this.onGoToPool,
    required this.onSwitchPool,
    this.initialCardIndex = 0,
    required this.poolSlots,
    this.onSlotsChanged,
  });

  @override
  State<MergePoolView> createState() => _MergePoolViewState();
}

class _MergePoolViewState extends State<MergePoolView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  final PdfInspectorService _inspector = PdfInspectorService();

  late int _selectedCardIndex;
  int _focusedQueueIndex = 0;
  bool _isCombinedPreview = false;

  List<PoolSlot> get _normalSlots =>
      widget.poolSlots.where((s) => !s.isInherited).toList();

  final List<TextEditingController> _mergeControllers = [];
  final Map<String, PdfDocumentInfo> _docCache = {};
  final Set<String> _inspectingKeys = {};
  final ValueNotifier<int> _zoomSyncVersion = ValueNotifier<int>(0);
  bool _isExecuting = false;
  bool _showExecutionStatus = false;
  double _executionProgress = 0.0;
  String? _executionMessage;
  int _executionStep = 0;
  int _executionTotalSteps = 0;
  Duration? _executionElapsed;
  bool _executionHasError = false;
  bool _executionCancelled = false;
  final Stopwatch _executionStopwatch = Stopwatch();
  BackendCancellationToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);

    if (_normalSlots.isEmpty) {
      widget.poolSlots.add(
        PoolSlot(id: UniqueKey().toString(), label: 'Merge File 1'),
      );
    }

    _initControllers();
    _focusQueueForSlot(_selectedCardIndex);
    _ensureQueueDocumentsInspected();
  }

  @override
  void didUpdateWidget(covariant MergePoolView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.poolSlots != widget.poolSlots) {
      if (_normalSlots.isEmpty) {
        widget.poolSlots.add(
          PoolSlot(id: UniqueKey().toString(), label: 'Merge File 1'),
        );
      }
      _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);
      _initControllers();
      _focusQueueForSlot(_selectedCardIndex);
    } else if (oldWidget.initialCardIndex != widget.initialCardIndex) {
      _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);
      _focusQueueForSlot(_selectedCardIndex);
    }
    _ensureQueueDocumentsInspected();
  }

  int _clampCardIndex(int raw) {
    if (widget.poolSlots.isEmpty) return 0;
    return raw.clamp(0, widget.poolSlots.length - 1);
  }

  String _docCacheKey(PoolFileRef ref) =>
      '${ref.filePath ?? ''}|${ref.fileName}';

  List<_MergeQueueEntry> _buildMergeQueue() {
    final queue = <_MergeQueueEntry>[];
    for (int i = 0; i < widget.poolSlots.length; i++) {
      final slot = widget.poolSlots[i];
      if (slot.isInherited) {
        for (final ref in slot.resolvedInheritedRefs) {
          final key = _docCacheKey(ref);
          final cachedDoc = _docCache[key] ??
              _inspector.getCached(
                ref.fileName,
                ref.filePath,
                hintPageCount: ref.pageCount,
              );
          queue.add(
            _MergeQueueEntry(
              ref: ref,
              slotIndex: i,
              isInherited: true,
              doc: cachedDoc,
            ),
          );
        }
      } else if (slot.hasFile) {
        final ref = PoolFileRef(
          fileName: slot.fileName!,
          filePath: slot.filePath,
          pageCount: slot.pageCount,
          pageRange: slot.pageRange,
          sourcePoolTitle: 'Merge Pool',
          pageRotations: Map<int, int>.from(slot.pageRotations),
        );
        final key = _docCacheKey(ref);
        final cachedDoc = _docCache[key] ??
            _inspector.getCached(
              ref.fileName,
              ref.filePath,
              hintPageCount: ref.pageCount,
            );
        queue.add(
          _MergeQueueEntry(
            ref: ref,
            slotIndex: i,
            isInherited: false,
            doc: cachedDoc,
          ),
        );
      }
    }
    return queue;
  }

  void _focusQueueForSlot(int slotIdx) {
    final queue = _buildMergeQueue();
    final matchedIdx = queue.indexWhere((e) => e.slotIndex == slotIdx);
    if (matchedIdx != -1) {
      _focusedQueueIndex = matchedIdx;
      _isCombinedPreview = false;
    } else if (queue.isNotEmpty) {
      _focusedQueueIndex = 0;
    }
  }

  int _getEntryPageRotation(_MergeQueueEntry entry, int pageNumber) {
    if (entry.slotIndex < 0 || entry.slotIndex >= widget.poolSlots.length) {
      return normalizePdfRotation(entry.ref.pageRotations[pageNumber] ?? 0);
    }
    final slot = widget.poolSlots[entry.slotIndex];
    return entry.isInherited
        ? slot.getInheritedPageRotation(entry.ref, pageNumber)
        : slot.getPageRotation(pageNumber);
  }

  PdfPageMeta _entryPageWithRotation(
    _MergeQueueEntry entry,
    PdfPageMeta page,
  ) {
    final deg = _getEntryPageRotation(entry, page.pageNumber);
    return deg == page.normalizedUserRotation
        ? page
        : page.copyWith(userRotation: deg);
  }

  void _applyEntryPageRotation(
    _MergeQueueEntry entry,
    int pageNumber,
    int absDegrees,
  ) {
    if (entry.slotIndex < 0 || entry.slotIndex >= widget.poolSlots.length) {
      return;
    }
    final slot = widget.poolSlots[entry.slotIndex];
    if (entry.isInherited) {
      slot.setInheritedPageRotation(entry.ref, pageNumber, absDegrees);
    } else {
      slot.setPageRotation(pageNumber, absDegrees);
    }
  }

  void _rotateEntryPage(
    _MergeQueueEntry entry,
    int pageNumber,
    int deltaDeg,
  ) {
    setState(() {
      final current = _getEntryPageRotation(entry, pageNumber);
      _applyEntryPageRotation(entry, pageNumber, current + deltaDeg);
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _setEntryPageRotation(
    _MergeQueueEntry entry,
    int pageNumber,
    int absDeg,
  ) {
    setState(() {
      _applyEntryPageRotation(entry, pageNumber, absDeg);
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _rotateEntryAllPages(_MergeQueueEntry entry, int deltaDeg) {
    final total = entry.effectivePageCount;
    setState(() {
      for (int p = 1; p <= total; p++) {
        final current = _getEntryPageRotation(entry, p);
        _applyEntryPageRotation(entry, p, current + deltaDeg);
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _resetEntryRotations(_MergeQueueEntry entry) {
    if (entry.slotIndex < 0 || entry.slotIndex >= widget.poolSlots.length) {
      return;
    }
    final slot = widget.poolSlots[entry.slotIndex];
    setState(() {
      if (entry.isInherited) {
        slot.resetInheritedRotations(entry.ref);
      } else {
        slot.pageRotations.clear();
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  int _countEntryRotatedPages(_MergeQueueEntry entry) {
    final total = entry.effectivePageCount;
    int count = 0;
    for (int p = 1; p <= total; p++) {
      if (_getEntryPageRotation(entry, p) != 0) count++;
    }
    return count;
  }

  void _rotateAllQueuePages(List<_MergeQueueEntry> queue, int deltaDeg) {
    setState(() {
      for (final entry in queue) {
        final total = entry.effectivePageCount;
        for (int p = 1; p <= total; p++) {
          final current = _getEntryPageRotation(entry, p);
          _applyEntryPageRotation(entry, p, current + deltaDeg);
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _resetAllQueueRotations(List<_MergeQueueEntry> queue) {
    setState(() {
      for (final entry in queue) {
        if (entry.slotIndex < 0 || entry.slotIndex >= widget.poolSlots.length) {
          continue;
        }
        final slot = widget.poolSlots[entry.slotIndex];
        if (entry.isInherited) {
          slot.resetInheritedRotations(entry.ref);
        } else {
          slot.pageRotations.clear();
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  int _countQueueRotatedPages(List<_MergeQueueEntry> queue) {
    int count = 0;
    for (final entry in queue) {
      count += _countEntryRotatedPages(entry);
    }
    return count;
  }

  PdfZoomRotateActions _buildEntryRotateZoomActions(_MergeQueueEntry entry) {
    return PdfZoomRotateActions(
      listenable: _zoomSyncVersion,
      getPageRotation: (_, page) =>
          _getEntryPageRotation(entry, page.sourcePageNumber ?? page.pageNumber),
      onRotatePage: (_, page, deltaDeg) => _rotateEntryPage(
        entry,
        page.sourcePageNumber ?? page.pageNumber,
        deltaDeg,
      ),
      onResetPageRotation: (_, page) => _setEntryPageRotation(
        entry,
        page.sourcePageNumber ?? page.pageNumber,
        0,
      ),
    );
  }

  PdfZoomRotateActions _buildCombinedRotateZoomActions(
    List<_MergeQueueEntry> combinedEntries,
    List<int> combinedOrigPageNums,
  ) {
    return PdfZoomRotateActions(
      listenable: _zoomSyncVersion,
      getPageRotation: (index, page) {
        if (index < 0 ||
            index >= combinedEntries.length ||
            index >= combinedOrigPageNums.length) {
          return page.normalizedUserRotation;
        }
        return _getEntryPageRotation(
          combinedEntries[index],
          combinedOrigPageNums[index],
        );
      },
      onRotatePage: (index, _, deltaDeg) {
        if (index < 0 ||
            index >= combinedEntries.length ||
            index >= combinedOrigPageNums.length) {
          return;
        }
        _rotateEntryPage(
          combinedEntries[index],
          combinedOrigPageNums[index],
          deltaDeg,
        );
      },
      onResetPageRotation: (index, _) {
        if (index < 0 ||
            index >= combinedEntries.length ||
            index >= combinedOrigPageNums.length) {
          return;
        }
        _setEntryPageRotation(
          combinedEntries[index],
          combinedOrigPageNums[index],
          0,
        );
      },
    );
  }

  String _summarizeQueueRotations(List<_MergeQueueEntry> queue) {
    final parts = <String>[];
    for (final entry in queue) {
      final total = entry.effectivePageCount;
      final rotatedPages = <String>[];
      for (int p = 1; p <= total; p++) {
        final deg = _getEntryPageRotation(entry, p);
        if (deg != 0) {
          rotatedPages.add('Hal $p: $deg°');
        }
      }
      if (rotatedPages.isNotEmpty) {
        parts.add('${entry.ref.fileName} (${rotatedPages.join(', ')})');
      }
    }
    return parts.join('; ');
  }

  Future<void> _ensureQueueDocumentsInspected() async {
    final queue = _buildMergeQueue();
    if (queue.isEmpty) return;

    final pendingEntries = <_MergeQueueEntry>[];
    for (final entry in queue) {
      final key = _docCacheKey(entry.ref);
      if (entry.doc != null) {
        _docCache[key] = entry.doc!;
        continue;
      }
      if (!_docCache.containsKey(key) && !_inspectingKeys.contains(key)) {
        _inspectingKeys.add(key);
        pendingEntries.add(entry);
      }
    }
    if (pendingEntries.isEmpty) return;

    bool anyUpdated = false;
    bool slotPageCountChanged = false;

    const int batchSize = 4;
    for (int start = 0; start < pendingEntries.length; start += batchSize) {
      if (!mounted) return;
      final end = (start + batchSize < pendingEntries.length)
          ? start + batchSize
          : pendingEntries.length;
      await Future.wait([
        for (int i = start; i < end; i++)
          () async {
            final entry = pendingEntries[i];
            final key = _docCacheKey(entry.ref);
            PdfDocumentInfo info;
            try {
              info = await _inspector.inspectFile(
                fileName: entry.ref.fileName,
                filePath: entry.ref.filePath,
                hintPageCount: entry.ref.pageCount,
              );
            } finally {
              _inspectingKeys.remove(key);
            }
            if (!mounted) return;

            _docCache[key] = info;
            anyUpdated = true;

            if (!entry.isInherited &&
                entry.slotIndex < widget.poolSlots.length) {
              final slot = widget.poolSlots[entry.slotIndex];
              if (slot.hasFile &&
                  slot.fileName == entry.ref.fileName &&
                  slot.filePath == entry.ref.filePath &&
                  slot.pageCount != info.pageCount) {
                slot.pageCount = info.pageCount;
                slotPageCountChanged = true;
              }
            }
          }(),
      ]);
    }

    if (anyUpdated && mounted) {
      setState(() {});
      if (slotPageCountChanged) {
        widget.onSlotsChanged?.call();
      }
    }
  }

  void _initControllers() {
    for (final ctrl in _mergeControllers) {
      ctrl.dispose();
    }
    _mergeControllers.clear();

    for (final slot in _normalSlots) {
      final label = slot.label;
      if (label == 'Number Split' ||
          label == 'Order Number' ||
          label.startsWith('Split ') ||
          label.startsWith('Order ')) {
        slot.label = 'Merge Number';
      }
      final ctrl = TextEditingController(text: slot.fileName ?? '');
      _mergeControllers.add(ctrl);
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    PdfPageZoomDialog.dismissActive();
    _zoomSyncVersion.dispose();
    for (final ctrl in _mergeControllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _addNewMergeSlot() {
    setState(() {
      final nextNum = _normalSlots.length + 1;
      final newSlot = PoolSlot(
        id: UniqueKey().toString(),
        label: 'Merge File $nextNum',
      );
      widget.poolSlots.add(newSlot);
      _mergeControllers.add(TextEditingController());
    });
    widget.onSlotsChanged?.call();
  }

  void _removeMergeSlot(int index) {
    if (index >= _normalSlots.length) return;

    final targetSlot = _normalSlots[index];
    if (index == 0 ||
        widget.poolSlots.indexOf(targetSlot) == _selectedCardIndex) {
      PdfPageZoomDialog.dismissActive();
    }
    final oldFile = targetSlot.fileName;

    setState(() {
      if (index == 0) {
        targetSlot.fileName = null;
        targetSlot.filePath = null;
        targetSlot.pageCount = null;
        targetSlot.pageRotations.clear();
        targetSlot.label = 'Merge File 1';
        if (_mergeControllers.isNotEmpty) {
          _mergeControllers[0].clear();
        }
      } else {
        widget.poolSlots.remove(targetSlot);
        _mergeControllers[index].dispose();
        _mergeControllers.removeAt(index);
        if (_selectedCardIndex >= widget.poolSlots.length) {
          _selectedCardIndex =
              widget.poolSlots.isEmpty ? 0 : widget.poolSlots.length - 1;
        }
      }
      _focusedQueueIndex = 0;
    });
    widget.onSlotsChanged?.call();

    if (oldFile != null && oldFile.isNotEmpty && index == 0 && mounted) {
      AppToast.showInfo(
        context,
        title: 'File Dihapus dari Kotak',
        message: 'File "$oldFile" berhasil dihilangkan dari kotak nomor 1.',
        duration: const Duration(milliseconds: 1500),
      );
    }
  }

  void _onReorderSlot(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final slot = widget.poolSlots.removeAt(oldIndex);
      widget.poolSlots.insert(newIndex, slot);
      _selectedCardIndex = newIndex;
      _syncControllersFromSlots();
      _focusQueueForSlot(newIndex);
    });
    widget.onSlotsChanged?.call();
  }

  void _onReorderNumberRow(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final normalList = _normalSlots;
    if (oldIndex >= normalList.length || newIndex >= normalList.length) return;

    final targetSlot = normalList[oldIndex];
    final destinationSlot = normalList[newIndex];

    final realOldIdx = widget.poolSlots.indexOf(targetSlot);
    final realNewIdx = widget.poolSlots.indexOf(destinationSlot);

    if (realOldIdx != -1 && realNewIdx != -1) {
      setState(() {
        final slot = widget.poolSlots.removeAt(realOldIdx);
        widget.poolSlots.insert(realNewIdx, slot);
        _syncControllersFromSlots();
      });
      widget.onSlotsChanged?.call();
    }
  }

  void _syncControllersFromSlots() {
    final normal = _normalSlots;
    while (_mergeControllers.length < normal.length) {
      _mergeControllers.add(TextEditingController());
    }
    while (_mergeControllers.length > normal.length) {
      _mergeControllers.removeLast().dispose();
    }
    for (int i = 0; i < normal.length; i++) {
      final text = normal[i].fileName ?? '';
      if (_mergeControllers[i].text != text) {
        _mergeControllers[i].text = text;
      }
    }
  }

  void _onRemoveCard(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= widget.poolSlots.length) return;
    final slot = widget.poolSlots[slotIndex];
    if (slot.isInherited) return;

    final normalIdx = _normalSlots.indexOf(slot);
    if (normalIdx != -1) {
      _removeMergeSlot(normalIdx);
    }
  }

  Future<void> _pickFileForRow(int index) async {
    if (index >= _normalSlots.length) return;

    const XTypeGroup typeGroup = XTypeGroup(
      label: 'pdf',
      extensions: <String>['pdf'],
    );
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );
    if (file != null && mounted) {
      PdfPageZoomDialog.dismissActive();
      final targetSlot = _normalSlots[index];
      final newRef = PoolFileRef(
        fileName: file.name,
        filePath: file.path,
        sourcePoolTitle: 'Merge Pool',
      );
      final newKey = _docCacheKey(newRef);
      final cached = _inspector.getCached(file.name, file.path);

      setState(() {
        targetSlot.fileName = file.name;
        targetSlot.filePath = file.path;
        targetSlot.pageCount = cached?.pageCount;
        targetSlot.pageRotations.clear();
        targetSlot.label = file.name;
        _mergeControllers[index].text = file.name;
        _selectedCardIndex = widget.poolSlots.indexOf(targetSlot);
        _isCombinedPreview = false;

        if (cached != null) {
          _docCache[newKey] = cached;
          _inspectingKeys.remove(newKey);
        } else {
          _inspectingKeys.add(newKey);
        }
        _focusQueueForSlot(_selectedCardIndex);
      });
      widget.onSlotsChanged?.call();

      late PdfDocumentInfo info;
      if (cached != null) {
        info = cached;
      } else {
        try {
          info = await _inspector.inspectFile(
            fileName: file.name,
            filePath: file.path,
          );
        } finally {
          _inspectingKeys.remove(newKey);
        }
        if (!mounted) return;
        if (targetSlot.filePath == file.path &&
            targetSlot.fileName == file.name) {
          targetSlot.pageCount = info.pageCount;
          _docCache[newKey] = info;
        }
        _focusQueueForSlot(_selectedCardIndex);
        setState(() {});
        widget.onSlotsChanged?.call();
      }

      if (!mounted) return;
      AppToast.showSuccess(
        context,
        title: 'File Dipilih untuk Merge',
        badgeLabel: '${info.pageCount} HAL',
        message:
            'File "${file.name}" (${info.pageCount} halaman) dipilih untuk Merge File ${index + 1}.',
        duration: const Duration(seconds: 2),
      );
    }
  }

  List<PoolSectionData> _buildEffectiveExecutionPools() {
    final globalPools = _appState.pdfPools;
    if (globalPools.isNotEmpty &&
        widget.poolIndex >= 0 &&
        widget.poolIndex < globalPools.length &&
        identical(globalPools[widget.poolIndex].slots, widget.poolSlots)) {
      final upstream = globalPools.sublist(0, widget.poolIndex);
      final current = PoolSectionData(
        id: globalPools[widget.poolIndex].id,
        title: 'Merge Pool',
        slots: widget.poolSlots,
      );
      return [...upstream, current];
    }
    return [
      PoolSectionData(
        id: 'merge_detail_single',
        title: 'Merge Pool',
        slots: widget.poolSlots,
      ),
    ];
  }

  Future<void> _mergePdf() async {
    if (_isExecuting) return;

    final queue = _buildMergeQueue();
    final normalFiles = _normalSlots
        .map((s) => s.fileName?.trim())
        .where((t) => t != null && t.isNotEmpty)
        .cast<String>()
        .toList();
    final inheritedFiles = widget.poolSlots
        .where((s) => s.isInherited)
        .expand((s) => s.inheritedFiles)
        .toList();
    final allMergeFiles = [...inheritedFiles, ...normalFiles];
    final totalPages = queue.fold<int>(0, (sum, e) => sum + e.effectivePageCount);

    final rotationSummary = _summarizeQueueRotations(queue);
    final baseSummaryText = allMergeFiles.isEmpty
        ? 'Menggabungkan halaman preview menjadi 1 dokumen PDF terpadu.'
        : 'Menggabungkan ${allMergeFiles.length} file PDF ($totalPages total halaman) secara berurutan:\n${allMergeFiles.join(' + ')}';
    final summaryText = rotationSummary.isEmpty
        ? baseSummaryText
        : '$baseSummaryText\nRotasi: $rotationSummary';

    final token = BackendCancellationToken();
    _cancelToken = token;
    final pools = _buildEffectiveExecutionPools();
    _executionStopwatch
      ..reset()
      ..start();
    setState(() {
      _isExecuting = true;
      _showExecutionStatus = true;
      _executionProgress = 0.10;
      _executionStep = 0;
      _executionTotalSteps = pools.length;
      _executionElapsed = null;
      _executionHasError = false;
      _executionCancelled = false;
      _executionMessage = allMergeFiles.isEmpty
          ? 'Menggabungkan halaman PDF...'
          : 'Menggabungkan ${allMergeFiles.length} file PDF ($totalPages halaman)...';
    });

    try {
      final batchResult = await _backend.executePdfWorkflow(
        pools: pools,
        taskModeLabel: 'PDF Manager (Merge)',
        outputSuffix: 'merged',
        timeoutSeconds: _appState.engineTimeoutSeconds,
        cancelToken: token,
        onProgress: (stepIdx, totalSteps, msg) {
          if (!mounted) return;
          final frac = totalSteps > 0
              ? (0.15 + 0.78 * (stepIdx / totalSteps)).clamp(0.15, 0.94)
              : 0.5;
          setState(() {
            _executionProgress = frac;
            _executionStep = stepIdx;
            _executionTotalSteps = totalSteps;
            _executionMessage = msg;
          });
        },
      );

      if (!mounted) {
        _executionStopwatch.stop();
        await batchResult.cleanupStaging();
        return;
      }

      _executionStopwatch.stop();
      setState(() {
        _isExecuting = false;
        _executionProgress = 1.0;
        _executionStep = _executionTotalSteps > 0 ? _executionTotalSteps : pools.length;
        _executionTotalSteps = _executionStep;
        _executionElapsed = _executionStopwatch.elapsed;
        _executionMessage =
            'Merge PDF selesai! ${batchResult.files.length} dokumen terpadu siap disimpan.';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });

      final outputItems = batchResult.files
          .map(
            (sf) => SaveOutputItem(
              sourceFileName: sf.sourceFileName,
              outputFileName: sf.suggestedFileName,
              taskType: 'PDF Manager (Merge)',
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
        taskTitle: 'Merge PDF (${allMergeFiles.length} File • $totalPages Hal)',
        summaryNote: summaryText,
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (savedFolder) {
          if (!mounted) return;
          AppToast.showSuccess(
            context,
            title: 'Merge PDF Selesai',
            badgeLabel: 'MERGE PDF',
            message: allMergeFiles.isEmpty
                ? 'Dokumen PDF terpadu berhasil disimpan.'
                : '${allMergeFiles.length} file PDF ($totalPages hal) berhasil digabung.',
            folderPath: savedFolder,
          );
        },
      );
    } on BackendCancelledException {
      if (!mounted) return;
      _executionStopwatch.stop();
      setState(() {
        _isExecuting = false;
        _executionCancelled = true;
        _executionHasError = false;
        _executionElapsed = _executionStopwatch.elapsed;
        _executionMessage = 'Proses Merge PDF dibatalkan oleh pengguna.';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
    } catch (e) {
      if (!mounted) return;
      _executionStopwatch.stop();
      setState(() {
        _isExecuting = false;
        _executionHasError = true;
        _executionCancelled = false;
        _executionElapsed = _executionStopwatch.elapsed;
        _executionMessage = 'Merge PDF gagal: $e';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'ERROR',
        message: 'Merge PDF gagal: $e',
        source: 'PIPELINE',
      );
      AppToast.showError(
        context,
        title: 'Merge PDF Gagal',
        message: 'Merge PDF gagal: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeIdx = _clampCardIndex(_selectedCardIndex);

    return Column(
      children: [
        // Top Header Dropdown (Merge Pool)
        PoolHeaderDropdown(
          title: 'Merge Pool',
          onSelected: widget.onSwitchPool,
        ),
        const SizedBox(height: 8),

        // Preview Area (Shows First & Last Pages + Total Page Count of Merge Queue)
        Expanded(
          child: DragTarget<SlotDragData>(
            hitTestBehavior: HitTestBehavior.opaque,
            onWillAcceptWithDetails: (details) => true,
            onAcceptWithDetails: (details) {
              if (details.data.slotIndex != _selectedCardIndex ||
                  _isCombinedPreview) {
                PdfPageZoomDialog.dismissActive();
              }
              setState(() {
                _selectedCardIndex = _clampCardIndex(details.data.slotIndex);
                _focusQueueForSlot(_selectedCardIndex);
              });
              _ensureQueueDocumentsInspected();
            },
            builder: (context, candidateData, rejectedData) {
              final isHovered = candidateData.isNotEmpty;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isHovered
                      ? Border.all(color: AppColors.primaryCyan, width: 2.5)
                      : null,
                  boxShadow: isHovered ? AppColors.cyanGlowShadow : null,
                ),
                child: _buildPreviewContent(),
              );
            },
          ),
        ),
        const SizedBox(height: 6),

        // Pool Thumbnail Row: synchronized with widget.poolSlots
        PoolThumbnailRow(
          labels: widget.poolSlots.map((s) => s.label).toList(),
          subLabels: widget.poolSlots.map((s) => s.subLabel).toList(),
          fileNames: widget.poolSlots.map((s) => s.fileName).toList(),
          isInheritedList: widget.poolSlots.map((s) => s.isInherited).toList(),
          inheritedCounts: widget.poolSlots
              .map((s) => s.resolvedInheritedRefs.length)
              .toList(),
          inheritedFilesList:
              widget.poolSlots.map((s) => s.inheritedFiles).toList(),
          isLoadingList: widget.poolSlots.map((s) {
            if (s.isInherited || !s.hasFile) return false;
            final key = '${s.filePath ?? ''}|${s.fileName ?? ''}';
            return _inspectingKeys.contains(key) && !_docCache.containsKey(key);
          }).toList(),
          selectedIndex: safeIdx,
          onReorder: _onReorderSlot,
          onSelectCard: (idx) {
            if (idx != _selectedCardIndex || _isCombinedPreview) {
              PdfPageZoomDialog.dismissActive();
            }
            final slot = widget.poolSlots[idx];
            setState(() {
              _selectedCardIndex = idx;
            });
            if (slot.isInherited || slot.hasFile) {
              setState(() => _focusQueueForSlot(idx));
              _ensureQueueDocumentsInspected();
            } else {
              final normalIdx = _normalSlots.indexOf(slot);
              if (normalIdx != -1) _pickFileForRow(normalIdx);
            }
          },
          onSelectLabel: (idx) {
            if (idx != _selectedCardIndex || _isCombinedPreview) {
              PdfPageZoomDialog.dismissActive();
            }
            setState(() {
              _selectedCardIndex = idx;
              _focusQueueForSlot(idx);
            });
            _ensureQueueDocumentsInspected();
          },
          onRemoveCard: _onRemoveCard,
          onAddTap: _addNewMergeSlot,
        ),
        const SizedBox(height: 6),

        if (_showExecutionStatus) ...[
          StatusProgressBar(
            compact: true,
            isProcessing: _isExecuting,
            progress: _executionProgress,
            stageLabel: 'MERGE POOL',
            completedItems: _executionStep,
            totalItems: _executionTotalSteps,
            itemUnitLabel: 'pool',
            processingMessage: _executionMessage ?? 'Memproses Merge PDF...',
            completedMessage: _executionMessage,
            hasError: _executionHasError,
            errorMessage: _executionMessage,
            wasCancelled: _executionCancelled,
            cancelledMessage: _executionMessage,
            elapsedOverride: _executionElapsed,
            onDismissResult: () =>
                setState(() => _showExecutionStatus = false),
          ),
          const SizedBox(height: 6),
        ],

        // Bottom Controls: Rows (Merge File 1, 2) + Add Merge Number + Actions
        PoolBottomControls(
          prefix: 'Merge File',
          hintText: 'File to Merge',
          addButtonLabel: '+ Add Merge Number',
          isFilePicker: true,
          onPickFileForRow: _pickFileForRow,
          controllers: _mergeControllers,
          onReorderItem: _onReorderNumberRow,
          onAddItem: _addNewMergeSlot,
          onRemoveItem: _removeMergeSlot,
          actionLabel: _isExecuting ? 'Memproses...' : 'Merge PDF',
          onAction: _isExecuting ? () {} : _mergePdf,
          onGoToPool: widget.onGoToPool,
        ),
      ],
    );
  }

  Widget _buildPreviewContent() {
    final queue = _buildMergeQueue();

    if (queue.isEmpty) {
      return PdfEmptySlotPreview(
        title: 'Belum Ada File PDF untuk Di-Merge',
        subtitle:
            'Tambahkan file PDF pada kotak di bawah atau hubungkan dari pool atas untuk menampilkan halaman awal, halaman akhir, dan total halaman merge.',
        isInherited: false,
        onPickFile: () => _pickFileForRow(0),
      );
    }

    final totalMergePages =
        queue.fold<int>(0, (sum, e) => sum + e.effectivePageCount);
    final safeQueueIdx = _focusedQueueIndex.clamp(0, queue.length - 1);
    final focusedEntry = queue[safeQueueIdx];
    final focusedDoc = focusedEntry.resolvedDoc;
    final focusedNormalIdx =
        !focusedEntry.isInherited && focusedEntry.slotIndex < widget.poolSlots.length
            ? _normalSlots.indexOf(widget.poolSlots[focusedEntry.slotIndex])
            : -1;
    final isQueueLoading = _inspectingKeys.isNotEmpty;
    final isCombinedLoading = _isCombinedPreview &&
        queue.any((e) =>
            e.doc == null && _inspectingKeys.contains(_docCacheKey(e.ref)));
    final isFocusedLoading = !_isCombinedPreview &&
        focusedEntry.doc == null &&
        _inspectingKeys.contains(_docCacheKey(focusedEntry.ref));
    final activeRotatedCount = _isCombinedPreview
        ? _countQueueRotatedPages(queue)
        : (isFocusedLoading ? 0 : _countEntryRotatedPages(focusedEntry));

    return Column(
      children: [
        // Top Merge Queue Summary Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.primaryCyan.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Icon(
                          Icons.merge_type_rounded,
                          color: AppColors.primaryCyan,
                          size: 18,
                        ),
                        Text(
                          'Antrean Merge: ${queue.length} File',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: (isQueueLoading
                                    ? AppColors.primaryCyan
                                    : const Color(0xFF00E676))
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: (isQueueLoading
                                      ? AppColors.primaryCyan
                                      : const Color(0xFF00E676))
                                  .withValues(alpha: 0.55),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isQueueLoading) ...[
                                const SizedBox(
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.primaryCyan,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                              ],
                              Text(
                                isQueueLoading
                                    ? 'Memuat ($totalMergePages Hal)...'
                                    : 'Total Merge: $totalMergePages Hal',
                                style: TextStyle(
                                  color: isQueueLoading
                                      ? AppColors.primaryCyan
                                      : const Color(0xFF00E676),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (!_isCombinedPreview) {
                              PdfPageZoomDialog.dismissActive();
                            }
                            setState(() => _isCombinedPreview = true);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: _isCombinedPreview
                                  ? AppColors.primaryCyan
                                  : AppColors.primaryCyan.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppColors.primaryCyan,
                              ),
                            ),
                            child: Text(
                              'Hasil Merge (Hal 1–$totalMergePages)',
                              style: TextStyle(
                                color: _isCombinedPreview
                                    ? Colors.black
                                    : AppColors.primaryCyan,
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PreviewRotateGroup(
                          rotateLeftKey:
                              const Key('merge_rotate_all_left_button'),
                          rotateRightKey:
                              const Key('merge_rotate_all_right_button'),
                          resetRotationKey:
                              const Key('merge_rotate_reset_button'),
                          rotatedCount: activeRotatedCount,
                          leftTooltip: _isCombinedPreview
                              ? 'Putar semua halaman gabungan 90° ke kiri (-90°)'
                              : 'Putar semua halaman ${focusedEntry.ref.fileName} 90° ke kiri (-90°)',
                          rightTooltip: _isCombinedPreview
                              ? 'Putar semua halaman gabungan 90° ke kanan (+90°)'
                              : 'Putar semua halaman ${focusedEntry.ref.fileName} 90° ke kanan (+90°)',
                          resetTooltip: _isCombinedPreview
                              ? 'Reset rotasi seluruh file antrean merge ke 0°'
                              : 'Reset rotasi semua halaman ${focusedEntry.ref.fileName} ke 0°',
                          onRotateLeft: (isCombinedLoading || isFocusedLoading)
                              ? null
                              : () => _isCombinedPreview
                                  ? _rotateAllQueuePages(queue, -90)
                                  : _rotateEntryAllPages(focusedEntry, -90),
                          onRotateRight: (isCombinedLoading || isFocusedLoading)
                              ? null
                              : () => _isCombinedPreview
                                  ? _rotateAllQueuePages(queue, 90)
                                  : _rotateEntryAllPages(focusedEntry, 90),
                          onResetRotation:
                              (!isCombinedLoading &&
                                      !isFocusedLoading &&
                                      activeRotatedCount > 0)
                                  ? () => _isCombinedPreview
                                      ? _resetAllQueueRotations(queue)
                                      : _resetEntryRotations(focusedEntry)
                                  : null,
                        ),
                        if (!_isCombinedPreview && focusedNormalIdx != -1)
                          PreviewHeaderButton(
                            label: 'Ganti File',
                            icon: Icons.swap_horiz_rounded,
                            tooltip: 'Ganti file PDF pada slot ini',
                            onPressed: () => _pickFileForRow(focusedNormalIdx),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 26,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: queue.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, idx) {
                    final item = queue[idx];
                    final isActive = !_isCombinedPreview && idx == safeQueueIdx;
                    final itemPages = item.effectivePageCount;
                    return GestureDetector(
                      onTap: () {
                        if (_isCombinedPreview || idx != safeQueueIdx) {
                          PdfPageZoomDialog.dismissActive();
                        }
                        setState(() {
                          _isCombinedPreview = false;
                          _focusedQueueIndex = idx;
                          _selectedCardIndex = item.slotIndex;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppColors.primaryCyan
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: isActive
                                ? AppColors.primaryCyan
                                : Colors.white24,
                          ),
                        ),
                        child: Text(
                          '#${idx + 1} ${item.ref.fileName} ($itemPages Hal)',
                          style: TextStyle(
                            color: isActive ? Colors.black : Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Side-by-side First Page & Last Page Preview with Center Merge Bridge
        Expanded(
          child: (isCombinedLoading || isFocusedLoading)
              ? PdfLoadingPreview(
                  fileName: _isCombinedPreview
                      ? 'Menggabungkan ${queue.length} File PDF'
                      : focusedEntry.ref.fileName,
                )
              : (_isCombinedPreview
                  ? _buildCombinedStartEndPreview(queue, totalMergePages)
                  : _buildIndividualStartEndPreview(
                      focusedEntry,
                      focusedDoc,
                      safeQueueIdx + 1,
                    )),
        ),
      ],
    );
  }

  Widget _buildIndividualStartEndPreview(
    _MergeQueueEntry entry,
    PdfDocumentInfo doc,
    int queuePosition,
  ) {
    final rotatedPages = doc.pages
        .map((p) => _entryPageWithRotation(entry, p))
        .toList();
    final firstPage = rotatedPages.first;
    final lastPage = rotatedPages.last;
    final rotateActions = _buildEntryRotateZoomActions(entry);

    return Row(
      children: [
        Expanded(
          child: PdfPageSheetCard(
            page: firstPage,
            fileName: doc.fileName,
            filePath: doc.filePath,
            totalPages: doc.pageCount,
            badgeText: 'Halaman Awal • Hal 1',
            badgeColor: AppColors.primaryCyan,
            roleSubtitle: entry.isInherited && entry.ref.sourcePoolTitle.isNotEmpty
                ? '${doc.fileName} (${entry.ref.sourcePoolTitle})'
                : doc.fileName,
            isSelected: true,
            renderQuality: PdfRenderQuality.card,
            onRotateLeft: () =>
                _rotateEntryPage(entry, firstPage.pageNumber, -90),
            onRotateRight: () =>
                _rotateEntryPage(entry, firstPage.pageNumber, 90),
            onZoom: () => PdfPageZoomDialog.show(
              context,
              fileName: doc.fileName,
              filePath: doc.filePath,
              pages: rotatedPages,
              initialIndex: 0,
              fileSizeLabel: doc.formattedFileSize,
              contextTitle: 'Merge File #$queuePosition',
              rotateActions: rotateActions,
            ),
          ),
        ),
        _buildMergeBridgeColumn(
          pageCount: doc.pageCount,
          subtitle: 'File #$queuePosition',
          rangeLabel: 'Hal 1 → Hal ${doc.pageCount}',
        ),
        Expanded(
          child: doc.pageCount == 1
              ? Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.cardBackground,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.filter_1_rounded,
                          color: AppColors.primaryCyan,
                          size: 30,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Dokumen 1 Halaman',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Halaman 1 adalah halaman awal dan akhir file ini.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : PdfPageSheetCard(
                  page: lastPage,
                  fileName: doc.fileName,
                  filePath: doc.filePath,
                  totalPages: doc.pageCount,
                  badgeText: 'Halaman Akhir • Hal ${doc.pageCount}',
                  badgeColor: AppColors.cardBackground,
                  roleSubtitle: doc.fileName,
                  renderQuality: PdfRenderQuality.card,
                  onRotateLeft: () =>
                      _rotateEntryPage(entry, lastPage.pageNumber, -90),
                  onRotateRight: () =>
                      _rotateEntryPage(entry, lastPage.pageNumber, 90),
                  onZoom: () => PdfPageZoomDialog.show(
                    context,
                    fileName: doc.fileName,
                    filePath: doc.filePath,
                    pages: rotatedPages,
                    initialIndex: doc.pageCount - 1,
                    fileSizeLabel: doc.formattedFileSize,
                    contextTitle: 'Merge File #$queuePosition',
                    rotateActions: rotateActions,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCombinedStartEndPreview(
    List<_MergeQueueEntry> queue,
    int totalMergePages,
  ) {
    final firstEntry = queue.first;
    final lastEntry = queue.last;
    final firstDoc = firstEntry.resolvedDoc;
    final lastDoc = lastEntry.resolvedDoc;

    // Bangun daftar halaman virtual gabungan (Hal 1..totalMergePages) untuk fitur Zoom
    final combinedPages = <PdfPageMeta>[];
    final combinedOrigins = <String>[];
    final combinedEntries = <_MergeQueueEntry>[];
    final combinedOrigPageNums = <int>[];
    int globalNum = 1;
    for (int fIdx = 0; fIdx < queue.length; fIdx++) {
      final entry = queue[fIdx];
      final doc = entry.resolvedDoc;
      for (final p in doc.pages) {
        combinedPages.add(
          PdfPageMeta(
            pageNumber: globalNum,
            widthPt: p.widthPt,
            heightPt: p.heightPt,
            rotation: p.rotation,
            userRotation: _getEntryPageRotation(entry, p.pageNumber),
            sourceFilePath: p.sourceFilePath ?? doc.filePath,
            sourcePageNumber: p.sourcePageNumber ?? p.pageNumber,
          ),
        );
        combinedOrigins.add(
          '#${fIdx + 1} ${doc.fileName} (Hal Asli ${p.pageNumber}/${doc.pageCount})',
        );
        combinedEntries.add(entry);
        combinedOrigPageNums.add(p.pageNumber);
        globalNum++;
      }
    }

    final firstCombinedPage = _entryPageWithRotation(
      firstEntry,
      firstDoc.pages.first,
    );
    final lastOrigPage = lastDoc.pages.last;
    final lastCombinedCardPage = PdfPageMeta(
      pageNumber: totalMergePages,
      widthPt: lastOrigPage.widthPt,
      heightPt: lastOrigPage.heightPt,
      rotation: lastOrigPage.rotation,
      userRotation: _getEntryPageRotation(lastEntry, lastOrigPage.pageNumber),
      sourceFilePath: lastOrigPage.sourceFilePath ?? lastDoc.filePath,
      sourcePageNumber: lastOrigPage.sourcePageNumber ?? lastOrigPage.pageNumber,
    );
    final combinedRotateActions = _buildCombinedRotateZoomActions(
      combinedEntries,
      combinedOrigPageNums,
    );

    return Row(
      children: [
        Expanded(
          child: PdfPageSheetCard(
            page: firstCombinedPage,
            fileName: firstDoc.fileName,
            filePath: firstDoc.filePath,
            totalPages: totalMergePages,
            badgeText: 'Awal Merge • Hal 1',
            badgeColor: AppColors.primaryCyan,
            roleSubtitle: '#1 ${firstDoc.fileName} (Hal 1/${firstDoc.pageCount})',
            isSelected: true,
            renderQuality: PdfRenderQuality.card,
            onRotateLeft: () =>
                _rotateEntryPage(firstEntry, firstDoc.pages.first.pageNumber, -90),
            onRotateRight: () =>
                _rotateEntryPage(firstEntry, firstDoc.pages.first.pageNumber, 90),
            onZoom: () => PdfPageZoomDialog.show(
              context,
              fileName: 'Hasil Merge (${queue.length} File)',
              filePath: firstDoc.filePath,
              pages: combinedPages,
              initialIndex: 0,
              contextTitle: 'Hasil Merge • $totalMergePages Halaman',
              pageSubtitleBuilder: (idx, _) =>
                  idx < combinedOrigins.length ? combinedOrigins[idx] : '',
              rotateActions: combinedRotateActions,
            ),
          ),
        ),
        _buildMergeBridgeColumn(
          pageCount: totalMergePages,
          subtitle: '${queue.length} File',
          rangeLabel: 'Hal 1 → Hal $totalMergePages',
        ),
        Expanded(
          child: PdfPageSheetCard(
            page: lastCombinedCardPage,
            fileName: lastDoc.fileName,
            filePath: lastDoc.filePath,
            totalPages: totalMergePages,
            badgeText: 'Akhir Merge • Hal $totalMergePages',
            badgeColor: AppColors.cardBackground,
            roleSubtitle:
                '#${queue.length} ${lastDoc.fileName} (Hal ${lastDoc.pageCount}/${lastDoc.pageCount})',
            renderQuality: PdfRenderQuality.card,
            onRotateLeft: () =>
                _rotateEntryPage(lastEntry, lastOrigPage.pageNumber, -90),
            onRotateRight: () =>
                _rotateEntryPage(lastEntry, lastOrigPage.pageNumber, 90),
            onZoom: () => PdfPageZoomDialog.show(
              context,
              fileName: 'Hasil Merge (${queue.length} File)',
              filePath: lastDoc.filePath,
              pages: combinedPages,
              initialIndex:
                  combinedPages.isNotEmpty ? combinedPages.length - 1 : 0,
              contextTitle: 'Hasil Merge • $totalMergePages Halaman',
              pageSubtitleBuilder: (idx, _) =>
                  idx < combinedOrigins.length ? combinedOrigins[idx] : '',
              rotateActions: combinedRotateActions,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMergeBridgeColumn({
    required int pageCount,
    required String subtitle,
    required String rangeLabel,
  }) {
    return Container(
      width: 92,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.primaryCyan.withValues(alpha: 0.45),
        ),
      ),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.arrow_forward_rounded,
                color: AppColors.primaryCyan,
                size: 20,
              ),
              const SizedBox(height: 4),
              Text(
                '$pageCount Hal',
                style: const TextStyle(
                  color: Color(0xFF00E676),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                rangeLabel,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MergeQueueEntry {
  final PoolFileRef ref;
  final int slotIndex;
  final bool isInherited;
  final PdfDocumentInfo? doc;

  const _MergeQueueEntry({
    required this.ref,
    required this.slotIndex,
    required this.isInherited,
    this.doc,
  });

  int get effectivePageCount {
    if (doc != null) return doc!.pageCount;
    if (ref.pageCount != null && ref.pageCount! > 0) return ref.pageCount!;
    return 1;
  }

  PdfDocumentInfo get resolvedDoc {
    if (doc != null) return doc!;
    final count = effectivePageCount;
    return PdfDocumentInfo(
      fileName: ref.fileName,
      filePath: ref.filePath,
      pageCount: count,
      pages: List<PdfPageMeta>.generate(
        count,
        (i) => PdfPageMeta(
          pageNumber: i + 1,
          sourceFilePath: ref.filePath,
          sourcePageNumber: i + 1,
        ),
      ),
    );
  }
}
