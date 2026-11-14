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

class _ReorderUndoSnapshot {
  final List<int> order;
  final String? pageRange;
  final String label;

  const _ReorderUndoSnapshot({
    required this.order,
    required this.pageRange,
    required this.label,
  });
}

class ReorderPoolView extends StatefulWidget {
  final int poolIndex;
  final VoidCallback onGoToPool;
  final ValueChanged<String> onSwitchPool;
  final int initialCardIndex;
  final List<PoolSlot> poolSlots;
  final VoidCallback? onSlotsChanged;

  const ReorderPoolView({
    super.key,
    this.poolIndex = 0,
    required this.onGoToPool,
    required this.onSwitchPool,
    this.initialCardIndex = 0,
    required this.poolSlots,
    this.onSlotsChanged,
  });

  @override
  State<ReorderPoolView> createState() => _ReorderPoolViewState();
}

class _ReorderPoolViewState extends State<ReorderPoolView> {
  final AppStateService _appState = AppStateService();
  final BackendService _backend = BackendService();
  final PdfInspectorService _inspector = PdfInspectorService();

  late int _selectedCardIndex;
  int _selectedInheritedFileIndex = 0;

  List<PoolSlot> get _normalSlots =>
      widget.poolSlots.where((s) => !s.isInherited).toList();

  final List<TextEditingController> _orderControllers = [];
  final Map<String, PdfDocumentInfo> _docCache = {};
  final Map<String, List<int>> _slotPageOrders = {};
  final Map<String, _ReorderUndoSnapshot> _undoSnapshots = {};
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
    _selectedCardIndex = _clampCardIndex(widget.initialCardIndex);

    if (_normalSlots.isEmpty) {
      widget.poolSlots.add(
        PoolSlot(id: UniqueKey().toString(), label: 'Order Number'),
      );
    }

    _initControllers();
    _ensureActiveDocumentInspected();
  }

  @override
  void didUpdateWidget(covariant ReorderPoolView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.poolSlots != widget.poolSlots) {
      if (_normalSlots.isEmpty) {
        widget.poolSlots.add(
          PoolSlot(id: UniqueKey().toString(), label: 'Order Number'),
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
        sourcePoolTitle: 'Reorder Pool',
        pageRotations: Map<int, int>.from(slot.pageRotations),
      );
    }
    return null;
  }

  String _docCacheKey(PoolFileRef ref) =>
      '${ref.filePath ?? ''}|${ref.fileName}';

  String _orderStateKey(PoolSlot slot, PoolFileRef ref) =>
      '${slot.id}|${_docCacheKey(ref)}';

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
      _ensureDefaultOrderInitialized(slot, ref, _docCache[key]!);
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
    _ensureDefaultOrderInitialized(slot, ref, info);

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

  void _ensureDefaultOrderInitialized(
    PoolSlot slot,
    PoolFileRef ref,
    PdfDocumentInfo doc,
  ) {
    final orderKey = _orderStateKey(slot, ref);
    if (_slotPageOrders.containsKey(orderKey)) {
      final sanitized = _slotPageOrders[orderKey]!
          .where((p) => p >= 1 && p <= doc.pageCount)
          .toList();
      if (sanitized.isNotEmpty) {
        _slotPageOrders[orderKey] = sanitized;
        return;
      }
    }

    final targetNormalIdx = _resolveTargetNormalIndex(slot);
    final rawSpec = !slot.isInherited
        ? slot.pageRange
        : (targetNormalIdx < _normalSlots.length
            ? _normalSlots[targetNormalIdx].pageRange
            : null);

    if (rawSpec != null && rawSpec.trim().isNotEmpty) {
      _slotPageOrders[orderKey] = PdfInspectorService.parseOrderSpec(
        rawSpec,
        doc.pageCount,
        appendMissing: false,
      );
    } else {
      _slotPageOrders[orderKey] =
          List<int>.generate(doc.pageCount, (i) => i + 1);
    }
  }

  int _resolveTargetNormalIndex(PoolSlot slot) {
    if (_normalSlots.isEmpty) return 0;
    if (!slot.isInherited) {
      final idx = _normalSlots.indexOf(slot);
      return idx != -1 ? idx : 0;
    }
    return (_selectedInheritedFileIndex >= 0 &&
            _selectedInheritedFileIndex < _normalSlots.length)
        ? _selectedInheritedFileIndex
        : 0;
  }

  bool _isSameOrder(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _captureUndoSnapshot(
    PoolSlot activeSlot,
    String orderKey,
    List<int> currentOrder, {
    String? overridePrevRange,
    String? overridePrevLabel,
  }) {
    final targetIdx = _normalSlots.isNotEmpty
        ? _resolveTargetNormalIndex(activeSlot)
        : -1;
    final targetSlot = (targetIdx >= 0 && targetIdx < _normalSlots.length)
        ? _normalSlots[targetIdx]
        : activeSlot;
    _undoSnapshots[orderKey] = _ReorderUndoSnapshot(
      order: List<int>.from(currentOrder),
      pageRange: overridePrevRange ?? targetSlot.pageRange,
      label: overridePrevLabel ?? targetSlot.label,
    );
  }

  void _undoLastOrderChange(PoolSlot activeSlot, String orderKey) {
    final snapshot = _undoSnapshots.remove(orderKey);
    if (snapshot == null) return;

    setState(() {
      _slotPageOrders[orderKey] = List<int>.from(snapshot.order);
      if (_normalSlots.isNotEmpty) {
        final targetIdx = _resolveTargetNormalIndex(activeSlot);
        if (targetIdx >= 0 && targetIdx < _normalSlots.length) {
          _normalSlots[targetIdx].pageRange = snapshot.pageRange;
          _normalSlots[targetIdx].label = snapshot.label;
          if (targetIdx < _orderControllers.length) {
            final targetText = snapshot.pageRange ?? '';
            if (_orderControllers[targetIdx].text != targetText) {
              _orderControllers[targetIdx].text = targetText;
            }
          }
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  int _getPageRotation(PoolSlot slot, PoolFileRef ref, int pageNumber) {
    return slot.isInherited
        ? slot.getInheritedPageRotation(ref, pageNumber)
        : slot.getPageRotation(pageNumber);
  }

  int _countRotatedPages(
    PoolSlot slot,
    PoolFileRef ref,
    List<int> activeOrder,
  ) {
    int count = 0;
    for (final p in activeOrder.toSet()) {
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
    List<int> activeOrder,
    int deltaDeg,
  ) {
    setState(() {
      for (final p in activeOrder.toSet()) {
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

  List<PdfPageMeta> _buildOrderedMetas(
    PoolSlot slot,
    PoolFileRef ref,
    PdfDocumentInfo doc,
    List<int> order,
  ) {
    return order.map((p) {
      final base = (p >= 1 && p <= doc.pages.length)
          ? doc.pages[p - 1]
          : PdfPageMeta(
              pageNumber: p,
              sourceFilePath: doc.filePath,
              sourcePageNumber: p,
            );
      final deg = _getPageRotation(slot, ref, p);
      return deg == base.normalizedUserRotation
          ? base
          : base.copyWith(userRotation: deg);
    }).toList();
  }

  PdfZoomReorderActions _buildReorderZoomActions(
    PoolSlot slot,
    PoolFileRef ref,
    PdfDocumentInfo doc,
    String orderKey,
  ) {
    List<int> currentOrder() =>
        _slotPageOrders[orderKey] ??
        List<int>.generate(doc.pageCount, (i) => i + 1);

    return PdfZoomReorderActions(
      listenable: _zoomSyncVersion,
      getPages: () => _buildOrderedMetas(slot, ref, doc, currentOrder()),
      getOriginalPageCount: () => doc.pageCount,
      canUndo: () => _undoSnapshots.containsKey(orderKey),
      onDeleteAt: (int currentIndex) =>
          _removePageFromOrder(slot, orderKey, currentOrder(), currentIndex),
      onMovePage: (int oldIndex, int newIndex) =>
          _onReorderPage(slot, orderKey, currentOrder(), oldIndex, newIndex),
      onReverseOrder: () => _reverseOrder(slot, orderKey, currentOrder()),
      onUndo: () => _undoLastOrderChange(slot, orderKey),
      onResetOrder: () => _resetOrder(slot, orderKey, doc.pageCount),
    );
  }

  PdfZoomRotateActions _buildReorderRotateZoomActions(
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

  void _syncOrderTextToSlot(PoolSlot activeSlot, List<int> order) {
    if (_normalSlots.isEmpty) return;
    final targetIdx = _resolveTargetNormalIndex(activeSlot);
    final orderStr = order.join(', ');
    _normalSlots[targetIdx].pageRange = orderStr;
    _normalSlots[targetIdx].label = 'Order $orderStr';
    if (targetIdx < _orderControllers.length) {
      _orderControllers[targetIdx].text = orderStr;
    }
  }

  void _removePageFromOrder(
    PoolSlot activeSlot,
    String orderKey,
    List<int> pageOrder,
    int gridIdx,
  ) {
    final currentOrder = List<int>.from(pageOrder);
    if (gridIdx < 0 || gridIdx >= currentOrder.length) return;
    if (currentOrder.length <= 1) {
      AppToast.showWarning(
        context,
        title: 'Batas Halaman Reorder',
        message:
            'Minimal 1 halaman harus tersisa. Klik "Reset 1..N" untuk mengembalikan semua halaman.',
        duration: const Duration(seconds: 2),
      );
      return;
    }

    _captureUndoSnapshot(activeSlot, orderKey, currentOrder);
    final removedPage = currentOrder[gridIdx];
    final updatedOrder = List<int>.from(currentOrder)..removeAt(gridIdx);
    setState(() {
      _slotPageOrders[orderKey] = updatedOrder;
      _syncOrderTextToSlot(activeSlot, updatedOrder);
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();

    AppToast.showWarning(
      context,
      title: 'Halaman Dihapus',
      message:
          'Halaman $removedPage dihapus dari Reorder (tersisa ${updatedOrder.length} halaman).',
      duration: const Duration(milliseconds: 1400),
    );
  }

  void _onReorderPage(
    PoolSlot activeSlot,
    String orderKey,
    List<int> pageOrder,
    int oldIdx,
    int newIdx,
  ) {
    final currentOrder = List<int>.from(pageOrder);
    if (oldIdx == newIdx ||
        oldIdx < 0 ||
        oldIdx >= currentOrder.length ||
        newIdx < 0 ||
        newIdx >= currentOrder.length) {
      return;
    }
    _captureUndoSnapshot(activeSlot, orderKey, currentOrder);
    final updatedOrder = List<int>.from(currentOrder);
    final p = updatedOrder.removeAt(oldIdx);
    updatedOrder.insert(newIdx, p);
    setState(() {
      _slotPageOrders[orderKey] = updatedOrder;
      _syncOrderTextToSlot(activeSlot, updatedOrder);
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _reverseOrder(
    PoolSlot activeSlot,
    String orderKey,
    List<int> pageOrder,
  ) {
    final currentOrder = List<int>.from(pageOrder);
    if (currentOrder.length <= 1) return;
    _captureUndoSnapshot(activeSlot, orderKey, currentOrder);
    final reversed = currentOrder.reversed.toList();
    setState(() {
      _slotPageOrders[orderKey] = reversed;
      _syncOrderTextToSlot(activeSlot, reversed);
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _resetOrder(
    PoolSlot activeSlot,
    String orderKey,
    int pageCount,
  ) {
    final defaultOrder = List<int>.generate(pageCount, (i) => i + 1);
    final currentOrder =
        List<int>.from(_slotPageOrders[orderKey] ?? defaultOrder);
    final targetIdx = _normalSlots.isNotEmpty
        ? _resolveTargetNormalIndex(activeSlot)
        : -1;
    final hasCustomRange = targetIdx >= 0 &&
        targetIdx < _normalSlots.length &&
        (_normalSlots[targetIdx].pageRange?.trim().isNotEmpty ?? false);
    if (_isSameOrder(currentOrder, defaultOrder) && !hasCustomRange) {
      return;
    }

    _captureUndoSnapshot(activeSlot, orderKey, currentOrder);
    setState(() {
      _slotPageOrders[orderKey] = defaultOrder;
      if (targetIdx >= 0 && targetIdx < _normalSlots.length) {
        _normalSlots[targetIdx].pageRange = null;
        _normalSlots[targetIdx].label = 'Order Number';
        if (targetIdx < _orderControllers.length) {
          _orderControllers[targetIdx].clear();
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
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
    while (_orderControllers.length < normal.length) {
      _orderControllers.add(TextEditingController());
    }
    while (_orderControllers.length > normal.length) {
      _orderControllers.removeLast().dispose();
    }
    for (int i = 0; i < normal.length; i++) {
      final text = normal[i].pageRange ?? '';
      if (_orderControllers[i].text != text) {
        _orderControllers[i].text = text;
      }
    }
  }

  void _initControllers() {
    for (final ctrl in _orderControllers) {
      ctrl.dispose();
    }
    _orderControllers.clear();

    for (final slot in _normalSlots) {
      final label = slot.label;
      if (label == 'Number Split' ||
          label == 'Merge Number' ||
          label.startsWith('Split ') ||
          label.startsWith('Merge File')) {
        final trimmed = slot.pageRange?.trim() ?? '';
        slot.label = trimmed.isNotEmpty ? 'Order $trimmed' : 'Order Number';
      }
      final ctrl = TextEditingController(text: slot.pageRange ?? '');
      _orderControllers.add(ctrl);
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    PdfPageZoomDialog.dismissActive();
    _zoomSyncVersion.dispose();
    for (final ctrl in _orderControllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _onControllerChanged(int index, String newText) {
    if (index >= _normalSlots.length) return;
    final trimmed = newText.trim();
    final editedSlot = _normalSlots[index];
    final prevRange = editedSlot.pageRange;
    final prevLabel = editedSlot.label;

    setState(() {
      editedSlot.pageRange = trimmed.isEmpty ? null : trimmed;
      editedSlot.label =
          trimmed.isEmpty ? 'Order Number' : 'Order $trimmed';

      final active = _activeSlot;
      final ref = _activeFileRef;
      if (active != null && ref != null) {
        final key = _docCacheKey(ref);
        final doc = _docCache[key] ??
            _inspector.getCached(
              ref.fileName,
              ref.filePath,
              hintPageCount: ref.pageCount,
            );
        if (doc != null &&
            (active == editedSlot ||
                (active.isInherited &&
                    _resolveTargetNormalIndex(active) == index))) {
          _docCache[key] = doc;
          final orderKey = _orderStateKey(active, ref);
          final defaultOrder =
              List<int>.generate(doc.pageCount, (i) => i + 1);
          final prevOrder =
              List<int>.from(_slotPageOrders[orderKey] ?? defaultOrder);
          final nextOrder = trimmed.isEmpty
              ? defaultOrder
              : PdfInspectorService.parseOrderSpec(
                  trimmed,
                  doc.pageCount,
                  appendMissing: false,
                );
          if (!_isSameOrder(prevOrder, nextOrder)) {
            _captureUndoSnapshot(
              active,
              orderKey,
              prevOrder,
              overridePrevRange: prevRange,
              overridePrevLabel: prevLabel,
            );
          }
          _slotPageOrders[orderKey] = nextOrder;
        }
      }
    });
    _zoomSyncVersion.value++;
    widget.onSlotsChanged?.call();
  }

  void _addNewOrderSlot() {
    setState(() {
      final newSlot = PoolSlot(
        id: UniqueKey().toString(),
        label: 'Order Number',
      );
      widget.poolSlots.add(newSlot);
      _orderControllers.add(TextEditingController());
    });
    widget.onSlotsChanged?.call();
  }

  void _removeOrderSlot(int index) {
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
        _normalSlots[0].label = 'Order Number';
        _slotPageOrders.removeWhere((k, _) => k.startsWith('$slotId|'));
        _undoSnapshots.removeWhere((k, _) => k.startsWith('$slotId|'));
        if (_orderControllers.isNotEmpty) {
          _orderControllers[0].clear();
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
      widget.poolSlots.remove(targetSlot);
      _slotPageOrders.removeWhere((k, _) => k.startsWith('${targetSlot.id}|'));
      _undoSnapshots.removeWhere((k, _) => k.startsWith('${targetSlot.id}|'));
      _orderControllers[index].dispose();
      _orderControllers.removeAt(index);
      if (_selectedCardIndex >= widget.poolSlots.length) {
        _selectedCardIndex =
            widget.poolSlots.isEmpty ? 0 : widget.poolSlots.length - 1;
      }
    });
    widget.onSlotsChanged?.call();
    _ensureActiveDocumentInspected();
  }

  void _onRemoveCard(int slotIndex) {
    if (slotIndex < 0 || slotIndex >= widget.poolSlots.length) return;
    final slot = widget.poolSlots[slotIndex];
    if (slot.isInherited) return;

    final normalIdx = _normalSlots.indexOf(slot);
    if (normalIdx != -1) {
      _removeOrderSlot(normalIdx);
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
        sourcePoolTitle: 'Reorder Pool',
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
          targetSlot.label = 'Order Number';
          final normalIdx = _normalSlots.indexOf(targetSlot);
          if (normalIdx != -1 && normalIdx < _orderControllers.length) {
            _orderControllers[normalIdx].clear();
          }
        }
        _slotPageOrders.removeWhere(
          (k, _) => k.startsWith('${targetSlot.id}|'),
        );
        _undoSnapshots.removeWhere(
          (k, _) => k.startsWith('${targetSlot.id}|'),
        );
        _selectedCardIndex = slotIndex;
        _selectedInheritedFileIndex = 0;

        if (cached != null) {
          _docCache[newKey] = cached;
          _loadingKey = null;
          _ensureDefaultOrderInitialized(targetSlot, newRef, cached);
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
            sourcePoolTitle: 'Reorder Pool',
          );
          _docCache[newKey] = info;
          _ensureDefaultOrderInitialized(targetSlot, resolvedRef, info);
        }
        setState(() {});
        widget.onSlotsChanged?.call();
      }

      if (!mounted) return;
      AppToast.showSuccess(
        context,
        title: 'File Ditambahkan ke Reorder',
        badgeLabel: '${info.pageCount} HAL',
        message:
            'File "${file.name}" (${info.pageCount} halaman) ditambahkan ke Reorder Pool.',
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
        title: 'Reorder Pool',
        slots: widget.poolSlots,
      );
      return [...upstream, current];
    }
    return [
      PoolSectionData(
        id: 'reorder_detail_single',
        title: 'Reorder Pool',
        slots: widget.poolSlots,
      ),
    ];
  }

  Future<void> _reorderPdf() async {
    if (_isExecuting) return;

    final orders = _normalSlots
        .map((s) => s.pageRange?.trim())
        .where((t) => t != null && t.isNotEmpty)
        .join(' | ');

    final slot = _activeSlot;
    final ref = _activeFileRef;
    List<int> activeOrder = const [1, 2, 3, 4, 5, 6, 7, 8];
    if (slot != null && ref != null) {
      final existing = _slotPageOrders[_orderStateKey(slot, ref)];
      if (existing != null && existing.isNotEmpty) {
        activeOrder = existing;
      }
    }

    final effectiveOrder =
        orders.isEmpty ? activeOrder.join(', ') : orders;
    final rotationSummary = _summarizeSlotRotations();

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
      _executionMessage = 'Menyusun ulang halaman PDF ($effectiveOrder)...';
    });

    try {
      final batchResult = await _backend.executePdfWorkflow(
        pools: pools,
        taskModeLabel: 'PDF Manager (Reorder)',
        outputSuffix: 'reordered',
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
            'Reorder PDF selesai! ${batchResult.files.length} file hasil siap disimpan.';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });

      final outputItems = batchResult.files
          .map(
            (sf) => SaveOutputItem(
              sourceFileName: sf.sourceFileName,
              outputFileName: sf.suggestedFileName,
              taskType: 'PDF Manager (Reorder)',
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
        taskTitle: 'Reorder PDF',
        summaryNote: rotationSummary.isEmpty
            ? 'Urutan halaman baru: $effectiveOrder'
            : 'Urutan halaman baru: $effectiveOrder • Rotasi: $rotationSummary',
        outputItems: outputItems,
        onCleanupStaging: batchResult.cleanupStaging,
        onSaved: (savedFolder) {
          if (!mounted) return;
          AppToast.showSuccess(
            context,
            title: 'Reorder PDF Selesai',
            badgeLabel: 'REORDER PDF',
            message: orders.isEmpty
                ? 'Urutan halaman (${activeOrder.join(", ")}) berhasil disimpan.'
                : 'Urutan halaman ($orders) berhasil disimpan.',
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
        _executionMessage = 'Proses Reorder PDF dibatalkan oleh pengguna.';
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
        _executionMessage = 'Reorder PDF gagal: $e';
        if (identical(_cancelToken, token)) _cancelToken = null;
      });
      _appState.addSystemLog(
        level: 'ERROR',
        message: 'Reorder PDF gagal: $e',
        source: 'PIPELINE',
      );
      AppToast.showError(
        context,
        title: 'Reorder PDF Gagal',
        message: 'Reorder PDF gagal: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final safeIdx = _clampCardIndex(_selectedCardIndex);

    return Column(
      children: [
        // Top Header Dropdown (Reorder Pool)
        PoolHeaderDropdown(
          title: 'Reorder Pool',
          onSelected: widget.onSwitchPool,
        ),
        const SizedBox(height: 8),

        // Main Preview Grid (shows ALL pages 1..N of selected file)
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
          onAddTap: _addNewOrderSlot,
        ),
        const SizedBox(height: 6),

        if (_showExecutionStatus) ...[
          StatusProgressBar(
            compact: true,
            isProcessing: _isExecuting,
            progress: _executionProgress,
            stageLabel: 'REORDER POOL',
            completedItems: _executionStep,
            totalItems: _executionTotalSteps,
            itemUnitLabel: 'pool',
            processingMessage: _executionMessage ?? 'Memproses Reorder PDF...',
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

        // Bottom Controls: Rows (Order Number 1, 2) + Add Order Number + Actions
        PoolBottomControls(
          prefix: 'Order Number',
          hintText: 'Pages to Reorder',
          addButtonLabel: '+ Add Order Number',
          controllers: _orderControllers,
          onTextChanged: _onControllerChanged,
          onReorderItem: _onReorderNumberRow,
          onAddItem: _addNewOrderSlot,
          onRemoveItem: _removeOrderSlot,
          actionLabel: _isExecuting ? 'Memproses...' : 'Reorder PDF',
          onAction: _isExecuting ? () {} : _reorderPdf,
          onGoToPool: widget.onGoToPool,
        ),
      ],
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
            ? 'Tambahkan file PDF pada pool sebelumnya di atas untuk menampilkan semua halaman yang siap di-reorder.'
            : 'Klik untuk memilih file PDF, lalu semua halaman (1..N) akan tampil untuk digeser urutan halamannya.',
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

    final orderKey = _orderStateKey(slot, ref);
    if (!isLoading) {
      _ensureDefaultOrderInitialized(slot, ref, doc);
    }
    final activeOrder = _slotPageOrders[orderKey] ??
        List<int>.generate(doc.pageCount, (i) => i + 1);

    final inheritedRefs =
        slot.isInherited ? slot.resolvedInheritedRefs : const <PoolFileRef>[];
    final rotatedCount =
        isLoading ? 0 : _countRotatedPages(slot, ref, activeOrder);
    final headerPage = doc.pages.isNotEmpty
        ? doc.pages.first.copyWith(
            userRotation: _getPageRotation(slot, ref, doc.pages.first.pageNumber),
          )
        : null;

    return Column(
      children: [
        PdfSlotInfoHeader(
          fileName: doc.fileName,
          pageCount: doc.pageCount,
          paperSizeLabel: headerPage?.paperSizeLabel,
          fileSizeLabel: isLoading ? null : doc.formattedFileSize,
          isInherited: slot.isInherited,
          sourcePoolTitle: ref.sourcePoolTitle,
          isLoading: isLoading,
          onChangeFile: slot.isInherited
              ? null
              : () => _pickFileForSlot(_clampCardIndex(_selectedCardIndex)),
          trailingWidgets: [
            if (!isLoading && activeOrder.length < doc.pageCount)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.orangeAccent.withValues(alpha: 0.55),
                  ),
                ),
                child: Text(
                  'Aktif: ${activeOrder.length}/${doc.pageCount} Hal',
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            PreviewHeaderButton(
              key: const Key('reorder_reverse_button'),
              label: 'Balik Urutan',
              icon: Icons.swap_vert_rounded,
              tooltip: 'Balik urutan seluruh halaman (N..1)',
              onPressed: (isLoading || activeOrder.length <= 1)
                  ? null
                  : () => _reverseOrder(slot, orderKey, activeOrder),
            ),
            PreviewHeaderButton(
              key: const Key('reorder_undo_button'),
              label: 'Undo 1x',
              icon: Icons.undo_rounded,
              tooltip: 'Kembalikan 1 langkah sebelumnya (Undo 1x)',
              onPressed: (!isLoading && _undoSnapshots.containsKey(orderKey))
                  ? () => _undoLastOrderChange(slot, orderKey)
                  : null,
            ),
            PreviewHeaderButton(
              key: const Key('reorder_reset_button'),
              label: 'Reset 1..N',
              icon: Icons.restart_alt_rounded,
              tooltip: 'Kembalikan urutan halaman asli (1..N)',
              onPressed:
                  isLoading ? null : () => _resetOrder(slot, orderKey, doc.pageCount),
            ),
            PreviewRotateGroup(
              rotateLeftKey: const Key('reorder_rotate_all_left_button'),
              rotateRightKey: const Key('reorder_rotate_all_right_button'),
              resetRotationKey: const Key('reorder_rotate_reset_button'),
              rotatedCount: rotatedCount,
              onRotateLeft: isLoading
                  ? null
                  : () => _rotateAllPages(slot, ref, activeOrder, -90),
              onRotateRight: isLoading
                  ? null
                  : () => _rotateAllPages(slot, ref, activeOrder, 90),
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
                    child: Text(
                      '#${idx + 1} ${item.fileName}',
                      style: TextStyle(
                        color: isActive ? Colors.black : Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
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
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 1.38,
                  ),
                  itemCount: activeOrder.length,
                  itemBuilder: (context, gridIdx) {
                    final pageNum = activeOrder[gridIdx];
                    final basePageMeta =
                        (pageNum >= 1 && pageNum <= doc.pages.length)
                            ? doc.pages[pageNum - 1]
                            : PdfPageMeta(
                                pageNumber: pageNum,
                                sourceFilePath: doc.filePath,
                                sourcePageNumber: pageNum,
                              );
                    final pageRot = _getPageRotation(slot, ref, pageNum);
                    final pageMeta = pageRot == basePageMeta.normalizedUserRotation
                        ? basePageMeta
                        : basePageMeta.copyWith(userRotation: pageRot);

                    final card = PdfPageSheetCard(
                      page: pageMeta,
                      fileName: doc.fileName,
                      filePath: doc.filePath,
                      totalPages: doc.pageCount,
                      compact: true,
                      renderQuality: PdfRenderQuality.thumb,
                      showReorderHandle: true,
                      displayOrderNumber: gridIdx + 1,
                      badgeText: 'Pos #${gridIdx + 1} • Hal $pageNum',
                      badgeColor: AppColors.cardBackground,
                      showDeleteButton: true,
                      onRotateLeft: () => _rotatePage(slot, ref, pageNum, -90),
                      onRotateRight: () => _rotatePage(slot, ref, pageNum, 90),
                      onDelete: () => _removePageFromOrder(
                        slot,
                        orderKey,
                        activeOrder,
                        gridIdx,
                      ),
                      onZoom: () {
                        final currentOrder = _slotPageOrders[orderKey] ?? activeOrder;
                        final orderedMetas =
                            _buildOrderedMetas(slot, ref, doc, currentOrder);
                        PdfPageZoomDialog.show(
                          context,
                          fileName: doc.fileName,
                          filePath: doc.filePath,
                          pages: orderedMetas,
                          initialIndex: gridIdx,
                          fileSizeLabel: doc.formattedFileSize,
                          contextTitle: 'Reorder Pool (Urutan Baru)',
                          showSequencePosition: true,
                          reorderActions: _buildReorderZoomActions(
                            slot,
                            ref,
                            doc,
                            orderKey,
                          ),
                          rotateActions: _buildReorderRotateZoomActions(
                            slot,
                            ref,
                          ),
                        );
                      },
                    );

              return DragTarget<PageDragData>(
                hitTestBehavior: HitTestBehavior.opaque,
                onWillAcceptWithDetails: (details) =>
                    details.data.pageIndex != gridIdx,
                onAcceptWithDetails: (details) => _onReorderPage(
                  slot,
                  orderKey,
                  activeOrder,
                  details.data.pageIndex,
                  gridIdx,
                ),
                builder: (context, candidateData, rejectedData) {
                  final isHovered = candidateData.isNotEmpty;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      border: isHovered
                          ? Border.all(color: AppColors.primaryCyan, width: 2.2)
                          : null,
                      boxShadow: isHovered ? AppColors.cyanGlowShadow : null,
                    ),
                    child: Draggable<PageDragData>(
                      data: PageDragData(pageIndex: gridIdx),
                      dragAnchorStrategy: childDragAnchorStrategy,
                      feedback: IgnorePointer(
                        child: Material(
                          color: Colors.transparent,
                          child: Opacity(
                            opacity: 0.9,
                            child: SizedBox(
                              width: 140,
                              height: 95,
                              child: card,
                            ),
                          ),
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.3,
                        child: card,
                      ),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: card,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
