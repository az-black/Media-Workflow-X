import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../models/pdf_models.dart';
import 'backend_service.dart';

class MediaFileEntry {
  static const Set<String> supportedImageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
  };

  final String name;
  final String path;
  final int? sizeBytes;
  final int? pageCount;

  const MediaFileEntry({
    required this.name,
    required this.path,
    this.sizeBytes,
    this.pageCount,
  });

  String get extensionLower {
    final trimmedName = name.trim();
    if (trimmedName.contains('.')) {
      final dot = trimmedName.lastIndexOf('.');
      if (dot >= 0 && dot < trimmedName.length - 1) {
        return trimmedName.substring(dot + 1).toLowerCase();
      }
    }
    final trimmedPath = path.trim();
    final dot = trimmedPath.lastIndexOf('.');
    if (dot >= 0 && dot < trimmedPath.length - 1) {
      return trimmedPath.substring(dot + 1).toLowerCase();
    }
    return '';
  }

  bool get isPdf => extensionLower == 'pdf';

  bool get isImage => supportedImageExtensions.contains(extensionLower);

  String get normalizedKey {
    final cleaned = path.trim();
    if (cleaned.isEmpty) return name.trim().toLowerCase();
    return cleaned.replaceAll('/', '\\').toLowerCase();
  }
}

enum DocEngineType {
  msWord,
  libreOffice,
}

enum SaveLocationMode {
  askEveryTime,
  autoDefaultFolder,
}

class TaskHistoryItem {
  final String id;
  final DateTime timestamp;
  final String taskType;
  final String fileName;
  final String targetFormat;
  final String engineUsed;
  final String status; // 'Sukses', 'Gagal', 'Proses'
  final int durationMs;
  final String originalSize;
  final String resultSize;
  final String outputPath;

  const TaskHistoryItem({
    required this.id,
    required this.timestamp,
    required this.taskType,
    required this.fileName,
    required this.targetFormat,
    required this.engineUsed,
    required this.status,
    required this.durationMs,
    required this.originalSize,
    required this.resultSize,
    required this.outputPath,
  });
}

class SystemLogEntry {
  final DateTime timestamp;
  final String level; // 'INFO', 'SUCCESS', 'WARN', 'ERROR'
  final String message;
  final String source; // 'ENGINE', 'CONVERTER', 'PIPELINE', 'SYSTEM'

  const SystemLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.source,
  });
}

class AppStateService extends ChangeNotifier {
  static final AppStateService _instance = AppStateService._internal();
  factory AppStateService() => _instance;

  AppStateService._internal() {
    _initDefaultLogsAndHistory();
    _initDefaultPdfPools();
    loadFromStorageSync();
  }

  // ==================== NAVIGATION STATE ====================
  int _selectedSidebarIndex = 0;
  int _selectedTopTab = 0;

  int get selectedSidebarIndex => _selectedSidebarIndex;
  int get selectedTopTab => _selectedTopTab;

  void setSelectedSidebarIndex(int index) {
    if (_selectedSidebarIndex != index) {
      _selectedSidebarIndex = index;
      _scheduleSave();
      notifyListeners();
    }
  }

  void setSelectedTopTab(int index) {
    if (_selectedTopTab != index) {
      _selectedTopTab = index;
      _scheduleSave();
      notifyListeners();
    }
  }

  // ==================== PERSISTENCE ====================
  static File? _customStorageFile;
  Timer? _saveDebounceTimer;
  bool _isSaving = false;
  bool _hasPendingSave = false;

  static void setStorageFileForTesting(File? file) {
    _customStorageFile = file;
  }

  File? _getStorageFile() {
    if (_customStorageFile != null) return _customStorageFile;
    if (BackendService.isRunningUnderFlutterTest()) {
      return null;
    }
    String baseDir;
    if (!kIsWeb) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        baseDir = appData;
      } else {
        final userProfile = Platform.environment['USERPROFILE'] ??
            Platform.environment['HOME'] ??
            '.';
        baseDir = '$userProfile\\AppData\\Roaming';
      }
    } else {
      baseDir = '.';
    }
    final appDir = Directory('$baseDir\\MediaWorkflowX');
    if (!appDir.existsSync()) {
      try {
        appDir.createSync(recursive: true);
      } catch (_) {}
    }
    return File('${appDir.path}\\app_state.json');
  }

  void _scheduleSave() {
    if (_isSaving) {
      _hasPendingSave = true;
      return;
    }
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(const Duration(milliseconds: 250), () {
      _performSave();
    });
  }

  Future<void> flushSave() async {
    _saveDebounceTimer?.cancel();
    await _performSave();
  }

  void flushSaveSync() {
    _saveDebounceTimer?.cancel();
    _performSaveSync();
  }

  void saveCurrentState() {
    _scheduleSave();
    notifyListeners();
  }

  Future<void> initPersistence({File? storageFile}) async {
    if (storageFile != null) {
      _customStorageFile = storageFile;
    }
    await _loadFromStorage();
  }

  Future<void> _performSave() async {
    final file = _getStorageFile();
    if (file == null) return;
    _isSaving = true;
    _hasPendingSave = false;
    try {
      final jsonString = jsonEncode(toJson());
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonString, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmpFile.rename(file.path);
    } catch (_) {
      try {
        await file.writeAsString(jsonEncode(toJson()), flush: true);
      } catch (_) {}
    } finally {
      _isSaving = false;
      if (_hasPendingSave) {
        _hasPendingSave = false;
        _scheduleSave();
      }
    }
  }

  void _performSaveSync() {
    final file = _getStorageFile();
    if (file == null) return;
    _isSaving = true;
    _hasPendingSave = false;
    try {
      final jsonString = jsonEncode(toJson());
      final tmpFile = File('${file.path}.tmp');
      tmpFile.writeAsStringSync(jsonString, flush: true);
      if (file.existsSync()) {
        file.deleteSync();
      }
      tmpFile.renameSync(file.path);
    } catch (_) {
      try {
        file.writeAsStringSync(jsonEncode(toJson()), flush: true);
      } catch (_) {}
    } finally {
      _isSaving = false;
    }
  }

  Future<void> _loadFromStorage() async {
    try {
      final file = _getStorageFile();
      if (file == null || !await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _applyLoadedData(data);
    } catch (e) {
      debugPrint('[AppStateService] Gagal memuat state tersimpan: $e');
    }
  }

  void loadFromStorageSync({File? storageFile}) {
    if (storageFile != null) {
      _customStorageFile = storageFile;
    }
    try {
      final file = _getStorageFile();
      if (file == null || !file.existsSync()) return;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      _applyLoadedData(data);
    } catch (e) {
      debugPrint('[AppStateService] Gagal memuat state tersimpan sync: $e');
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'savedAt': DateTime.now().toIso8601String(),
      'navigation': {
        'selectedSidebarIndex': _selectedSidebarIndex,
        'selectedTopTab': _selectedTopTab,
      },
      'engineConfig': {
        'selectedEngine': _selectedEngine.name,
        'autoFallback': _autoFallback,
        'engineTimeoutSeconds': _engineTimeoutSeconds,
        'highDpiRendering': _highDpiRendering,
      },
      'settings': {
        'outputDirectory': _outputDirectory,
        'saveLocationMode': _saveLocationMode.name,
        'lastSavedDirectory': _lastSavedDirectory,
        'fileNamingPattern': _fileNamingPattern,
        'overwriteExisting': _overwriteExisting,
        'maxWorkerThreads': _maxWorkerThreads,
        'enableGpuAcceleration': _enableGpuAcceleration,
        'autoClearQueue': _autoClearQueue,
        'playNotificationSound': _playNotificationSound,
      },
      'mediaTools': {
        'mediaToolsTabIndex': _mediaToolsTabIndex,
        'convertOnly': {
          'format': _convertOnlyFormat,
          'entries': _convertOnlyEntries
              .map((e) => {
                    'name': e.name,
                    'path': e.path,
                    'sizeBytes': e.sizeBytes,
                    'pageCount': e.pageCount,
                  })
              .toList(),
        },
        'compressConvert': {
          'format': _compressFormat,
          'targetPerPage': _compressTargetPerPage,
          'type': _compressType,
          'targetKb': _compressTargetKb,
          'entries': _compressEntries
              .map((e) => {
                    'name': e.name,
                    'path': e.path,
                    'sizeBytes': e.sizeBytes,
                    'pageCount': e.pageCount,
                  })
              .toList(),
        },
        'upscaleAi': {
          'format': _upscaleFormat,
          'model': _upscaleModel,
          'scales': _upscaleModelScales,
          'entries': _upscaleEntries
              .map((e) => {
                    'name': e.name,
                    'path': e.path,
                    'sizeBytes': e.sizeBytes,
                    'pageCount': e.pageCount,
                  })
              .toList(),
        },
      },
      'pdfManager': {
        'viewMode': _pdfViewMode.name,
        'activePoolIndex': _activePdfPoolIndex,
        'activeSlotIndex': _activePdfSlotIndex,
        'pools': _pdfPools
            .map((p) => {
                  'id': p.id,
                  'title': p.title,
                  'slots': p.slots
                      .map((s) => {
                            'id': s.id,
                            'label': s.label,
                            'fileName': s.fileName,
                            'filePath': s.filePath,
                            'pageRange': s.pageRange,
                            'pageCount': s.pageCount,
                            'isInherited': s.isInherited,
                            'pageRotations': s.pageRotations
                                .map((k, v) => MapEntry(k.toString(), v)),
                            'inheritedPageRotations': s.inheritedPageRotations
                                .map(
                              (k, v) => MapEntry(
                                  k,
                                  v.map((k2, v2) =>
                                      MapEntry(k2.toString(), v2))),
                            ),
                          })
                      .toList(),
                })
            .toList(),
      },
      'history': _history
          .map((h) => {
                'id': h.id,
                'timestamp': h.timestamp.toIso8601String(),
                'taskType': h.taskType,
                'fileName': h.fileName,
                'targetFormat': h.targetFormat,
                'engineUsed': h.engineUsed,
                'status': h.status,
                'durationMs': h.durationMs,
                'originalSize': h.originalSize,
                'resultSize': h.resultSize,
                'outputPath': h.outputPath,
              })
          .toList(),
      'systemLogs': _systemLogs
          .take(300)
          .map((l) => {
                'timestamp': l.timestamp.toIso8601String(),
                'level': l.level,
                'message': l.message,
                'source': l.source,
              })
          .toList(),
    };
  }

  void _applyLoadedData(Map<String, dynamic> data) {
    final nav = data['navigation'] as Map<String, dynamic>?;
    if (nav != null) {
      if (nav['selectedSidebarIndex'] is int) {
        _selectedSidebarIndex =
            (nav['selectedSidebarIndex'] as int).clamp(0, 3);
      }
      if (nav['selectedTopTab'] is int) {
        _selectedTopTab = (nav['selectedTopTab'] as int).clamp(0, 1);
      }
    }

    final ec = data['engineConfig'] as Map<String, dynamic>?;
    if (ec != null) {
      final engineStr = ec['selectedEngine'] as String?;
      if (engineStr == DocEngineType.libreOffice.name) {
        _selectedEngine = DocEngineType.libreOffice;
      } else if (engineStr == DocEngineType.msWord.name) {
        _selectedEngine = DocEngineType.msWord;
      }
      if (ec['autoFallback'] is bool) {
        _autoFallback = ec['autoFallback'] as bool;
      }
      if (ec['engineTimeoutSeconds'] is int) {
        _engineTimeoutSeconds = ec['engineTimeoutSeconds'] as int;
      }
      if (ec['highDpiRendering'] is bool) {
        _highDpiRendering = ec['highDpiRendering'] as bool;
      }
    }

    final st = data['settings'] as Map<String, dynamic>?;
    if (st != null) {
      if (st['outputDirectory'] is String &&
          (st['outputDirectory'] as String).isNotEmpty) {
        _outputDirectory = st['outputDirectory'] as String;
      }
      final modeStr = st['saveLocationMode'] as String?;
      if (modeStr == SaveLocationMode.autoDefaultFolder.name) {
        _saveLocationMode = SaveLocationMode.autoDefaultFolder;
      } else if (modeStr == SaveLocationMode.askEveryTime.name) {
        _saveLocationMode = SaveLocationMode.askEveryTime;
      }
      if (st['lastSavedDirectory'] is String) {
        _lastSavedDirectory = st['lastSavedDirectory'] as String;
      }
      if (st['fileNamingPattern'] is String) {
        _fileNamingPattern = st['fileNamingPattern'] as String;
      }
      if (st['overwriteExisting'] is bool) {
        _overwriteExisting = st['overwriteExisting'] as bool;
      }
      if (st['maxWorkerThreads'] is int) {
        _maxWorkerThreads = (st['maxWorkerThreads'] as int).clamp(1, 16);
      }
      if (st['enableGpuAcceleration'] is bool) {
        _enableGpuAcceleration = st['enableGpuAcceleration'] as bool;
      }
      if (st['autoClearQueue'] is bool) {
        _autoClearQueue = st['autoClearQueue'] as bool;
      }
      if (st['playNotificationSound'] is bool) {
        _playNotificationSound = st['playNotificationSound'] as bool;
      }
    }

    final mt = data['mediaTools'] as Map<String, dynamic>?;
    if (mt != null) {
      if (mt['mediaToolsTabIndex'] is int) {
        _mediaToolsTabIndex = (mt['mediaToolsTabIndex'] as int).clamp(0, 2);
      }
      final co = mt['convertOnly'] as Map<String, dynamic>?;
      if (co != null) {
        if (co['format'] is String && (co['format'] as String).isNotEmpty) {
          _convertOnlyFormat = co['format'] as String;
        }
        if (co['entries'] is List) {
          _convertOnlyEntries.clear();
          for (final item in co['entries'] as List) {
            if (item is Map) {
              final path = item['path'] as String? ?? '';
              final name = item['name'] as String? ??
                  BackendService.fileNameFromPath(path);
              if (name.isNotEmpty) {
                _convertOnlyEntries.add(MediaFileEntry(
                  name: name,
                  path: path,
                  sizeBytes: item['sizeBytes'] as int?,
                  pageCount: item['pageCount'] as int?,
                ));
              }
            }
          }
        }
      }

      final cc = mt['compressConvert'] as Map<String, dynamic>?;
      if (cc != null) {
        if (cc['format'] is String) _compressFormat = cc['format'] as String;
        if (cc['targetPerPage'] is String) {
          _compressTargetPerPage = cc['targetPerPage'] as String;
        }
        if (cc['type'] is String) _compressType = cc['type'] as String;
        if (cc['targetKb'] is String) {
          _compressTargetKb = cc['targetKb'] as String;
        }
        if (cc['entries'] is List) {
          _compressEntries.clear();
          for (final item in cc['entries'] as List) {
            if (item is Map) {
              final path = item['path'] as String? ?? '';
              final name = item['name'] as String? ??
                  BackendService.fileNameFromPath(path);
              if (name.isNotEmpty) {
                _compressEntries.add(MediaFileEntry(
                  name: name,
                  path: path,
                  sizeBytes: item['sizeBytes'] as int?,
                  pageCount: item['pageCount'] as int?,
                ));
              }
            }
          }
        }
      }

      final ua = mt['upscaleAi'] as Map<String, dynamic>?;
      if (ua != null) {
        if (ua['format'] is String) _upscaleFormat = ua['format'] as String;
        if (ua['model'] is String) _upscaleModel = ua['model'] as String;
        if (ua['scales'] is Map) {
          final scalesMap = ua['scales'] as Map;
          for (final entry in scalesMap.entries) {
            if (entry.key is String && entry.value is int) {
              _upscaleModelScales[entry.key as String] =
                  (entry.value as int).clamp(1, 16);
            }
          }
        }
        if (ua['entries'] is List) {
          _upscaleEntries.clear();
          for (final item in ua['entries'] as List) {
            if (item is Map) {
              final path = item['path'] as String? ?? '';
              final name = item['name'] as String? ??
                  BackendService.fileNameFromPath(path);
              if (name.isNotEmpty) {
                _upscaleEntries.add(MediaFileEntry(
                  name: name,
                  path: path,
                  sizeBytes: item['sizeBytes'] as int?,
                  pageCount: item['pageCount'] as int?,
                ));
              }
            }
          }
        }
      }
    }

    final pm = data['pdfManager'] as Map<String, dynamic>?;
    if (pm != null) {
      final modeStr = pm['viewMode'] as String?;
      for (final mode in PdfViewMode.values) {
        if (mode.name == modeStr) {
          _pdfViewMode = mode;
          break;
        }
      }
      if (pm['activePoolIndex'] is int) {
        _activePdfPoolIndex = pm['activePoolIndex'] as int;
      }
      if (pm['activeSlotIndex'] is int) {
        _activePdfSlotIndex = pm['activeSlotIndex'] as int;
      }
      if (pm['pools'] is List) {
        final rawPools = pm['pools'] as List;
        final loadedPools = <PoolSectionData>[];
        for (final pItem in rawPools) {
          if (pItem is Map) {
            final pId =
                pItem['id'] as String? ?? 'pool_${loadedPools.length}';
            final pTitle = pItem['title'] as String? ?? 'Split Pool';
            final rawSlots = pItem['slots'] as List? ?? [];
            final loadedSlots = <PoolSlot>[];
            for (final sItem in rawSlots) {
              if (sItem is Map) {
                final sId = sItem['id'] as String? ?? 's_${loadedSlots.length}';
                final sLabel = sItem['label'] as String? ?? 'Slot';
                final sFileName = sItem['fileName'] as String?;
                final sFilePath = sItem['filePath'] as String?;
                final sPageRange = sItem['pageRange'] as String?;
                final sPageCount = sItem['pageCount'] as int?;
                final sIsInherited = sItem['isInherited'] as bool? ?? false;

                final rawPageRotations = sItem['pageRotations'] as Map?;
                final pageRotations = <int, int>{};
                if (rawPageRotations != null) {
                  for (final rEntry in rawPageRotations.entries) {
                    final pNum = int.tryParse(rEntry.key.toString());
                    final deg = rEntry.value as int?;
                    if (pNum != null && deg != null) {
                      pageRotations[pNum] = deg;
                    }
                  }
                }

                final rawInhRotations =
                    sItem['inheritedPageRotations'] as Map?;
                final inhPageRotations = <String, Map<int, int>>{};
                if (rawInhRotations != null) {
                  for (final irEntry in rawInhRotations.entries) {
                    if (irEntry.value is Map) {
                      final innerMap = <int, int>{};
                      for (final subEntry
                          in (irEntry.value as Map).entries) {
                        final pNum = int.tryParse(subEntry.key.toString());
                        final deg = subEntry.value as int?;
                        if (pNum != null && deg != null) {
                          innerMap[pNum] = deg;
                        }
                      }
                      inhPageRotations[irEntry.key.toString()] = innerMap;
                    }
                  }
                }

                loadedSlots.add(PoolSlot(
                  id: sId,
                  label: sLabel,
                  fileName: sFileName,
                  filePath: sFilePath,
                  pageRange: sPageRange,
                  pageCount: sPageCount,
                  isInherited: sIsInherited,
                  pageRotations: pageRotations,
                  inheritedPageRotations: inhPageRotations,
                ));
              }
            }
            loadedPools.add(PoolSectionData(
              id: pId,
              title: pTitle,
              slots: loadedSlots,
            ));
          }
        }
        if (loadedPools.isNotEmpty) {
          _pdfPools = loadedPools;
          updatePdfInheritedSlots();
        }
      }
    }

    final hist = data['history'] as List?;
    if (hist != null) {
      _history.clear();
      for (final item in hist) {
        if (item is Map) {
          try {
            _history.add(TaskHistoryItem(
              id: item['id'] as String? ?? UniqueKey().toString(),
              timestamp:
                  DateTime.tryParse(item['timestamp'] as String? ?? '') ??
                      DateTime.now(),
              taskType: item['taskType'] as String? ?? 'Convert',
              fileName: item['fileName'] as String? ?? 'file',
              targetFormat: item['targetFormat'] as String? ?? 'PDF',
              engineUsed: item['engineUsed'] as String? ?? 'Word',
              status: item['status'] as String? ?? 'Sukses',
              durationMs: item['durationMs'] as int? ?? 0,
              originalSize: item['originalSize'] as String? ?? '0 B',
              resultSize: item['resultSize'] as String? ?? '0 B',
              outputPath: item['outputPath'] as String? ?? '',
            ));
          } catch (_) {}
        }
      }
    }

    final logs = data['systemLogs'] as List?;
    if (logs != null) {
      _systemLogs.clear();
      for (final item in logs) {
        if (item is Map) {
          try {
            _systemLogs.add(SystemLogEntry(
              timestamp:
                  DateTime.tryParse(item['timestamp'] as String? ?? '') ??
                      DateTime.now(),
              level: item['level'] as String? ?? 'INFO',
              message: item['message'] as String? ?? '',
              source: item['source'] as String? ?? 'SYSTEM',
            ));
          } catch (_) {}
        }
      }
    }

    notifyListeners();
  }

  // ==================== ENGINE CONFIG STATE ====================
  DocEngineType _selectedEngine = DocEngineType.msWord;
  bool _autoFallback = true;
  int _engineTimeoutSeconds = 45;
  bool _highDpiRendering = true;
  bool _isEngineOnline = BackendService.isRunningUnderFlutterTest();
  bool _isEngineConnecting = !BackendService.isRunningUnderFlutterTest();
  int _lastLatencyMs = 12;

  String msWordVersion = 'Microsoft Word 365 (64-bit)';
  String msWordPath =
      r'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE';
  bool isMsWordInstalled = true;

  String libreVersion = 'LibreOffice 24.8.2 Community (64-bit)';
  String librePath =
      r'C:\Program Files\LibreOffice\program\soffice.exe';
  bool isLibreInstalled = true;

  bool _hasQpdf = true;
  bool _hasPdfCompressor = true;
  bool _hasRealEsrgan = true;
  bool _hasCppRuntime = true;
  int _realEsrganModelsCount = 5;

  DocEngineType get selectedEngine => _selectedEngine;
  bool get autoFallback => _autoFallback;
  int get engineTimeoutSeconds => _engineTimeoutSeconds;
  bool get hasNoEngineTimeout => _engineTimeoutSeconds <= 0;
  String get engineTimeoutLabel =>
      _engineTimeoutSeconds <= 0 ? 'No Time' : '$_engineTimeoutSeconds Detik';
  bool get highDpiRendering => _highDpiRendering;
  bool get isEngineOnline => _isEngineOnline;
  bool get isEngineConnecting => _isEngineConnecting;
  int get lastLatencyMs => _lastLatencyMs;
  bool get hasQpdf => _hasQpdf;
  bool get hasPdfCompressor => _hasPdfCompressor;
  bool get hasRealEsrgan => _hasRealEsrgan;
  bool get hasCppRuntime => _hasCppRuntime;
  int get realEsrganModelsCount => _realEsrganModelsCount;

  void updateDetectedCapabilities({
    required bool isMsWordInstalled,
    required String msWordVersion,
    required String msWordPath,
    required bool isLibreInstalled,
    required String libreVersion,
    required String librePath,
    required bool hasQpdf,
    required bool hasPdfCompressor,
    required bool hasRealEsrgan,
    required bool hasCppRuntime,
    required int realEsrganModelsCount,
    List<String>? realEsrganModels,
  }) {
    this.isMsWordInstalled = isMsWordInstalled;
    this.msWordVersion = msWordVersion;
    this.msWordPath = msWordPath;
    this.isLibreInstalled = isLibreInstalled;
    this.libreVersion = libreVersion;
    this.librePath = librePath;
    _hasQpdf = hasQpdf;
    _hasPdfCompressor = hasPdfCompressor;
    _hasRealEsrgan = hasRealEsrgan;
    _hasCppRuntime = hasCppRuntime;
    _realEsrganModelsCount = realEsrganModelsCount;
    if (realEsrganModels != null && realEsrganModels.isNotEmpty) {
      _availableUpscaleModels = List<String>.from(realEsrganModels);
      for (final model in _availableUpscaleModels) {
        _upscaleModelScales.putIfAbsent(
          model,
          () => BackendService.defaultUpscaleScale,
        );
      }
      if (!_availableUpscaleModels.contains(_upscaleModel)) {
        _upscaleModel = _availableUpscaleModels.first;
      }
    }
    notifyListeners();
  }

  void setBackendStatus({
    required bool isOnline,
    required bool isConnecting,
    int? latencyMs,
  }) {
    _isEngineOnline = isOnline;
    _isEngineConnecting = isConnecting;
    if (latencyMs != null) {
      _lastLatencyMs = latencyMs;
    }
    notifyListeners();
  }

  String get engineDisplayName => _selectedEngine == DocEngineType.msWord
      ? 'Microsoft Word (COM)'
      : 'LibreOffice (Headless)';

  String get engineShortName =>
      _selectedEngine == DocEngineType.msWord ? 'Word' : 'LibreOffice';

  void setSelectedEngine(DocEngineType engine) {
    if (_selectedEngine != engine) {
      _selectedEngine = engine;
      addSystemLog(
        level: 'INFO',
        message: 'Engine konversi aktif diubah menjadi: $engineDisplayName',
        source: 'ENGINE',
      );
      _scheduleSave();
      notifyListeners();
    }
  }

  void setAutoFallback(bool value) {
    if (_autoFallback != value) {
      _autoFallback = value;
      _scheduleSave();
      notifyListeners();
    }
  }

  void setEngineTimeoutSeconds(int seconds) {
    if (_engineTimeoutSeconds != seconds) {
      _engineTimeoutSeconds = seconds;
      final label =
          seconds <= 0 ? 'No Time (Tanpa Batas Waktu)' : '$seconds Detik';
      addSystemLog(
        level: 'INFO',
        message: 'Batas waktu eksekusi engine diubah menjadi: $label',
        source: 'ENGINE',
      );
      _scheduleSave();
      notifyListeners();
    }
  }

  void setHighDpiRendering(bool value) {
    if (_highDpiRendering != value) {
      _highDpiRendering = value;
      _scheduleSave();
      notifyListeners();
    }
  }

  Future<bool> testEngineConnection() async {
    addSystemLog(
      level: 'INFO',
      message:
          'Menjalankan diagnostik ping ke backend Go & engine $engineDisplayName...',
      source: 'ENGINE',
    );
    _isEngineConnecting = true;
    notifyListeners();

    final backend = BackendService();
    var latency = await backend.pingHealth(timeout: const Duration(seconds: 2));
    if (latency == null) {
      final started = await backend.ensureRunning();
      if (started) {
        latency = backend.lastPingLatencyMs > 0
            ? backend.lastPingLatencyMs
            : 12;
      }
    }

    if (latency != null) {
      _isEngineOnline = true;
      _isEngineConnecting = false;
      _lastLatencyMs = latency;
      addSystemLog(
        level: 'SUCCESS',
        message:
            'Diagnostik backend Go & $engineDisplayName berhasil: Status ONLINE (${_lastLatencyMs}ms). Siap mengeksekusi tugas.',
        source: 'ENGINE',
      );
      notifyListeners();
      return true;
    }

    _isEngineOnline = false;
    _isEngineConnecting = false;
    final detail = backend.lastError;
    addSystemLog(
      level: 'ERROR',
      message: detail != null && detail.isNotEmpty
          ? 'Diagnostik gagal: $detail'
          : 'Diagnostik gagal: Backend Go tidak merespons di ${BackendService.baseUrl}.',
      source: 'ENGINE',
    );
    notifyListeners();
    return false;
  }

  // ==================== SETTINGS STATE ====================
  String _outputDirectory = r'C:\Users\ACER\Downloads\MediaWorkflow_Output';
  SaveLocationMode _saveLocationMode = SaveLocationMode.askEveryTime;
  String? _lastSavedDirectory;
  String _fileNamingPattern = '[original]_converted';
  bool _overwriteExisting = false;
  int _maxWorkerThreads = 4;
  bool _enableGpuAcceleration = true;
  bool _autoClearQueue = false;
  bool _playNotificationSound = true;

  String get outputDirectory => _outputDirectory;
  SaveLocationMode get saveLocationMode => _saveLocationMode;
  bool get askSaveFolderEachTime =>
      _saveLocationMode == SaveLocationMode.askEveryTime;
  String? get lastSavedDirectory => _lastSavedDirectory;
  String get fileNamingPattern => _fileNamingPattern;
  bool get overwriteExisting => _overwriteExisting;
  int get maxWorkerThreads => _maxWorkerThreads;
  bool get enableGpuAcceleration => _enableGpuAcceleration;
  bool get autoClearQueue => _autoClearQueue;
  bool get playNotificationSound => _playNotificationSound;

  void setOutputDirectory(String path) {
    _outputDirectory = path;
    addSystemLog(
      level: 'INFO',
      message: 'Direktori output default diperbarui: $path',
      source: 'SETTINGS',
    );
    _scheduleSave();
    notifyListeners();
  }

  void setSaveLocationMode(SaveLocationMode mode) {
    if (_saveLocationMode != mode) {
      _saveLocationMode = mode;
      final label = mode == SaveLocationMode.askEveryTime
          ? 'Tanya Dulu Mau Simpan Folder Dimana (Pop-up)'
          : 'Simpan Otomatis ke Folder Default';
      addSystemLog(
        level: 'INFO',
        message: 'Mode lokasi penyimpanan diubah menjadi: $label',
        source: 'SETTINGS',
      );
      _scheduleSave();
      notifyListeners();
    }
  }

  void setLastSavedDirectory(String path) {
    _lastSavedDirectory = path;
    _scheduleSave();
    notifyListeners();
  }

  String buildOutputFileName(
    String inputFileName,
    String targetFormat, {
    String? customSuffix,
  }) {
    final trimmed = inputFileName.trim();
    final dotIdx = trimmed.lastIndexOf('.');
    final baseName = dotIdx > 0 ? trimmed.substring(0, dotIdx) : trimmed;
    final cleanExt = targetFormat.trim().toLowerCase().replaceAll('.', '');

    switch (_fileNamingPattern) {
      case '[original]_[engine]':
        return '${baseName}_${engineShortName.toLowerCase()}.$cleanExt';
      case '[original]':
        return '$baseName.$cleanExt';
      case '[original]_converted':
      default:
        final suffix = customSuffix ?? 'converted';
        return '${baseName}_$suffix.$cleanExt';
    }
  }

  String joinOutputPath(String directory, String fileName) {
    final cleanDir = directory.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    if (cleanDir.isEmpty) return fileName;
    final sep = cleanDir.contains('/') && !cleanDir.contains('\\') ? '/' : '\\';
    return '$cleanDir$sep$fileName';
  }

  void setFileNamingPattern(String pattern) {
    _fileNamingPattern = pattern;
    _scheduleSave();
    notifyListeners();
  }

  void setOverwriteExisting(bool value) {
    _overwriteExisting = value;
    _scheduleSave();
    notifyListeners();
  }

  void setMaxWorkerThreads(int threads) {
    _maxWorkerThreads = threads;
    _scheduleSave();
    notifyListeners();
  }

  void setEnableGpuAcceleration(bool value) {
    _enableGpuAcceleration = value;
    _scheduleSave();
    notifyListeners();
  }

  void setAutoClearQueue(bool value) {
    _autoClearQueue = value;
    _scheduleSave();
    notifyListeners();
  }

  void setPlayNotificationSound(bool value) {
    _playNotificationSound = value;
    _scheduleSave();
    notifyListeners();
  }

  void resetSettingsToDefault() {
    _outputDirectory = r'C:\Users\ACER\Downloads\MediaWorkflow_Output';
    _saveLocationMode = SaveLocationMode.askEveryTime;
    _lastSavedDirectory = null;
    _fileNamingPattern = '[original]_converted';
    _overwriteExisting = false;
    _maxWorkerThreads = 4;
    _enableGpuAcceleration = true;
    _autoClearQueue = false;
    _playNotificationSound = true;
    addSystemLog(
      level: 'INFO',
      message: 'Seluruh konfigurasi pengaturan telah di-reset ke default.',
      source: 'SETTINGS',
    );
    _scheduleSave();
    notifyListeners();
  }

  // ==================== LOGS & HISTORY STATE ====================
  final List<TaskHistoryItem> _history = [];
  final List<SystemLogEntry> _systemLogs = [];

  List<TaskHistoryItem> get history => List.unmodifiable(_history);
  List<SystemLogEntry> get systemLogs => List.unmodifiable(_systemLogs);

  void addTaskHistory({
    required String taskType,
    required String fileName,
    required String targetFormat,
    String? engineUsed,
    required String status,
    required int durationMs,
    required String originalSize,
    required String resultSize,
    String? outputPath,
  }) {
    final item = TaskHistoryItem(
      id: UniqueKey().toString(),
      timestamp: DateTime.now(),
      taskType: taskType,
      fileName: fileName,
      targetFormat: targetFormat,
      engineUsed: engineUsed ?? engineDisplayName,
      status: status,
      durationMs: durationMs,
      originalSize: originalSize,
      resultSize: resultSize,
      outputPath: outputPath ?? '$_outputDirectory\\$fileName.$targetFormat',
    );
    _history.insert(0, item);

    addSystemLog(
      level: status == 'Sukses' ? 'SUCCESS' : 'ERROR',
      message:
          'Tugas "$taskType" selesai untuk $fileName ($originalSize -> $resultSize) dalam ${durationMs}ms menggunakan ${item.engineUsed}.',
      source: 'CONVERTER',
    );

    _scheduleSave();
    notifyListeners();
  }

  void removeHistoryItem(String id) {
    _history.removeWhere((item) => item.id == id);
    _scheduleSave();
    notifyListeners();
  }

  void clearHistory() {
    _history.clear();
    addSystemLog(
      level: 'INFO',
      message: 'Riwayat tugas berhasil dibersihkan oleh pengguna.',
      source: 'SYSTEM',
    );
    _scheduleSave();
    notifyListeners();
  }

  void addSystemLog({
    required String level,
    required String message,
    required String source,
  }) {
    final entry = SystemLogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      source: source,
    );
    _systemLogs.insert(0, entry);
    // Batasi maksimum 300 logs agar performa tetap ringan
    if (_systemLogs.length > 300) {
      _systemLogs.removeLast();
    }
    _scheduleSave();
    notifyListeners();
  }

  void clearSystemLogs() {
    _systemLogs.clear();
    _scheduleSave();
    notifyListeners();
  }

  void _initDefaultLogsAndHistory() {
    _history.clear();
    _systemLogs.clear();
  }

  void resetAll() {
    _selectedSidebarIndex = 0;
    _selectedTopTab = 0;
    _selectedEngine = DocEngineType.msWord;
    _autoFallback = true;
    _engineTimeoutSeconds = 45;
    _highDpiRendering = true;
    _isEngineOnline = BackendService.isRunningUnderFlutterTest();
    _isEngineConnecting = !BackendService.isRunningUnderFlutterTest();
    _lastLatencyMs = 12;
    msWordVersion = 'Microsoft Word 365 (64-bit)';
    msWordPath = r'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE';
    isMsWordInstalled = true;
    libreVersion = 'LibreOffice 24.8.2 Community (64-bit)';
    librePath = r'C:\Program Files\LibreOffice\program\soffice.exe';
    isLibreInstalled = true;
    _hasQpdf = true;
    _hasPdfCompressor = true;
    _hasRealEsrgan = true;
    _hasCppRuntime = true;
    _realEsrganModelsCount = 5;
    _mediaToolsTabIndex = 0;
    _convertOnlyFormat = 'PNG';
    _convertOnlyEntries.clear();
    _compressFormat = 'JPG';
    _compressTargetPerPage = 'True';
    _compressType = 'Native';
    _compressTargetKb = '200';
    _compressEntries.clear();
    _upscaleFormat = 'PNG';
    _availableUpscaleModels =
        List<String>.from(BackendService.expectedRealEsrganModels);
    _upscaleModel = _availableUpscaleModels.first;
    _upscaleModelScales.clear();
    _upscaleEntries.clear();
    resetSettingsToDefault();
    _history.clear();
    _systemLogs.clear();
    _initDefaultLogsAndHistory();
    resetPdfPools();
    _scheduleSave();
    notifyListeners();
  }

  // ==================== PDF MANAGER STATE PERSISTENCE ====================
  late List<PoolSectionData> _pdfPools;
  PdfViewMode _pdfViewMode = PdfViewMode.overview;
  int _activePdfPoolIndex = 0;
  int _activePdfSlotIndex = 0;
  double _pdfProgress = 0.0;
  bool _isPdfProcessing = false;
  String _pdfStatusMessage = 'Pilih file pada slot (+) untuk memulai workflow';
  int _pdfCompletedSteps = 0;
  int _pdfTotalSteps = 0;
  Duration? _pdfElapsedDuration;
  DateTime? _pdfProcessStartedAt;
  bool _pdfHasError = false;
  bool _pdfWasCancelled = false;

  List<PoolSectionData> get pdfPools => _pdfPools;
  PdfViewMode get pdfViewMode => _pdfViewMode;
  int get activePdfPoolIndex => _activePdfPoolIndex;
  int get activePdfSlotIndex => _activePdfSlotIndex;
  double get pdfProgress => _pdfProgress;
  bool get isPdfProcessing => _isPdfProcessing;
  String get pdfStatusMessage => _pdfStatusMessage;
  int get pdfCompletedSteps => _pdfCompletedSteps;
  int get pdfTotalSteps => _pdfTotalSteps;
  Duration? get pdfElapsedDuration => _pdfElapsedDuration;
  DateTime? get pdfProcessStartedAt => _pdfProcessStartedAt;
  bool get pdfHasError => _pdfHasError;
  bool get pdfWasCancelled => _pdfWasCancelled;

  void setPdfViewMode(PdfViewMode mode) {
    if (_pdfViewMode != mode) {
      _pdfViewMode = mode;
      _scheduleSave();
      notifyListeners();
    }
  }

  void setActivePdfPool(int poolIdx, int slotIdx) {
    if (_activePdfPoolIndex != poolIdx || _activePdfSlotIndex != slotIdx) {
      _activePdfPoolIndex = poolIdx;
      _activePdfSlotIndex = slotIdx;
      _scheduleSave();
      notifyListeners();
    }
  }

  void setPdfProcessing({
    required bool isProcessing,
    double? progress,
    String? message,
    int? completedSteps,
    int? totalSteps,
    Duration? elapsedDuration,
    bool clearElapsed = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
    bool? hasError,
    bool? wasCancelled,
  }) {
    _isPdfProcessing = isProcessing;
    if (progress != null) _pdfProgress = progress;
    if (message != null) _pdfStatusMessage = message;
    if (completedSteps != null) _pdfCompletedSteps = completedSteps;
    if (totalSteps != null) _pdfTotalSteps = totalSteps;
    if (clearElapsed) {
      _pdfElapsedDuration = null;
    } else if (elapsedDuration != null) {
      _pdfElapsedDuration = elapsedDuration;
    }
    if (clearStartedAt) {
      _pdfProcessStartedAt = null;
    } else if (startedAt != null) {
      _pdfProcessStartedAt = startedAt;
    }
    if (hasError != null) _pdfHasError = hasError;
    if (wasCancelled != null) _pdfWasCancelled = wasCancelled;
    notifyListeners();
  }

  void _initDefaultPdfPools() {
    _pdfPools = [
      PoolSectionData(
        id: 'pool_0',
        title: 'Split Pool',
        slots: [
          PoolSlot(id: 's_0_0', label: 'Number Split'),
        ],
      ),
    ];
    updatePdfInheritedSlots();
  }

  void resetPdfPools() {
    _initDefaultPdfPools();
    _pdfViewMode = PdfViewMode.overview;
    _activePdfPoolIndex = 0;
    _activePdfSlotIndex = 0;
    _isPdfProcessing = false;
    _pdfProgress = 0.0;
    _pdfStatusMessage = 'Pilih file pada slot (+) untuk memulai workflow';
    _pdfCompletedSteps = 0;
    _pdfTotalSteps = 0;
    _pdfElapsedDuration = null;
    _pdfProcessStartedAt = null;
    _pdfHasError = false;
    _pdfWasCancelled = false;
    _scheduleSave();
    notifyListeners();
  }

  void updatePdfInheritedSlots() {
    if (_pdfPools.isEmpty) return;
    final topPool = _pdfPools[0];
    topPool.slots.removeWhere((slot) => slot.isInherited);
    if (topPool.slots.isEmpty) {
      topPool.slots.add(
        PoolSlot(
          id: 's_0_${DateTime.now().microsecondsSinceEpoch}',
          label: topPool.defaultSlotLabel,
        ),
      );
    }
    for (int i = 1; i < _pdfPools.length; i++) {
      final previousPool = _pdfPools[i - 1];
      final currentPool = _pdfPools[i];
      final inheritedFiles = previousPool.getAllFileNames();
      final inheritedRefs = previousPool.getAllFileRefs();
      final existingInhIndex =
          currentPool.slots.indexWhere((s) => s.isInherited);
      if (existingInhIndex == -1) {
        currentPool.slots.insert(
          0,
          PoolSlot(
            id: 'inh_${currentPool.id}_${DateTime.now().microsecondsSinceEpoch}',
            label: '${previousPool.title} File',
            isInherited: true,
            inheritedFiles: inheritedFiles,
            inheritedFileRefs: inheritedRefs,
          ),
        );
      } else {
        final inhSlot = currentPool.slots[existingInhIndex];
        inhSlot.label = '${previousPool.title} File';
        inhSlot.inheritedFiles = inheritedFiles;
        inhSlot.inheritedFileRefs = inheritedRefs;
        final validKeys = inheritedRefs
            .map(PoolSlot.fileRotationKey)
            .toSet();
        inhSlot.inheritedPageRotations
            .removeWhere((key, _) => !validKeys.contains(key));
      }
    }
    _scheduleSave();
    notifyListeners();
  }

  // ==================== MEDIA TOOLS STATE PERSISTENCE ====================
  int _mediaToolsTabIndex = 0;
  int get mediaToolsTabIndex => _mediaToolsTabIndex;
  void setMediaToolsTabIndex(int index) {
    if (_mediaToolsTabIndex != index) {
      _mediaToolsTabIndex = index;
      _scheduleSave();
      notifyListeners();
    }
  }

  // Convert Only state
  String _convertOnlyFormat = 'PNG';
  final List<MediaFileEntry> _convertOnlyEntries = [];
  String get convertOnlyFormat => _convertOnlyFormat;
  List<MediaFileEntry> get convertOnlyEntries =>
      List.unmodifiable(_convertOnlyEntries);
  List<String> get convertOnlyFiles =>
      _convertOnlyEntries.map((e) => e.name).toList();
  void setConvertOnlyFormat(String format) {
    if (_convertOnlyFormat != format) {
      _convertOnlyFormat = format;
      _scheduleSave();
      notifyListeners();
    }
  }

  void addConvertOnlyEntries(List<MediaFileEntry> entries) {
    final existingKeys = _convertOnlyEntries.map((e) => e.normalizedKey).toSet();
    bool added = false;
    for (final entry in entries) {
      if (existingKeys.add(entry.normalizedKey)) {
        _convertOnlyEntries.add(entry);
        added = true;
      }
    }
    if (added) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void addConvertOnlyFiles(List<String> files) {
    addConvertOnlyEntries(
      files
          .map(
            (f) => MediaFileEntry(
              name: BackendService.fileNameFromPath(f),
              path: f,
            ),
          )
          .toList(),
    );
  }

  void removeConvertOnlyFile(int index) {
    if (index >= 0 && index < _convertOnlyEntries.length) {
      _convertOnlyEntries.removeAt(index);
      _scheduleSave();
      notifyListeners();
    }
  }

  void clearConvertOnlyFiles() {
    if (_convertOnlyEntries.isNotEmpty) {
      _convertOnlyEntries.clear();
      _scheduleSave();
      notifyListeners();
    }
  }

  // Compress & Convert state
  String _compressFormat = 'JPG';
  String _compressTargetPerPage = 'True';
  String _compressType = 'Native';
  String _compressTargetKb = '200';
  final List<MediaFileEntry> _compressEntries = [];
  String get compressFormat => _compressFormat;
  String get compressTargetPerPage => _compressTargetPerPage;
  String get compressType => _compressType;
  String get compressTargetKb => _compressTargetKb;
  List<MediaFileEntry> get compressEntries =>
      List.unmodifiable(_compressEntries);
  List<String> get compressFiles => _compressEntries.map((e) => e.name).toList();
  void setCompressOptions({
    String? format,
    String? perPage,
    String? type,
    String? kb,
  }) {
    bool changed = false;
    if (format != null && _compressFormat != format) {
      _compressFormat = format;
      changed = true;
    }
    if (perPage != null && _compressTargetPerPage != perPage) {
      _compressTargetPerPage = perPage;
      changed = true;
    }
    if (type != null && _compressType != type) {
      _compressType = type;
      changed = true;
    }
    if (kb != null && _compressTargetKb != kb) {
      _compressTargetKb = kb;
      changed = true;
    }
    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void addCompressEntries(List<MediaFileEntry> entries) {
    final existingKeys = _compressEntries.map((e) => e.normalizedKey).toSet();
    bool added = false;
    for (final entry in entries) {
      if (existingKeys.add(entry.normalizedKey)) {
        _compressEntries.add(entry);
        added = true;
      }
    }
    if (added) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void addCompressFiles(List<String> files) {
    addCompressEntries(
      files
          .map(
            (f) => MediaFileEntry(
              name: BackendService.fileNameFromPath(f),
              path: f,
            ),
          )
          .toList(),
    );
  }

  void removeCompressFile(int index) {
    if (index >= 0 && index < _compressEntries.length) {
      _compressEntries.removeAt(index);
      _scheduleSave();
      notifyListeners();
    }
  }

  void clearCompressFiles() {
    if (_compressEntries.isNotEmpty) {
      _compressEntries.clear();
      _scheduleSave();
      notifyListeners();
    }
  }

  // Upscale AI state
  String _upscaleFormat = 'PNG';
  List<String> _availableUpscaleModels =
      List<String>.from(BackendService.expectedRealEsrganModels);
  String _upscaleModel = BackendService.expectedRealEsrganModels.first;
  final Map<String, int> _upscaleModelScales = <String, int>{};
  final List<MediaFileEntry> _upscaleEntries = [];
  String get upscaleFormat => _upscaleFormat;
  List<String> get availableUpscaleModels =>
      List<String>.unmodifiable(_availableUpscaleModels);
  String get upscaleModel => _upscaleModel;
  int get upscaleScale => getScaleForUpscaleModel(_upscaleModel);
  Map<String, int> get upscaleModelScales => {
        for (final model in _availableUpscaleModels)
          model: getScaleForUpscaleModel(model),
        ..._upscaleModelScales,
      };
  int getScaleForUpscaleModel(String model) =>
      _upscaleModelScales[model] ?? BackendService.defaultUpscaleScale;
  List<MediaFileEntry> get upscaleEntries => List.unmodifiable(_upscaleEntries);
  List<String> get upscaleFiles => _upscaleEntries.map((e) => e.name).toList();
  void setUpscaleModelScale(String model, int scale) {
    final normalizedScale = scale.clamp(1, 16);
    if (_upscaleModelScales[model] != normalizedScale) {
      _upscaleModelScales[model] = normalizedScale;
      _scheduleSave();
      notifyListeners();
    }
  }

  void setUpscaleOptions({String? format, String? model, int? scale}) {
    bool changed = false;
    if (format != null && _upscaleFormat != format) {
      _upscaleFormat = format;
      changed = true;
    }
    if (model != null && _upscaleModel != model) {
      _upscaleModel = model;
      _upscaleModelScales.putIfAbsent(
        model,
        () => BackendService.defaultUpscaleScale,
      );
      changed = true;
    }
    if (scale != null) {
      final normalized = scale.clamp(1, 16);
      if (_upscaleModelScales[_upscaleModel] != normalized) {
        _upscaleModelScales[_upscaleModel] = normalized;
        changed = true;
      }
    }
    if (changed) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void addUpscaleEntries(List<MediaFileEntry> entries) {
    final existingKeys = _upscaleEntries.map((e) => e.normalizedKey).toSet();
    bool added = false;
    for (final entry in entries) {
      if (existingKeys.add(entry.normalizedKey)) {
        _upscaleEntries.add(entry);
        added = true;
      }
    }
    if (added) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void addUpscaleFiles(List<String> files) {
    addUpscaleEntries(
      files
          .map(
            (f) => MediaFileEntry(
              name: BackendService.fileNameFromPath(f),
              path: f,
            ),
          )
          .toList(),
    );
  }

  void removeUpscaleFile(int index) {
    if (index >= 0 && index < _upscaleEntries.length) {
      _upscaleEntries.removeAt(index);
      _scheduleSave();
      notifyListeners();
    }
  }

  void clearUpscaleFiles() {
    if (_upscaleEntries.isNotEmpty) {
      _upscaleEntries.clear();
      _scheduleSave();
      notifyListeners();
    }
  }
}
