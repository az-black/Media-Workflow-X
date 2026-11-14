import 'dart:io' show Directory, File, FileSystemException, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/services/app_state_service.dart';
import '../../core/services/backend_service.dart';
import 'app_action_button.dart';
import 'app_toast.dart';

class SaveOutputItem {
  final String sourceFileName;
  final String outputFileName;
  final String taskType;
  final String targetFormat;
  final String engineUsed;
  final String originalSize;
  final String resultSize;
  final int durationMs;
  final String? stagedFilePath;
  final String? sourceGroupName;

  const SaveOutputItem({
    required this.sourceFileName,
    required this.outputFileName,
    required this.taskType,
    required this.targetFormat,
    required this.engineUsed,
    required this.originalSize,
    required this.resultSize,
    required this.durationMs,
    this.stagedFilePath,
    this.sourceGroupName,
  });
}

class SaveDialogResult {
  final String folder;
  final List<String> fileNames;

  const SaveDialogResult({
    required this.folder,
    required this.fileNames,
  });
}

class SaveDestinationHelper {
  static String _resolveUniquePath(
    AppStateService appState,
    String folder,
    String fileName, {
    required bool overwriteExisting,
    Set<String>? reservedPathsLower,
  }) {
    final candidate = appState.joinOutputPath(folder, fileName);
    final candidateKey = candidate.toLowerCase();
    final blockedByExisting = !overwriteExisting && File(candidate).existsSync();
    final blockedByBatch = reservedPathsLower?.contains(candidateKey) ?? false;
    if (!blockedByExisting && !blockedByBatch) {
      reservedPathsLower?.add(candidateKey);
      return candidate;
    }

    final dotIdx = fileName.lastIndexOf('.');
    final stem = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
    final ext = dotIdx > 0 ? fileName.substring(dotIdx) : '';

    var counter = 1;
    while (true) {
      final altName = '${stem}_$counter$ext';
      final altPath = appState.joinOutputPath(folder, altName);
      final altKey = altPath.toLowerCase();
      final altExists = !overwriteExisting && File(altPath).existsSync();
      final altReserved = reservedPathsLower?.contains(altKey) ?? false;
      if (!altExists && !altReserved) {
        reservedPathsLower?.add(altKey);
        return altPath;
      }
      counter++;
    }
  }

  /// Menangani penyimpanan akhir setelah proses selesai pada seluruh fitur aplikasi:
  /// - Jika Settings = [SaveLocationMode.askEveryTime], memunculkan pop-up pemilihan folder simpan
  ///   beserta input edit manual nama file hasil.
  /// - Jika Settings = [SaveLocationMode.autoDefaultFolder], langsung menyimpan ke folder default.
  static Future<String?> handleProcessCompletion(
    BuildContext context, {
    required String taskTitle,
    String? summaryNote,
    required List<SaveOutputItem> outputItems,
    void Function(String savedFolder)? onSaved,
    Future<void> Function()? onCleanupStaging,
  }) async {
    final appState = AppStateService();
    try {
      String? chosenFolder;
      List<String> finalFileNames =
          outputItems.map((e) => e.outputFileName).toList();

      if (appState.askSaveFolderEachTime) {
        if (!context.mounted) return null;
        final SaveDialogResult? dialogResult = await showDialog<SaveDialogResult>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => SaveDestinationDialog(
            taskTitle: taskTitle,
            summaryNote: summaryNote,
            outputItems: outputItems,
          ),
        );

        if (dialogResult == null || dialogResult.folder.trim().isEmpty) {
          appState.addSystemLog(
            level: 'WARN',
            message:
                'Penyimpanan hasil "$taskTitle" dibatalkan sebelum memilih folder.',
            source: 'SYSTEM',
          );
          if (context.mounted) {
            AppToast.showWarning(
              context,
              title: 'Penyimpanan Dibatalkan',
              message: 'Penyimpanan hasil dibatalkan oleh pengguna.',
              duration: const Duration(seconds: 2),
            );
          }
          return null;
        }
        chosenFolder = dialogResult.folder;
        if (dialogResult.fileNames.length == outputItems.length) {
          finalFileNames = dialogResult.fileNames;
        }
      } else {
        chosenFolder = appState.outputDirectory;
      }

      final cleanFolder = chosenFolder.trim();
      final hasStagedFiles = outputItems.any(
        (item) =>
            item.stagedFilePath != null &&
            item.stagedFilePath!.trim().isNotEmpty,
      );

      if (hasStagedFiles) {
        try {
          await Directory(cleanFolder).create(recursive: true);
        } catch (e) {
          final msg =
              'Gagal menyiapkan folder penyimpanan "$cleanFolder": $e';
          appState.addSystemLog(level: 'ERROR', message: msg, source: 'SYSTEM');
          if (context.mounted) {
            AppToast.showError(
              context,
              title: 'Gagal Menyiapkan Folder',
              message: msg,
              duration: const Duration(seconds: 4),
            );
          }
          return null;
        }
      }

      appState.setLastSavedDirectory(cleanFolder);

      final stageRefCounts = <String, int>{};
      for (final item in outputItems) {
        final stagedPath = item.stagedFilePath?.trim();
        if (stagedPath != null && stagedPath.isNotEmpty) {
          final normKey = File(stagedPath).absolute.path.toLowerCase();
          stageRefCounts[normKey] = (stageRefCounts[normKey] ?? 0) + 1;
        }
      }

      final reservedPathsLower = <String>{};
      final plans = <({
        SaveOutputItem item,
        String requestedName,
        String fullPath,
        String resolvedName,
        String? stagedPath,
        bool canMove,
      })>[];
      final resolvedResultSizes = <String>[
        for (final item in outputItems) item.resultSize,
      ];

      for (int i = 0; i < outputItems.length; i++) {
        final item = outputItems[i];
        final requestedName = finalFileNames[i];
        final stagedPath = item.stagedFilePath?.trim();
        String fullPath = appState.joinOutputPath(cleanFolder, requestedName);
        String resolvedName = requestedName;
        bool canMove = false;

        if (stagedPath != null && stagedPath.isNotEmpty) {
          fullPath = _resolveUniquePath(
            appState,
            cleanFolder,
            requestedName,
            overwriteExisting: appState.overwriteExisting,
            reservedPathsLower: reservedPathsLower,
          );
          resolvedName = BackendService.fileNameFromPath(fullPath);
          final stageKey = File(stagedPath).absolute.path.toLowerCase();
          canMove =
              onCleanupStaging != null && (stageRefCounts[stageKey] ?? 0) == 1;
        }

        plans.add((
          item: item,
          requestedName: requestedName,
          fullPath: fullPath,
          resolvedName: resolvedName,
          stagedPath: stagedPath,
          canMove: canMove,
        ));
      }

      final hasFilesToTransfer = plans.any(
        (p) => p.stagedPath != null && p.stagedPath!.isNotEmpty,
      );
      if (hasFilesToTransfer) {
        final maxConcurrent = plans.length < 8 ? plans.length : 8;
        int nextIdx = 0;
        String? firstError;

        Future<void> runSaveWorker() async {
          while (true) {
            if (firstError != null) return;
            final i = nextIdx++;
            if (i >= plans.length) return;
            final plan = plans[i];
            final stagedPath = plan.stagedPath;
            if (stagedPath == null || stagedPath.isEmpty) continue;

            try {
              final srcFile = File(stagedPath);
              if (!await srcFile.exists()) {
                throw Exception('File sementara tidak ditemukan: $stagedPath');
              }

              final dstFile = File(plan.fullPath);
              if (srcFile.absolute.path.toLowerCase() !=
                  dstFile.absolute.path.toLowerCase()) {
                if (plan.canMove) {
                  if (await dstFile.exists()) {
                    await dstFile.delete();
                  }
                  try {
                    final moved = await srcFile.rename(plan.fullPath);
                    resolvedResultSizes[i] =
                        BackendService.formatBytes(await moved.length());
                    continue;
                  } on FileSystemException {
                    // Jatuh kembali ke copy jika berbeda drive/volume
                  }
                }
                final copied = await srcFile.copy(plan.fullPath);
                resolvedResultSizes[i] =
                    BackendService.formatBytes(await copied.length());
              }
            } catch (e) {
              firstError ??= 'Gagal menyimpan file "${plan.requestedName}": $e';
              return;
            }
          }
        }

        await Future.wait(
          List<Future<void>>.generate(maxConcurrent, (_) => runSaveWorker()),
        );

        if (firstError != null) {
          appState.addSystemLog(
            level: 'ERROR',
            message: firstError!,
            source: 'SYSTEM',
          );
          if (context.mounted) {
            AppToast.showError(
              context,
              title: 'Gagal Menyimpan File',
              message: firstError!,
              duration: const Duration(seconds: 4),
            );
          }
          return null;
        }
      }

      for (int i = 0; i < plans.length; i++) {
        final plan = plans[i];
        appState.addTaskHistory(
          taskType: plan.item.taskType,
          fileName: plan.resolvedName,
          targetFormat: plan.item.targetFormat,
          engineUsed: plan.item.engineUsed,
          status: 'Sukses',
          durationMs: plan.item.durationMs,
          originalSize: plan.item.originalSize,
          resultSize: resolvedResultSizes[i],
          outputPath: plan.fullPath,
        );
      }

      appState.addSystemLog(
        level: 'SUCCESS',
        message:
            '${outputItems.length} file hasil "$taskTitle" disimpan ke folder: $cleanFolder',
        source: 'SYSTEM',
      );

      onSaved?.call(cleanFolder);
      return cleanFolder;
    } finally {
      if (onCleanupStaging != null) {
        try {
          await onCleanupStaging();
        } catch (_) {}
      }
    }
  }
}

class SaveDestinationDialog extends StatefulWidget {
  final String taskTitle;
  final String? summaryNote;
  final List<SaveOutputItem> outputItems;

  const SaveDestinationDialog({
    super.key,
    required this.taskTitle,
    this.summaryNote,
    required this.outputItems,
  });

  @override
  State<SaveDestinationDialog> createState() => _SaveDestinationDialogState();
}

class _SaveDestinationDialogState extends State<SaveDestinationDialog> {
  static final RegExp _invalidFileNameChars = RegExp(r'[<>:"/\\|?*]');
  static final RegExp _extensionPattern = RegExp(r'\.[a-zA-Z][a-zA-Z0-9]{0,7}$');

  final AppStateService _appState = AppStateService();
  late final TextEditingController _folderController;
  late final List<TextEditingController> _fileNameControllers;
  bool _setAsDefaultFolder = false;
  bool _isBrowsing = false;
  String? _errorText;
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      final newOffset = _dragOffset + details.delta;
      final size = MediaQuery.maybeOf(context)?.size;
      if (size != null && size.width > 0 && size.height > 0) {
        final maxDx = (size.width / 2) - 80;
        final minDx = -maxDx;
        final maxDy = (size.height / 2) - 60;
        final minDy = -((size.height / 2) - 40);
        _dragOffset = Offset(
          newOffset.dx.clamp(minDx, maxDx),
          newOffset.dy.clamp(minDy, maxDy),
        );
      } else {
        _dragOffset = newOffset;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _folderController = TextEditingController(text: _appState.outputDirectory);
    _fileNameControllers = widget.outputItems
        .map((item) => TextEditingController(text: item.outputFileName))
        .toList();
  }

  @override
  void dispose() {
    _folderController.dispose();
    for (final ctrl in _fileNameControllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  String _getUserHomeDir() {
    if (!kIsWeb) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) return userProfile;
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) return home;
    }
    return r'C:\Users\ACER';
  }

  Future<void> _browseFolder() async {
    if (_isBrowsing) return;
    setState(() {
      _isBrowsing = true;
      _errorText = null;
    });

    try {
      final currentPath = _folderController.text.trim();
      final String? selectedDir = await getDirectoryPath(
        initialDirectory: currentPath.isNotEmpty ? currentPath : null,
        confirmButtonText: 'Pilih Folder Simpan',
      );
      if (selectedDir != null && selectedDir.trim().isNotEmpty && mounted) {
        setState(() {
          _folderController.text = selectedDir.trim();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorText =
              'Pemilih folder sistem tidak tersedia, silakan ketik/pilih jalur di bawah.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isBrowsing = false);
      }
    }
  }

  String _normalizeOutputFileName(String rawName, String targetFormat) {
    final trimmed = rawName.trim().replaceAll(RegExp(r'[.\s]+$'), '');
    if (_extensionPattern.hasMatch(trimmed)) {
      return trimmed;
    }
    final cleanExt = targetFormat.trim().toLowerCase().replaceAll('.', '');
    if (cleanExt.isEmpty) return trimmed;
    return '$trimmed.$cleanExt';
  }

  void _confirmSave() {
    final chosen = _folderController.text.trim();
    if (chosen.isEmpty) {
      setState(() {
        _errorText = 'Silakan tentukan folder tujuan penyimpanan terlebih dahulu.';
      });
      return;
    }

    final normalizedNames = <String>[];
    for (int i = 0; i < _fileNameControllers.length; i++) {
      final rawName = _fileNameControllers[i].text.trim();
      if (rawName.isEmpty) {
        setState(() {
          _errorText = 'Nama file #${i + 1} tidak boleh kosong.';
        });
        return;
      }
      if (_invalidFileNameChars.hasMatch(rawName)) {
        setState(() {
          _errorText =
              'Nama file #${i + 1} mengandung karakter tidak valid (< > : " / \\ | ? *).';
        });
        return;
      }
      final cleanedBase = rawName.replaceAll(RegExp(r'[.\s]+$'), '');
      if (cleanedBase.isEmpty) {
        setState(() {
          _errorText = 'Nama file #${i + 1} tidak valid.';
        });
        return;
      }
      normalizedNames.add(
        _normalizeOutputFileName(
          rawName,
          widget.outputItems[i].targetFormat,
        ),
      );
    }

    if (_setAsDefaultFolder) {
      _appState.setOutputDirectory(chosen);
    }

    Navigator.of(context).pop(
      SaveDialogResult(
        folder: chosen,
        fileNames: normalizedNames,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final homeDir = _getUserHomeDir();
    final sep = homeDir.contains('/') && !homeDir.contains('\\') ? '/' : '\\';
    final downloadsDir = '$homeDir${sep}Downloads';
    final documentsDir = '$homeDir${sep}Documents';
    final desktopDir = '$homeDir${sep}Desktop';
    final lastUsed = _appState.lastSavedDirectory;

    return Transform.translate(
      key: const Key('save_destination_dialog_transform'),
      offset: _dragOffset,
      child: AlertDialog(
        backgroundColor: AppColors.cardBackground,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: _isDragging
                ? AppColors.primaryCyan
                : AppColors.primaryCyan.withValues(alpha: 0.85),
            width: _isDragging ? 2.4 : 1.8,
          ),
        ),
        title: MouseRegion(
          cursor: _isDragging
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () => setState(() => _dragOffset = Offset.zero),
            onPanStart: (_) => setState(() => _isDragging = true),
            onPanUpdate: _onPanUpdate,
            onPanEnd: (_) => setState(() => _isDragging = false),
            onPanCancel: () => setState(() => _isDragging = false),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E676).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFF00E676),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Proses Selesai — Pilih Folder Simpan',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.taskTitle,
                        style: const TextStyle(
                          color: AppColors.primaryCyan,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message:
                      'Tahan dan geser untuk memindahkan posisi dialog\n(Klik dua kali untuk kembalikan ke tengah)',
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: _isDragging
                          ? AppColors.primaryCyan.withValues(alpha: 0.25)
                          : Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _isDragging
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
                          size: 16,
                          color: _isDragging
                              ? AppColors.primaryCyan
                              : AppColors.primaryCyan.withValues(alpha: 0.85),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          'Geser',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                            color: _isDragging
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
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.summaryNote != null &&
                  widget.summaryNote!.trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    widget.summaryNote!,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Output Files List (Editable filenames)
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.inventory_2_outlined,
                          color: AppColors.primaryCyan,
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'File Hasil Siap Disimpan (${widget.outputItems.length}):',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.edit_note_rounded,
                          color: AppColors.primaryCyan,
                          size: 14,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Klik nama file untuk edit manual',
                          style: TextStyle(
                            color: AppColors.primaryCyan,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              _buildOutputFilesListBox(),
              const SizedBox(height: 14),

              // Destination Picker Section
              Row(
                children: const [
                  Icon(
                    Icons.folder_open_rounded,
                    color: AppColors.primaryCyan,
                    size: 16,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Mau disimpan di folder mana?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: AppColors.primaryCyan.withValues(alpha: 0.6),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: TextField(
                        key: const Key('save_folder_path_field'),
                        controller: _folderController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: r'Masukkan atau pilih folder simpan...',
                          hintStyle: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                          prefixIcon: Icon(
                            Icons.folder_outlined,
                            color: AppColors.primaryCyan,
                            size: 16,
                          ),
                          prefixIconConstraints: BoxConstraints(minWidth: 28),
                        ),
                        onChanged: (_) {
                          if (_errorText != null) {
                            setState(() => _errorText = null);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppActionButton(
                    label: _isBrowsing ? 'Membuka...' : 'Pilih Folder...',
                    icon: Icons.drive_file_move_outlined,
                    isPrimary: false,
                    minWidth: 120,
                    onPressed: _isBrowsing ? null : _browseFolder,
                  ),
                ],
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  _errorText!,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 10.5,
                  ),
                ),
              ],
              const SizedBox(height: 8),

              // Quick Folder Chips
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildQuickChip('Folder Default', _appState.outputDirectory),
                  if (lastUsed != null &&
                      lastUsed.isNotEmpty &&
                      lastUsed != _appState.outputDirectory)
                    _buildQuickChip('Terakhir Dipakai', lastUsed),
                  _buildQuickChip('Downloads', downloadsDir),
                  _buildQuickChip('Documents', documentsDir),
                  _buildQuickChip('Desktop', desktopDir),
                ],
              ),
              const SizedBox(height: 8),

              // Remember as Default Checkbox
              Material(
                color: Colors.transparent,
                child: CheckboxListTile(
                  value: _setAsDefaultFolder,
                  onChanged: (val) {
                    setState(() => _setAsDefaultFolder = val ?? false);
                  },
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: AppColors.primaryCyan,
                  checkColor: Colors.black,
                  title: const Text(
                    'Jadikan folder terpilih sebagai Folder Default di Settings',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        SizedBox(
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              MouseRegion(
                cursor: _isDragging
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => setState(() => _isDragging = true),
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: (_) => setState(() => _isDragging = false),
                  onPanCancel: () => setState(() => _isDragging = false),
                  onDoubleTap: () => setState(() => _dragOffset = Offset.zero),
                  child: Tooltip(
                    message:
                        'Tahan dan geser untuk memindahkan posisi dialog\n(Klik dua kali untuk kembalikan ke tengah)',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.open_with_rounded,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.4),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'Drag untuk geser',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: Colors.white.withValues(alpha: 0.4),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppActionButton(
                    label: 'Batal',
                    icon: Icons.close_rounded,
                    isPrimary: false,
                    minWidth: 100,
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryCyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(19),
                      ),
                    ),
                    onPressed: _confirmSave,
                    icon: const Icon(Icons.save_alt_rounded, size: 17),
                    label: const Text(
                      'Simpan di Folder Ini',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

  Widget _buildOutputFilesListBox() {
    final hasGroupedItems = widget.outputItems.any(
      (item) =>
          item.sourceGroupName != null &&
          item.sourceGroupName!.trim().isNotEmpty,
    );

    if (!hasGroupedItems) {
      return Container(
        constraints: const BoxConstraints(maxHeight: 165),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: widget.outputItems.length,
          separatorBuilder: (_, _) =>
              const Divider(color: Colors.white10, height: 8),
          itemBuilder: (context, idx) => _buildOutputItemRow(idx),
        ),
      );
    }

    final grouped = <String, ({String label, List<int> indices})>{};
    for (int i = 0; i < widget.outputItems.length; i++) {
      final rawGroup = widget.outputItems[i].sourceGroupName?.trim() ?? '';
      final label = rawGroup.isNotEmpty ? rawGroup : 'File Lainnya';
      final key = rawGroup.isNotEmpty ? rawGroup.toLowerCase() : '__other__';
      final bucket = grouped.putIfAbsent(
        key,
        () => (label: label, indices: <int>[]),
      );
      bucket.indices.add(i);
    }

    final entries = <({
      bool isHeader,
      String groupLabel,
      int groupCount,
      int groupIndex,
      int itemIndex,
      bool showDividerBefore,
    })>[];
    int groupIdx = 0;
    for (final group in grouped.values) {
      entries.add((
        isHeader: true,
        groupLabel: group.label,
        groupCount: group.indices.length,
        groupIndex: groupIdx,
        itemIndex: -1,
        showDividerBefore: false,
      ));
      for (int pos = 0; pos < group.indices.length; pos++) {
        entries.add((
          isHeader: false,
          groupLabel: group.label,
          groupCount: group.indices.length,
          groupIndex: groupIdx,
          itemIndex: group.indices[pos],
          showDividerBefore: pos > 0,
        ));
      }
      groupIdx++;
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 215),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: entries.length,
        itemBuilder: (context, rowIdx) {
          final entry = entries[rowIdx];
          if (entry.isHeader) {
            return Container(
              key: Key('save_file_group_header_${entry.groupIndex}'),
              margin: EdgeInsets.only(
                top: entry.groupIndex == 0 ? 0 : 8,
                bottom: 5,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primaryCyan.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: AppColors.primaryCyan.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.picture_as_pdf_rounded,
                    color: AppColors.primaryCyan,
                    size: 13,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.groupLabel,
                      style: const TextStyle(
                        color: AppColors.primaryCyan,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${entry.groupCount} file',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.showDividerBefore)
                const Divider(color: Colors.white10, height: 8),
              _buildOutputItemRow(entry.itemIndex),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOutputItemRow(int idx) {
    final item = widget.outputItems[idx];
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: AppColors.primaryCyan.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            item.targetFormat.toUpperCase(),
            style: const TextStyle(
              color: AppColors.primaryCyan,
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: AppColors.primaryCyan.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('save_file_name_field_$idx'),
                    controller: _fileNameControllers[idx],
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText:
                          'Nama file output (.${item.targetFormat.toLowerCase()})',
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                    onChanged: (_) {
                      if (_errorText != null) {
                        setState(() => _errorText = null);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Edit manual nama file hasil',
                  child: Icon(
                    Icons.edit_outlined,
                    color: AppColors.primaryCyan.withValues(alpha: 0.85),
                    size: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          item.resultSize,
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 10.5,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickChip(String label, String path) {
    final isSelected = _folderController.text.trim() == path;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _folderController.text = path;
            _errorText = null;
          });
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryCyan.withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? AppColors.primaryCyan : Colors.white12,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.folder_copy_outlined,
                size: 12,
                color: isSelected ? AppColors.primaryCyan : Colors.white54,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppColors.primaryCyan : Colors.white70,
                  fontSize: 10,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
