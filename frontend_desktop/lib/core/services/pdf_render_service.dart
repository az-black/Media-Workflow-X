import 'dart:async';
import 'dart:collection';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_inspector_service.dart';

enum PdfRenderQuality {
  thumb,
  card,
  zoom,
}

/// Ref-counted handle wrapping a rendered PDF page [ui.Image].
///
/// Callers must call [retain] while holding a reference inside widget state and
/// [release] on dispose or handle swap so evicted images are only disposed once
/// no widget can paint them anymore.
class PdfRenderedPageHandle {
  final String cacheKey;
  final ui.Image image;

  int _refCount = 0;
  bool _evicted = false;
  bool _disposed = false;

  PdfRenderedPageHandle({
    required this.cacheKey,
    required this.image,
  });

  bool get isDisposed => _disposed;

  void retain() {
    if (!_disposed) {
      _refCount++;
    }
  }

  void release() {
    if (_refCount > 0) {
      _refCount--;
    }
    _maybeDispose();
  }

  void markEvicted() {
    _evicted = true;
    _maybeDispose();
  }

  void _maybeDispose() {
    if (!_disposed && _evicted && _refCount <= 0) {
      _disposed = true;
      image.dispose();
    }
  }
}

class _OpenPdfEntry {
  final String filePath;
  Future<PdfDocument?>? opening;
  PdfDocument? document;
  int activeOperations = 0;
  bool evicted = false;
  bool disposed = false;

  _OpenPdfEntry(this.filePath);

  void maybeDispose() {
    if (!disposed && evicted && activeOperations <= 0) {
      disposed = true;
      final doc = document;
      document = null;
      doc?.dispose();
    }
  }
}

class _InFlightRender {
  final Future<PdfRenderedPageHandle?> future;
  int listeners = 0;

  _InFlightRender({
    required this.future,
  });
}

/// Renders real PDF pages via PDFium (`pdfrx`) with bounded LRU caching for
/// open documents, thumbnail/card bitmaps, and crisp high-DPI zoom renders.
class PdfRenderService {
  static final PdfRenderService _instance = PdfRenderService._internal();
  factory PdfRenderService() => _instance;
  PdfRenderService._internal();

  static const int _maxOpenDocuments = 12;
  static const int _maxCachedThumbImages = 108;
  static const int _maxCachedZoomImages = 14;

  Future<bool>? _initFuture;
  bool _initFailed = false;
  String? _lastError;

  @visibleForTesting
  bool? overrideNativeSupport;

  bool get hasInitError => _initFailed;
  String? get lastError => _lastError;

  final LinkedHashMap<String, _OpenPdfEntry> _openDocs =
      LinkedHashMap<String, _OpenPdfEntry>();
  final LinkedHashMap<String, PdfRenderedPageHandle> _thumbCache =
      LinkedHashMap<String, PdfRenderedPageHandle>();
  final LinkedHashMap<String, PdfRenderedPageHandle> _zoomCache =
      LinkedHashMap<String, PdfRenderedPageHandle>();
  final Map<String, _InFlightRender> _inFlight = {};
  final Map<String, PdfRenderedPageHandle> _testOverrides = {};

  bool get isNativeRenderSupported {
    if (overrideNativeSupport != null) return overrideNativeSupport!;
    if (_initFailed) return false;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return true;
  }

  @visibleForTesting
  void putTestRenderedPage({
    required String filePath,
    required int pageNumber,
    required ui.Image image,
    PdfRenderQuality quality = PdfRenderQuality.card,
  }) {
    final key = _makeCacheKey(filePath, pageNumber, quality, null);
    final old = _testOverrides.remove(key);
    old?.markEvicted();
    final handle = PdfRenderedPageHandle(cacheKey: key, image: image);
    _testOverrides[key] = handle;
  }

  @visibleForTesting
  void clearTestOverrides() {
    for (final handle in _testOverrides.values) {
      handle.markEvicted();
    }
    _testOverrides.clear();
  }

  void clearAllCaches() {
    _inFlight.clear();

    for (final handle in _thumbCache.values) {
      handle.markEvicted();
    }
    _thumbCache.clear();

    for (final handle in _zoomCache.values) {
      handle.markEvicted();
    }
    _zoomCache.clear();

    for (final entry in _openDocs.values) {
      entry.evicted = true;
      entry.maybeDispose();
    }
    _openDocs.clear();
  }

  String _makeCacheKey(
    String filePath,
    int pageNumber,
    PdfRenderQuality quality,
    int? zoomBucketPx,
  ) {
    final normalizedPath = filePath.trim();
    switch (quality) {
      case PdfRenderQuality.thumb:
        return 't|$normalizedPath|$pageNumber';
      case PdfRenderQuality.card:
        return 'c|$normalizedPath|$pageNumber';
      case PdfRenderQuality.zoom:
        return 'z|$normalizedPath|$pageNumber|${zoomBucketPx ?? 1440}';
    }
  }

  int _bucketZoomSize(double maxEdgePx) {
    final clamped = maxEdgePx.clamp(640.0, 3040.0);
    // Bucket to 160 px increments so intermediate zoom tweaks reuse crisp frames
    return ((clamped / 160.0).ceil() * 160).clamp(640, 3040);
  }

  Future<bool> ensureInitialized() async {
    if (!isNativeRenderSupported) return false;
    if (_initFuture != null) return _initFuture!;
    _initFuture = () async {
      try {
        try {
          await pdfrxFlutterInitialize();
        } catch (_) {
          Pdfrx.cacheDirectoryPath ??=
              '${Directory.systemTemp.path}${Platform.pathSeparator}pdfrx_cache';
          await pdfrxFlutterInitialize();
        }
        _lastError = null;
        return true;
      } catch (e) {
        debugPrint('PdfRenderService init skipped/fallback: $e');
        _lastError = e.toString();
        _initFailed = true;
        return false;
      }
    }();
    return _initFuture!;
  }

  /// Synchronously returns an already-cached rendered handle. Caller must call
  /// [PdfRenderedPageHandle.retain] if stored in state.
  PdfRenderedPageHandle? getCachedRender(
    String? filePath,
    int pageNumber, {
    PdfRenderQuality quality = PdfRenderQuality.card,
    double? targetMaxEdgePx,
  }) {
    final path = filePath?.trim();
    if (path == null || path.isEmpty || pageNumber < 1) return null;

    final bucket = quality == PdfRenderQuality.zoom
        ? _bucketZoomSize(targetMaxEdgePx ?? 1440)
        : null;
    final exactKey = _makeCacheKey(path, pageNumber, quality, bucket);

    final testExact = _testOverrides[exactKey];
    if (testExact != null && !testExact.isDisposed) return testExact;

    final primaryCache =
        quality == PdfRenderQuality.zoom ? _zoomCache : _thumbCache;
    final hit = _touchLru(primaryCache, exactKey);
    if (hit != null && !hit.isDisposed) return hit;

    return null;
  }

  /// Finds the highest-resolution already cached handle for `(filePath, pageNumber)`
  /// so Zoom dialogs and enlarged cards display an immediate non-blank preview
  /// while a higher-DPI render completes.
  PdfRenderedPageHandle? getBestAvailableCachedRender(
    String? filePath,
    int pageNumber,
  ) {
    final path = filePath?.trim();
    if (path == null || path.isEmpty || pageNumber < 1) return null;

    for (final q in [
      PdfRenderQuality.zoom,
      PdfRenderQuality.card,
      PdfRenderQuality.thumb,
    ]) {
      final prefix = q == PdfRenderQuality.zoom
          ? 'z|$path|$pageNumber|'
          : _makeCacheKey(path, pageNumber, q, null);
      for (final entry in _testOverrides.entries) {
        if ((q == PdfRenderQuality.zoom
                ? entry.key.startsWith(prefix)
                : entry.key == prefix) &&
            !entry.value.isDisposed) {
          return entry.value;
        }
      }
    }

    PdfRenderedPageHandle? bestZoom;
    int bestZoomWidth = 0;
    final zoomPrefix = 'z|$path|$pageNumber|';
    for (final entry in _zoomCache.entries) {
      if (entry.key.startsWith(zoomPrefix) && !entry.value.isDisposed) {
        if (entry.value.image.width > bestZoomWidth) {
          bestZoom = entry.value;
          bestZoomWidth = entry.value.image.width;
        }
      }
    }
    if (bestZoom != null) return bestZoom;

    final cardHit = _touchLru(
      _thumbCache,
      _makeCacheKey(path, pageNumber, PdfRenderQuality.card, null),
    );
    if (cardHit != null && !cardHit.isDisposed) return cardHit;

    final thumbHit = _touchLru(
      _thumbCache,
      _makeCacheKey(path, pageNumber, PdfRenderQuality.thumb, null),
    );
    if (thumbHit != null && !thumbHit.isDisposed) return thumbHit;

    return null;
  }

  /// Inspects exact page count and per-page PDF dimensions via PDFium when available.
  Future<PdfDocumentInfo?> inspectDocumentWithPdfium({
    required String fileName,
    required String filePath,
    int? fileSizeBytes,
  }) async {
    if (!isNativeRenderSupported) return null;
    final trimmedPath = filePath.trim();
    if (trimmedPath.isEmpty) return null;

    final ready = await ensureInitialized();
    if (!ready) return null;

    final entry = await _acquireOpenDocEntry(trimmedPath);
    if (entry == null) return null;

    try {
      final doc = entry.document;
      if (doc == null || doc.pages.isEmpty) return null;

      final pages = <PdfPageMeta>[
        for (int i = 0; i < doc.pages.length; i++)
          PdfPageMeta(
            pageNumber: i + 1,
            widthPt: doc.pages[i].width,
            heightPt: doc.pages[i].height,
            sourceFilePath: trimmedPath,
            sourcePageNumber: i + 1,
          ),
      ];

      final resolvedSize = fileSizeBytes ??
          (File(trimmedPath).existsSync() ? File(trimmedPath).lengthSync() : null);

      return PdfDocumentInfo(
        fileName: fileName,
        filePath: trimmedPath,
        pageCount: pages.length,
        fileSizeBytes: resolvedSize,
        pages: pages,
        isFromDisk: true,
        isFallbackEstimate: false,
      );
    } catch (e) {
      debugPrint('PdfRenderService inspectDocumentWithPdfium failed: $e');
      return null;
    } finally {
      _releaseOpenDocEntry(entry);
    }
  }

  /// Renders a specific PDF page and returns a cached [PdfRenderedPageHandle],
  /// or `null` when unavailable (e.g., headless test or unreadable path).
  Future<PdfRenderedPageHandle?> renderPage({
    required String filePath,
    required int pageNumber,
    PdfRenderQuality quality = PdfRenderQuality.card,
    double? targetMaxEdgePx,
  }) async {
    final path = filePath.trim();
    if (path.isEmpty || pageNumber < 1) return null;

    final bucket = quality == PdfRenderQuality.zoom
        ? _bucketZoomSize(targetMaxEdgePx ?? 1440)
        : null;
    final cacheKey = _makeCacheKey(path, pageNumber, quality, bucket);

    final testHit = _testOverrides[cacheKey];
    if (testHit != null && !testHit.isDisposed) return testHit;

    final cacheMap =
        quality == PdfRenderQuality.zoom ? _zoomCache : _thumbCache;
    final existing = _touchLru(cacheMap, cacheKey);
    if (existing != null && !existing.isDisposed) {
      return existing;
    }

    if (!isNativeRenderSupported) return null;
    if (!File(path).existsSync()) return null;

    final existingFlight = _inFlight[cacheKey];
    if (existingFlight != null) {
      existingFlight.listeners++;
      try {
        return await existingFlight.future;
      } finally {
        existingFlight.listeners--;
      }
    }

    final future = _performRender(
      filePath: path,
      pageNumber: pageNumber,
      quality: quality,
      bucketZoomEdgePx: bucket,
      cacheKey: cacheKey,
    );
    final flight = _InFlightRender(future: future);
    flight.listeners = 1;
    _inFlight[cacheKey] = flight;

    try {
      return await future;
    } finally {
      flight.listeners--;
      if (identical(_inFlight[cacheKey], flight)) {
        _inFlight.remove(cacheKey);
      }
    }
  }

  Future<PdfRenderedPageHandle?> _performRender({
    required String filePath,
    required int pageNumber,
    required PdfRenderQuality quality,
    required int? bucketZoomEdgePx,
    required String cacheKey,
  }) async {
    final ready = await ensureInitialized();
    if (!ready) return null;

    final entry = await _acquireOpenDocEntry(filePath);
    if (entry == null) return null;

    try {
      final doc = entry.document;
      if (doc == null || pageNumber < 1 || pageNumber > doc.pages.length) {
        return null;
      }

      final page = doc.pages[pageNumber - 1];
      final token = page.createCancellationToken();
      final maxEdge = switch (quality) {
        PdfRenderQuality.thumb => 460.0,
        PdfRenderQuality.card => 880.0,
        PdfRenderQuality.zoom => (bucketZoomEdgePx ?? 1440).toDouble(),
      };

      final pageW = page.width > 1 ? page.width : 595.0;
      final pageH = page.height > 1 ? page.height : 842.0;
      final longer = math.max(pageW, pageH);
      final scale = maxEdge / longer;
      final targetW = math.max(48.0, (pageW * scale).roundToDouble());
      final targetH = math.max(48.0, (pageH * scale).roundToDouble());

      final ui.Image? rendered = await page.renderForDisplay(
        width: targetW.round(),
        height: targetH.round(),
        fullWidth: targetW,
        fullHeight: targetH,
        backgroundColor: 0xffffffff,
        cancellationToken: token,
      );
      if (rendered == null) return null;

      final handle = PdfRenderedPageHandle(
        cacheKey: cacheKey,
        image: rendered,
      );
      final targetCache =
          quality == PdfRenderQuality.zoom ? _zoomCache : _thumbCache;
      final limit = quality == PdfRenderQuality.zoom
          ? _maxCachedZoomImages
          : _maxCachedThumbImages;
      _putLru(targetCache, cacheKey, handle, limit);
      return handle;
    } catch (e) {
      debugPrint('PdfRenderService render error ($filePath p.$pageNumber): $e');
      return null;
    } finally {
      _releaseOpenDocEntry(entry);
    }
  }

  Future<_OpenPdfEntry?> _acquireOpenDocEntry(String filePath) async {
    var entry = _openDocs.remove(filePath);
    if (entry != null && !entry.evicted && !entry.disposed) {
      _openDocs[filePath] = entry;
      entry.activeOperations++;
      try {
        final doc = entry.document ?? await entry.opening;
        if (doc == null || entry.disposed) {
          _releaseOpenDocEntry(entry);
          return null;
        }
        return entry;
      } catch (_) {
        _releaseOpenDocEntry(entry);
        return null;
      }
    }

    if (!File(filePath).existsSync()) return null;

    final newEntry = _OpenPdfEntry(filePath);
    newEntry.activeOperations = 1;
    newEntry.opening = () async {
      try {
        final doc = await PdfDocument.openFile(
          filePath,
          useProgressiveLoading: false,
        );
        if (newEntry.disposed || newEntry.evicted) {
          await doc.dispose();
          return null;
        }
        newEntry.document = doc;
        return doc;
      } catch (e) {
        debugPrint('PdfRenderService openFile failed ($filePath): $e');
        return null;
      }
    }();

    _openDocs[filePath] = newEntry;
    _evictOldOpenDocs();

    try {
      final doc = await newEntry.opening;
      if (doc == null || newEntry.disposed) {
        _releaseOpenDocEntry(newEntry);
        return null;
      }
      return newEntry;
    } catch (_) {
      _releaseOpenDocEntry(newEntry);
      return null;
    }
  }

  void _releaseOpenDocEntry(_OpenPdfEntry entry) {
    if (entry.activeOperations > 0) {
      entry.activeOperations--;
    }
    entry.maybeDispose();
  }

  void _evictOldOpenDocs() {
    while (_openDocs.length > _maxOpenDocuments) {
      final oldestKey = _openDocs.keys.first;
      final oldest = _openDocs.remove(oldestKey);
      if (oldest != null) {
        oldest.evicted = true;
        oldest.maybeDispose();
      }
    }
  }

  PdfRenderedPageHandle? _touchLru(
    LinkedHashMap<String, PdfRenderedPageHandle> map,
    String key,
  ) {
    final item = map.remove(key);
    if (item != null) {
      if (item.isDisposed) {
        return null;
      }
      map[key] = item;
    }
    return item;
  }

  void _putLru(
    LinkedHashMap<String, PdfRenderedPageHandle> map,
    String key,
    PdfRenderedPageHandle value,
    int maxEntries,
  ) {
    final existing = map.remove(key);
    if (existing != null && !identical(existing, value)) {
      existing.markEvicted();
    }
    map[key] = value;
    while (map.length > maxEntries) {
      final oldestKey = map.keys.first;
      final oldest = map.remove(oldestKey);
      oldest?.markEvicted();
    }
  }
}
