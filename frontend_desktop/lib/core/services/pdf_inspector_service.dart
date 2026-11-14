import 'dart:io' show File, zlib;
import 'dart:isolate' show Isolate;
import 'dart:typed_data';

import 'pdf_render_service.dart';

class PdfPageMeta {
  final int pageNumber;
  final double widthPt;
  final double heightPt;
  final int rotation;
  final int userRotation;
  final String? sourceFilePath;
  final int? sourcePageNumber;

  const PdfPageMeta({
    required this.pageNumber,
    this.widthPt = 595.0,
    this.heightPt = 842.0,
    this.rotation = 0,
    this.userRotation = 0,
    this.sourceFilePath,
    this.sourcePageNumber,
  });

  int get normalizedUserRotation => ((userRotation % 360) + 360) % 360;

  int get userQuarterTurns => (normalizedUserRotation ~/ 90) % 4;

  int get effectiveRotation => (((rotation + userRotation) % 360) + 360) % 360;

  double get effectiveWidthPt =>
      (effectiveRotation % 180 == 90) ? heightPt : widthPt;

  double get effectiveHeightPt =>
      (effectiveRotation % 180 == 90) ? widthPt : heightPt;

  PdfPageMeta copyWith({
    int? pageNumber,
    double? widthPt,
    double? heightPt,
    int? rotation,
    int? userRotation,
    String? sourceFilePath,
    int? sourcePageNumber,
  }) {
    return PdfPageMeta(
      pageNumber: pageNumber ?? this.pageNumber,
      widthPt: widthPt ?? this.widthPt,
      heightPt: heightPt ?? this.heightPt,
      rotation: rotation ?? this.rotation,
      userRotation: userRotation ?? this.userRotation,
      sourceFilePath: sourceFilePath ?? this.sourceFilePath,
      sourcePageNumber: sourcePageNumber ?? this.sourcePageNumber,
    );
  }

  double get aspectRatio => effectiveHeightPt > 0
      ? (effectiveWidthPt / effectiveHeightPt)
      : (595.0 / 842.0);

  bool get isLandscape => effectiveWidthPt > effectiveHeightPt;

  String get paperSizeLabel {
    final shortSide = effectiveWidthPt < effectiveHeightPt
        ? effectiveWidthPt
        : effectiveHeightPt;
    final longSide = effectiveWidthPt < effectiveHeightPt
        ? effectiveHeightPt
        : effectiveWidthPt;

    bool near(double a, double b, double c, double d) =>
        (a - c).abs() <= 14 && (b - d).abs() <= 14;

    String base;
    if (near(shortSide, longSide, 595, 842)) {
      base = 'A4';
    } else if (near(shortSide, longSide, 842, 1191)) {
      base = 'A3';
    } else if (near(shortSide, longSide, 420, 595)) {
      base = 'A5';
    } else if (near(shortSide, longSide, 612, 792)) {
      base = 'Letter';
    } else if (near(shortSide, longSide, 612, 1008)) {
      base = 'Legal';
    } else if (near(shortSide, longSide, 612, 936) ||
        near(shortSide, longSide, 595, 935)) {
      base = 'F4';
    } else {
      base = '${effectiveWidthPt.round()}×${effectiveHeightPt.round()}';
    }

    return isLandscape ? '$base (L)' : base;
  }
}

class PdfDocumentInfo {
  final String fileName;
  final String? filePath;
  final int pageCount;
  final int? fileSizeBytes;
  final List<PdfPageMeta> pages;
  final bool isFromDisk;
  final bool isFallbackEstimate;

  const PdfDocumentInfo({
    required this.fileName,
    this.filePath,
    required this.pageCount,
    this.fileSizeBytes,
    required this.pages,
    this.isFromDisk = false,
    this.isFallbackEstimate = false,
  });

  String get formattedFileSize {
    final bytes = fileSizeBytes;
    if (bytes == null || bytes < 0) return 'Simulasi';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}

class PdfInspectorService {
  static final PdfInspectorService _instance = PdfInspectorService._internal();
  factory PdfInspectorService() => _instance;
  PdfInspectorService._internal();

  static const int _isolateThresholdBytes = 256 * 1024;

  final Map<String, PdfDocumentInfo> _cache = {};
  final Map<String, Future<PdfDocumentInfo>> _inFlightInspects = {};

  void clearCache() {
    _cache.clear();
    _inFlightInspects.clear();
  }

  PdfDocumentInfo? getCached(
    String fileName,
    String? filePath, {
    int? hintPageCount,
  }) {
    final trimmedPath = filePath?.trim();
    if (trimmedPath != null && trimmedPath.isNotEmpty) {
      final byPath = _cache[trimmedPath];
      if (byPath != null) return byPath;
    }
    return _cache[_cacheKey(fileName, trimmedPath, hintPageCount)];
  }

  void putTestDocument(PdfDocumentInfo info) {
    final key = _cacheKey(info.fileName, info.filePath, info.pageCount);
    _cache[key] = info;
    if (info.filePath != null && info.filePath!.isNotEmpty) {
      _cache[info.filePath!] = info;
    }
  }

  String _cacheKey(String fileName, String? filePath, int? hintPageCount) {
    if (filePath != null && filePath.isNotEmpty) {
      return '$filePath|${hintPageCount ?? ''}';
    }
    return 'mem:$fileName|${hintPageCount ?? ''}';
  }

  Future<PdfDocumentInfo> inspectFile({
    required String fileName,
    String? filePath,
    int? hintPageCount,
  }) async {
    final trimmedPath = filePath?.trim();
    if (trimmedPath != null && trimmedPath.isNotEmpty) {
      final cachedByPath = _cache[trimmedPath];
      if (cachedByPath != null) {
        return cachedByPath;
      }
    }

    final fallbackKey = _cacheKey(fileName, trimmedPath, hintPageCount);
    if (trimmedPath == null || trimmedPath.isEmpty) {
      final cachedFallback = _cache[fallbackKey];
      if (cachedFallback != null) {
        return cachedFallback;
      }
    }

    final flightKey = (trimmedPath != null && trimmedPath.isNotEmpty)
        ? 'file:${trimmedPath.toLowerCase()}'
        : fallbackKey;
    final existingFlight = _inFlightInspects[flightKey];
    if (existingFlight != null) {
      return existingFlight;
    }

    final future = _performInspectFile(
      fileName: fileName,
      trimmedPath: trimmedPath,
      hintPageCount: hintPageCount,
      fallbackKey: fallbackKey,
    );
    _inFlightInspects[flightKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightInspects[flightKey], future)) {
        _inFlightInspects.remove(flightKey);
      }
    }
  }

  Future<PdfDocumentInfo> _performInspectFile({
    required String fileName,
    String? trimmedPath,
    int? hintPageCount,
    required String fallbackKey,
  }) async {
    if (trimmedPath != null && trimmedPath.isNotEmpty) {
      final cachedByPath = _cache[trimmedPath];
      if (cachedByPath != null) {
        return cachedByPath;
      }
      try {
        final file = File(trimmedPath);
        if (file.existsSync()) {
          final fileLen = file.lengthSync();
          final renderService = PdfRenderService();
          if (renderService.isNativeRenderSupported) {
            final pdfiumParsed = await renderService.inspectDocumentWithPdfium(
              fileName: fileName,
              filePath: trimmedPath,
              fileSizeBytes: fileLen,
            );
            if (pdfiumParsed != null) {
              _cache[trimmedPath] = pdfiumParsed;
              return pdfiumParsed;
            }
          }
          final PdfDocumentInfo parsed;
          if (fileLen >= _isolateThresholdBytes) {
            parsed = await Isolate.run(() {
              final bytes = File(trimmedPath).readAsBytesSync();
              return _parsePdfBytesSync(
                bytes,
                fileName: fileName,
                filePath: trimmedPath,
              );
            });
          } else {
            await Future<void>.delayed(Duration.zero);
            final bytes = file.readAsBytesSync();
            parsed = _parsePdfBytesSync(
              bytes,
              fileName: fileName,
              filePath: trimmedPath,
            );
          }
          _cache[trimmedPath] = parsed;
          return parsed;
        }
      } catch (_) {
        // Jatuh kembali ke estimasi placeholder bila file tidak dapat dibaca
      }
    }

    final cachedFallback = _cache[fallbackKey];
    if (cachedFallback != null) {
      return cachedFallback;
    }

    final count = (hintPageCount != null && hintPageCount > 0) ? hintPageCount : 8;
    final pages = List<PdfPageMeta>.generate(
      count,
      (i) => PdfPageMeta(pageNumber: i + 1),
    );
    final fallback = PdfDocumentInfo(
      fileName: fileName,
      filePath: trimmedPath,
      pageCount: count,
      fileSizeBytes: null,
      pages: pages,
      isFromDisk: false,
      isFallbackEstimate: true,
    );
    _cache[fallbackKey] = fallback;
    return fallback;
  }

  PdfDocumentInfo parsePdfBytes(
    Uint8List bytes, {
    required String fileName,
    String? filePath,
  }) {
    return _parsePdfBytesSync(
      bytes,
      fileName: fileName,
      filePath: filePath,
    );
  }

  /// Parses page range specifications like `"1-3, 5, 8-6"` into sorted unique 1-based page numbers.
  static List<int> parsePageRangeSpec(String spec, int maxPage) {
    if (maxPage <= 0 || spec.trim().isEmpty) return const [];
    final selected = <int>{};
    final parts = spec.split(RegExp(r'[,;]+'));
    for (final rawPart in parts) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final rangeMatch = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(part);
      if (rangeMatch != null) {
        final a = int.tryParse(rangeMatch.group(1)!);
        final b = int.tryParse(rangeMatch.group(2)!);
        if (a != null && b != null) {
          final start = a < b ? a : b;
          final end = a < b ? b : a;
          for (int p = start; p <= end; p++) {
            if (p >= 1 && p <= maxPage) selected.add(p);
          }
        }
      } else {
        final single = int.tryParse(part);
        if (single != null && single >= 1 && single <= maxPage) {
          selected.add(single);
        }
      }
    }
    final list = selected.toList()..sort();
    return list;
  }

  /// Compacts `[2, 3, 4, 5]` into `"2-5"`, or `[2, 5]` into `"2, 5"`.
  static String formatCompactPageRanges(List<int> pages) {
    if (pages.isEmpty) return '';
    final sorted = pages.toSet().toList()..sort();
    final ranges = <String>[];
    int start = sorted.first;
    int prev = sorted.first;

    for (int i = 1; i < sorted.length; i++) {
      final curr = sorted[i];
      if (curr == prev + 1) {
        prev = curr;
      } else {
        ranges.add(start == prev ? '$start' : '$start-$prev');
        start = curr;
        prev = curr;
      }
    }
    ranges.add(start == prev ? '$start' : '$start-$prev');
    return ranges.join(', ');
  }

  /// Parses custom page order expressions like `"3, 1, 2"` or `"4-1"` for `maxPage`.
  /// Preserves explicit order without duplicates and optionally appends missing pages from `1..maxPage`.
  static List<int> parseOrderSpec(
    String spec,
    int maxPage, {
    bool appendMissing = true,
  }) {
    if (maxPage <= 0) return const [];
    final trimmed = spec.trim();
    if (trimmed.isEmpty) {
      return List<int>.generate(maxPage, (i) => i + 1);
    }

    final result = <int>[];
    final seen = <int>{};
    final parts = trimmed.split(RegExp(r'[,;|\s]+'));

    for (final rawPart in parts) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final rangeMatch = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(part);
      if (rangeMatch != null) {
        final a = int.tryParse(rangeMatch.group(1)!);
        final b = int.tryParse(rangeMatch.group(2)!);
        if (a != null && b != null) {
          final step = a <= b ? 1 : -1;
          for (int p = a; step > 0 ? p <= b : p >= b; p += step) {
            if (p >= 1 && p <= maxPage && seen.add(p)) {
              result.add(p);
            }
          }
        }
      } else {
        final single = int.tryParse(part);
        if (single != null &&
            single >= 1 &&
            single <= maxPage &&
            seen.add(single)) {
          result.add(single);
        }
      }
    }

    if (result.isEmpty) {
      return List<int>.generate(maxPage, (i) => i + 1);
    }

    if (appendMissing) {
      for (int p = 1; p <= maxPage; p++) {
        if (seen.add(p)) {
          result.add(p);
        }
      }
    }
    return result;
  }
}

PdfDocumentInfo _parsePdfBytesSync(
  Uint8List bytes, {
  required String fileName,
  String? filePath,
}) {
  final content = String.fromCharCodes(bytes);
  final objects = <int, String>{};

  final objHeaderRegex = RegExp(r'(\d+)\s+(\d+)\s+obj\b');
  final lengthRegex = RegExp(r'/Length\s+(\d+)\b(?!\s+\d+\s+R)');
  int searchFrom = 0;

  while (searchFrom < content.length) {
    final iterator = objHeaderRegex.allMatches(content, searchFrom).iterator;
    if (!iterator.moveNext()) break;
    final match = iterator.current;

    final objNum = int.tryParse(match.group(1)!) ?? 0;
    final objBodyStart = match.end;

    final endObjIdx = _findToken(content, 'endobj', objBodyStart);
    final streamKeywordIdx = _findStreamKeyword(
      content,
      objBodyStart,
      maxIndex: endObjIdx,
    );

    if (streamKeywordIdx != -1 &&
        (endObjIdx == -1 || streamKeywordIdx < endObjIdx)) {
      final dictPart = content.substring(objBodyStart, streamKeywordIdx);
      objects[objNum] = dictPart;

      int streamDataStart = streamKeywordIdx + 6;
      if (streamDataStart < content.length &&
          content.codeUnitAt(streamDataStart) == 13) {
        streamDataStart++;
      }
      if (streamDataStart < content.length &&
          content.codeUnitAt(streamDataStart) == 10) {
        streamDataStart++;
      }

      int streamDataEnd = -1;
      final lengthMatch = lengthRegex.firstMatch(dictPart);
      if (lengthMatch != null) {
        final declaredLen = int.tryParse(lengthMatch.group(1)!) ?? -1;
        if (declaredLen >= 0 &&
            streamDataStart + declaredLen <= bytes.length) {
          final candidateEnd = streamDataStart + declaredLen;
          final afterLimit = (candidateEnd + 16 < content.length)
              ? candidateEnd + 16
              : content.length;
          final tail = content.substring(candidateEnd, afterLimit);
          if (tail.trimLeft().startsWith('endstream')) {
            streamDataEnd = candidateEnd;
          }
        }
      }

      int endStreamIdx;
      if (streamDataEnd != -1) {
        endStreamIdx = content.indexOf('endstream', streamDataEnd);
      } else {
        endStreamIdx = content.indexOf('endstream', streamDataStart);
        streamDataEnd = endStreamIdx != -1 ? endStreamIdx : streamDataStart;
        while (streamDataEnd > streamDataStart &&
            (bytes[streamDataEnd - 1] == 10 || bytes[streamDataEnd - 1] == 13)) {
          streamDataEnd--;
        }
      }

      if (_looksLikeObjStm(dictPart) && streamDataEnd > streamDataStart) {
        _extractObjStm(
          dictPart: dictPart,
          streamBytes: Uint8List.sublistView(
            bytes,
            streamDataStart,
            streamDataEnd,
          ),
          objects: objects,
        );
      }

      if (endStreamIdx != -1) {
        final postStreamEndObj = _findToken(
          content,
          'endobj',
          endStreamIdx + 9,
        );
        searchFrom =
            postStreamEndObj != -1 ? postStreamEndObj + 6 : endStreamIdx + 9;
      } else {
        searchFrom = streamDataEnd;
      }
    } else if (endObjIdx != -1) {
      objects[objNum] = content.substring(objBodyStart, endObjIdx);
      searchFrom = endObjIdx + 6;
    } else {
      objects[objNum] = content.substring(objBodyStart);
      break;
    }
  }

  int? catalogPagesRoot;
  final catalogRegex = RegExp(r'/Type\s*/Catalog\b');
  final pagesRefRegex = RegExp(r'/Pages\s+(\d+)\s+\d+\s+R');
  for (final entry in objects.entries) {
    if (catalogRegex.hasMatch(entry.value)) {
      final pagesRef = pagesRefRegex.firstMatch(entry.value);
      if (pagesRef != null) {
        catalogPagesRoot = int.tryParse(pagesRef.group(1)!);
      }
    }
  }

  final pageMetas = <PdfPageMeta>[];
  int? declaredCount;
  _Box inheritRootBox = const _Box(595.0, 842.0);
  int inheritRootRot = 0;

  if (catalogPagesRoot != null && objects.containsKey(catalogPagesRoot)) {
    final rootBody = objects[catalogPagesRoot]!;
    declaredCount = _extractCount(rootBody);
    inheritRootBox = _extractBox(rootBody) ?? inheritRootBox;
    inheritRootRot = _extractRotation(rootBody) ?? 0;

    final visited = <int>{};
    _collectPagesFromNode(
      nodeObjNum: catalogPagesRoot,
      objects: objects,
      inheritedBox: inheritRootBox,
      inheritedRotation: inheritRootRot,
      visited: visited,
      outPages: pageMetas,
    );
  }

  if (declaredCount == null || declaredCount <= 0) {
    int maxPagesNodeCount = 0;
    final pagesTypeRegex = RegExp(r'/Type\s*/Pages\b');
    for (final body in objects.values) {
      if (pagesTypeRegex.hasMatch(body)) {
        final c = _extractCount(body);
        if (c != null && c > maxPagesNodeCount) {
          maxPagesNodeCount = c;
          inheritRootBox = _extractBox(body) ?? inheritRootBox;
          inheritRootRot = _extractRotation(body) ?? inheritRootRot;
        }
      }
    }
    if (maxPagesNodeCount > 0) {
      declaredCount = maxPagesNodeCount;
    }
  }

  if (pageMetas.isEmpty) {
    for (final body in objects.values) {
      if (_isLeafPageDict(body)) {
        final box = _extractBox(body) ?? inheritRootBox;
        final rot = _extractRotation(body) ?? inheritRootRot;
        pageMetas.add(
          PdfPageMeta(
            pageNumber: pageMetas.length + 1,
            widthPt: box.width,
            heightPt: box.height,
            rotation: rot,
          ),
        );
      }
    }
  }

  int finalCount;
  if (declaredCount != null && declaredCount > 0) {
    finalCount = declaredCount;
  } else if (pageMetas.isNotEmpty) {
    finalCount = pageMetas.length;
  } else {
    final fallbackMatches =
        RegExp(r'/Type\s*/Page\b(?![sS])').allMatches(content).length;
    finalCount = fallbackMatches > 0 ? fallbackMatches : 1;
  }

  while (pageMetas.length < finalCount) {
    pageMetas.add(
      PdfPageMeta(
        pageNumber: pageMetas.length + 1,
        widthPt: inheritRootBox.width,
        heightPt: inheritRootBox.height,
        rotation: inheritRootRot,
      ),
    );
  }

  final rawTrimmedPages = pageMetas.length > finalCount
      ? pageMetas.sublist(0, finalCount)
      : pageMetas;
  final trimmedPages = [
    for (int i = 0; i < rawTrimmedPages.length; i++)
      PdfPageMeta(
        pageNumber: rawTrimmedPages[i].pageNumber,
        widthPt: rawTrimmedPages[i].widthPt,
        heightPt: rawTrimmedPages[i].heightPt,
        rotation: rawTrimmedPages[i].rotation,
        sourceFilePath: filePath,
        sourcePageNumber: rawTrimmedPages[i].pageNumber,
      ),
  ];

  return PdfDocumentInfo(
    fileName: fileName,
    filePath: filePath,
    pageCount: finalCount,
    fileSizeBytes: bytes.length,
    pages: trimmedPages,
    isFromDisk: true,
    isFallbackEstimate: false,
  );
}

final RegExp _kidsRegex = RegExp(r'/Kids\s*\[([\s\S]*?)\]');
final RegExp _childRefRegex = RegExp(r'(\d+)\s+\d+\s+R');
final RegExp _leafPageRegex = RegExp(r'/Type\s*/Page\b(?![sS])');
final RegExp _kidsBracketRegex = RegExp(r'/Kids\s*\[');
final RegExp _countRegex = RegExp(r'/Count\s+(\d+)\b');
final RegExp _cropBoxRegex = RegExp(
  r'/CropBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]',
);
final RegExp _mediaBoxRegex = RegExp(
  r'/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]',
);
final RegExp _rotateRegex = RegExp(r'/Rotate\s+(-?\d+)\b');

void _collectPagesFromNode({
  required int nodeObjNum,
  required Map<int, String> objects,
  required _Box inheritedBox,
  required int inheritedRotation,
  required Set<int> visited,
  required List<PdfPageMeta> outPages,
}) {
  if (!visited.add(nodeObjNum)) return;
  final body = objects[nodeObjNum];
  if (body == null) return;

  final box = _extractBox(body) ?? inheritedBox;
  final rot = _extractRotation(body) ?? inheritedRotation;

  final kidsMatch = _kidsRegex.firstMatch(body);
  if (kidsMatch != null) {
    final kidsContent = kidsMatch.group(1)!;
    for (final m in _childRefRegex.allMatches(kidsContent)) {
      final childNum = int.tryParse(m.group(1)!);
      if (childNum != null) {
        _collectPagesFromNode(
          nodeObjNum: childNum,
          objects: objects,
          inheritedBox: box,
          inheritedRotation: rot,
          visited: visited,
          outPages: outPages,
        );
      }
    }
    return;
  }

  if (_isLeafPageDict(body)) {
    outPages.add(
      PdfPageMeta(
        pageNumber: outPages.length + 1,
        widthPt: box.width,
        heightPt: box.height,
        rotation: rot,
      ),
    );
  }
}

bool _isLeafPageDict(String body) {
  return _leafPageRegex.hasMatch(body) && !_kidsBracketRegex.hasMatch(body);
}

int? _extractCount(String body) {
  final m = _countRegex.firstMatch(body);
  return m != null ? int.tryParse(m.group(1)!) : null;
}

_Box? _extractBox(String body) {
  final m = _cropBoxRegex.firstMatch(body) ?? _mediaBoxRegex.firstMatch(body);
  if (m == null) return null;
  final x1 = double.tryParse(m.group(1)!) ?? 0.0;
  final y1 = double.tryParse(m.group(2)!) ?? 0.0;
  final x2 = double.tryParse(m.group(3)!) ?? 595.0;
  final y2 = double.tryParse(m.group(4)!) ?? 842.0;
  final w = (x2 - x1).abs();
  final h = (y2 - y1).abs();
  if (w < 10 || h < 10) return null;
  return _Box(w, h);
}

int? _extractRotation(String body) {
  final m = _rotateRegex.firstMatch(body);
  if (m == null) return null;
  final raw = int.tryParse(m.group(1)!) ?? 0;
  return ((raw % 360) + 360) % 360;
}

int _findToken(String content, String token, int start) {
  int idx = start;
  while (idx < content.length) {
    final found = content.indexOf(token, idx);
    if (found == -1) return -1;
    final beforeOk = found == 0 || _isDelimiter(content.codeUnitAt(found - 1));
    final afterPos = found + token.length;
    final afterOk =
        afterPos >= content.length || _isDelimiter(content.codeUnitAt(afterPos));
    if (beforeOk && afterOk) return found;
    idx = found + token.length;
  }
  return -1;
}

int _findStreamKeyword(String content, int start, {int maxIndex = -1}) {
  int idx = start;
  final limit =
      (maxIndex != -1 && maxIndex < content.length) ? maxIndex : content.length;
  while (idx < limit) {
    final found = content.indexOf('stream', idx);
    if (found == -1 || found >= limit) return -1;
    final beforeOk = found == 0 || _isDelimiter(content.codeUnitAt(found - 1));
    final afterPos = found + 6;
    final afterCode = afterPos < content.length ? content.codeUnitAt(afterPos) : -1;
    final afterOk = afterCode == 10 || afterCode == 13;
    if (beforeOk && afterOk) return found;
    idx = found + 6;
  }
  return -1;
}

bool _isDelimiter(int code) {
  return code == 32 ||
      code == 9 ||
      code == 10 ||
      code == 13 ||
      code == 47 ||
      code == 60 ||
      code == 62 ||
      code == 91 ||
      code == 93 ||
      code == 40 ||
      code == 41;
}

final RegExp _objStmTypeRegex = RegExp(r'/Type\s*/ObjStm\b');
final RegExp _objStmNRegex = RegExp(r'/N\s+(\d+)\b');
final RegExp _objStmFirstRegex = RegExp(r'/First\s+(\d+)\b');
final RegExp _flateFilterRegex = RegExp(r'/Filter\s*(?:\[\s*)?/FlateDecode\b');
final RegExp _digitsRegex = RegExp(r'\d+');

bool _looksLikeObjStm(String dictPart) {
  return _objStmTypeRegex.hasMatch(dictPart);
}

void _extractObjStm({
  required String dictPart,
  required Uint8List streamBytes,
  required Map<int, String> objects,
}) {
  final nMatch = _objStmNRegex.firstMatch(dictPart);
  final firstMatch = _objStmFirstRegex.firstMatch(dictPart);
  if (nMatch == null || firstMatch == null) return;

  final n = int.tryParse(nMatch.group(1)!) ?? 0;
  final first = int.tryParse(firstMatch.group(1)!) ?? 0;
  if (n <= 0 || first <= 0) return;

  List<int> decoded = streamBytes;
  if (_flateFilterRegex.hasMatch(dictPart)) {
    try {
      decoded = zlib.decode(streamBytes);
    } catch (_) {
      return;
    }
  }

  if (first >= decoded.length) return;
  final headerStr = String.fromCharCodes(decoded.sublist(0, first));
  final ints = _digitsRegex
      .allMatches(headerStr)
      .map((m) => int.tryParse(m.group(0)!) ?? 0)
      .toList();

  final pairCount = (ints.length ~/ 2) < n ? (ints.length ~/ 2) : n;
  for (int i = 0; i < pairCount; i++) {
    final embeddedObjNum = ints[i * 2];
    final relOffset = ints[i * 2 + 1];
    final startOffset = first + relOffset;
    final endOffset = (i + 1 < pairCount)
        ? first + ints[(i + 1) * 2 + 1]
        : decoded.length;
    if (startOffset >= decoded.length || endOffset <= startOffset) continue;
    final safeEnd = endOffset > decoded.length ? decoded.length : endOffset;
    final objText = String.fromCharCodes(decoded.sublist(startOffset, safeEnd));
    objects[embeddedObjNum] = objText;
  }
}

class _Box {
  final double width;
  final double height;

  const _Box(this.width, this.height);
}
