import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/pdf_models.dart';
import 'app_state_service.dart';
import 'pdf_inspector_service.dart';
import 'window_control_service.dart';

enum BackendConnectionStatus {
  disconnected,
  starting,
  online,
  error,
}

class BackendException implements Exception {
  final String message;

  const BackendException(this.message);

  @override
  String toString() => message;
}

class BackendCancelledException implements Exception {
  final String message;

  const BackendCancelledException([this.message = 'Proses dibatalkan oleh pengguna.']);

  @override
  String toString() => message;
}

class BackendCancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _isCancelled;

  void onCancel(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final snapshot = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final listener in snapshot) {
      try {
        listener();
      } catch (_) {}
    }
  }
}

class BackendStagedFile {
  final String sourceFileName;
  final String stagedFilePath;
  final String suggestedFileName;
  final String? groupFileName;
  final int originalBytes;
  final int resultBytes;
  final int durationMs;
  final String engineUsed;
  final String targetFormat;

  const BackendStagedFile({
    required this.sourceFileName,
    required this.stagedFilePath,
    required this.suggestedFileName,
    this.groupFileName,
    required this.originalBytes,
    required this.resultBytes,
    required this.durationMs,
    required this.engineUsed,
    required this.targetFormat,
  });
}

class BackendBatchResult {
  final List<BackendStagedFile> files;
  final String? stagingDirPath;

  const BackendBatchResult({
    required this.files,
    this.stagingDirPath,
  });

  Future<void> cleanupStaging() async {
    final path = stagingDirPath;
    if (path == null || path.isEmpty) return;
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

class BackendCapabilities {
  final String? engineRootDir;
  final String? backendExePath;
  final String? qpdfExePath;
  final String? pdfCompressorExePath;
  final String? realEsrganExePath;
  final List<String> realEsrganModels;
  final bool hasVisualCppRuntime;
  final bool isMsWordInstalled;
  final String msWordVersion;
  final String msWordPath;
  final bool isLibreInstalled;
  final String libreVersion;
  final String librePath;

  const BackendCapabilities({
    this.engineRootDir,
    this.backendExePath,
    this.qpdfExePath,
    this.pdfCompressorExePath,
    this.realEsrganExePath,
    this.realEsrganModels = const [],
    this.hasVisualCppRuntime = false,
    this.isMsWordInstalled = false,
    this.msWordVersion = 'Tidak terdeteksi di sistem ini',
    this.msWordPath = '-',
    this.isLibreInstalled = false,
    this.libreVersion = 'Tidak terdeteksi di sistem ini',
    this.librePath = '-',
  });

  bool get hasBackendExe =>
      backendExePath != null && backendExePath!.isNotEmpty;
  bool get hasQpdf => qpdfExePath != null && qpdfExePath!.isNotEmpty;
  bool get hasPdfCompressor =>
      pdfCompressorExePath != null && pdfCompressorExePath!.isNotEmpty;
  bool get hasRealEsrgan =>
      realEsrganExePath != null && realEsrganExePath!.isNotEmpty;
}

class BackendCompressTestRequest {
  final String filePath;
  final String fileName;
  final String action;
  final String targetFormat;
  final String? compressionType;
  final int? targetKB;
  final bool? targetPerPage;
  final String? model;
  final int? scale;
  final String engine;
  final bool autoFallback;
  final int timeoutSeconds;

  const BackendCompressTestRequest({
    required this.filePath,
    required this.fileName,
    required this.action,
    required this.targetFormat,
    this.compressionType,
    this.targetKB,
    this.targetPerPage,
    this.model,
    this.scale,
    required this.engine,
    required this.autoFallback,
    required this.timeoutSeconds,
  });
}

class BackendWorkflowTestRequest {
  final List<PoolSectionData> pools;
  final String taskModeLabel;
  final String outputSuffix;

  const BackendWorkflowTestRequest({
    required this.pools,
    required this.taskModeLabel,
    this.outputSuffix = 'workflow',
  });
}

class _TrackedPageOrigin {
  final String sourceKey;
  final int originalPageNumber;
  final int appliedRotationDeg;

  const _TrackedPageOrigin({
    required this.sourceKey,
    required this.originalPageNumber,
    this.appliedRotationDeg = 0,
  });

  _TrackedPageOrigin copyWith({int? appliedRotationDeg}) =>
      _TrackedPageOrigin(
        sourceKey: sourceKey,
        originalPageNumber: originalPageNumber,
        appliedRotationDeg: appliedRotationDeg ?? this.appliedRotationDeg,
      );
}

class _UpstreamPdfArtifact {
  final String filePath;
  final String displayName;
  final String? originalFileName;
  final int? sourceFileBytes;
  final bool isSplitSeparate;
  final List<_TrackedPageOrigin> pageOrigins;

  const _UpstreamPdfArtifact({
    required this.filePath,
    required this.displayName,
    this.originalFileName,
    this.sourceFileBytes,
    this.isSplitSeparate = false,
    required this.pageOrigins,
  });
}

class BackendService extends ChangeNotifier {
  static final BackendService _instance = BackendService._internal();
  factory BackendService() => _instance;

  BackendService._internal();

  static const String baseUrl = 'http://127.0.0.1:8080';
  static const List<String> expectedRealEsrganModels = <String>[
    'realesr-animevideov3-x2',
    'realesr-animevideov3-x3',
    'realesr-animevideov3-x4',
    'realesrgan-x4plus-anime',
    'realesrgan-x4plus',
  ];

  BackendConnectionStatus _status = BackendConnectionStatus.disconnected;
  BackendCapabilities _capabilities = const BackendCapabilities();
  Process? _ownedProcess;
  int? _ownedPid;
  bool _adoptedExternalProcess = false;
  Future<bool>? _startingFuture;
  String? _lastError;
  int _lastPingLatencyMs = 0;
  HttpClient? _sharedHttpClient;
  DateTime? _lastHealthyAt;
  String? _lastHealthyBaseUrl;
  Completer<void>? _officeLockTail;

  @visibleForTesting
  String? overrideEngineRootDir;

  @visibleForTesting
  String? overrideBaseUrl;

  String get effectiveBaseUrl => overrideBaseUrl ?? baseUrl;

  @visibleForTesting
  Future<BackendStagedFile> Function(
    BackendCompressTestRequest request,
  )? testCompressHandler;

  @visibleForTesting
  Future<BackendBatchResult> Function(
    BackendWorkflowTestRequest request,
  )? testWorkflowHandler;

  @visibleForTesting
  Future<int> Function()? testPingHandler;

  @visibleForTesting
  Future<bool> Function(String path)? testOpenInExplorerHandler;

  BackendConnectionStatus get status => _status;
  BackendCapabilities get capabilities => _capabilities;
  String? get lastError => _lastError;
  int get lastPingLatencyMs => _lastPingLatencyMs;
  bool get isOwnedProcessRunning => _ownedProcess != null;
  bool get isAdoptedExternalProcess => _adoptedExternalProcess;
  bool get isOnline => _status == BackendConnectionStatus.online;

  @visibleForTesting
  void resetTestOverrides() {
    overrideEngineRootDir = null;
    overrideBaseUrl = null;
    testCompressHandler = null;
    testWorkflowHandler = null;
    testPingHandler = null;
    testOpenInExplorerHandler = null;
    _status = BackendConnectionStatus.disconnected;
    _lastError = null;
    _lastPingLatencyMs = 0;
    _adoptedExternalProcess = false;
    _officeLockTail = null;
    _closeSharedHttpClient();
  }

  HttpClient _getOrCreateHttpClient({int? timeoutSeconds}) {
    final client = _sharedHttpClient ??= (HttpClient()
      ..maxConnectionsPerHost = 12
      ..idleTimeout = const Duration(seconds: 30)
      ..connectionTimeout = const Duration(seconds: 10));
    if (timeoutSeconds != null && timeoutSeconds > 0) {
      client.connectionTimeout = Duration(
        seconds: timeoutSeconds < 10 ? timeoutSeconds : 10,
      );
    } else if (timeoutSeconds != null) {
      client.connectionTimeout = const Duration(seconds: 15);
    }
    return client;
  }

  void _closeSharedHttpClient() {
    _lastHealthyAt = null;
    _lastHealthyBaseUrl = null;
    final client = _sharedHttpClient;
    _sharedHttpClient = null;
    if (client != null) {
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  Future<T> _runWithOfficeLock<T>(Future<T> Function() fn) async {
    final prev = _officeLockTail?.future;
    final gate = Completer<void>();
    _officeLockTail = gate;
    if (prev != null) {
      try {
        await prev;
      } catch (_) {}
    }
    try {
      return await fn();
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
      if (identical(_officeLockTail, gate)) {
        _officeLockTail = null;
      }
    }
  }

  static String formatBytes(int bytes) {
    if (bytes < 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static const int defaultUpscaleScale = 4;

  static String fileNameFromPath(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    for (int i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return path;
  }

  static String extensionOf(String path) {
    final name = fileNameFromPath(path);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx <= 0 || dotIdx == name.length - 1) return '';
    return name.substring(dotIdx + 1).toLowerCase();
  }

  static String _joinPath(String a, String b) {
    final cleanA = a.replaceAll(RegExp(r'[\\/]+$'), '');
    final cleanB = b.replaceAll(RegExp(r'^[\\/]+'), '');
    if (cleanA.isEmpty) return cleanB;
    final sep = Platform.pathSeparator;
    return '$cleanA$sep$cleanB';
  }

  static bool isRunningUnderFlutterTest() {
    return Platform.environment.containsKey('FLUTTER_TEST');
  }

  String? resolveEngineRootDir() {
    final override = overrideEngineRootDir;
    if (override != null && override.isNotEmpty) {
      if (File(_joinPath(override, 'smart_compress_backend.exe')).existsSync() ||
          Directory(_joinPath(override, 'tools')).existsSync()) {
        return override;
      }
    }

    final candidates = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add(_joinPath(exeDir, 'engine'));
      candidates.add(_joinPath(
        _joinPath(_joinPath(exeDir, 'data'), 'flutter_assets'),
        _joinPath('assets', 'engine'),
      ));
    } catch (_) {}

    var currentDir = Directory.current;
    for (int depth = 0; depth < 6; depth++) {
      candidates.add(_joinPath(_joinPath(currentDir.path, 'assets'), 'engine'));
      candidates.add(_joinPath(
        _joinPath(_joinPath(currentDir.path, 'frontend_desktop'), 'assets'),
        'engine',
      ));
      final parent = currentDir.parent;
      if (parent.path == currentDir.path) break;
      currentDir = parent;
    }

    for (final candidate in candidates) {
      if (File(_joinPath(candidate, 'smart_compress_backend.exe'))
          .existsSync()) {
        return Directory(candidate).absolute.path;
      }
    }
    for (final candidate in candidates) {
      if (Directory(_joinPath(candidate, 'tools')).existsSync()) {
        return Directory(candidate).absolute.path;
      }
    }
    return null;
  }

  String? _findFirstExistingFile(List<String> paths) {
    for (final p in paths) {
      if (File(p).existsSync()) {
        return File(p).absolute.path;
      }
    }
    return null;
  }

  Future<BackendCapabilities> inspectCapabilities({
    bool detectExternalOfficeApps = true,
  }) async {
    final root = resolveEngineRootDir();
    String? backendExe;
    String? qpdfExe;
    String? pdfCompExe;
    String? realEsrganExe;
    final models = <String>[];
    bool hasCppRuntime = false;

    if (root != null) {
      backendExe = _findFirstExistingFile([
        _joinPath(root, 'smart_compress_backend.exe'),
      ]);
      qpdfExe = _findFirstExistingFile([
        _joinPath(_joinPath(_joinPath(root, 'tools'), 'qpdf'), _joinPath('bin', 'qpdf.exe')),
        _joinPath(_joinPath(_joinPath(_joinPath(root, 'tools'), 'qpdf'), 'qpdf'), _joinPath('bin', 'qpdf.exe')),
      ]);
      pdfCompExe = _findFirstExistingFile([
        _joinPath(_joinPath(_joinPath(root, 'tools'), 'pdf_compressor'), _joinPath('build', 'pdf_compressor.exe')),
        _joinPath(_joinPath(_joinPath(root, 'tools'), 'pdf_compressor'), 'pdf_compressor.exe'),
      ]);
      realEsrganExe = _findFirstExistingFile([
        _joinPath(_joinPath(_joinPath(root, 'tools'), 'realesrgan'), 'realesrgan-ncnn-vulkan.exe'),
        _joinPath(_joinPath(_joinPath(_joinPath(root, 'tools'), 'realesrgan'), 'realesrgan'), 'realesrgan-ncnn-vulkan.exe'),
      ]);

      final modelsDir = _joinPath(_joinPath(_joinPath(root, 'tools'), 'realesrgan'), 'models');
      final modelsDirectory = Directory(modelsDir);
      if (modelsDirectory.existsSync()) {
        final discoveredPairs = <String, ({bool hasBin, bool hasParam})>{};
        for (final entity in modelsDirectory.listSync(followLinks: false)) {
          if (entity is! File) continue;
          final fileName = fileNameFromPath(entity.path);
          final dotIdx = fileName.lastIndexOf('.');
          if (dotIdx <= 0) continue;
          final stem = fileName.substring(0, dotIdx);
          final ext = fileName.substring(dotIdx + 1).toLowerCase();
          if (ext != 'bin' && ext != 'param') continue;
          final prev = discoveredPairs[stem] ?? (hasBin: false, hasParam: false);
          discoveredPairs[stem] = (
            hasBin: prev.hasBin || ext == 'bin',
            hasParam: prev.hasParam || ext == 'param',
          );
        }
        final discovered = discoveredPairs.entries
            .where((e) => e.value.hasBin && e.value.hasParam)
            .map((e) => e.key)
            .toList()
          ..sort(naturalCompare);
        models.addAll(discovered);
      }

      final qpdfBin = _joinPath(_joinPath(_joinPath(root, 'tools'), 'qpdf'), 'bin');
      final realEsrganDir = _joinPath(_joinPath(_joinPath(root, 'tools'), 'realesrgan'), '');
      hasCppRuntime = File(_joinPath(qpdfBin, 'vcruntime140.dll')).existsSync() ||
          File(_joinPath(realEsrganDir, 'vcomp140.dll')).existsSync();
    }

    bool wordInstalled = false;
    String wordVersion = 'Tidak terdeteksi di Windows';
    String wordPath = '-';
    bool libreInstalled = false;
    String libreVersion = 'Tidak terdeteksi di Windows';
    String librePath = '-';

    if (detectExternalOfficeApps && Platform.isWindows) {
      final wordInfo = await _detectMicrosoftWord();
      wordInstalled = wordInfo.$1;
      wordPath = wordInfo.$2;
      wordVersion = wordInfo.$3;

      final libreInfo = await _detectLibreOffice();
      libreInstalled = libreInfo.$1;
      librePath = libreInfo.$2;
      libreVersion = libreInfo.$3;
    }

    _capabilities = BackendCapabilities(
      engineRootDir: root,
      backendExePath: backendExe,
      qpdfExePath: qpdfExe,
      pdfCompressorExePath: pdfCompExe,
      realEsrganExePath: realEsrganExe,
      realEsrganModels: models,
      hasVisualCppRuntime: hasCppRuntime,
      isMsWordInstalled: wordInstalled,
      msWordVersion: wordVersion,
      msWordPath: wordPath,
      isLibreInstalled: libreInstalled,
      libreVersion: libreVersion,
      librePath: librePath,
    );

    AppStateService().updateDetectedCapabilities(
      isMsWordInstalled: wordInstalled,
      msWordVersion: wordVersion,
      msWordPath: wordPath,
      isLibreInstalled: libreInstalled,
      libreVersion: libreVersion,
      librePath: librePath,
      hasQpdf: _capabilities.hasQpdf,
      hasPdfCompressor: _capabilities.hasPdfCompressor,
      hasRealEsrgan: _capabilities.hasRealEsrgan,
      hasCppRuntime: _capabilities.hasVisualCppRuntime,
      realEsrganModelsCount: models.length,
      realEsrganModels: models,
    );

    notifyListeners();
    return _capabilities;
  }

  Future<(bool, String, String)> _detectMicrosoftWord() async {
    final programFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';

    final candidates = <String>[
      '$programFiles\\Microsoft Office\\root\\Office16\\WINWORD.EXE',
      '$programFilesX86\\Microsoft Office\\root\\Office16\\WINWORD.EXE',
      '$programFiles\\Microsoft Office\\Office16\\WINWORD.EXE',
      '$programFilesX86\\Microsoft Office\\Office16\\WINWORD.EXE',
      '$programFiles\\Microsoft Office\\Office15\\WINWORD.EXE',
      '$programFilesX86\\Microsoft Office\\Office15\\WINWORD.EXE',
    ];

    String? foundPath = _findFirstExistingFile(candidates);

    if (foundPath == null) {
      try {
        final regRes = await Process.run(
          'reg',
          ['query', r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Winword.exe', '/ve'],
        ).timeout(const Duration(seconds: 2));
        if (regRes.exitCode == 0) {
          final out = regRes.stdout.toString();
          final match = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.+)').firstMatch(out);
          if (match != null) {
            final p = match.group(1)!.trim().replaceAll('"', '');
            if (p.isNotEmpty && File(p).existsSync()) {
              foundPath = p;
            }
          }
        }
      } catch (_) {}
    }

    if (foundPath == null) {
      return (false, '-', 'Microsoft Word tidak terdeteksi');
    }

    String version = 'Microsoft Word (COM API Terpasang)';
    try {
      final regVer = await Process.run(
        'reg',
        ['query', r'HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration', '/v', 'VersionToReport'],
      ).timeout(const Duration(seconds: 2));
      if (regVer.exitCode == 0) {
        final m = RegExp(r'REG_SZ\s+(\S+)').firstMatch(regVer.stdout.toString());
        if (m != null) {
          version = 'Microsoft Word ${m.group(1)}';
        }
      }
    } catch (_) {}

    return (true, foundPath, version);
  }

  Future<(bool, String, String)> _detectLibreOffice() async {
    final programFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';

    String? foundPath = _findFirstExistingFile([
      '$programFiles\\LibreOffice\\program\\soffice.exe',
      '$programFilesX86\\LibreOffice\\program\\soffice.exe',
    ]);

    if (foundPath == null) {
      try {
        final whereRes = await Process.run('where', ['soffice'])
            .timeout(const Duration(seconds: 2));
        if (whereRes.exitCode == 0) {
          final firstLine = whereRes.stdout
              .toString()
              .split(RegExp(r'[\r\n]+'))
              .map((l) => l.trim())
              .firstWhere((l) => l.isNotEmpty, orElse: () => '');
          if (firstLine.isNotEmpty && File(firstLine).existsSync()) {
            foundPath = firstLine;
          }
        }
      } catch (_) {}
    }

    if (foundPath == null) {
      return (false, '-', 'LibreOffice tidak terdeteksi');
    }

    String version = 'LibreOffice Headless (soffice.exe)';
    try {
      final regRes = await Process.run(
        'reg',
        ['query', r'HKLM\SOFTWARE\LibreOffice\UNO\InstallPath', '/ve'],
      ).timeout(const Duration(seconds: 2));
      if (regRes.exitCode == 0) {
        final regVer = await Process.run(
          'reg',
          ['query', r'HKLM\SOFTWARE\LibreOffice\LibreOffice', '/s', '/f', 'Version'],
        ).timeout(const Duration(seconds: 2));
        final match = RegExp(r'2\d\.\d+\.\d+').firstMatch(regVer.stdout.toString());
        if (match != null) {
          version = 'LibreOffice ${match.group(0)}';
        }
      }
    } catch (_) {}

    return (true, foundPath, version);
  }

  Future<int?> pingHealth({Duration timeout = const Duration(seconds: 2)}) async {
    if (testPingHandler != null) {
      final sw = Stopwatch()..start();
      try {
        final latency = await testPingHandler!();
        sw.stop();
        final resolvedLatency = latency > 0 ? latency : sw.elapsedMilliseconds;
        _lastPingLatencyMs = resolvedLatency;
        _status = BackendConnectionStatus.online;
        _lastError = null;
        AppStateService().setBackendStatus(
          isOnline: true,
          isConnecting: false,
          latencyMs: resolvedLatency,
        );
        notifyListeners();
        return resolvedLatency;
      } catch (e) {
        _status = BackendConnectionStatus.error;
        _lastError = e.toString();
        AppStateService().setBackendStatus(
          isOnline: false,
          isConnecting: false,
        );
        notifyListeners();
        return null;
      }
    }

    final targetUrl = effectiveBaseUrl;
    final client = _getOrCreateHttpClient();
    HttpClientRequest? activeReq;
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse('$targetUrl/compress'))
          .timeout(timeout);
      activeReq = req;
      final resp = await req.close().timeout(timeout);
      final body = await utf8.decoder.bind(resp).join().timeout(timeout);
      sw.stop();

      final isGoBackend = resp.statusCode == HttpStatus.methodNotAllowed &&
          body.contains('Method tidak diizinkan');
      if (isGoBackend) {
        final ms = sw.elapsedMilliseconds < 1 ? 1 : sw.elapsedMilliseconds;
        _lastPingLatencyMs = ms;
        _status = BackendConnectionStatus.online;
        _lastError = null;
        _lastHealthyAt = DateTime.now();
        _lastHealthyBaseUrl = targetUrl;
        AppStateService().setBackendStatus(
          isOnline: true,
          isConnecting: false,
          latencyMs: ms,
        );
        notifyListeners();
        return ms;
      }
      _lastHealthyAt = null;
      _lastHealthyBaseUrl = null;
      return null;
    } catch (_) {
      try {
        activeReq?.abort();
      } catch (_) {}
      _closeSharedHttpClient();
      return null;
    }
  }

  Future<void> startupInitialize() async {
    AppStateService().setBackendStatus(isOnline: false, isConnecting: true);
    await inspectCapabilities(detectExternalOfficeApps: true);
    final ok = await ensureRunning();
    if (ok) {
      final engine = AppStateService().selectedEngine == DocEngineType.libreOffice
          ? 'libreoffice'
          : 'word';
      await warmupEngine(engine);
    }
  }

  Future<bool> warmupEngine(String engine) async {
    if (testPingHandler != null) {
      AppStateService().setBackendStatus(
        isOnline: true,
        isConnecting: false,
      );
      return true;
    }
    AppStateService().setBackendStatus(isOnline: false, isConnecting: true);
    final targetUrl = effectiveBaseUrl;
    final client = _getOrCreateHttpClient();
    try {
      final req = await client
          .postUrl(Uri.parse('$targetUrl/engine/warmup'))
          .timeout(const Duration(seconds: 15));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'engine': engine}));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decoder.bind(resp).join().timeout(const Duration(seconds: 15));
      final data = jsonDecode(body) as Map<String, dynamic>;
      final success = data['success'] == true;
      final msg = data['message'] as String? ?? 'Engine siap';
      AppStateService().addSystemLog(
        level: success ? 'SUCCESS' : 'WARN',
        message: 'Warmup Engine ($engine): $msg',
        source: 'ENGINE',
      );
      AppStateService().setBackendStatus(
        isOnline: success,
        isConnecting: false,
      );
      notifyListeners();
      return success;
    } catch (e) {
      AppStateService().addSystemLog(
        level: 'WARN',
        message: 'Gagal melakukan warmup engine ($engine): $e',
        source: 'ENGINE',
      );
      AppStateService().setBackendStatus(
        isOnline: false,
        isConnecting: false,
      );
      notifyListeners();
      return false;
    }
  }

  Future<bool> ensureRunning() {
    if (testPingHandler != null ||
        testCompressHandler != null ||
        testWorkflowHandler != null) {
      _status = BackendConnectionStatus.online;
      return Future<bool>.value(true);
    }
    final activeFuture = _startingFuture;
    if (activeFuture != null) return activeFuture;

    final created = _ensureRunningInternal();
    _startingFuture = created;
    created.whenComplete(() {
      if (identical(_startingFuture, created)) {
        _startingFuture = null;
      }
    });
    return created;
  }

  Future<bool> _ensureRunningInternal() async {
    final now = DateTime.now();
    if (_status == BackendConnectionStatus.online &&
        (_ownedProcess != null || _adoptedExternalProcess) &&
        _lastHealthyBaseUrl == effectiveBaseUrl &&
        _lastHealthyAt != null &&
        now.difference(_lastHealthyAt!) < const Duration(seconds: 3)) {
      return true;
    }

    final existingLatency = await pingHealth(
      timeout: const Duration(milliseconds: 900),
    );
    if (existingLatency != null) {
      if (_ownedProcess == null) {
        _adoptedExternalProcess = true;
      }
      return true;
    }

    if (!_capabilities.hasBackendExe) {
      await inspectCapabilities(detectExternalOfficeApps: false);
    }

    final exePath = _capabilities.backendExePath;
    final rootDir = _capabilities.engineRootDir;
    if (exePath == null || rootDir == null || !File(exePath).existsSync()) {
      const msg =
          'Backend engine smart_compress_backend.exe tidak ditemukan di assets/engine.';
      _status = BackendConnectionStatus.error;
      _lastError = msg;
      AppStateService().setBackendStatus(isOnline: false, isConnecting: false);
      AppStateService().addSystemLog(
        level: 'ERROR',
        message: msg,
        source: 'ENGINE',
      );
      notifyListeners();
      return false;
    }

    _status = BackendConnectionStatus.starting;
    _lastError = null;
    _adoptedExternalProcess = false;
    AppStateService().setBackendStatus(isOnline: false, isConnecting: true);
    AppStateService().addSystemLog(
      level: 'INFO',
      message: 'Memulai backend engine Go: $exePath (workdir: $rootDir)',
      source: 'ENGINE',
    );
    notifyListeners();

    final sep = Platform.pathSeparator;
    final extraPaths = <String>[
      '$rootDir${sep}tools${sep}qpdf${sep}bin',
      '$rootDir${sep}tools${sep}pdf_compressor',
      '$rootDir${sep}tools${sep}pdf_compressor${sep}build',
      '$rootDir${sep}tools${sep}realesrgan',
    ];
    final currentPath = Platform.environment['PATH'] ?? '';
    final augmentedPath = '${extraPaths.join(';')};$currentPath';
    final env = <String, String>{
      ...Platform.environment,
      'PATH': augmentedPath,
    };

    try {
      final proc = await Process.start(
        exePath,
        const <String>[],
        workingDirectory: rootDir,
        environment: env,
        mode: ProcessStartMode.normal,
      );
      _ownedProcess = proc;
      _ownedPid = proc.pid;

      var exitedEarly = false;
      int? earlyExitCode;

      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        final isError = trimmed.contains('[ERROR]') ||
            trimmed.contains('gagal') ||
            trimmed.contains('GAGAL');
        AppStateService().addSystemLog(
          level: isError ? 'WARN' : 'INFO',
          message: trimmed,
          source: 'ENGINE',
        );
      });

      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        AppStateService().addSystemLog(
          level: 'WARN',
          message: trimmed,
          source: 'ENGINE',
        );
      });

      unawaited(
        proc.exitCode.then((code) {
          exitedEarly = true;
          earlyExitCode = code;
          if (identical(_ownedProcess, proc)) {
            _ownedProcess = null;
            _ownedPid = null;
            if (_status != BackendConnectionStatus.disconnected) {
              _status = BackendConnectionStatus.disconnected;
              AppStateService().setBackendStatus(
                isOnline: false,
                isConnecting: false,
              );
              AppStateService().addSystemLog(
                level: 'WARN',
                message: 'Proses backend Go berhenti (exit code: $code).',
                source: 'ENGINE',
              );
              notifyListeners();
            }
          }
        }),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        if (exitedEarly) break;
        final ms = await pingHealth(
          timeout: const Duration(milliseconds: 450),
        );
        if (ms != null) {
          AppStateService().addSystemLog(
            level: 'SUCCESS',
            message:
                'Backend engine Go aktif di $baseUrl (PID: ${proc.pid}, latensi: ${ms}ms).',
            source: 'ENGINE',
          );
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      if (exitedEarly) {
        final again = await pingHealth(
          timeout: const Duration(milliseconds: 500),
        );
        if (again != null) {
          _adoptedExternalProcess = true;
          return true;
        }
        _lastError =
            'Backend berhenti sebelum siap (exit code: $earlyExitCode).';
      } else {
        _lastError = 'Backend tidak merespons di $baseUrl setelah 6 detik.';
      }
      _status = BackendConnectionStatus.error;
      AppStateService().setBackendStatus(isOnline: false, isConnecting: false);
      AppStateService().addSystemLog(
        level: 'ERROR',
        message: _lastError!,
        source: 'ENGINE',
      );
      notifyListeners();
      return false;
    } catch (e) {
      _status = BackendConnectionStatus.error;
      _lastError = 'Gagal menjalankan smart_compress_backend.exe: $e';
      AppStateService().setBackendStatus(isOnline: false, isConnecting: false);
      AppStateService().addSystemLog(
        level: 'ERROR',
        message: _lastError!,
        source: 'ENGINE',
      );
      notifyListeners();
      return false;
    }
  }

  Future<void> stopOwnedBackend() async {
    final proc = _ownedProcess;
    final pid = _ownedPid;
    _ownedProcess = null;
    _ownedPid = null;
    _adoptedExternalProcess = false;
    _status = BackendConnectionStatus.disconnected;
    _closeSharedHttpClient();

    if (proc != null) {
      try {
        proc.kill(ProcessSignal.sigterm);
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        if (Platform.isWindows && pid != null) {
          try {
            await Process.run(
              'taskkill',
              ['/PID', '$pid', '/T', '/F'],
            ).timeout(const Duration(seconds: 3));
          } catch (_) {}
        } else {
          try {
            proc.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      }
    }

    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/IM', 'smart_compress_backend.exe', '/F'])
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    AppStateService().setBackendStatus(isOnline: false, isConnecting: false);
    notifyListeners();
  }

  Future<bool> restartBackend() async {
    AppStateService().addSystemLog(
      level: 'INFO',
      message: 'Memulai ulang backend engine Go...',
      source: 'ENGINE',
    );
    await stopOwnedBackend();
    await inspectCapabilities(detectExternalOfficeApps: true);
    return ensureRunning();
  }

  Future<Directory> createStagingDir(String prefix) async {
    return Directory.systemTemp.createTemp('mwx_$prefix');
  }

  Future<BackendBatchResult> compressBatch({
    required List<MediaFileEntry> entries,
    required String action,
    required String targetFormat,
    required String? compressionType,
    required int? targetKB,
    required bool? targetPerPage,
    required String? model,
    int? scale,
    required String Function(
      String inputFileName,
      String actualExtension, {
      required int partIndex,
      required int totalParts,
    }) buildOutputName,
    String engine = 'word',
    bool autoFallback = true,
    int timeoutSeconds = 45,
    BackendCancellationToken? cancelToken,
    void Function(int completedCount, int totalCount, String message)?
        onProgress,
  }) async {
    if (entries.isEmpty) {
      throw const BackendException('Pilih setidaknya satu file terlebih dahulu!');
    }

    final normAction = action.trim().toLowerCase();
    final normTarget = targetFormat.trim().toLowerCase();
    final normEngine = engine.trim().toLowerCase() == 'libreoffice'
        ? 'libreoffice'
        : 'word';
    final int? effectiveScale =
        scale ?? (normAction == 'upscale_ai' ? defaultUpscaleScale : null);

    if (normAction == 'convert_compress' && (targetKB == null || targetKB <= 0)) {
      throw const BackendException('Target KB harus berupa angka lebih besar dari 0.');
    }

    if (testCompressHandler != null) {
      final staged = <BackendStagedFile>[];
      for (int i = 0; i < entries.length; i++) {
        if (cancelToken?.isCancelled ?? false) {
          throw const BackendCancelledException();
        }
        final entry = entries[i];
        onProgress?.call(i, entries.length, 'Memproses ${entry.name}...');
        final res = await testCompressHandler!(
          BackendCompressTestRequest(
            filePath: entry.path,
            fileName: entry.name,
            action: normAction,
            targetFormat: normTarget,
            compressionType: compressionType?.trim().toLowerCase(),
            targetKB: targetKB,
            targetPerPage: targetPerPage,
            model: model,
            scale: effectiveScale,
            engine: normEngine,
            autoFallback: autoFallback,
            timeoutSeconds: timeoutSeconds,
          ),
        );
        staged.add(res);
      }
      onProgress?.call(entries.length, entries.length, 'Selesai!');
      return BackendBatchResult(files: staged);
    }

    // Validate all input files upfront before spawning/calling engine
    for (final entry in entries) {
      if (!File(entry.path).existsSync()) {
        throw BackendException('File tidak ditemukan di disk: ${entry.path}');
      }
      final ext = extensionOf(entry.path);
      if (normAction == 'upscale_ai' && (ext == 'doc' || ext == 'docx')) {
        throw BackendException(
          'Upscale AI tidak mendukung file dokumen "${entry.name}". Gunakan gambar (JPG/PNG/WEBP) atau PDF.',
        );
      }
      if (normAction == 'convert_only' &&
          (ext == 'doc' || ext == 'docx') &&
          (normTarget == 'doc' || normTarget == 'docx')) {
        throw BackendException(
          'File "${entry.name}" sudah berformat dokumen Word ($ext). Pilih target lain seperti PDF, PNG, atau JPG.',
        );
      }
      if (normAction == 'convert_only' && ext == 'pdf' && normTarget == 'pdf') {
        throw BackendException(
          'File "${entry.name}" sudah berformat PDF. Pilih target PNG, JPG, atau DOCX pada Convert Only, atau gunakan menu Compress & Convert untuk kompresi PDF.',
        );
      }
    }

    final ok = await ensureRunning();
    if (!ok) {
      throw BackendException(
        _lastError ??
            'Backend engine smart_compress_backend.exe tidak aktif dan gagal dijalankan.',
      );
    }

    final rootStaging = await createStagingDir('compress_batch_');

    final configuredWorkers = AppStateService().maxWorkerThreads;
    var concurrency = configuredWorkers < 1
        ? 1
        : (configuredWorkers > 8 ? 8 : configuredWorkers);
    if (normAction == 'upscale_ai' && concurrency > 2) {
      concurrency = 2;
    }
    var completedCount = 0;

    onProgress?.call(
      0,
      entries.length,
      entries.length == 1
          ? 'Memproses ${entries.first.name}...'
          : 'Memproses ${entries.length} file secara paralel ($concurrency worker)...',
    );

    try {
      final perEntryResults =
          await _runBoundedPool<MediaFileEntry, List<BackendStagedFile>>(
        entries,
        concurrency,
        (i, entry) async {
          if (cancelToken?.isCancelled ?? false) {
            throw const BackendCancelledException();
          }

          final itemDir = Directory(_joinPath(rootStaging.path, 'item_$i'));
          await itemDir.create(recursive: true);

          final origBytes = entry.sizeBytes ?? File(entry.path).lengthSync();
          final ext = extensionOf(entry.path);
          final sw = Stopwatch()..start();

          String usedEngineLabel = _describeEngineLabel(
            normAction,
            ext,
            normTarget,
            normEngine,
            compressionType,
            model,
          );

          String sourceForMainStep = entry.path;
          String effectiveEngineUsed = normEngine;

          // Edge case: Go backend only returns early from Word->PDF when action == "convert_only".
          // For "convert_only -> PNG/JPG" or "convert_compress" on .doc/.docx, first convert .docx -> .pdf.
          final needsDocxPreStep = (ext == 'doc' || ext == 'docx') &&
              !(normAction == 'convert_only' && normTarget == 'pdf');

          if (needsDocxPreStep) {
            final step1Dir = Directory(_joinPath(itemDir.path, 'step1_pdf'));
            await step1Dir.create(recursive: true);
            final step1Out = await _runWithOfficeLock(
              () => _executeCompressHttpWithFallback(
                filePath: entry.path,
                outputDir: step1Dir.path,
                action: 'convert_only',
                targetFormat: 'pdf',
                engine: normEngine,
                autoFallback: autoFallback,
                timeoutSeconds: timeoutSeconds,
                cancelToken: cancelToken,
              ),
            );
            if (step1Out.files.isEmpty) {
              throw BackendException(
                'Konversi awal Word ke PDF untuk "${entry.name}" tidak menghasilkan file output.',
              );
            }
            sourceForMainStep = step1Out.files.first.path;
            effectiveEngineUsed = step1Out.usedEngine;
            if (normAction == 'convert_only') {
              usedEngineLabel =
                  '${effectiveEngineUsed == 'libreoffice' ? 'LibreOffice' : 'Microsoft Word'} + MuPDF Pipeline';
            }
          }

          final mainOutDir = Directory(_joinPath(itemDir.path, 'out'));
          await mainOutDir.create(recursive: true);

          final isDirectDocConversion = !needsDocxPreStep &&
              ((ext == 'doc' || ext == 'docx') || normTarget == 'docx');
          final normalizedCompressionType = compressionType?.trim().toLowerCase();
          final effectiveCompressionType =
              (normAction == 'convert_compress' &&
                      (normalizedCompressionType == null ||
                          normalizedCompressionType.isEmpty))
                  ? 'native'
                  : normalizedCompressionType;

          Future<({List<File> files, String usedEngine})> runMainStep() =>
              _executeCompressHttpWithFallback(
                filePath: sourceForMainStep,
                outputDir: mainOutDir.path,
                action: normAction,
                targetFormat: normTarget,
                compressionType: effectiveCompressionType,
                targetKB: targetKB,
                targetPerPage: targetPerPage,
                model: model,
                scale: effectiveScale,
                engine: normEngine,
                autoFallback: autoFallback && isDirectDocConversion,
                timeoutSeconds: timeoutSeconds,
                cancelToken: cancelToken,
              );

          final mainOut = isDirectDocConversion
              ? await _runWithOfficeLock(runMainStep)
              : await runMainStep();

          sw.stop();

          if (!needsDocxPreStep && isDirectDocConversion) {
            usedEngineLabel = mainOut.usedEngine == 'libreoffice'
                ? 'LibreOffice (Headless)'
                : 'Microsoft Word (COM)';
          }

          final outputs = mainOut.files;
          if (outputs.isEmpty) {
            throw BackendException(
              'Backend tidak menghasilkan file output untuk "${entry.name}".',
            );
          }

          final itemStaged = <BackendStagedFile>[];
          for (int pIdx = 0; pIdx < outputs.length; pIdx++) {
            final outFile = outputs[pIdx];
            final actualExt = extensionOf(outFile.path).isEmpty
                ? normTarget
                : extensionOf(outFile.path);
            final suggested = buildOutputName(
              entry.name,
              actualExt,
              partIndex: pIdx,
              totalParts: outputs.length,
            );
            itemStaged.add(
              BackendStagedFile(
                sourceFileName: entry.name,
                stagedFilePath: outFile.path,
                suggestedFileName: suggested,
                originalBytes: origBytes,
                resultBytes: outFile.lengthSync(),
                durationMs: sw.elapsedMilliseconds,
                engineUsed: usedEngineLabel,
                targetFormat: actualExt.toUpperCase(),
              ),
            );
          }

          completedCount++;
          onProgress?.call(
            completedCount,
            entries.length,
            'Selesai $completedCount/${entries.length}: ${entry.name}',
          );
          return itemStaged;
        },
        cancelToken: cancelToken,
      );

      final stagedFiles = <BackendStagedFile>[
        for (final batch in perEntryResults) ...batch,
      ];

      onProgress?.call(entries.length, entries.length, 'Selesai!');
      return BackendBatchResult(
        files: stagedFiles,
        stagingDirPath: rootStaging.path,
      );
    } catch (_) {
      try {
        if (await rootStaging.exists()) {
          await rootStaging.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  String _describeEngineLabel(
    String action,
    String sourceExt,
    String targetExt,
    String engine,
    String? compressionType,
    String? model,
  ) {
    if (action == 'upscale_ai') {
      return model ?? 'Real-ESRGAN AI';
    }
    if (action == 'convert_compress') {
      final isPdfInOut = sourceExt == 'pdf' || targetExt == 'pdf';
      if (isPdfInOut) {
        return 'PDF Compressor (${compressionType ?? 'native'})';
      }
      return 'ImageMagick Pipeline';
    }
    if ((sourceExt == 'doc' || sourceExt == 'docx') || targetExt == 'docx') {
      return engine == 'libreoffice'
          ? 'LibreOffice (Headless)'
          : 'Microsoft Word (COM)';
    }
    return 'Media Image/Document Pipeline';
  }

  static bool _isBackendSuccess(Map<String, dynamic> decoded) {
    final success = decoded['success'];
    if (success is bool) return success;
    final status = decoded['status']?.toString().toLowerCase();
    return status == 'success' || status == 'ok';
  }

  Future<({List<File> files, String usedEngine})>
      _executeCompressHttpWithFallback({
    required String filePath,
    required String outputDir,
    required String action,
    required String targetFormat,
    String? compressionType,
    int? targetKB,
    bool? targetPerPage,
    String? model,
    int? scale,
    required String engine,
    required bool autoFallback,
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    Future<List<File>> callOnce(String chosenEngine, String outSubDir) async {
      final dir = Directory(outSubDir);
      await dir.create(recursive: true);

      final payload = <String, dynamic>{
        'files': <String>[filePath],
        'action': action,
        'target_format': targetFormat,
        'outputDir': outSubDir,
        if (compressionType != null && compressionType.isNotEmpty)
          'compression_type': compressionType,
        'targetKB': ?targetKB,
        'is_target_per_page': ?targetPerPage,
        if (model != null && model.isNotEmpty) 'model': model,
        'scale': ?scale,
        'engine': chosenEngine,
      };

      final decoded = await _postJson(
        '/compress',
        payload,
        timeoutSeconds: timeoutSeconds,
        cancelToken: cancelToken,
      );

      if (!_isBackendSuccess(decoded)) {
        final msg = decoded['message']?.toString() ?? 'Proses gagal di backend.';
        throw BackendException(msg);
      }

      final rawFiles = (decoded['files'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
      return _collectOutputFiles(rawFiles, outSubDir, targetFormat);
    }

    try {
      final attemptDir = _joinPath(outputDir, 'primary_$engine');
      final files = await callOnce(engine, attemptDir);
      return (files: files, usedEngine: engine);
    } catch (primaryErr) {
      if (primaryErr is BackendCancelledException ||
          (cancelToken?.isCancelled ?? false)) {
        rethrow;
      }

      final ext = extensionOf(filePath);
      final isDocConv =
          (ext == 'doc' || ext == 'docx') || targetFormat == 'docx';
      if (!autoFallback || !isDocConv) {
        rethrow;
      }

      final fallbackEngine = engine == 'word' ? 'libreoffice' : 'word';
      AppStateService().addSystemLog(
        level: 'WARN',
        message:
            'Engine "$engine" gagal ($primaryErr). Mencoba Auto-Fallback ke "$fallbackEngine"...',
        source: 'ENGINE',
      );

      final fallbackDir = _joinPath(outputDir, 'fallback_$fallbackEngine');
      final files = await callOnce(fallbackEngine, fallbackDir);
      return (files: files, usedEngine: fallbackEngine);
    }
  }

  List<File> _collectOutputFiles(
    List<String> returnedPaths,
    String expectedOutDir,
    String expectedExt,
  ) {
    final cleanExt = expectedExt.trim().toLowerCase();
    final collected = <String, File>{};

    void addIfValidFile(File f) {
      try {
        if (!f.existsSync() || f.lengthSync() <= 0) return;
        final abs = f.absolute.path;
        collected[abs.toLowerCase()] = File(abs);
      } catch (_) {}
    }

    for (final raw in returnedPaths) {
      final p = raw.trim();
      if (p.isEmpty) continue;
      final type = FileSystemEntity.typeSync(p);
      if (type == FileSystemEntityType.file) {
        addIfValidFile(File(p));
      } else if (type == FileSystemEntityType.directory) {
        for (final entity in Directory(p).listSync(followLinks: false)) {
          if (entity is File) {
            final fExt = extensionOf(entity.path);
            if (cleanExt.isEmpty ||
                fExt == cleanExt ||
                (cleanExt == 'jpg' && fExt == 'jpeg') ||
                (cleanExt == 'jpeg' && fExt == 'jpg')) {
              addIfValidFile(entity);
            }
          }
        }
      }
    }

    if (collected.isEmpty && Directory(expectedOutDir).existsSync()) {
      for (final entity
          in Directory(expectedOutDir).listSync(followLinks: false)) {
        if (entity is File) {
          addIfValidFile(entity);
        }
      }
    }

    final result = collected.values.toList();
    result.sort((a, b) => naturalCompare(a.path, b.path));
    return result;
  }

  static int naturalCompare(String a, String b) {
    final tokenRegex = RegExp(r'(\d+|\D+)');
    final aParts = tokenRegex.allMatches(a).map((m) => m.group(0)!).toList();
    final bParts = tokenRegex.allMatches(b).map((m) => m.group(0)!).toList();
    final len = aParts.length < bParts.length ? aParts.length : bParts.length;
    for (int i = 0; i < len; i++) {
      final ap = aParts[i];
      final bp = bParts[i];
      final ai = int.tryParse(ap);
      final bi = int.tryParse(bp);
      if (ai != null && bi != null) {
        final cmp = ai.compareTo(bi);
        if (cmp != 0) return cmp;
      } else {
        final cmp = ap.toLowerCase().compareTo(bp.toLowerCase());
        if (cmp != 0) return cmp;
      }
    }
    return aParts.length.compareTo(bParts.length);
  }

  Future<Map<String, dynamic>> _postJson(
    String route,
    Map<String, dynamic> body, {
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const BackendCancelledException();
    }

    final targetUrl = effectiveBaseUrl;
    final client = _getOrCreateHttpClient(timeoutSeconds: timeoutSeconds);
    HttpClientRequest? activeReq;
    var cancelledLocally = false;

    void abortHandler() {
      cancelledLocally = true;
      try {
        activeReq?.abort();
      } catch (_) {}
    }

    cancelToken?.onCancel(abortHandler);

    try {
      final reqFuture = client
          .postUrl(Uri.parse('$targetUrl$route'))
          .then((req) async {
        activeReq = req;
        if (cancelledLocally || (cancelToken?.isCancelled ?? false)) {
          try {
            req.abort();
          } catch (_) {}
          throw const BackendCancelledException();
        }
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        return (statusCode: resp.statusCode, body: text);
      });

      final result = timeoutSeconds > 0
          ? await reqFuture.timeout(Duration(seconds: timeoutSeconds))
          : await reqFuture;

      if (cancelledLocally || (cancelToken?.isCancelled ?? false)) {
        throw const BackendCancelledException();
      }

      if (result.body.trim().isEmpty) {
        if (result.statusCode >= 400) {
          throw BackendException(
            'Backend mengembalikan HTTP ${result.statusCode} tanpa pesan detail.',
          );
        }
        return const <String, dynamic>{};
      }

      try {
        final decoded = jsonDecode(result.body);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } catch (_) {}

      if (result.statusCode >= 400) {
        throw BackendException(result.body.trim());
      }
      throw BackendException('Respon JSON tidak valid dari backend.');
    } on TimeoutException {
      try {
        activeReq?.abort();
      } catch (_) {}
      if (cancelledLocally || (cancelToken?.isCancelled ?? false)) {
        throw const BackendCancelledException();
      }
      throw BackendException(
        'Proses timeout melebihi batas $timeoutSeconds detik. Anda dapat memperbesar timeout atau memilih "No Time" di Engine Config.',
      );
    } on SocketException catch (e) {
      if (cancelledLocally || (cancelToken?.isCancelled ?? false)) {
        throw const BackendCancelledException();
      }
      _closeSharedHttpClient();
      throw BackendException('Koneksi ke backend terputus: ${e.message}');
    } on HttpException catch (e) {
      if (cancelledLocally || (cancelToken?.isCancelled ?? false)) {
        throw const BackendCancelledException();
      }
      _lastHealthyAt = null;
      throw BackendException('Gagal berkomunikasi dengan backend: ${e.message}');
    } finally {
      cancelToken?.removeListener(abortHandler);
    }
  }

  Future<List<R>> _runBoundedPool<T, R>(
    List<T> items,
    int maxConcurrent,
    Future<R> Function(int index, T item) worker, {
    BackendCancellationToken? cancelToken,
  }) async {
    if (items.isEmpty) return <R>[];
    final workerCount = items.length < maxConcurrent
        ? items.length
        : (maxConcurrent < 1 ? 1 : maxConcurrent);
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runWorker() async {
      while (true) {
        if (firstError != null) return;
        if (cancelToken?.isCancelled ?? false) {
          firstError ??= const BackendCancelledException();
          firstStackTrace ??= StackTrace.current;
          return;
        }
        final idx = nextIndex++;
        if (idx >= items.length) return;
        try {
          results[idx] = await worker(idx, items[idx]);
        } catch (e, st) {
          firstError ??= e;
          firstStackTrace ??= st;
          return;
        }
      }
    }

    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => runWorker()),
    );
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    return results.cast<R>();
  }

  Future<File> _moveOrCopyFile(String srcPath, String dstPath) async {
    final srcFile = File(srcPath);
    final dstFile = File(dstPath);
    if (srcFile.absolute.path.toLowerCase() ==
        dstFile.absolute.path.toLowerCase()) {
      return dstFile;
    }
    await dstFile.parent.create(recursive: true);
    if (await dstFile.exists()) {
      await dstFile.delete();
    }
    try {
      return await srcFile.rename(dstPath);
    } on FileSystemException {
      final copied = await srcFile.copy(dstPath);
      try {
        if (await srcFile.exists()) {
          await srcFile.delete();
        }
      } catch (_) {}
      return copied;
    }
  }

  /// Applies relative per-page clockwise rotations (+90/+180/+270) via bundled QPDF.
  Future<File> applyQpdfRotations({
    required String inputPdfPath,
    required String outputPdfPath,
    required Map<int, int> oneBasedPageDeltas,
    BackendCancellationToken? cancelToken,
  }) async {
    final normalizedDeltas = <int, List<int>>{};
    for (final entry in oneBasedPageDeltas.entries) {
      if (entry.key < 1) continue;
      final deg = normalizePdfRotation(entry.value);
      if (deg == 0) continue;
      normalizedDeltas.putIfAbsent(deg, () => <int>[]).add(entry.key);
    }

    if (normalizedDeltas.isEmpty) {
      if (inputPdfPath != outputPdfPath) {
        await File(inputPdfPath).copy(outputPdfPath);
      }
      return File(outputPdfPath);
    }

    if (!_capabilities.hasQpdf) {
      await inspectCapabilities(detectExternalOfficeApps: false);
    }

    final qpdfPath = _capabilities.qpdfExePath;
    if (qpdfPath == null || !File(qpdfPath).existsSync()) {
      throw const BackendException(
        'Tool rotasi qpdf.exe tidak ditemukan di assets/engine/tools/qpdf/bin.',
      );
    }

    final sortedAngles = normalizedDeltas.keys.toList()..sort();
    final args = <String>[inputPdfPath];
    for (final angle in sortedAngles) {
      final compacted = PdfInspectorService.formatCompactPageRanges(
        normalizedDeltas[angle]!,
      ).replaceAll(' ', '');
      if (compacted.isNotEmpty) {
        args.add('--rotate=+$angle:$compacted');
      }
    }

    final writeInPlace = File(inputPdfPath).absolute.path.toLowerCase() ==
        File(outputPdfPath).absolute.path.toLowerCase();
    final tempOutPath = writeInPlace
        ? '$outputPdfPath.qpdf_tmp.pdf'
        : outputPdfPath;
    args.add(tempOutPath);

    final proc = await Process.start(
      qpdfPath,
      args,
      workingDirectory: File(qpdfPath).parent.path,
    );

    void killQpdf() {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }

    cancelToken?.onCancel(killQpdf);

    try {
      final stderrFuture = utf8.decoder.bind(proc.stderr).join();
      final stdoutFuture = utf8.decoder.bind(proc.stdout).join();
      final exitCode = await proc.exitCode;
      final stderrText = await stderrFuture;
      final stdoutText = await stdoutFuture;

      if (cancelToken?.isCancelled ?? false) {
        throw const BackendCancelledException();
      }

      // QPDF exitCode == 3 means succeeded with non-fatal PDF structure warnings.
      final tempFile = File(tempOutPath);
      if ((exitCode != 0 && exitCode != 3) ||
          !tempFile.existsSync() ||
          tempFile.lengthSync() <= 0) {
        final detail = stderrText.trim().isNotEmpty
            ? stderrText.trim()
            : stdoutText.trim();
        throw BackendException(
          'QPDF gagal menerapkan rotasi (exit code $exitCode): $detail',
        );
      }

      if (writeInPlace) {
        final target = File(outputPdfPath);
        if (await target.exists()) {
          await target.delete();
        }
        await tempFile.rename(outputPdfPath);
      }

      if (exitCode == 3 && stderrText.trim().isNotEmpty) {
        AppStateService().addSystemLog(
          level: 'WARN',
          message: 'QPDF warning saat rotasi: ${stderrText.trim()}',
          source: 'PIPELINE',
        );
      }

      return File(outputPdfPath);
    } finally {
      cancelToken?.removeListener(killQpdf);
    }
  }

  /// Executes a single PDF pool or chained multi-pool workflow on disk via Go `/pdf-workflow` + QPDF.
  Future<BackendBatchResult> executePdfWorkflow({
    required List<PoolSectionData> pools,
    required String taskModeLabel,
    String outputSuffix = 'workflow',
    int timeoutSeconds = 120,
    BackendCancellationToken? cancelToken,
    void Function(int currentStep, int totalSteps, String message)? onProgress,
  }) async {
    if (testWorkflowHandler != null) {
      return testWorkflowHandler!(
        BackendWorkflowTestRequest(
          pools: pools,
          taskModeLabel: taskModeLabel,
          outputSuffix: outputSuffix,
        ),
      );
    }

    final ok = await ensureRunning();
    if (!ok) {
      throw BackendException(
        _lastError ??
            'Backend engine smart_compress_backend.exe tidak aktif untuk mengeksekusi PDF Manager.',
      );
    }

    // Check that at least one pool has at least one valid real file on disk
    final anySlotHasFile = pools.any(
      (p) => p.slots.any((s) => !s.isInherited && s.hasFile),
    );
    if (!anySlotHasFile) {
      throw const BackendException(
        'Belum ada file PDF pada pool. Pilih file PDF terlebih dahulu!',
      );
    }

    for (final p in pools) {
      for (final s in p.slots) {
        if (!s.isInherited && s.hasFile) {
          final path = s.filePath ?? '';
          if (path.isEmpty || !File(path).existsSync()) {
            throw BackendException(
              'File PDF "${s.fileName}" tidak ditemukan di disk ($path).',
            );
          }
        }
      }
    }

    final rootStaging = await createStagingDir('pdf_workflow_');
    final inspector = PdfInspectorService();
    final sw = Stopwatch()..start();

    try {
      final activePoolIndices = <int>[];
      for (int i = 0; i < pools.length; i++) {
        final p = pools[i];
        final hasOwnFiles = p.slots.any((s) => !s.isInherited && s.hasFile);
        final hasInherited = p.slots.any((s) => s.isInherited);
        if (hasOwnFiles || (i > 0 && hasInherited && activePoolIndices.isNotEmpty)) {
          activePoolIndices.add(i);
        }
      }

      if (activePoolIndices.isEmpty) {
        throw const BackendException('Tidak ada pool dengan file valid untuk diproses.');
      }

      final docPageCountCache = <String, int>{};
      Future<int> getPageCount(String path, String name, int? hint) async {
        final key = '${path.toLowerCase()}|$name';
        if (docPageCountCache.containsKey(key)) {
          return docPageCountCache[key]!;
        }
        final cached = inspector.getCached(name, path, hintPageCount: hint);
        if (cached != null) {
          docPageCountCache[key] = cached.pageCount;
          return cached.pageCount;
        }
        if (hint != null && hint > 0) {
          docPageCountCache[key] = hint;
          return hint;
        }
        final info = await inspector.inspectFile(
          fileName: name,
          filePath: path,
          hintPageCount: hint,
        );
        docPageCountCache[key] = info.pageCount;
        return info.pageCount;
      }

      // Pre-inspeksi seluruh file slot yang belum memiliki hint pageCount secara paralel terbatas.
      final slotsToPreInspect = <PoolSlot>[];
      final queuedKeys = <String>{};
      for (final poolIdx in activePoolIndices) {
        for (final s in pools[poolIdx].slots) {
          if (!s.isInherited &&
              s.hasFile &&
              (s.pageCount == null || s.pageCount! <= 0)) {
            final key = '${s.filePath!.toLowerCase()}|${s.fileName}';
            if (queuedKeys.add(key) &&
                inspector.getCached(
                      s.fileName!,
                      s.filePath,
                      hintPageCount: s.pageCount,
                    ) ==
                    null) {
              slotsToPreInspect.add(s);
            }
          }
        }
      }
      if (slotsToPreInspect.isNotEmpty) {
        await _runBoundedPool(
          slotsToPreInspect,
          4,
          (_, s) => getPageCount(s.filePath!, s.fileName!, s.pageCount),
          cancelToken: cancelToken,
        );
      }

      var upstreamArtifacts = <_UpstreamPdfArtifact>[];
      var lastOrigBytesTotal = 0;
      var primarySourceName = 'Dokumen.pdf';

      for (int stepIdx = 0; stepIdx < activePoolIndices.length; stepIdx++) {
        if (cancelToken?.isCancelled ?? false) {
          throw const BackendCancelledException();
        }
        final poolIdx = activePoolIndices[stepIdx];
        final pool = pools[poolIdx];
        final isLastStep = stepIdx == activePoolIndices.length - 1;

        onProgress?.call(
          stepIdx,
          activePoolIndices.length,
          'Menjalankan Pool #${poolIdx + 1}: ${pool.title}...',
        );

        final stepDir = Directory(_joinPath(rootStaging.path, 'pool_$poolIdx'));
        await stepDir.create(recursive: true);

        final normalSlotsWithFiles =
            pool.slots.where((s) => !s.isInherited && s.hasFile).toList();
        final emptyNormalSpecSlots =
            pool.slots.where((s) => !s.isInherited && !s.hasFile).toList();

        for (final s in normalSlotsWithFiles) {
          final p = s.filePath!;
          lastOrigBytesTotal += File(p).lengthSync();
          if (primarySourceName == 'Dokumen.pdf' && s.fileName != null) {
            primarySourceName = s.fileName!;
          }
        }
        if (primarySourceName == 'Dokumen.pdf' && upstreamArtifacts.isNotEmpty) {
          primarySourceName = upstreamArtifacts.first.displayName;
        }

        if (pool.title == 'Split Separate Pool') {
          upstreamArtifacts = await _executeSplitSeparateStep(
            pool: pool,
            upstreamArtifacts: upstreamArtifacts,
            normalSlotsWithFiles: normalSlotsWithFiles,
            emptyNormalSpecSlots: emptyNormalSpecSlots,
            stepDir: stepDir.path,
            getPageCount: getPageCount,
            timeoutSeconds: timeoutSeconds,
            cancelToken: cancelToken,
          );
          if (!isLastStep && upstreamArtifacts.isEmpty) {
            throw const BackendException(
              'Split Separate Pool tidak menghasilkan file output.',
            );
          }
        } else if (pool.title == 'Split Pool') {
          final artifact = await _executeSplitStep(
            pool: pool,
            upstreamArtifacts: upstreamArtifacts,
            normalSlotsWithFiles: normalSlotsWithFiles,
            emptyNormalSpecSlots: emptyNormalSpecSlots,
            stepDir: stepDir.path,
            getPageCount: getPageCount,
            timeoutSeconds: timeoutSeconds,
            cancelToken: cancelToken,
          );
          upstreamArtifacts = [artifact];
        } else if (pool.title == 'Reorder Pool') {
          final artifact = await _executeReorderStep(
            pool: pool,
            upstreamArtifacts: upstreamArtifacts,
            normalSlotsWithFiles: normalSlotsWithFiles,
            emptyNormalSpecSlots: emptyNormalSpecSlots,
            stepDir: stepDir.path,
            getPageCount: getPageCount,
            timeoutSeconds: timeoutSeconds,
            cancelToken: cancelToken,
          );
          upstreamArtifacts = [artifact];
        } else if (pool.title == 'Merge Pool') {
          final artifact = await _executeMergeStep(
            pool: pool,
            upstreamArtifacts: upstreamArtifacts,
            stepDir: stepDir.path,
            getPageCount: getPageCount,
            timeoutSeconds: timeoutSeconds,
            cancelToken: cancelToken,
          );
          upstreamArtifacts = [artifact];
        } else {
          final artifact = await _executeSplitStep(
            pool: pool,
            upstreamArtifacts: upstreamArtifacts,
            normalSlotsWithFiles: normalSlotsWithFiles,
            emptyNormalSpecSlots: emptyNormalSpecSlots,
            stepDir: stepDir.path,
            getPageCount: getPageCount,
            timeoutSeconds: timeoutSeconds,
            cancelToken: cancelToken,
          );
          upstreamArtifacts = [artifact];
        }
      }

      sw.stop();
      if (upstreamArtifacts.isEmpty) {
        throw const BackendException('Workflow tidak menghasilkan file PDF output.');
      }

      final appState = AppStateService();
      final totalInputBytes = lastOrigBytesTotal > 0
          ? lastOrigBytesTotal
          : upstreamArtifacts.fold<int>(
              0,
              (sum, a) => sum + File(a.filePath).lengthSync(),
            );

      final stagedOutputs = <BackendStagedFile>[];
      for (int i = 0; i < upstreamArtifacts.length; i++) {
        final artifact = upstreamArtifacts[i];
        final outFile = File(artifact.filePath);
        if (!outFile.existsSync() || outFile.lengthSync() <= 0) {
          throw BackendException(
            'File output "${artifact.displayName}" kosong atau gagal dibuat.',
          );
        }

        final isSplitSeparateOutput = artifact.isSplitSeparate;
        final sourceForNaming =
            (isSplitSeparateOutput &&
                    artifact.originalFileName != null &&
                    artifact.originalFileName!.trim().isNotEmpty)
                ? artifact.originalFileName!
                : primarySourceName;

        final suffix = (!isSplitSeparateOutput && upstreamArtifacts.length == 1)
            ? outputSuffix
            : '${outputSuffix}_p${_extractPageBadgeFromName(artifact.displayName, i + 1)}';
        final suggested = appState.buildOutputFileName(
          sourceForNaming,
          'PDF',
          customSuffix: suffix,
        );
        final originalBytes =
            (isSplitSeparateOutput &&
                    artifact.sourceFileBytes != null &&
                    artifact.sourceFileBytes! > 0)
                ? artifact.sourceFileBytes!
                : totalInputBytes;

        stagedOutputs.add(
          BackendStagedFile(
            sourceFileName: artifact.displayName,
            stagedFilePath: outFile.path,
            suggestedFileName: suggested,
            groupFileName: isSplitSeparateOutput
                ? (artifact.originalFileName ?? artifact.displayName)
                : null,
            originalBytes: originalBytes,
            resultBytes: outFile.lengthSync(),
            durationMs: sw.elapsedMilliseconds,
            engineUsed: 'PDF Manager Core + QPDF',
            targetFormat: 'PDF',
          ),
        );
      }

      onProgress?.call(
        activePoolIndices.length,
        activePoolIndices.length,
        'Proses selesai!',
      );
      return BackendBatchResult(
        files: stagedOutputs,
        stagingDirPath: rootStaging.path,
      );
    } catch (_) {
      try {
        if (await rootStaging.exists()) {
          await rootStaging.delete(recursive: true);
        }
      } catch (_) {}
      rethrow;
    }
  }

  String _extractPageBadgeFromName(String name, int fallbackIdx) {
    final m = RegExp(r'_p(\d+)(?=\.[^.]+$|$)').firstMatch(name);
    if (m != null) return m.group(1)!;
    return '$fallbackIdx';
  }

  String _fileNameFromOrigin(_TrackedPageOrigin origin, String fallback) {
    final pipeIdx = origin.sourceKey.lastIndexOf('|');
    if (pipeIdx >= 0 && pipeIdx < origin.sourceKey.length - 1) {
      final candidate = origin.sourceKey.substring(pipeIdx + 1).trim();
      if (candidate.isNotEmpty) return candidate;
    }
    return fallback;
  }

  String? _pathFromOrigin(_TrackedPageOrigin origin) {
    final pipeIdx = origin.sourceKey.lastIndexOf('|');
    if (pipeIdx > 0) {
      final candidate = origin.sourceKey.substring(0, pipeIdx).trim();
      if (candidate.isNotEmpty) return candidate;
    }
    return null;
  }

  String _stripFileExtension(String fileName) {
    final trimmed = fileName.trim();
    final dot = trimmed.lastIndexOf('.');
    return dot > 0 ? trimmed.substring(0, dot) : trimmed;
  }

  List<int> _mapOrigPagesThroughUpstream(
    List<int> requestedOrigPages,
    _UpstreamPdfArtifact upstream,
    PoolFileRef? matchedRef,
  ) {
    if (upstream.pageOrigins.isEmpty) return requestedOrigPages;
    final refKey = matchedRef != null ? PoolSlot.fileRotationKey(matchedRef) : null;
    final mapped = <int>[];

    for (final reqPage in requestedOrigPages) {
      int matchedPos = -1;
      for (int idx = 0; idx < upstream.pageOrigins.length; idx++) {
        final origin = upstream.pageOrigins[idx];
        final keyMatch = refKey == null || origin.sourceKey == refKey;
        if (keyMatch && origin.originalPageNumber == reqPage) {
          matchedPos = idx + 1;
          break;
        }
      }
      if (matchedPos == -1 && refKey != null) {
        for (int idx = 0; idx < upstream.pageOrigins.length; idx++) {
          if (upstream.pageOrigins[idx].originalPageNumber == reqPage) {
            matchedPos = idx + 1;
            break;
          }
        }
      }
      if (matchedPos != -1) {
        mapped.add(matchedPos);
      } else if (reqPage >= 1 && reqPage <= upstream.pageOrigins.length && upstream.pageOrigins.every((o) => o.sourceKey == upstream.pageOrigins.first.sourceKey)) {
        final available = upstream.pageOrigins
            .where((o) => refKey == null || o.sourceKey == refKey)
            .map((o) => o.originalPageNumber)
            .toList();
        throw BackendException(
          'Halaman $reqPage tidak tersedia pada output pool sebelumnya (tersedia: ${available.join(', ')}).',
        );
      } else {
        throw BackendException(
          'Halaman $reqPage tidak tersedia pada output pool sebelumnya.',
        );
      }
    }
    return mapped;
  }

  int _resolveDesiredInheritedRotation(
    PoolSlot? inhSlot,
    List<PoolFileRef> inhRefs,
    _TrackedPageOrigin origin,
  ) {
    for (final ref in inhRefs) {
      if (PoolSlot.fileRotationKey(ref) == origin.sourceKey) {
        if (inhSlot != null) {
          return inhSlot.getInheritedPageRotation(ref, origin.originalPageNumber);
        }
        return normalizePdfRotation(ref.pageRotations[origin.originalPageNumber] ?? 0);
      }
    }
    return origin.appliedRotationDeg;
  }

  Future<_UpstreamPdfArtifact> _executeSplitStep({
    required PoolSectionData pool,
    required List<_UpstreamPdfArtifact> upstreamArtifacts,
    required List<PoolSlot> normalSlotsWithFiles,
    required List<PoolSlot> emptyNormalSpecSlots,
    required String stepDir,
    required Future<int> Function(String path, String name, int? hint) getPageCount,
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    final initialFiles = <Map<String, String>>[];
    final splits = <Map<String, dynamic>>[];
    final resultOrigins = <_TrackedPageOrigin>[];
    final desiredRotations = <int, int>{};

    var inputSeq = 0;
    final usedUpstreamIds = <String, String>{};

    String registerInput(String path) {
      final norm = path.toLowerCase();
      if (usedUpstreamIds.containsKey(norm)) return usedUpstreamIds[norm]!;
      final id = 'in_${inputSeq++}';
      usedUpstreamIds[norm] = id;
      initialFiles.add({'id': id, 'path': path});
      return id;
    }

    int emptySpecCursor = 0;

    for (final slot in pool.slots) {
      if (slot.isInherited) {
        final inhRefs = slot.resolvedInheritedRefs;
        for (int idx = 0; idx < upstreamArtifacts.length; idx++) {
          final upstream = upstreamArtifacts[idx];
          final ref = idx < inhRefs.length
              ? inhRefs[idx]
              : (inhRefs.isNotEmpty ? inhRefs.first : null);
          final specText = (emptySpecCursor < emptyNormalSpecSlots.length)
              ? emptyNormalSpecSlots[emptySpecCursor++].pageRange?.trim()
              : null;

          final upstreamPageCount = upstream.pageOrigins.length;
          late final List<int> pagesToExtract;
          if (specText == null || specText.isEmpty) {
            pagesToExtract = List<int>.generate(upstreamPageCount, (i) => i + 1);
          } else {
            final origMax = (ref?.pageCount ?? upstreamPageCount) > upstreamPageCount
                ? (ref?.pageCount ?? upstreamPageCount)
                : upstreamPageCount;
            final requestedOrig = PdfInspectorService.parsePageRangeSpec(specText, origMax);
            if (requestedOrig.isEmpty) {
              throw BackendException(
                'Format halaman split "$specText" tidak valid.',
              );
            }
            pagesToExtract = _mapOrigPagesThroughUpstream(requestedOrig, upstream, ref);
          }

          final srcId = registerInput(upstream.filePath);
          splits.add({'sourceId': srcId, 'pages': pagesToExtract});

          for (final pos in pagesToExtract) {
            final baseOrigin = upstream.pageOrigins[pos - 1];
            final outPos = resultOrigins.length + 1;
            final desired = _resolveDesiredInheritedRotation(slot, inhRefs, baseOrigin);
            final delta = normalizePdfRotation(desired - baseOrigin.appliedRotationDeg);
            if (delta != 0) desiredRotations[outPos] = delta;
            resultOrigins.add(baseOrigin.copyWith(appliedRotationDeg: desired));
          }
        }
      } else if (slot.hasFile) {
        final filePath = slot.filePath!;
        final fileName = slot.fileName!;
        final totalPages = await getPageCount(filePath, fileName, slot.pageCount);
        final specText = slot.pageRange?.trim();

        final pages = (specText == null || specText.isEmpty)
            ? List<int>.generate(totalPages, (i) => i + 1)
            : PdfInspectorService.parsePageRangeSpec(specText, totalPages);
        if (pages.isEmpty) {
          throw BackendException(
            'Range halaman "$specText" pada "$fileName" tidak valid atau melebihi $totalPages halaman.',
          );
        }

        final srcId = registerInput(filePath);
        splits.add({'sourceId': srcId, 'pages': pages});
        final sourceKey = '$filePath|$fileName';

        for (final origPage in pages) {
          final outPos = resultOrigins.length + 1;
          final deg = slot.getPageRotation(origPage);
          if (deg != 0) desiredRotations[outPos] = deg;
          resultOrigins.add(
            _TrackedPageOrigin(
              sourceKey: sourceKey,
              originalPageNumber: origPage,
              appliedRotationDeg: deg,
            ),
          );
        }
      }
    }

    if (splits.isEmpty) {
      throw const BackendException('Split Pool tidak memiliki slot file yang valid.');
    }

    final rawDir = _joinPath(stepDir, 'raw');
    final resp = await _postJson(
      '/pdf-workflow',
      {
        'initialFiles': initialFiles,
        'outputDir': rawDir,
        'steps': [
          {
            'action': 'split',
            'outputId': 'split_out',
            'splits': splits,
            if (desiredRotations.isNotEmpty)
              'rotations': {
                for (final e in desiredRotations.entries) '${e.key}': e.value,
              },
          },
        ],
      },
      timeoutSeconds: timeoutSeconds,
      cancelToken: cancelToken,
    );

    if (!_isBackendSuccess(resp)) {
      throw BackendException(
        resp['message']?.toString() ?? 'Eksekusi Split Pool gagal di backend.',
      );
    }

    final rawFiles = _collectOutputFiles(
      (resp['files'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
      rawDir,
      'pdf',
    );
    if (rawFiles.isEmpty) {
      throw const BackendException('Split Pool tidak menghasilkan file PDF.');
    }

    final finalPath = _joinPath(stepDir, 'split_result.pdf');
    final backendAppliedRotations = resp['rotations_applied'] == true;
    if (desiredRotations.isEmpty || backendAppliedRotations) {
      await _moveOrCopyFile(rawFiles.first.path, finalPath);
    } else {
      await applyQpdfRotations(
        inputPdfPath: rawFiles.first.path,
        outputPdfPath: finalPath,
        oneBasedPageDeltas: desiredRotations,
        cancelToken: cancelToken,
      );
    }

    final displayName = normalSlotsWithFiles.isNotEmpty
        ? normalSlotsWithFiles.first.fileName!
        : (upstreamArtifacts.isNotEmpty ? upstreamArtifacts.first.displayName : 'Split.pdf');

    return _UpstreamPdfArtifact(
      filePath: finalPath,
      displayName: displayName,
      pageOrigins: resultOrigins,
    );
  }

  Future<List<_UpstreamPdfArtifact>> _executeSplitSeparateStep({
    required PoolSectionData pool,
    required List<_UpstreamPdfArtifact> upstreamArtifacts,
    required List<PoolSlot> normalSlotsWithFiles,
    required List<PoolSlot> emptyNormalSpecSlots,
    required String stepDir,
    required Future<int> Function(String path, String name, int? hint) getPageCount,
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    final tasks = <({
      String inputPdfPath,
      String baseDisplayName,
      List<int> pagesToExtract,
      List<_TrackedPageOrigin> sourceOrigins,
      ({int desired, int delta}) Function(_TrackedPageOrigin origin) resolveDelta,
      String outSubDir,
      String outputPrefix,
    })>[];
    int targetIdx = 0;
    int emptySpecCursor = 0;

    for (final slot in pool.slots) {
      if (slot.isInherited) {
        final inhRefs = slot.resolvedInheritedRefs;
        for (int idx = 0; idx < upstreamArtifacts.length; idx++) {
          final upstream = upstreamArtifacts[idx];
          final ref = idx < inhRefs.length
              ? inhRefs[idx]
              : (inhRefs.isNotEmpty ? inhRefs.first : null);
          final specText = (emptySpecCursor < emptyNormalSpecSlots.length)
              ? emptyNormalSpecSlots[emptySpecCursor++].pageRange?.trim()
              : null;

          final upstreamPageCount = upstream.pageOrigins.length;
          late final List<int> pagesToExtract;
          if (specText == null || specText.isEmpty) {
            pagesToExtract = List<int>.generate(upstreamPageCount, (i) => i + 1);
          } else {
            final origMax = (ref?.pageCount ?? upstreamPageCount) > upstreamPageCount
                ? (ref?.pageCount ?? upstreamPageCount)
                : upstreamPageCount;
            final requestedOrig = PdfInspectorService.parsePageRangeSpec(specText, origMax);
            if (requestedOrig.isEmpty) {
              throw BackendException(
                'Format halaman split separate "$specText" tidak valid.',
              );
            }
            pagesToExtract = _mapOrigPagesThroughUpstream(requestedOrig, upstream, ref);
          }

          tasks.add((
            inputPdfPath: upstream.filePath,
            baseDisplayName: upstream.displayName,
            pagesToExtract: pagesToExtract,
            sourceOrigins: [
              for (final pos in pagesToExtract) upstream.pageOrigins[pos - 1],
            ],
            resolveDelta: (origin) {
              final desired = _resolveDesiredInheritedRotation(slot, inhRefs, origin);
              return (
                desired: desired,
                delta: normalizePdfRotation(desired - origin.appliedRotationDeg),
              );
            },
            outSubDir: _joinPath(stepDir, 'sep_$targetIdx'),
            outputPrefix: 'sep_$targetIdx',
          ));
          targetIdx++;
        }
      } else if (slot.hasFile) {
        final filePath = slot.filePath!;
        final fileName = slot.fileName!;
        final totalPages = await getPageCount(filePath, fileName, slot.pageCount);
        final specText = slot.pageRange?.trim();

        final pages = (specText == null || specText.isEmpty)
            ? List<int>.generate(totalPages, (i) => i + 1)
            : PdfInspectorService.parsePageRangeSpec(specText, totalPages);
        if (pages.isEmpty) {
          throw BackendException(
            'Range halaman "$specText" pada "$fileName" tidak valid atau melebihi $totalPages halaman.',
          );
        }

        final sourceKey = '$filePath|$fileName';
        tasks.add((
          inputPdfPath: filePath,
          baseDisplayName: fileName,
          pagesToExtract: pages,
          sourceOrigins: [
            for (final orig in pages)
              _TrackedPageOrigin(
                sourceKey: sourceKey,
                originalPageNumber: orig,
                appliedRotationDeg: 0,
              ),
          ],
          resolveDelta: (origin) {
            final deg = slot.getPageRotation(origin.originalPageNumber);
            return (desired: deg, delta: deg);
          },
          outSubDir: _joinPath(stepDir, 'sep_$targetIdx'),
          outputPrefix: 'sep_$targetIdx',
        ));
        targetIdx++;
      }
    }

    if (tasks.isEmpty) {
      return <_UpstreamPdfArtifact>[];
    }

    final perTargetOutputs = await _runBoundedPool(
      tasks,
      4,
      (_, task) => _runSingleSplitSeparated(
        inputPdfPath: task.inputPdfPath,
        baseDisplayName: task.baseDisplayName,
        pagesToExtract: task.pagesToExtract,
        sourceOrigins: task.sourceOrigins,
        resolveDelta: task.resolveDelta,
        outSubDir: task.outSubDir,
        outputPrefix: task.outputPrefix,
        timeoutSeconds: timeoutSeconds,
        cancelToken: cancelToken,
      ),
      cancelToken: cancelToken,
    );

    final allOutputs = [for (final batch in perTargetOutputs) ...batch];
    final grouped = <String, List<_UpstreamPdfArtifact>>{};
    for (final artifact in allOutputs) {
      final groupKey = (artifact.originalFileName ?? artifact.displayName)
          .trim()
          .toLowerCase();
      grouped.putIfAbsent(groupKey, () => <_UpstreamPdfArtifact>[]).add(artifact);
    }
    return [for (final batch in grouped.values) ...batch];
  }

  Future<List<_UpstreamPdfArtifact>> _runSingleSplitSeparated({
    required String inputPdfPath,
    required String baseDisplayName,
    required List<int> pagesToExtract,
    required List<_TrackedPageOrigin> sourceOrigins,
    required ({int desired, int delta}) Function(_TrackedPageOrigin origin)
        resolveDelta,
    required String outSubDir,
    required String outputPrefix,
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    final rawDir = _joinPath(outSubDir, 'raw');
    await Directory(rawDir).create(recursive: true);

    final rots = <({int desired, int delta})>[
      for (final origin in sourceOrigins) resolveDelta(origin),
    ];
    final stepRotations = <String, int>{};
    for (int i = 0; i < rots.length; i++) {
      if (rots[i].delta != 0) {
        stepRotations['${i + 1}'] = rots[i].delta;
      }
    }

    final resp = await _postJson(
      '/pdf-workflow',
      {
        'initialFiles': [
          {'id': 'target', 'path': inputPdfPath},
        ],
        'outputDir': rawDir,
        'steps': [
          {
            'action': 'split_separated',
            'targetId': 'target',
            'outputId': outputPrefix,
            'pages': pagesToExtract,
            if (stepRotations.isNotEmpty) 'rotations': stepRotations,
          },
        ],
      },
      timeoutSeconds: timeoutSeconds,
      cancelToken: cancelToken,
    );

    if (!_isBackendSuccess(resp)) {
      throw BackendException(
        resp['message']?.toString() ?? 'Split Separate Pool gagal di backend.',
      );
    }

    // Important: Go backend split_separated returns only [firstSplitPath],
    // so always scan rawDir for <outputPrefix>_p<pageNum>.pdf in pagesToExtract order.
    final rotDir = Directory(_joinPath(outSubDir, 'final'));
    await rotDir.create(recursive: true);

    final backendAppliedRotations = resp['rotations_applied'] == true;
    final sourceBytesCache = <String, int?>{};
    int? resolveSourceBytes(_TrackedPageOrigin origin) {
      final path = _pathFromOrigin(origin);
      if (path == null) return null;
      final key = path.toLowerCase();
      if (sourceBytesCache.containsKey(key)) return sourceBytesCache[key];
      final file = File(path);
      final size = file.existsSync() ? file.lengthSync() : null;
      sourceBytesCache[key] = size;
      return size;
    }

    final rawUseCounts = <String, int>{};
    final pageJobs = <({
      _TrackedPageOrigin origin,
      File expectedRaw,
      ({int desired, int delta}) rot,
      String finalPath,
      String displayName,
      String originalFileName,
      int? sourceFileBytes,
    })>[];

    for (int i = 0; i < pagesToExtract.length; i++) {
      final pageNum = pagesToExtract[i];
      final origin = sourceOrigins[i];
      final expectedRaw = File(_joinPath(rawDir, '${outputPrefix}_p$pageNum.pdf'));
      if (!expectedRaw.existsSync() || expectedRaw.lengthSync() <= 0) {
        throw BackendException(
          'Halaman hasil split $pageNum tidak ditemukan di output backend.',
        );
      }
      final rawKey = expectedRaw.path.toLowerCase();
      rawUseCounts[rawKey] = (rawUseCounts[rawKey] ?? 0) + 1;

      final pageSourceName = _fileNameFromOrigin(origin, baseDisplayName);
      final pageBaseName = _stripFileExtension(pageSourceName);
      final finalPath = _joinPath(
        rotDir.path,
        '${outputPrefix}_${i}_p${origin.originalPageNumber}.pdf',
      );
      pageJobs.add((
        origin: origin,
        expectedRaw: expectedRaw,
        rot: rots[i],
        finalPath: finalPath,
        displayName: '${pageBaseName}_p${origin.originalPageNumber}.pdf',
        originalFileName: pageSourceName,
        sourceFileBytes: resolveSourceBytes(origin),
      ));
    }

    return _runBoundedPool(
      pageJobs,
      4,
      (_, job) async {
        if (backendAppliedRotations || job.rot.delta == 0) {
          final rawKey = job.expectedRaw.path.toLowerCase();
          if ((rawUseCounts[rawKey] ?? 1) == 1) {
            await _moveOrCopyFile(job.expectedRaw.path, job.finalPath);
          } else {
            await job.expectedRaw.copy(job.finalPath);
          }
        } else {
          await applyQpdfRotations(
            inputPdfPath: job.expectedRaw.path,
            outputPdfPath: job.finalPath,
            oneBasedPageDeltas: {1: job.rot.delta},
            cancelToken: cancelToken,
          );
        }
        return _UpstreamPdfArtifact(
          filePath: job.finalPath,
          displayName: job.displayName,
          originalFileName: job.originalFileName,
          sourceFileBytes: job.sourceFileBytes,
          isSplitSeparate: true,
          pageOrigins: [job.origin.copyWith(appliedRotationDeg: job.rot.desired)],
        );
      },
      cancelToken: cancelToken,
    );
  }

  Future<_UpstreamPdfArtifact> _executeReorderStep({
    required PoolSectionData pool,
    required List<_UpstreamPdfArtifact> upstreamArtifacts,
    required List<PoolSlot> normalSlotsWithFiles,
    required List<PoolSlot> emptyNormalSpecSlots,
    required String stepDir,
    required Future<int> Function(String path, String name, int? hint) getPageCount,
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    final initialFiles = <Map<String, String>>[];
    final reorders = <Map<String, dynamic>>[];
    final resultOrigins = <_TrackedPageOrigin>[];
    final desiredRotations = <int, int>{};

    var inputSeq = 0;
    final usedIds = <String, String>{};
    String registerInput(String path) {
      final norm = path.toLowerCase();
      if (usedIds.containsKey(norm)) return usedIds[norm]!;
      final id = 'in_${inputSeq++}';
      usedIds[norm] = id;
      initialFiles.add({'id': id, 'path': path});
      return id;
    }

    int emptySpecCursor = 0;

    for (final slot in pool.slots) {
      if (slot.isInherited) {
        final inhRefs = slot.resolvedInheritedRefs;
        for (int idx = 0; idx < upstreamArtifacts.length; idx++) {
          final upstream = upstreamArtifacts[idx];
          final ref = idx < inhRefs.length
              ? inhRefs[idx]
              : (inhRefs.isNotEmpty ? inhRefs.first : null);
          final specText = (emptySpecCursor < emptyNormalSpecSlots.length)
              ? emptyNormalSpecSlots[emptySpecCursor++].pageRange?.trim()
              : null;

          final upstreamPageCount = upstream.pageOrigins.length;
          late final List<int> newOrder;
          if (specText == null || specText.isEmpty) {
            newOrder = List<int>.generate(upstreamPageCount, (i) => i + 1);
          } else {
            final origMax = (ref?.pageCount ?? upstreamPageCount) > upstreamPageCount
                ? (ref?.pageCount ?? upstreamPageCount)
                : upstreamPageCount;
            final requestedOrig = PdfInspectorService.parseOrderSpec(
              specText,
              origMax,
              appendMissing: false,
            );
            if (requestedOrig.isEmpty) {
              throw BackendException(
                'Urutan halaman "$specText" pada Reorder Pool tidak valid.',
              );
            }
            newOrder = _mapOrigPagesThroughUpstream(requestedOrig, upstream, ref);
          }

          final srcId = registerInput(upstream.filePath);
          reorders.add({'sourceId': srcId, 'newOrder': newOrder});

          for (final pos in newOrder) {
            final baseOrigin = upstream.pageOrigins[pos - 1];
            final outPos = resultOrigins.length + 1;
            final desired = _resolveDesiredInheritedRotation(slot, inhRefs, baseOrigin);
            final delta = normalizePdfRotation(desired - baseOrigin.appliedRotationDeg);
            if (delta != 0) desiredRotations[outPos] = delta;
            resultOrigins.add(baseOrigin.copyWith(appliedRotationDeg: desired));
          }
        }
      } else if (slot.hasFile) {
        final filePath = slot.filePath!;
        final fileName = slot.fileName!;
        final totalPages = await getPageCount(filePath, fileName, slot.pageCount);
        final specText = slot.pageRange?.trim();

        final newOrder = (specText == null || specText.isEmpty)
            ? List<int>.generate(totalPages, (i) => i + 1)
            : PdfInspectorService.parseOrderSpec(
                specText,
                totalPages,
                appendMissing: false,
              );
        if (newOrder.isEmpty) {
          throw BackendException(
            'Urutan halaman "$specText" pada "$fileName" tidak valid.',
          );
        }

        final srcId = registerInput(filePath);
        reorders.add({'sourceId': srcId, 'newOrder': newOrder});
        final sourceKey = '$filePath|$fileName';

        for (final origPage in newOrder) {
          final outPos = resultOrigins.length + 1;
          final deg = slot.getPageRotation(origPage);
          if (deg != 0) desiredRotations[outPos] = deg;
          resultOrigins.add(
            _TrackedPageOrigin(
              sourceKey: sourceKey,
              originalPageNumber: origPage,
              appliedRotationDeg: deg,
            ),
          );
        }
      }
    }

    if (reorders.isEmpty) {
      throw const BackendException('Reorder Pool tidak memiliki file yang valid.');
    }

    final rawDir = _joinPath(stepDir, 'raw');
    final resp = await _postJson(
      '/pdf-workflow',
      {
        'initialFiles': initialFiles,
        'outputDir': rawDir,
        'steps': [
          {
            'action': 'reorder',
            'outputId': 'reorder_out',
            'reorders': reorders,
            if (desiredRotations.isNotEmpty)
              'rotations': {
                for (final e in desiredRotations.entries) '${e.key}': e.value,
              },
          },
        ],
      },
      timeoutSeconds: timeoutSeconds,
      cancelToken: cancelToken,
    );

    if (!_isBackendSuccess(resp)) {
      throw BackendException(
        resp['message']?.toString() ?? 'Eksekusi Reorder Pool gagal di backend.',
      );
    }

    final rawFiles = _collectOutputFiles(
      (resp['files'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
      rawDir,
      'pdf',
    );
    if (rawFiles.isEmpty) {
      throw const BackendException('Reorder Pool tidak menghasilkan file PDF.');
    }

    final finalPath = _joinPath(stepDir, 'reorder_result.pdf');
    final backendAppliedRotations = resp['rotations_applied'] == true;
    if (desiredRotations.isEmpty || backendAppliedRotations) {
      await _moveOrCopyFile(rawFiles.first.path, finalPath);
    } else {
      await applyQpdfRotations(
        inputPdfPath: rawFiles.first.path,
        outputPdfPath: finalPath,
        oneBasedPageDeltas: desiredRotations,
        cancelToken: cancelToken,
      );
    }

    final displayName = normalSlotsWithFiles.isNotEmpty
        ? normalSlotsWithFiles.first.fileName!
        : (upstreamArtifacts.isNotEmpty ? upstreamArtifacts.first.displayName : 'Reorder.pdf');

    return _UpstreamPdfArtifact(
      filePath: finalPath,
      displayName: displayName,
      pageOrigins: resultOrigins,
    );
  }

  Future<_UpstreamPdfArtifact> _executeMergeStep({
    required PoolSectionData pool,
    required List<_UpstreamPdfArtifact> upstreamArtifacts,
    required String stepDir,
    required Future<int> Function(String path, String name, int? hint) getPageCount,
    required int timeoutSeconds,
    BackendCancellationToken? cancelToken,
  }) async {
    final initialFiles = <Map<String, String>>[];
    final inputIds = <String>[];
    final resultOrigins = <_TrackedPageOrigin>[];
    final desiredRotations = <int, int>{};

    var inputSeq = 0;
    String? firstDisplayName;

    for (final slot in pool.slots) {
      if (slot.isInherited) {
        final inhRefs = slot.resolvedInheritedRefs;
        for (final upstream in upstreamArtifacts) {
          firstDisplayName ??= upstream.displayName;
          final id = 'in_${inputSeq++}';
          initialFiles.add({'id': id, 'path': upstream.filePath});
          inputIds.add(id);

          for (final origin in upstream.pageOrigins) {
            final outPos = resultOrigins.length + 1;
            final desired = _resolveDesiredInheritedRotation(slot, inhRefs, origin);
            final delta = normalizePdfRotation(desired - origin.appliedRotationDeg);
            if (delta != 0) desiredRotations[outPos] = delta;
            resultOrigins.add(origin.copyWith(appliedRotationDeg: desired));
          }
        }
      } else if (slot.hasFile) {
        final filePath = slot.filePath!;
        final fileName = slot.fileName!;
        firstDisplayName ??= fileName;
        final totalPages = await getPageCount(filePath, fileName, slot.pageCount);

        final id = 'in_${inputSeq++}';
        initialFiles.add({'id': id, 'path': filePath});
        inputIds.add(id);

        final sourceKey = '$filePath|$fileName';
        for (int p = 1; p <= totalPages; p++) {
          final outPos = resultOrigins.length + 1;
          final deg = slot.getPageRotation(p);
          if (deg != 0) desiredRotations[outPos] = deg;
          resultOrigins.add(
            _TrackedPageOrigin(
              sourceKey: sourceKey,
              originalPageNumber: p,
              appliedRotationDeg: deg,
            ),
          );
        }
      }
    }

    if (inputIds.isEmpty) {
      throw const BackendException('Merge Pool tidak memiliki file PDF untuk digabungkan.');
    }

    final finalPath = _joinPath(stepDir, 'merge_result.pdf');
    if (inputIds.length == 1) {
      final singlePath = initialFiles.first['path']!;
      if (desiredRotations.isEmpty) {
        await File(singlePath).copy(finalPath);
      } else {
        await applyQpdfRotations(
          inputPdfPath: singlePath,
          outputPdfPath: finalPath,
          oneBasedPageDeltas: desiredRotations,
          cancelToken: cancelToken,
        );
      }
    } else {
      final rawDir = _joinPath(stepDir, 'raw');
      final resp = await _postJson(
        '/pdf-workflow',
        {
          'initialFiles': initialFiles,
          'outputDir': rawDir,
          'steps': [
            {
              'action': 'merge',
              'outputId': 'merge_out',
              'inputIds': inputIds,
              if (desiredRotations.isNotEmpty)
                'rotations': {
                  for (final e in desiredRotations.entries) '${e.key}': e.value,
                },
            },
          ],
        },
        timeoutSeconds: timeoutSeconds,
        cancelToken: cancelToken,
      );

      if (!_isBackendSuccess(resp)) {
        throw BackendException(
          resp['message']?.toString() ?? 'Eksekusi Merge Pool gagal di backend.',
        );
      }

      final rawFiles = _collectOutputFiles(
        (resp['files'] as List<dynamic>? ?? const []).map((e) => e.toString()).toList(),
        rawDir,
        'pdf',
      );
      if (rawFiles.isEmpty) {
        throw const BackendException('Merge Pool tidak menghasilkan file PDF.');
      }

      final backendAppliedRotations = resp['rotations_applied'] == true;
      if (desiredRotations.isEmpty || backendAppliedRotations) {
        await _moveOrCopyFile(rawFiles.first.path, finalPath);
      } else {
        await applyQpdfRotations(
          inputPdfPath: rawFiles.first.path,
          outputPdfPath: finalPath,
          oneBasedPageDeltas: desiredRotations,
          cancelToken: cancelToken,
        );
      }
    }

    return _UpstreamPdfArtifact(
      filePath: finalPath,
      displayName: firstDisplayName ?? 'Merge.pdf',
      pageOrigins: resultOrigins,
    );
  }

  /// Opens a file selection or folder directory in Windows Explorer and brings
  /// the Explorer window to the foreground.
  Future<bool> openInExplorer(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return false;
    if (testOpenInExplorerHandler != null) {
      return testOpenInExplorerHandler!(clean);
    }
    if (isRunningUnderFlutterTest()) return false;
    if (!Platform.isWindows) return false;

    String? resolvedTarget;
    bool resolvedIsFile = false;

    try {
      final candidates = <String>[
        clean,
        if (clean.contains(',')) ...clean.split(',').map((s) => s.trim()),
      ];
      for (final raw in candidates) {
        if (raw.isEmpty) continue;
        final normalized = raw.replaceAll('"', '').trim();
        final type = FileSystemEntity.typeSync(normalized);
        if (type == FileSystemEntityType.file) {
          resolvedTarget = normalized;
          resolvedIsFile = true;
          break;
        }
        if (type == FileSystemEntityType.directory) {
          resolvedTarget = normalized;
          resolvedIsFile = false;
          break;
        }
        Directory probe = File(normalized).parent;
        for (int depth = 0; depth < 8; depth++) {
          if (probe.existsSync()) {
            resolvedTarget = probe.path;
            resolvedIsFile = false;
            break;
          }
          final up = probe.parent;
          if (up.path == probe.path) break;
          probe = up;
        }
        if (resolvedTarget != null) break;
      }

      if (resolvedTarget == null) return false;

      if (await WindowControlService().openInExplorer(resolvedTarget)) {
        return true;
      }

      if (resolvedIsFile) {
        await Process.start('explorer.exe', ['/select,$resolvedTarget']);
        return true;
      }
      await Process.start('explorer.exe', [resolvedTarget]);
      return true;
    } catch (_) {}
    return false;
  }
}
