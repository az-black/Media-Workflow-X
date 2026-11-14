int normalizePdfRotation(int degrees) => ((degrees % 360) + 360) % 360;

enum PdfViewMode {
  overview,
  splitPool,
  splitSeparatePool,
  reorderPool,
  mergePool,
}

class PoolFileRef {
  final String fileName;
  final String? filePath;
  final int? pageCount;
  final String? pageRange;
  final String sourcePoolTitle;
  final Map<int, int> pageRotations;

  const PoolFileRef({
    required this.fileName,
    this.filePath,
    this.pageCount,
    this.pageRange,
    this.sourcePoolTitle = '',
    this.pageRotations = const {},
  });
}

class PoolSlot {
  final String id;
  String label;
  String? fileName;
  String? filePath;
  String? pageRange;
  int? pageCount;
  bool isInherited;
  List<String> inheritedFiles;
  List<PoolFileRef> inheritedFileRefs;
  Map<int, int> pageRotations;
  Map<String, Map<int, int>> inheritedPageRotations;

  PoolSlot({
    required this.id,
    required this.label,
    this.fileName,
    this.filePath,
    this.pageRange,
    this.pageCount,
    this.isInherited = false,
    this.inheritedFiles = const [],
    this.inheritedFileRefs = const [],
    Map<int, int>? pageRotations,
    Map<String, Map<int, int>>? inheritedPageRotations,
  })  : pageRotations =
            pageRotations != null ? Map<int, int>.from(pageRotations) : {},
        inheritedPageRotations = inheritedPageRotations != null
            ? {
                for (final e in inheritedPageRotations.entries)
                  e.key: Map<int, int>.from(e.value),
              }
            : {};

  static String fileRotationKey(PoolFileRef ref) =>
      '${ref.filePath ?? ''}|${ref.fileName}';

  int getPageRotation(int pageNumber) =>
      normalizePdfRotation(pageRotations[pageNumber] ?? 0);

  void setPageRotation(int pageNumber, int degrees) {
    final normalized = normalizePdfRotation(degrees);
    if (normalized == 0) {
      pageRotations.remove(pageNumber);
    } else {
      pageRotations[pageNumber] = normalized;
    }
  }

  int getInheritedPageRotation(PoolFileRef ref, int pageNumber) {
    final key = fileRotationKey(ref);
    final override = inheritedPageRotations[key];
    if (override != null && override.containsKey(pageNumber)) {
      return normalizePdfRotation(override[pageNumber]!);
    }
    return normalizePdfRotation(ref.pageRotations[pageNumber] ?? 0);
  }

  void setInheritedPageRotation(PoolFileRef ref, int pageNumber, int degrees) {
    final key = fileRotationKey(ref);
    final normalized = normalizePdfRotation(degrees);
    final base = normalizePdfRotation(ref.pageRotations[pageNumber] ?? 0);
    final map = inheritedPageRotations.putIfAbsent(key, () => {});
    if (normalized == base) {
      map.remove(pageNumber);
      if (map.isEmpty) {
        inheritedPageRotations.remove(key);
      }
    } else {
      map[pageNumber] = normalized;
    }
  }

  void resetInheritedRotations(PoolFileRef ref) {
    final key = fileRotationKey(ref);
    if (ref.pageRotations.isEmpty) {
      inheritedPageRotations.remove(key);
      return;
    }
    final map = <int, int>{};
    for (final entry in ref.pageRotations.entries) {
      if (normalizePdfRotation(entry.value) != 0) {
        map[entry.key] = 0;
      }
    }
    if (map.isEmpty) {
      inheritedPageRotations.remove(key);
    } else {
      inheritedPageRotations[key] = map;
    }
  }

  bool get hasFile => fileName != null && fileName!.isNotEmpty;

  List<PoolFileRef> get resolvedInheritedRefs {
    if (inheritedFileRefs.isNotEmpty) return inheritedFileRefs;
    if (inheritedFiles.isEmpty) return const [];
    return inheritedFiles.map((raw) {
      final cleanName = raw.replaceAll(RegExp(r'\s*\(Hal\s+[^)]+\)$'), '').trim();
      return PoolFileRef(
        fileName: cleanName.isEmpty ? raw : cleanName,
      );
    }).toList();
  }

  String? get subLabel {
    if (pageRange != null && pageRange!.trim().isNotEmpty) {
      return 'Hal ${pageRange!.trim()}';
    }
    if (pageCount != null && pageCount! > 0) {
      return '$pageCount Hal';
    }
    return null;
  }
}

class PoolSectionData {
  final String id;
  String title;
  List<PoolSlot> slots;

  PoolSectionData({
    required this.id,
    required this.title,
    required this.slots,
  });

  String get defaultSlotLabel {
    switch (title) {
      case 'Split Pool':
      case 'Split Separate Pool':
        return 'Number Split';
      case 'Reorder Pool':
        return 'Order Number';
      case 'Merge Pool':
        return 'Merge Number';
      default:
        return 'Number Split';
    }
  }

  String labelForSlot(PoolSlot slot) {
    final trimmedRange = slot.pageRange?.trim() ?? '';
    switch (title) {
      case 'Split Pool':
      case 'Split Separate Pool':
        return trimmedRange.isNotEmpty ? 'Split $trimmedRange' : 'Number Split';
      case 'Reorder Pool':
        return trimmedRange.isNotEmpty ? 'Order $trimmedRange' : 'Order Number';
      case 'Merge Pool':
        return 'Merge Number';
      default:
        return defaultSlotLabel;
    }
  }

  void syncSlotLabelsToType() {
    for (final slot in slots) {
      if (!slot.isInherited) {
        slot.label = labelForSlot(slot);
      }
    }
  }

  List<String> getAllFileNames() {
    final list = <String>[];
    for (final slot in slots) {
      if (slot.isInherited) {
        list.addAll(slot.inheritedFiles);
      } else if (slot.hasFile) {
        if (slot.pageRange != null && slot.pageRange!.trim().isNotEmpty) {
          list.add('${slot.fileName} (Hal ${slot.pageRange!.trim()})');
        } else {
          list.add(slot.fileName!);
        }
      } else if (slot.pageRange != null && slot.pageRange!.trim().isNotEmpty) {
        list.add(slot.label);
      } else if (title == 'Merge Pool' &&
          slot.label.isNotEmpty &&
          !slot.label.startsWith('Merge File') &&
          slot.label != 'Merge Number') {
        list.add(slot.label);
      }
    }
    return list;
  }

  List<PoolFileRef> getAllFileRefs() {
    final list = <PoolFileRef>[];
    for (final slot in slots) {
      if (slot.isInherited) {
        for (final ref in slot.resolvedInheritedRefs) {
          final key = PoolSlot.fileRotationKey(ref);
          final mergedRotations = <int, int>{
            ...ref.pageRotations,
            ...?slot.inheritedPageRotations[key],
          }..removeWhere((_, deg) => normalizePdfRotation(deg) == 0);
          list.add(
            PoolFileRef(
              fileName: ref.fileName,
              filePath: ref.filePath,
              pageCount: ref.pageCount,
              pageRange: ref.pageRange,
              sourcePoolTitle:
                  ref.sourcePoolTitle.isNotEmpty ? ref.sourcePoolTitle : title,
              pageRotations: mergedRotations,
            ),
          );
        }
      } else if (slot.hasFile) {
        final cleanRotations = Map<int, int>.from(slot.pageRotations)
          ..removeWhere((_, deg) => normalizePdfRotation(deg) == 0);
        list.add(
          PoolFileRef(
            fileName: slot.fileName!,
            filePath: slot.filePath,
            pageCount: slot.pageCount,
            pageRange: slot.pageRange,
            sourcePoolTitle: title,
            pageRotations: cleanRotations,
          ),
        );
      }
    }
    return list;
  }
}

class PoolDragData {
  final int poolIndex;

  const PoolDragData({required this.poolIndex});
}

class SlotDragData {
  final int poolIndex;
  final int slotIndex;

  const SlotDragData({required this.poolIndex, required this.slotIndex});
}

class RowDragData {
  final int rowIndex;

  const RowDragData({required this.rowIndex});
}

class PageDragData {
  final int pageIndex;

  const PageDragData({required this.pageIndex});
}
