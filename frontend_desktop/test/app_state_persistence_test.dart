import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/models/pdf_models.dart';
import 'package:frontend/core/services/app_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File tempFile;
  late AppStateService appState;

  setUp(() {
    tempFile = File('${Directory.systemTemp.path}/test_app_state_${DateTime.now().microsecondsSinceEpoch}.json');
    AppStateService.setStorageFileForTesting(tempFile);
    appState = AppStateService();
    appState.resetAll();
  });

  tearDown(() {
    AppStateService.setStorageFileForTesting(null);
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
  });

  test('AppStateService saves and restores state across sessions', () {
    // 1. Navigation State
    appState.setSelectedSidebarIndex(2);
    appState.setSelectedTopTab(1);

    // 2. Engine Config State
    appState.setSelectedEngine(DocEngineType.libreOffice);
    appState.setAutoFallback(false);
    appState.setEngineTimeoutSeconds(60);
    appState.setHighDpiRendering(false);

    // 3. Settings State
    appState.setOutputDirectory(r'D:\TestOutput');
    appState.setSaveLocationMode(SaveLocationMode.autoDefaultFolder);
    appState.setLastSavedDirectory(r'D:\TestOutput\Sub');
    appState.setFileNamingPattern('[original]');
    appState.setOverwriteExisting(true);
    appState.setMaxWorkerThreads(8);
    appState.setEnableGpuAcceleration(false);
    appState.setAutoClearQueue(true);
    appState.setPlayNotificationSound(false);

    // 4. Media Tools State
    appState.setMediaToolsTabIndex(2);
    appState.setConvertOnlyFormat('JPG');
    appState.addConvertOnlyFiles([r'C:\test\sample1.png', r'C:\test\sample2.pdf']);

    appState.setCompressOptions(
      format: 'PNG',
      perPage: 'False',
      type: 'Advanced',
      kb: '500',
    );
    appState.addCompressFiles([r'C:\test\compress1.pdf']);

    appState.setUpscaleOptions(
      format: 'JPG',
      model: 'realesr-animevideov3-x2',
      scale: 2,
    );
    appState.addUpscaleFiles([r'C:\test\upscale1.png']);

    // 5. PDF Manager State
    appState.setPdfViewMode(PdfViewMode.splitPool);
    appState.setActivePdfPool(0, 0);
    final topSlot = appState.pdfPools[0].slots.first;
    topSlot.fileName = 'doc.pdf';
    topSlot.filePath = r'C:\test\doc.pdf';
    topSlot.pageRange = '1-5';
    topSlot.pageCount = 10;
    topSlot.pageRotations[1] = 90;
    topSlot.pageRotations[3] = 180;
    appState.updatePdfInheritedSlots();

    // 6. History and System Logs
    appState.addTaskHistory(
      taskType: 'Convert Only',
      fileName: 'doc.pdf',
      targetFormat: 'DOCX',
      engineUsed: 'Microsoft Word (COM)',
      status: 'Sukses',
      durationMs: 1200,
      originalSize: '1.2 MB',
      resultSize: '450 KB',
      outputPath: r'D:\TestOutput\doc.docx',
    );

    appState.addSystemLog(
      level: 'INFO',
      message: 'Uji persistensi state dimulai',
      source: 'TEST',
    );

    // Save synchronously
    appState.flushSaveSync();

    expect(tempFile.existsSync(), isTrue);

    // Reset all state to defaults
    appState.resetAll();
    expect(appState.selectedSidebarIndex, equals(0));
    expect(appState.selectedTopTab, equals(0));
    expect(appState.selectedEngine, equals(DocEngineType.msWord));
    expect(appState.convertOnlyEntries, isEmpty);
    expect(appState.history, isEmpty);

    // Restore from saved storage
    appState.loadFromStorageSync(storageFile: tempFile);

    // Verify Navigation State
    expect(appState.selectedSidebarIndex, equals(2));
    expect(appState.selectedTopTab, equals(1));

    // Verify Engine Config State
    expect(appState.selectedEngine, equals(DocEngineType.libreOffice));
    expect(appState.autoFallback, isFalse);
    expect(appState.engineTimeoutSeconds, equals(60));
    expect(appState.highDpiRendering, isFalse);

    // Verify Settings State
    expect(appState.outputDirectory, equals(r'D:\TestOutput'));
    expect(appState.saveLocationMode, equals(SaveLocationMode.autoDefaultFolder));
    expect(appState.lastSavedDirectory, equals(r'D:\TestOutput\Sub'));
    expect(appState.fileNamingPattern, equals('[original]'));
    expect(appState.overwriteExisting, isTrue);
    expect(appState.maxWorkerThreads, equals(8));
    expect(appState.enableGpuAcceleration, isFalse);
    expect(appState.autoClearQueue, isTrue);
    expect(appState.playNotificationSound, isFalse);

    // Verify Media Tools State
    expect(appState.mediaToolsTabIndex, equals(2));
    expect(appState.convertOnlyFormat, equals('JPG'));
    expect(appState.convertOnlyEntries.length, equals(2));
    expect(appState.convertOnlyEntries[0].name, equals('sample1.png'));
    expect(appState.convertOnlyEntries[1].name, equals('sample2.pdf'));

    expect(appState.compressFormat, equals('PNG'));
    expect(appState.compressTargetPerPage, equals('False'));
    expect(appState.compressType, equals('Advanced'));
    expect(appState.compressTargetKb, equals('500'));
    expect(appState.compressEntries.length, equals(1));
    expect(appState.compressEntries[0].name, equals('compress1.pdf'));

    expect(appState.upscaleFormat, equals('JPG'));
    expect(appState.upscaleModel, equals('realesr-animevideov3-x2'));
    expect(appState.getScaleForUpscaleModel('realesr-animevideov3-x2'), equals(2));
    expect(appState.upscaleEntries.length, equals(1));
    expect(appState.upscaleEntries[0].name, equals('upscale1.png'));

    // Verify PDF Manager State
    expect(appState.pdfViewMode, equals(PdfViewMode.splitPool));
    expect(appState.activePdfPoolIndex, equals(0));
    expect(appState.pdfPools.isNotEmpty, isTrue);
    final restoredSlot = appState.pdfPools[0].slots.first;
    expect(restoredSlot.fileName, equals('doc.pdf'));
    expect(restoredSlot.filePath, equals(r'C:\test\doc.pdf'));
    expect(restoredSlot.pageRange, equals('1-5'));
    expect(restoredSlot.pageCount, equals(10));
    expect(restoredSlot.pageRotations[1], equals(90));
    expect(restoredSlot.pageRotations[3], equals(180));

    // Verify History and Logs
    expect(appState.history.length, equals(1));
    expect(appState.history[0].fileName, equals('doc.pdf'));
    expect(appState.history[0].targetFormat, equals('DOCX'));
    expect(appState.history[0].status, equals('Sukses'));
    expect(appState.history[0].durationMs, equals(1200));

    expect(appState.systemLogs.any((l) => l.message.contains('Uji persistensi state dimulai')), isTrue);
  });
}
