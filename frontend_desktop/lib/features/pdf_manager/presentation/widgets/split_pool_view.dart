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

class SplitPoolView extends StatefulWidget {
  final String title;
  final int initialMode;
  final int poolIndex;
  final VoidCallback onGoToPool;
  final ValueChanged<String> onSwitchPool;
  final int initialCardIndex;
  final List<PoolSlot> poolSlots;
  final VoidCallback? onSlotsChanged;

  const SplitPoolView({
    super.key,
    this.title = 'Split Pool',
    this.initialMode = 0,
    this.poolIndex = 0,
    required this.onGoToPool,
    required this.onSwitchPool,
    this.initialCardIndex = 0,
    required this.poolSlots,
    this.onSlotsChanged,
  });

  @override
  State<SplitPoolView> createState() => _SplitPoolViewState();
}

class _SplitPoolViewState extends State<SplitPoolView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  final PdfInspectorService _inspector = PdfInspectorService();

  late int _selectedMode;
  late int _selectedCardIndex;
  int _selectedInheritedFileIndex = 0;

  List<PoolSlot> get _normalSlots =>
      widget.poolSlots.where((s) => !s.isInherited).toList();

  final List<TextEditingController> _splitControllers = [];
  final Map<String, PdfDocumentInfo> _docCache = {};
  final Map<String, Set<int>> _slotSelectedPages = {};
  final ValueNotifier<int> _zoomSyncVersion = ValueNotifier<int>(0);
  String? _loadingKey;
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
    _selectedMode = widget.initialMode;
    _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);

    if (_normalSlots.isEmpty) {
      widget.poolSlots.add(
        PoolSlot(id: UniqueKey().toString(), label: 'Number Split'),
      );
    }

    _initControllers();
    _ensureActiveDocumentInspected();
  }

  @override
  void didUpdateWidget(covariant SplitPoolView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialMode != widget.initialMode) {
      _selectedMode = widget.initialMode;
    }
    if (oldWidget.poolSlots != widget.poolSlots) {
      if (_normalSlots.isEmpty) {
        widget.poolSlots.add(
          PoolSlot(id: UniqueKey().toString(), label: 'Number Split'),
        );
      }
      _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);
      _selectedInheritedFileIndex = 0;
      _initControllers();
    } else if (oldWidget.initialCardIndex != widget.initialCardIndex) {
      _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);
      _selectedInheritedFileIndex = 0;
    }
    _ensureActiveDocumentInspected();
  }

  int _clampCardIndex(int raw) {
    if (widget.poolSlots.isEmpty) return 0;
    return raw.clamp(0, widget.poolSlots.length - 1);
  }

  PoolSlot? get _activeSlot {
    if (widget.poolSlots.isEmpty) return null;
    final safeIdx = _clampCardIndex(_selectedCardIndex);
    return widget.poolSlots[safeIdx];
  }

  PoolFileRef? get _activeFileRef {
    final slot = _activeSlot;
    if (slot == null) return null;
    if (slot.isInherited) {
      final refs = slot.resolvedInheritedRefs;
      if (refs.isEmpty) return null;
      final idx = _selectedInheritedFileIndex.clamp(0, refs.length - 1);
      return refs[idx];
    }
    if (slot.hasFile) {
      return PoolFileRef(
        fileName: slot.fileName!,
        filePath: slot.filePath,
        pageCount: slot.pageCount,
        pageRange: slot.pageRange,
        sourcePoolTitle: widget.title,
        pageRotations: Map<int, int>.from(slot.pageRotations),
      );
    }
    return null;
  }

  String _docCacheKey(PoolFileRef ref) =>
      '${ref.filePath ?? ''}|${ref.fileName}';

  String _selectionStateKey(PoolSlot slot, PoolFileRef ref) =>
      '${slot.id}|${_docCacheKey(ref)}';

  int? _resolveTargetNormalIndex(PoolSlot activeSlot) {
    if (_normalSlots.isEmpty) return null;
    if (!activeSlot.isInherited) {
      final idx = _normalSlots.indexOf(activeSlot);
      return idx != -1 ? idx : null;
    }
    if (_selectedInheritedFileIndex >= 0 &&
        _selectedInheritedFileIndex < _normalSlots.length) {
      return _selectedInheritedFileIndex;
    }
    return 0;
  }

  Future<void> _ensureActiveDocumentInspected() async {
    final slot = _activeSlot;
    final ref = _activeFileRef;
    if (slot == null || ref == null) return;

    final key = _docCacheKey(ref);
    if (!_docCache.containsKey(key)) {
      final cached = _inspector.getCached(
        ref.fileName,
        ref.filePath,
        hintPageCount: ref.pageCount,
      );
      if (cached != null) {
        _docCache[key] = cached;
      }
    }

    if (_docCache.containsKey(key)) {
      _ensureDefaultSelectionInitialized(slot, ref, _docCache[key]!);
      return;
    }

    if (_loadingKey == key) return;
    _loadingKey = key;

    PdfDocumentInfo info;
    try {
      info = await _inspector.inspectFile(
        fileName: ref.fileName,
        filePath: ref.filePath,
        hintPageCount: ref.pageCount,
      );
    } finally {
      if (_loadingKey == key) {
        _loadingKey = null;
      }
    }

    if (!mounted) return;
    _docCache[key] = info;
    _ensureDefaultSelectionInitialized(slot, ref, info);

    bool slotPageCountUpdated = false;
    if (!slot.isInherited &&
        slot.hasFile &&
        slot.fileName == ref.fileName &&
        slot.filePath == ref.filePath &&
        slot.pageCount != info.pageCount) {
      slot.pageCount = info.pageCount;
      slotPageCountUpdated = true;
    }

    setState(() {});
    if (slotPageCountUpdated) {
      widget.onSlotsChanged?.call();
    }
  }

  void _ensureDefaultSelectionInitialized(
    PoolSlot slot,
    PoolFileRef ref,
    PdfDocumentInfo doc,
  ) {
    final selKey = _selectionStateKey(slot, ref);
    if (_slotSelectedPages.containsKey(selKey)) return;

    String? rangeText;
    if (!slot.isInherited) {
      rangeText = ref.pageRange ?? slot.pageRange;
    } else if (_selectedInheritedFileIndex >= 0 &&
        _selectedInheritedFileIndex < _normalSlots.length) {
      rangeText = _normalSlots[_selectedInheritedFileIndex].pageRange ?? ref.pageRange;
    } else {
      rangeText = ref.pageRange;
    }

    if (rangeText != null && rangeText.trim().isNotEmpty) {
      final parsed =
          PdfInspectorService.parsePageRangeSpec(rangeText, doc.pageCount);
      _slotSelectedPages[selKey] = parsed.toSet();
      return;
    }
    _slotSelectedPages[selKey] = <int>{};
  }

  void _initControllers() {
    for (final ctrl in _splitControllers) {
      ctrl.dispose();
    }
    _splitControllers.clear();

    for (final slot in _normalSlots) {
      final label = slot.label;
      if (label == 'Order Number' ||
          label == 'Merge Number' ||
          label.startsWith('Order ') ||
          label.startsWith('Merge File')) {
        final trimmed = slot.pageRange?.trim() ?? '';
        slot.label = trimmed.isNotEmpty ? 'Split $trimmed' : 'Number Split';
      }
      final ctrl = TextEditingController(text: slot.pageRange ?? '');
      _splitControllers.add(ctrl);
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    PdfPageZoomDialog.dismissActive();
    _zoomSyncVersion.dispose();
    for (final ctrl in _splitControllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged(int index, String newText) {
    if (index >= _normalSlots.length) return;
    final trimmed = newText.trim();
    final targetSlot = _normalSlots[index];
    setState(() {
      targetSlot.pageRange = trimmed.isEmpty ? null : trimmed;
      targetSlot.label = trimmed.isEmpty ? 'Number Split' : 'Split $trimmed';

      if (targetSlot.hasFile) {
        final ref = PoolFileRef(
          fileName: targetSlot.fileName!,
          filePath: targetSlot.filePath,
          pageCount: targetSlot.pageCount,
          pageRange: targetSlot.pageRange,
          sourcePoolTitle: widget.title,
        );
        final key = _docCacheKey(ref);
        final doc = _docCache[key] ??
            _inspector.getCached(
              ref.fileName,
              ref.filePath,
              hintPageCount: ref.pageCount,
            );
        if (doc != null) {
          _docCache[key] = doc;
          _slotSelectedPages[_selectionStateKey(targetSlot, ref)] = trimmed.isEmpty
              ? <int>{}
              : PdfInspectorService.parsePageRangeSpec(trimmed, doc.pageCount)
                  .toSet();
        }
      }

      final active = _activeSlot;
      final activeRef = _activeFileRef;
      if (active != null &&
          active.isInherited &&
          activeRef != null &&
          _resolveTargetNormalIndex(active) == index) {
        final key = _docCacheKey(activeRef);
        final doc = _docCache[key] ??
            _inspector.getCached(
              activeRef.fileName,
              activeRef.filePath,
              hintPageCount: activeRef.pageCount,
            );
        if (doc != null) {
          _docCache[key] = doc;
          _slotSelectedPages[_selectionStateKey(active, activeRef)] =
              trimmed.isEmpty
                  ? <int>{}
                  : PdfInspectorService.parsePageRangeSpec(
                      trimmed,
                      doc.pageCount,
                    ).toSet();
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _addNewSplitSlot() {
    setState(() {
      final newSlot = PoolSlot(
        id: UniqueKey().toString(),
        label: 'Number Split',
      );
      widget.poolSlots.add(newSlot);
      _splitControllers.add(TextEditingController());
    });
    widget.onSlotsChanged?.call();
  }

  void _removeSplitSlot(int index) {
    if (index == 0) {
      PdfPageZoomDialog.dismissActive();
      final oldFile = _normalSlots[0].fileName;
      final slotId = _normalSlots[0].id;
      setState(() {
        _normalSlots[0].fileName = null;
        _normalSlots[0].filePath = null;
        _normalSlots[0].pageRange = null;
        _normalSlots[0].pageCount = null;
        _normalSlots[0].pageRotations.clear();
        _normalSlots[0].label = 'Number Split';
        _slotSelectedPages.removeWhere((k, _) => k.startsWith('$slotId|'));
        if (_splitControllers.isNotEmpty) {
          _splitControllers[0].clear();
        }
      });
      widget.onSlotsChanged?.call();
      if (oldFile != null && oldFile.isNotEmpty) {
        AppToast.showInfo(
          context,
          title: 'File Dihapus dari Kotak',
          message: 'File "$oldFile" berhasil dihilangkan dari kotak nomor 1.',
          duration: const Duration(milliseconds: 1500),
        );
      }
      return;
    }

    final targetSlot = _normalSlots[index];
    if (targetSlot == _activeSlot) {
      PdfPageZoomDialog.dismissActive();
    }
    setState(() {
      final realRemovedIdx = widget.poolSlots.indexOf(targetSlot);
      widget.poolSlots.remove(targetSlot);
      _slotSelectedPages.removeWhere(
        (k, _) => k.startsWith('${targetSlot.id}|'),
      );
      _splitControllers[index].dispose();
      _splitControllers.removeAt(index);
      if (realRemovedIdx != -1 && _selectedCardIndex >= widget.poolSlots.length) {
        _selectedCardIndex =
            widget.poolSlots.isEmpty ? 0 : widget.poolSlots.length - 1;
      }
    });
    widget.onSlotsChanged?.call();
    _ensureActiveDocumentInspected();
  }

  void _onReorderSlot(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final slot = widget.poolSlots.removeAt(oldIndex);
      widget.poolSlots.insert(newIndex, slot);
      _selectedCardIndex = newIndex;
      _syncControllersFromSlots();
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
    while (_splitControllers.length < normal.length) {
      _splitControllers.add(TextEditingController());
    }
    while (_splitControllers.length > normal.length) {
      _splitControllers.removeLast().dispose();
    }
    for (int i = 0; i < normal.length; i++) {
      final text = normal[i].pageRange ?? '';
      if (_splitControllers[i].text != text) {
        _splitControllers[i].text = text;
      }
    }
  }

  void _onRemoveCard(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= widget.poolSlots.length) return;
    final slot = widget.poolSlots[slotIndex];
    if (slot.isInherited) return;

    final normalIdx = _normalSlots.indexOf(slot);
    if (normalIdx != -1) {
      _removeSplitSlot(normalIdx);
    }
  }

  Future<void> _pickFileForSlot(int slotIndex) async {
    if (slotIndex < 0 || slotIndex >= widget.poolSlots.length) return;
    final targetSlot = widget.poolSlots[slotIndex];
    if (targetSlot.isInherited) return;

    const XTypeGroup typeGroup = XTypeGroup(
      label: 'pdf',
      extensions: <String>['pdf'],
    );
    final XFile? file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[typeGroup],
    );
    if (file != null && mounted) {
      PdfPageZoomDialog.dismissActive();
      final hadPreviousFile = targetSlot.hasFile;
      final newRef = PoolFileRef(
        fileName: file.name,
        filePath: file.path,
        pageRange: hadPreviousFile ? null : targetSlot.pageRange,
        sourcePoolTitle: widget.title,
      );
      final newKey = _docCacheKey(newRef);
      final cached = _inspector.getCached(file.name, file.path);

      setState(() {
        targetSlot.fileName = file.name;
        targetSlot.filePath = file.path;
        targetSlot.pageCount = cached?.pageCount;
        targetSlot.pageRotations.clear();
        if (hadPreviousFile) {
          targetSlot.pageRange = null;
          targetSlot.label = 'Number Split';
          final normalIdx = _normalSlots.indexOf(targetSlot);
          if (normalIdx != -1 && normalIdx < _splitControllers.length) {
            _splitControllers[normalIdx].clear();
          }
        }
        _slotSelectedPages.removeWhere(
          (k, _) => k.startsWith('${targetSlot.id}|'),
        );
        _selectedCardIndex = slotIndex;
        _selectedInheritedFileIndex = 0;

        if (cached != null) {
          _docCache[newKey] = cached;
          _loadingKey = null;
          _ensureDefaultSelectionInitialized(targetSlot, newRef, cached);
        } else {
          _loadingKey = newKey;
        }
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
          if (_loadingKey == newKey) {
            _loadingKey = null;
          }
        }
        if (!mounted) return;
        if (targetSlot.filePath == file.path &&
            targetSlot.fileName == file.name) {
          targetSlot.pageCount = info.pageCount;
          final resolvedRef = PoolFileRef(
            fileName: file.name,
            filePath: file.path,
            pageCount: info.pageCount,
            pageRange: targetSlot.pageRange,
            sourcePoolTitle: widget.title,
          );
          _docCache[newKey] = info;
          _ensureDefaultSelectionInitialized(targetSlot, resolvedRef, info);
        }
        setState(() {});
        widget.onSlotsChanged?.call();
      }

      if (!mounted) return;
      AppToast.showSuccess(
        context,
        title: 'PDF Siap Dipreview',
        badgeLabel: '${info.pageCount} HAL',
        message: 'File "${file.name}" (${info.pageCount} halaman) siap dipreview.',
      );
    }
  }

  void _updatePageSelectionAndSync(
    PoolSlot activeSlot,
    String selKey,
    Set<int> nextSelection,
  ) {
    final compacted =
        PdfInspectorService.formatCompactPageRanges(nextSelection.toList());
    final targetNormalIdx = _resolveTargetNormalIndex(activeSlot);

    setState(() {
      _slotSelectedPages[selKey] = nextSelection;
      if (targetNormalIdx != null && targetNormalIdx < _normalSlots.length) {
        _normalSlots[targetNormalIdx].pageRange =
            compacted.isEmpty ? null : compacted;
        _normalSlots[targetNormalIdx].label =
            compacted.isEmpty ? 'Number Split' : 'Split $compacted';
        if (targetNormalIdx < _splitControllers.length) {
          _splitControllers[targetNormalIdx].text = compacted;
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  PdfZoomSplitActions _buildSplitZoomActions(
    PoolSlot slot,
    PdfDocumentInfo doc,
    String selKey,
  ) {
    return PdfZoomSplitActions(
      listenable: _zoomSyncVersion,
      getSelectedPages: () =>
          Set<int>.from(_slotSelectedPages[selKey] ?? const <int>{}),
      onTogglePage: (int pageNumber) {
        final current = Set<int>.from(_slotSelectedPages[selKey] ?? <int>{});
        if (current.contains(pageNumber)) {
          current.remove(pageNumber);
        } else {
          current.add(pageNumber);
        }
        _updatePageSelectionAndSync(slot, selKey, current);
      },
      onSelectAll: () => _updatePageSelectionAndSync(
        slot,
        selKey,
        Set<int>.from(List<int>.generate(doc.pageCount, (i) => i + 1)),
      ),
      onClearSelection: () => _updatePageSelectionAndSync(
        slot,
        selKey,
        <int>{},
      ),
    );
  }

  int _getPageRotation(PoolSlot slot, PoolFileRef ref, int pageNumber) {
    return slot.isInherited
        ? slot.getInheritedPageRotation(ref, pageNumber)
        : slot.getPageRotation(pageNumber);
  }

  PdfPageMeta _pageWithRotation(
    PoolSlot slot,
    PoolFileRef ref,
    PdfPageMeta page,
  ) {
    final deg = _getPageRotation(slot, ref, page.pageNumber);
    return deg == page.normalizedUserRotation
        ? page
        : page.copyWith(userRotation: deg);
  }

  int _countRotatedPages(PoolSlot slot, PoolFileRef ref, int pageCount) {
    int count = 0;
    for (int p = 1; p <= pageCount; p++) {
      if (_getPageRotation(slot, ref, p) != 0) count++;
    }
    return count;
  }

  void _rotatePage(
    PoolSlot slot,
    PoolFileRef ref,
    int pageNumber,
    int deltaDeg,
  ) {
    setState(() {
      final current = _getPageRotation(slot, ref, pageNumber);
      final next = normalizePdfRotation(current + deltaDeg);
      if (slot.isInherited) {
        slot.setInheritedPageRotation(ref, pageNumber, next);
      } else {
        slot.setPageRotation(pageNumber, next);
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _rotateAllPages(
    PoolSlot slot,
    PoolFileRef ref,
    int pageCount,
    int deltaDeg,
  ) {
    setState(() {
      for (int p = 1; p <= pageCount; p++) {
        final current = _getPageRotation(slot, ref, p);
        final next = normalizePdfRotation(current + deltaDeg);
        if (slot.isInherited) {
          slot.setInheritedPageRotation(ref, p, next);
        } else {
          slot.setPageRotation(p, next);
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _resetAllRotations(PoolSlot slot, PoolFileRef ref) {
    setState(() {
      if (slot.isInherited) {
        slot.resetInheritedRotations(ref);
      } else {
        slot.pageRotations.clear();
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  PdfZoomRotateActions _buildSplitRotateZoomActions(
    PoolSlot slot,
    PoolFileRef ref,
  ) {
    return PdfZoomRotateActions(
      listenable: _zoomSyncVersion,
      getPageRotation: (_, page) => _getPageRotation(slot, ref, page.pageNumber),
      onRotatePage: (_, page, deltaDeg) =>
          _rotatePage(slot, ref, page.pageNumber, deltaDeg),
      onResetPageRotation: (_, page) {
        setState(() {
          if (slot.isInherited) {
            slot.setInheritedPageRotation(ref, page.pageNumber, 0);
          } else {
            slot.setPageRotation(page.pageNumber, 0);
          }
        });
        _zoomSyncVersion.value++;
        widget.onSlotsChanged?.call();
      },
    );
  }

  String _summarizeSlotRotations() {
    final parts = <String>[];
    for (final s in _normalSlots) {
      if (!s.hasFile) continue;
      final rotated = s.pageRotations.entries
          .where((e) => normalizePdfRotation(e.value) != 0)
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      if (rotated.isNotEmpty) {
        parts.add(
          '${s.fileName} (${rotated.map((e) => 'Hal ${e.key}: ${normalizePdfRotation(e.value)}°').join(', ')})',
        );
      }
    }
    for (final s in widget.poolSlots.where((s) => s.isInherited)) {
      for (final ref in s.resolvedInheritedRefs) {
        final key = PoolSlot.fileRotationKey(ref);
        final merged = <int, int>{
          ...ref.pageRotations,
          ...?s.inheritedPageRotations[key],
        }..removeWhere((_, deg) => normalizePdfRotation(deg) == 0);
        if (merged.isNotEmpty) {
          final entries = merged.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          parts.add(
            '${ref.fileName} (${entries.map((e) => 'Hal ${e.key}: ${normalizePdfRotation(e.value)}°').join(', ')})',
          );
        }
      }
    }
    return parts.join('; ');
  }

  int _countTotalSelectedPages() {
    int total = 0;
    for (final s in widget.poolSlots) {
      if (s.isInherited) {
        for (final r in s.resolvedInheritedRefs) {
          final sel = _slotSelectedPages[_selectionStateKey(s, r)];
          if (sel != null) {
            total += sel.length;
          } else {
            final spec = r.pageRange?.trim() ?? s.pageRange?.trim() ?? '';
            final countHint = r.pageCount ?? 0;
            if (spec.isNotEmpty && countHint > 0) {
              total +=
                  PdfInspectorService.parsePageRangeSpec(spec, countHint).length;
            }
          }
        }
      } else if (s.hasFile) {
        final r = PoolFileRef(
          fileName: s.fileName!,
          filePath: s.filePath,
          pageCount: s.pageCount,
          pageRange: s.pageRange,
          sourcePoolTitle: widget.title,
        );
        final selKey = _selectionStateKey(s, r);
        final sel = _slotSelectedPages[selKey];
        if (sel != null) {
          total += sel.length;
        } else if (s.pageRange != null && s.pageRange!.trim().isNotEmpty) {
          final docKey = _docCacheKey(r);
          final cachedDoc = _docCache[docKey] ??
              _inspector.getCached(
                r.fileName,
                r.filePath,
                hintPageCount: r.pageCount,
              );
          final maxPages = cachedDoc?.pageCount ?? s.pageCount ?? 0;
          if (maxPages > 0) {
            total += PdfInspectorService.parsePageRangeSpec(
              s.pageRange!.trim(),
              maxPages,
            ).length;
          }
        }
      }
    }
    return total;
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
        title: widget.title,
        slots: widget.poolSlots,
      );
      return [...upstream, current];
    }
    return [
      PoolSectionData(
        id: 'split_detail_single',
        title: widget.title,
        slots: widget.poolSlots,
      ),
    ];
  }

  Future<void> _splitPdf() async {
    if (_isExecuting) return;

    final rangesList = _normalSlots
        .map((s) => s.pageRange?.trim())
        .where((t) => t != null && t.isNotEmpty)
        .cast<String>()
        .toList();
    final ranges = rangesList.join(', ');

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
      _executionMessage = ranges.isEmpty
          ? 'Memproses ${widget.title} (Semua Halaman)...'
          : 'Memproses ${widget.title} (Hal $ranges)...';
    });

    try {
      final batchResult = await _backend.executePdfWorkflow(
        pools: pools,
        taskModeLabel: 'PDF Manager (${widget.title})',
        outputSuffix: 'split',
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
            '${widget.title} selesai! ${batchResult.files.length} file hasil siap disimpan.';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });

      final outputItems = batchResult.files
          .map(
            (sf) => SaveOutputItem(
              sourceFileName: sf.sourceFileName,
              outputFileName: sf.suggestedFileName,
              taskType: 'PDF Manager (${widget.title})',
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

      final selectedPageCount = _countTotalSelectedPages();

      final modeLabel = _selectedMode == 0
          ? 'Mode: Range'
          : 'Mode: Pages ($selectedPageCount halaman dipilih)';
      final rangeSummary =
          ranges.isEmpty ? 'Semua Halaman' : 'Halaman: $ranges';
      final rotationSummary = _summarizeSlotRotations();

      await SaveDestinationHelper.handleProcessCompletion(
        context,
        taskTitle: '${widget.title} ($modeLabel)',
        summaryNote: rotationSummary.isEmpty
            ? '$modeLabel • Target Split: $rangeSummary'
            : '$modeLabel • Target Split: $rangeSummary • Rotasi: $rotationSummary',
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (savedFolder) {
          if (!mounted) return;
          AppToast.showSuccess(
            context,
            title: '${widget.title} Selesai',
            badgeLabel: 'SPLIT PDF',
            message: ranges.isEmpty
                ? 'Pemisahan semua halaman PDF berhasil disimpan.'
                : 'Pemisahan halaman ($ranges) berhasil disimpan.',
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
        _executionMessage = 'Proses ${widget.title} dibatalkan oleh pengguna.';
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
        _executionMessage = '${widget.title} gagal: $e';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'ERROR',
        message: '${widget.title} gagal: $e',
        source: 'PIPELINE',
      );
      AppToast.showError(
        context,
        title: '${widget.title} Gagal',
        message: '${widget.title} gagal: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeIdx = _clampCardIndex(_selectedCardIndex);

    return Column(
      children: [
        // Top Header Dropdown (Split Pool / Split Separate Pool)
        PoolHeaderDropdown(
          title: widget.title,
          onSelected: widget.onSwitchPool,
        ),
        const SizedBox(height: 6),

        // Sub Toggle: Range vs Pages (Segmented Pill)
        Container(
          height: 36,
          width: 260,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            children: [
              _buildModeTab(0, 'Range'),
              _buildModeTab(1, 'Pages'),
            ],
          ),
        ),
        const SizedBox(height: 6),

        // Preview Area (Expanded) - Accepts Slot Drop to preview that file
        Expanded(
          child: DragTarget<SlotDragData>(
            hitTestBehavior: HitTestBehavior.opaque,
            onWillAcceptWithDetails: (details) => true,
            onAcceptWithDetails: (details) {
              setState(() {
                _selectedCardIndex = _clampCardIndex(details.data.slotIndex);
                _selectedInheritedFileIndex = 0;
              });
              _ensureActiveDocumentInspected();
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
            return _loadingKey == key && !_docCache.containsKey(key);
          }).toList(),
          selectedIndex: safeIdx,
          onReorder: _onReorderSlot,
          onSelectCard: (idx) {
            if (idx != _selectedCardIndex) {
              PdfPageZoomDialog.dismissActive();
            }
            final slot = widget.poolSlots[idx];
            setState(() {
              _selectedCardIndex = idx;
              _selectedInheritedFileIndex = 0;
            });
            if (slot.isInherited || slot.hasFile) {
              _ensureActiveDocumentInspected();
            } else {
              _pickFileForSlot(idx);
            }
          },
          onSelectLabel: (idx) {
            if (idx != _selectedCardIndex) {
              PdfPageZoomDialog.dismissActive();
            }
            setState(() {
              _selectedCardIndex = idx;
              _selectedInheritedFileIndex = 0;
            });
            _ensureActiveDocumentInspected();
          },
          onRemoveCard: _onRemoveCard,
          onAddTap: _addNewSplitSlot,
        ),
        const SizedBox(height: 6),

        if (_showExecutionStatus) ...[
          StatusProgressBar(
            compact: true,
            isProcessing: _isExecuting,
            progress: _executionProgress,
            stageLabel: widget.title.toUpperCase(),
            completedItems: _executionStep,
            totalItems: _executionTotalSteps,
            itemUnitLabel: 'pool',
            processingMessage:
                _executionMessage ?? 'Memproses ${widget.title}...',
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

        // Bottom Controls: Rows (Split Number 1, 2) + Add Split Number + Actions
        PoolBottomControls(
          prefix: 'Split Number',
          hintText: 'Pages to Split',
          addButtonLabel: '+ Add Split Number',
          controllers: _splitControllers,
          onTextChanged: _onControllerChanged,
          onReorderItem: _onReorderNumberRow,
          onAddItem: _addNewSplitSlot,
          onRemoveItem: _removeSplitSlot,
          actionLabel: _isExecuting ? 'Memproses...' : 'Split PDF',
          onAction: _isExecuting ? () {} : _splitPdf,
          onGoToPool: widget.onGoToPool,
        ),
      ],
    );
  }

  Widget _buildModeTab(int index, String label) {
    final isSelected = _selectedMode == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedMode = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.primaryCyan : Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewContent() {
    final slot = _activeSlot;
    final ref = _activeFileRef;

    if (slot == null || ref == null) {
      final isInherited = slot?.isInherited ?? false;
      final slotNum = _normalSlots.indexOf(slot ?? PoolSlot(id: '', label: '')) + 1;
      return PdfEmptySlotPreview(
        title: isInherited
            ? 'Slot Pool Atas Belum Memiliki File PDF'
            : 'Slot #${slotNum > 0 ? slotNum : 1} Belum Memiliki File PDF',
        subtitle: isInherited
            ? 'Tambahkan file PDF pada pool sebelumnya di atas untuk menampilkan preview halaman awal/akhir atau semua halaman di sini.'
            : 'Klik untuk memilih file PDF, lalu tampilan otomatis memperlihatkan halaman pertama & terakhir (Range) atau seluruh halaman (Pages).',
        isInherited: isInherited,
        onPickFile:
            isInherited ? null : () => _pickFileForSlot(_clampCardIndex(_selectedCardIndex)),
      );
    }

    final key = _docCacheKey(ref);
    final cachedDoc = _docCache[key] ??
        _inspector.getCached(
          ref.fileName,
          ref.filePath,
          hintPageCount: ref.pageCount,
        );
    if (cachedDoc != null && !_docCache.containsKey(key)) {
      _docCache[key] = cachedDoc;
    }

    final isLoading = cachedDoc == null;
    final doc = cachedDoc ??
        PdfDocumentInfo(
          fileName: ref.fileName,
          filePath: ref.filePath,
          pageCount: (ref.pageCount != null && ref.pageCount! > 0)
              ? ref.pageCount!
              : 1,
          pages: List<PdfPageMeta>.generate(
            (ref.pageCount != null && ref.pageCount! > 0) ? ref.pageCount! : 1,
            (i) => PdfPageMeta(
              pageNumber: i + 1,
              sourceFilePath: ref.filePath,
              sourcePageNumber: i + 1,
            ),
          ),
        );

    final inheritedRefs =
        slot.isInherited ? slot.resolvedInheritedRefs : const <PoolFileRef>[];
    final selKey = _selectionStateKey(slot, ref);
    if (!isLoading) {
      _ensureDefaultSelectionInitialized(slot, ref, doc);
    }
    final selectedSet = _slotSelectedPages[selKey] ?? <int>{};
    final compactedRange =
        PdfInspectorService.formatCompactPageRanges(selectedSet.toList());
    final rotatedCount =
        isLoading ? 0 : _countRotatedPages(slot, ref, doc.pageCount);
    final headerFirstPage = doc.pages.isNotEmpty
        ? _pageWithRotation(slot, ref, doc.pages.first)
        : null;

    return Column(
      children: [
        PdfSlotInfoHeader(
          fileName: doc.fileName,
          pageCount: doc.pageCount,
          paperSizeLabel: headerFirstPage?.paperSizeLabel,
          fileSizeLabel: isLoading ? null : doc.formattedFileSize,
          isInherited: slot.isInherited,
          sourcePoolTitle: ref.sourcePoolTitle,
          isLoading: isLoading,
          onChangeFile: slot.isInherited
              ? null
              : () => _pickFileForSlot(_clampCardIndex(_selectedCardIndex)),
          trailingWidgets: _selectedMode == 1
              ? [
                  PreviewHeaderButton(
                    label: 'Pilih Semua',
                    icon: Icons.done_all_rounded,
                    onPressed: isLoading
                        ? null
                        : () => _updatePageSelectionAndSync(
                              slot,
                              selKey,
                              Set<int>.from(
                                List<int>.generate(
                                  doc.pageCount,
                                  (i) => i + 1,
                                ),
                              ),
                            ),
                  ),
                  PreviewHeaderButton(
                    label: 'Hapus Pilihan',
                    icon: Icons.deselect_rounded,
                    onPressed: isLoading
                        ? null
                        : () => _updatePageSelectionAndSync(
                              slot,
                              selKey,
                              <int>{},
                            ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: selectedSet.isEmpty
                          ? Colors.white.withValues(alpha: 0.06)
                          : const Color(0xFF00E676).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: selectedSet.isEmpty
                            ? Colors.white24
                            : const Color(0xFF00E676).withValues(alpha: 0.55),
                      ),
                    ),
                    child: Text(
                      selectedSet.isEmpty
                          ? 'Dipilih: 0'
                          : 'Dipilih (${selectedSet.length}): $compactedRange',
                      style: TextStyle(
                        color: selectedSet.isEmpty
                            ? Colors.white60
                            : const Color(0xFF00E676),
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  PreviewRotateGroup(
                    rotateLeftKey: const Key('split_rotate_all_left_button'),
                    rotateRightKey: const Key('split_rotate_all_right_button'),
                    resetRotationKey: const Key('split_rotate_reset_button'),
                    rotatedCount: rotatedCount,
                    onRotateLeft: isLoading
                        ? null
                        : () => _rotateAllPages(slot, ref, doc.pageCount, -90),
                    onRotateRight: isLoading
                        ? null
                        : () => _rotateAllPages(slot, ref, doc.pageCount, 90),
                    onResetRotation: (!isLoading && rotatedCount > 0)
                        ? () => _resetAllRotations(slot, ref)
                        : null,
                  ),
                ]
              : [
                  if (slot.pageRange != null && slot.pageRange!.trim().isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryCyan.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: AppColors.primaryCyan.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Text(
                        'Target: Hal ${slot.pageRange!.trim()}',
                        style: const TextStyle(
                          color: AppColors.primaryCyan,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  PreviewRotateGroup(
                    rotateLeftKey: const Key('split_rotate_all_left_button'),
                    rotateRightKey: const Key('split_rotate_all_right_button'),
                    resetRotationKey: const Key('split_rotate_reset_button'),
                    rotatedCount: rotatedCount,
                    onRotateLeft: isLoading
                        ? null
                        : () => _rotateAllPages(slot, ref, doc.pageCount, -90),
                    onRotateRight: isLoading
                        ? null
                        : () => _rotateAllPages(slot, ref, doc.pageCount, 90),
                    onResetRotation: (!isLoading && rotatedCount > 0)
                        ? () => _resetAllRotations(slot, ref)
                        : null,
                  ),
                ],
        ),

        if (inheritedRefs.length > 1) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: inheritedRefs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, idx) {
                final item = inheritedRefs[idx];
                final isActive = idx ==
                    _selectedInheritedFileIndex.clamp(
                      0,
                      inheritedRefs.length - 1,
                    );
                return GestureDetector(
                  onTap: () {
                    if (idx != _selectedInheritedFileIndex) {
                      PdfPageZoomDialog.dismissActive();
                    }
                    setState(() => _selectedInheritedFileIndex = idx);
                    _ensureActiveDocumentInspected();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isActive
                          ? AppColors.primaryCyan
                          : AppColors.cardBackground,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isActive ? AppColors.primaryCyan : Colors.white24,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '#${idx + 1} ${item.fileName}',
                          style: TextStyle(
                            color: isActive ? Colors.black : Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],

        const SizedBox(height: 8),
        Expanded(
          child: isLoading
              ? PdfLoadingPreview(fileName: ref.fileName)
              : (_selectedMode == 0
                  ? _buildRangePreview(slot, ref, doc, selKey)
                  : _buildPagesPreview(slot, ref, doc, selKey, selectedSet)),
        ),
      ],
    );
  }

  Widget _buildRangePreview(
    PoolSlot activeSlot,
    PoolFileRef activeRef,
    PdfDocumentInfo doc,
    String selKey,
  ) {
    final rotatedPages = doc.pages
        .map((p) => _pageWithRotation(activeSlot, activeRef, p))
        .toList();
    final firstPage = rotatedPages.first;
    final lastPage = rotatedPages.last;
    final splitActions = _buildSplitZoomActions(activeSlot, doc, selKey);
    final rotateActions = _buildSplitRotateZoomActions(activeSlot, activeRef);

    return Row(
      children: [
        Expanded(
          child: PdfPageSheetCard(
            page: firstPage,
            fileName: doc.fileName,
            filePath: doc.filePath,
            totalPages: doc.pageCount,
            badgeText: 'Halaman Pertama • Hal 1',
            badgeColor: AppColors.primaryCyan,
            roleSubtitle: null,
            isSelected: true,
            renderQuality: PdfRenderQuality.card,
            onRotateLeft: () =>
                _rotatePage(activeSlot, activeRef, firstPage.pageNumber, -90),
            onRotateRight: () =>
                _rotatePage(activeSlot, activeRef, firstPage.pageNumber, 90),
            onZoom: () => PdfPageZoomDialog.show(
              context,
              fileName: doc.fileName,
              filePath: doc.filePath,
              pages: rotatedPages,
              initialIndex: 0,
              fileSizeLabel: doc.formattedFileSize,
              contextTitle: widget.title,
              splitActions: splitActions,
              rotateActions: rotateActions,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: doc.pageCount == 1
              ? Container(
                  padding: const EdgeInsets.all(16),
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
                          size: 32,
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
                          'Halaman 1 adalah halaman pertama sekaligus halaman terakhir dokumen ini.',
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
                  badgeText: 'Halaman Terakhir • Hal ${doc.pageCount}',
                  badgeColor: AppColors.cardBackground,
                  roleSubtitle: null,
                  renderQuality: PdfRenderQuality.card,
                  onRotateLeft: () =>
                      _rotatePage(activeSlot, activeRef, lastPage.pageNumber, -90),
                  onRotateRight: () =>
                      _rotatePage(activeSlot, activeRef, lastPage.pageNumber, 90),
                  onZoom: () => PdfPageZoomDialog.show(
                    context,
                    fileName: doc.fileName,
                    filePath: doc.filePath,
                    pages: rotatedPages,
                    initialIndex: doc.pageCount - 1,
                    fileSizeLabel: doc.formattedFileSize,
                    contextTitle: widget.title,
                    splitActions: splitActions,
                    rotateActions: rotateActions,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPagesPreview(
    PoolSlot activeSlot,
    PoolFileRef activeRef,
    PdfDocumentInfo doc,
    String selKey,
    Set<int> selectedSet,
  ) {
    final splitActions = _buildSplitZoomActions(activeSlot, doc, selKey);
    final rotateActions = _buildSplitRotateZoomActions(activeSlot, activeRef);
    final rotatedPages = doc.pages
        .map((p) => _pageWithRotation(activeSlot, activeRef, p))
        .toList();

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 1.38,
      ),
      itemCount: rotatedPages.length,
      itemBuilder: (context, idx) {
        final page = rotatedPages[idx];
        final isChecked = selectedSet.contains(page.pageNumber);

        void toggleCheck() {
          final current = Set<int>.from(_slotSelectedPages[selKey] ?? <int>{});
          if (isChecked) {
            current.remove(page.pageNumber);
          } else {
            current.add(page.pageNumber);
          }
          _updatePageSelectionAndSync(activeSlot, selKey, current);
        }

        return PdfPageSheetCard(
          page: page,
          fileName: doc.fileName,
          filePath: doc.filePath,
          totalPages: doc.pageCount,
          compact: true,
          renderQuality: PdfRenderQuality.thumb,
          showCheckmark: true,
          isChecked: isChecked,
          badgeText: 'Hal ${page.pageNumber}',
          badgeColor: AppColors.cardBackground,
          onToggleCheck: toggleCheck,
          onTap: toggleCheck,
          onRotateLeft: () =>
              _rotatePage(activeSlot, activeRef, page.pageNumber, -90),
          onRotateRight: () =>
              _rotatePage(activeSlot, activeRef, page.pageNumber, 90),
          onZoom: () => PdfPageZoomDialog.show(
            context,
            fileName: doc.fileName,
            filePath: doc.filePath,
            pages: rotatedPages,
            initialIndex: idx,
            fileSizeLabel: doc.formattedFileSize,
            contextTitle: '${widget.title} (Pages)',
            splitActions: splitActions,
            rotateActions: rotateActions,
          ),
        );
      },
    );
  }
}
