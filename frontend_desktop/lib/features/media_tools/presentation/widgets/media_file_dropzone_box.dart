import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../core/services/backend_service.dart';
import '../../../../core/services/pdf_inspector_service.dart';
import '../../../../shared/widgets/dashed_container.dart';
import '../../../pdf_manager/presentation/widgets/pdf_preview_components.dart';

class MediaFileDropzoneBox extends StatefulWidget {
  final List<MediaFileEntry> entries;
  final String contextTitle;
  final String selectedCountLabel;
  final List<Widget> emptyBadges;
  final String emptyTitle;
  final String emptySubtitle;
  final VoidCallback onPickFiles;
  final ValueChanged<int> onRemoveFile;
  final VoidCallback onClearAll;

  const MediaFileDropzoneBox({
    super.key,
    required this.entries,
    required this.contextTitle,
    required this.selectedCountLabel,
    required this.emptyBadges,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.onPickFiles,
    required this.onRemoveFile,
    required this.onClearAll,
  });

  @override
  State<MediaFileDropzoneBox> createState() => _MediaFileDropzoneBoxState();
}

class _MediaFileDropzoneBoxState extends State<MediaFileDropzoneBox> {
  static const int _maxConcurrentInspections = 2;

  final PdfInspectorService _inspector = PdfInspectorService();
  final Map<String, PdfDocumentInfo> _pdfDocs = {};
  final Set<String> _loadingKeys = {};
  final Set<String> _queuedKeys = {};
  final List<MediaFileEntry> _pendingQueue = [];
  int _activeWorkers = 0;

  final Map<String, bool> _imageReadableCache = {};
  final Map<String, int> _imageSizeCache = {};
  final Set<String> _imageCheckingKeys = {};

  String? _activeZoomEntryKey;
  int _activeZoomGeneration = 0;

  @override
  void initState() {
    super.initState();
    _syncMediaInspections();
  }

  @override
  void didUpdateWidget(covariant MediaFileDropzoneBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMediaInspections();

    if (_activeZoomEntryKey != null &&
        !_currentZoomableKeys().contains(_activeZoomEntryKey)) {
      final staleGen = _activeZoomGeneration;
      _activeZoomEntryKey = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_activeZoomGeneration == staleGen) {
          PdfPageZoomDialog.dismissActive();
        }
      });
    }
  }

  @override
  void dispose() {
    if (_activeZoomEntryKey != null) {
      _activeZoomEntryKey = null;
      PdfPageZoomDialog.dismissActive();
    }
    _pendingQueue.clear();
    _queuedKeys.clear();
    _loadingKeys.clear();
    _imageCheckingKeys.clear();
    super.dispose();
  }

  Set<String> _currentPdfKeys() {
    return widget.entries
        .where((e) => e.isPdf)
        .map((e) => e.normalizedKey)
        .toSet();
  }

  Set<String> _currentImageKeys() {
    return widget.entries
        .where((e) => e.isImage)
        .map((e) => e.normalizedKey)
        .toSet();
  }

  Set<String> _currentZoomableKeys() {
    return widget.entries
        .where((e) => e.isPdf || e.isImage)
        .map((e) => e.normalizedKey)
        .toSet();
  }

  void _syncMediaInspections() {
    final activePdfKeys = _currentPdfKeys();
    final activeImageKeys = _currentImageKeys();

    _pdfDocs.removeWhere((key, _) => !activePdfKeys.contains(key));
    _loadingKeys.removeWhere((key) => !activePdfKeys.contains(key));
    _queuedKeys.removeWhere((key) => !activePdfKeys.contains(key));
    _pendingQueue.removeWhere((e) => !activePdfKeys.contains(e.normalizedKey));

    _imageReadableCache.removeWhere((key, _) => !activeImageKeys.contains(key));
    _imageSizeCache.removeWhere((key, _) => !activeImageKeys.contains(key));
    _imageCheckingKeys.removeWhere((key) => !activeImageKeys.contains(key));

    for (final entry in widget.entries) {
      final key = entry.normalizedKey;

      if (entry.isPdf) {
        if (_pdfDocs.containsKey(key)) continue;

        final cached = _inspector.getCached(
          entry.name,
          entry.path,
          hintPageCount: entry.pageCount,
        );
        if (cached != null) {
          _pdfDocs[key] = cached;
          continue;
        }

        if (!_loadingKeys.contains(key) && !_queuedKeys.contains(key)) {
          _queuedKeys.add(key);
          _pendingQueue.add(entry);
        }
      } else if (entry.isImage) {
        if (_imageReadableCache.containsKey(key) ||
            _imageCheckingKeys.contains(key)) {
          continue;
        }
        final trimmedPath = entry.path.trim();
        if (trimmedPath.isEmpty) {
          _imageReadableCache[key] = false;
          continue;
        }
        _imageCheckingKeys.add(key);
        unawaited(_checkImageAvailability(entry, key));
      }
    }

    _pumpInspectionQueue();
  }

  Future<void> _checkImageAvailability(
    MediaFileEntry entry,
    String key,
  ) async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    final trimmedPath = entry.path.trim();
    bool exists = false;
    int? diskBytes = entry.sizeBytes;
    if (trimmedPath.isNotEmpty) {
      try {
        final file = File(trimmedPath);
        exists = file.existsSync();
        if (exists && diskBytes == null) {
          diskBytes = file.lengthSync();
        }
      } catch (_) {
        exists = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _imageCheckingKeys.remove(key);
      if (_currentImageKeys().contains(key)) {
        _imageReadableCache[key] = exists;
        if (diskBytes != null) {
          _imageSizeCache[key] = diskBytes;
        }
      }
    });
  }

  void _pumpInspectionQueue() {
    while (_activeWorkers < _maxConcurrentInspections &&
        _pendingQueue.isNotEmpty) {
      final next = _pendingQueue.removeAt(0);
      final key = next.normalizedKey;
      _queuedKeys.remove(key);

      if (!_currentPdfKeys().contains(key) ||
          _pdfDocs.containsKey(key) ||
          _loadingKeys.contains(key)) {
        continue;
      }

      _activeWorkers++;
      _loadingKeys.add(key);
      unawaited(_inspectEntry(next, key));
    }
  }

  Future<void> _inspectEntry(MediaFileEntry entry, String key) async {
    try {
      final doc = await _inspector.inspectFile(
        fileName: entry.name,
        filePath: entry.path,
        hintPageCount: entry.pageCount,
      );
      if (!mounted) return;
      setState(() {
        _loadingKeys.remove(key);
        if (_currentPdfKeys().contains(key)) {
          _pdfDocs[key] = doc;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingKeys.remove(key);
      });
    } finally {
      if (_activeWorkers > 0) {
        _activeWorkers--;
      }
      if (mounted) {
        _pumpInspectionQueue();
      }
    }
  }

  int? _resolvedPageCount(MediaFileEntry entry, PdfDocumentInfo? doc) {
    if (doc != null && !doc.isFallbackEstimate && doc.pageCount > 0) {
      return doc.pageCount;
    }
    if (entry.pageCount != null && entry.pageCount! > 0) {
      return entry.pageCount;
    }
    return null;
  }

  List<PdfPageMeta> _resolvedPages(
    MediaFileEntry entry,
    PdfDocumentInfo? doc,
  ) {
    if (doc != null && !doc.isFallbackEstimate && doc.pages.isNotEmpty) {
      return doc.pages;
    }
    final count = entry.pageCount;
    if (count != null && count > 0) {
      final trimmedPath = entry.path.trim();
      return List<PdfPageMeta>.generate(
        count,
        (i) => PdfPageMeta(
          pageNumber: i + 1,
          sourceFilePath: trimmedPath.isEmpty ? null : trimmedPath,
          sourcePageNumber: i + 1,
        ),
      );
    }
    return const [];
  }

  Future<void> _openPdfPreview(
    MediaFileEntry entry,
    PdfDocumentInfo? doc,
    List<PdfPageMeta> pages,
  ) async {
    if (pages.isEmpty) return;

    final gen = ++_activeZoomGeneration;
    _activeZoomEntryKey = entry.normalizedKey;

    final sizeBytes = entry.sizeBytes ?? doc?.fileSizeBytes;
    final fileSizeLabel =
        sizeBytes != null ? BackendService.formatBytes(sizeBytes) : null;
    final trimmedPath = entry.path.trim();
    final resolvedPath =
        trimmedPath.isNotEmpty ? trimmedPath : doc?.filePath;

    try {
      await PdfPageZoomDialog.show(
        context,
        fileName: entry.name,
        filePath: resolvedPath,
        pages: pages,
        initialIndex: 0,
        fileSizeLabel: fileSizeLabel,
        contextTitle: widget.contextTitle,
        enableRotate: false,
      );
    } finally {
      if (_activeZoomGeneration == gen) {
        _activeZoomEntryKey = null;
      }
    }
  }

  Future<void> _openImagePreview(
    MediaFileEntry entry,
    int? resolvedBytes,
  ) async {
    final trimmedPath = entry.path.trim();
    if (trimmedPath.isEmpty) return;

    final gen = ++_activeZoomGeneration;
    _activeZoomEntryKey = entry.normalizedKey;

    final fileSizeLabel = resolvedBytes != null
        ? BackendService.formatBytes(resolvedBytes)
        : null;

    try {
      await PdfPageZoomDialog.showImage(
        context,
        fileName: entry.name,
        filePath: trimmedPath,
        fileSizeLabel: fileSizeLabel,
        contextTitle: widget.contextTitle,
      );
    } finally {
      if (_activeZoomGeneration == gen) {
        _activeZoomEntryKey = null;
      }
    }
  }

  void _handleRemoveFile(int index) {
    if (index >= 0 && index < widget.entries.length) {
      final removed = widget.entries[index];
      if (_activeZoomEntryKey != null &&
          (removed.isPdf || removed.isImage) &&
          removed.normalizedKey == _activeZoomEntryKey) {
        _activeZoomEntryKey = null;
        PdfPageZoomDialog.dismissActive();
      }
    }
    widget.onRemoveFile(index);
  }

  void _handleClearAll() {
    if (_activeZoomEntryKey != null) {
      _activeZoomEntryKey = null;
      PdfPageZoomDialog.dismissActive();
    }
    widget.onClearAll();
  }

  @override
  Widget build(BuildContext context) {
    return DashedContainer(
      borderRadius: 12,
      borderWidth: 1.5,
      borderColor: AppColors.borderCyan,
      fillColor: AppColors.cardBackground,
      hoverFillColor: AppColors.cardHover,
      onTap: widget.onPickFiles,
      child: widget.entries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: widget.emptyBadges,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.emptyTitle,
                    style: const TextStyle(
                      color: AppColors.textWhite,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.emptySubtitle,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Header list info
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white10)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        widget.selectedCountLabel,
                        style: const TextStyle(
                          color: AppColors.primaryCyan,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: widget.onPickFiles,
                        child: const Text(
                          '+ Tambah File',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      InkWell(
                        onTap: _handleClearAll,
                        child: const Text(
                          'Hapus Semua',
                          style: TextStyle(
                            color: AppColors.accentRed,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Scrollable file items
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: widget.entries.length,
                    itemBuilder: (context, index) => _buildFileRow(index),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildFileRow(int index) {
    final entry = widget.entries[index];
    final fileName = entry.name;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toUpperCase()
        : 'FILE';
    final isPdf = entry.isPdf;
    final isImage = entry.isImage;
    final key = entry.normalizedKey;

    final doc = isPdf ? _pdfDocs[key] : null;
    final resolvedPageCount = isPdf ? _resolvedPageCount(entry, doc) : null;
    final resolvedPages = isPdf && resolvedPageCount != null
        ? _resolvedPages(entry, doc)
        : const <PdfPageMeta>[];
    final isLoadingPages = isPdf &&
        resolvedPageCount == null &&
        (_loadingKeys.contains(key) || _queuedKeys.contains(key));
    final canOpenPdfZoom = isPdf &&
        resolvedPageCount != null &&
        resolvedPageCount > 0 &&
        resolvedPages.isNotEmpty;

    final canOpenImageZoom = isImage && (_imageReadableCache[key] == true);
    final canOpenZoom = canOpenPdfZoom || canOpenImageZoom;

    final displayBytes =
        entry.sizeBytes ?? (isPdf ? doc?.fileSizeBytes : _imageSizeCache[key]);

    final rowInner = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: (canOpenZoom || isLoadingPages)
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: canOpenZoom
                    ? AppColors.primaryCyan.withValues(alpha: 0.22)
                    : Colors.white10,
              ),
            )
          : BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white10),
            ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primaryCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              ext,
              style: const TextStyle(
                color: AppColors.primaryCyan,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    fileName,
                    style: const TextStyle(
                      color: AppColors.textWhite,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isLoadingPages) ...[
                  const SizedBox(width: 8),
                  _buildPageStatusPill(
                    label: 'Memuat...',
                    accent: AppColors.primaryCyan,
                    showSpinner: true,
                  ),
                ] else if (canOpenPdfZoom) ...[
                  const SizedBox(width: 8),
                  _buildPageStatusPill(
                    key: Key('media_file_page_badge_$index'),
                    label: '$resolvedPageCount Halaman',
                    accent: const Color(0xFF00E676),
                  ),
                ],
              ],
            ),
          ),
          if (canOpenZoom) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: isImage
                  ? 'Pratinjau & Zoom gambar'
                  : 'Pratinjau & Zoom halaman PDF',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  key: Key('media_file_zoom_button_$index'),
                  onTap: () => isImage
                      ? _openImagePreview(entry, displayBytes)
                      : _openPdfPreview(entry, doc, resolvedPages),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryCyan.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: AppColors.primaryCyan.withValues(alpha: 0.5),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.zoom_in_rounded,
                          color: AppColors.primaryCyan,
                          size: 13,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Zoom',
                          style: TextStyle(
                            color: AppColors.primaryCyan,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (displayBytes != null) ...[
            const SizedBox(width: 8),
            Text(
              BackendService.formatBytes(displayBytes),
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 10.5,
              ),
            ),
          ],
          IconButton(
            key: Key('media_file_remove_button_$index'),
            icon: const Icon(
              Icons.close,
              color: Colors.redAccent,
              size: 16,
            ),
            onPressed: () => _handleRemoveFile(index),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );

    if (!canOpenZoom && !isLoadingPages) {
      return Padding(
        key: Key('media_file_item_$index'),
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: rowInner,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('media_file_item_$index'),
          borderRadius: BorderRadius.circular(6),
          hoverColor: AppColors.primaryCyan.withValues(alpha: 0.09),
          onTap: canOpenPdfZoom
              ? () => _openPdfPreview(entry, doc, resolvedPages)
              : (canOpenImageZoom
                  ? () => _openImagePreview(entry, displayBytes)
                  : () {}),
          child: rowInner,
        ),
      ),
    );
  }

  Widget _buildPageStatusPill({
    Key? key,
    required String label,
    required Color accent,
    bool showSpinner = false,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
