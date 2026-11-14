import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/services/app_state_service.dart';
import 'package:frontend/core/services/backend_service.dart';
import 'package:frontend/core/services/pdf_inspector_service.dart';
import 'package:frontend/core/services/pdf_render_service.dart';
import 'package:frontend/core/services/window_control_service.dart';
import 'package:frontend/features/media_tools/presentation/widgets/convert_only_view.dart';
import 'package:frontend/features/pdf_manager/presentation/widgets/pdf_card_components.dart';
import 'package:frontend/features/pdf_manager/presentation/widgets/pdf_manager_view.dart';
import 'package:frontend/features/pdf_manager/presentation/widgets/pdf_preview_components.dart';
import 'package:frontend/features/pdf_manager/presentation/widgets/split_pool_view.dart';
import 'package:frontend/main.dart';
import 'package:frontend/shared/widgets/app_brand_logo.dart';
import 'package:frontend/shared/widgets/app_toast.dart';
import 'package:frontend/shared/widgets/status_progress_bar.dart';
import 'package:frontend/shared/widgets/window_title_bar.dart';

Future<ui.Image> _createTestRenderedImage(
  int width,
  int height,
  Color fillColor,
) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = fillColor,
  );
  final picture = recorder.endRecording();
  return picture.toImage(width, height);
}

Uint8List _buildSyntheticPdfBytes(
  int pageCount, {
  bool compressedObjStm = false,
}) {
  if (!compressedObjStm) {
    final kids = List<String>.generate(pageCount, (i) => '${i + 3} 0 R').join(' ');
    final buf = StringBuffer()
      ..writeln('%PDF-1.4')
      ..writeln('1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj')
      ..writeln(
        '2 0 obj << /Type /Pages /Count $pageCount /MediaBox [0 0 595 842] /Kids [ $kids ] >> endobj',
      );
    for (int i = 0; i < pageCount; i++) {
      buf.writeln('${i + 3} 0 obj << /Type /Page /Parent 2 0 R >> endobj');
    }
    buf.writeln('%%EOF');
    return Uint8List.fromList(latin1.encode(buf.toString()));
  }

  final innerObjs = <int, String>{
    1: '<< /Type /Catalog /Pages 2 0 R >>',
    2: '<< /Type /Pages /Count $pageCount /MediaBox [0 0 595 842] /Kids [ ${List<String>.generate(pageCount, (i) => '${i + 3} 0 R').join(' ')} ] >>',
  };
  for (int i = 0; i < pageCount; i++) {
    innerObjs[i + 3] = '<< /Type /Page /Parent 2 0 R >>';
  }

  final header = StringBuffer();
  final body = StringBuffer();
  int currentOffset = 0;
  for (final entry in innerObjs.entries) {
    header.write('${entry.key} $currentOffset ');
    final objStr = '${entry.value}\n';
    body.write(objStr);
    currentOffset += objStr.length;
  }

  final headerBytes = latin1.encode(header.toString());
  final bodyBytes = latin1.encode(body.toString());
  final rawObjStm = Uint8List.fromList([...headerBytes, ...bodyBytes]);
  final compressed = zlib.encode(rawObjStm);

  final prefix = latin1.encode(
    '%PDF-1.5\n'
    '10 0 obj << /Type /ObjStm /N ${innerObjs.length} /First ${headerBytes.length} '
    '/Length ${compressed.length} /Filter /FlateDecode >>\nstream\n',
  );
  final suffix = latin1.encode('\nendstream\nendobj\n%%EOF\n');
  return Uint8List.fromList([...prefix, ...compressed, ...suffix]);
}

void main() {
  setUp(() {
    AppStateService().resetAll();
    BackendService().resetTestOverrides();
    PdfInspectorService().clearCache();
    PdfRenderService().clearTestOverrides();
    PdfRenderService().clearAllCaches();

    BackendService().testPingHandler = () async => 4;
    BackendService().testCompressHandler = (req) async {
      final suffix = req.action == 'convert_only'
          ? 'converted'
          : (req.action == 'convert_compress' ? 'compressed' : 'upscaled');
      final suggested = AppStateService().buildOutputFileName(
        req.fileName,
        req.targetFormat.toUpperCase(),
        customSuffix: suffix,
      );
      return BackendStagedFile(
        sourceFileName: req.fileName,
        stagedFilePath: '',
        suggestedFileName: suggested,
        originalBytes: 2048,
        resultBytes: 1024,
        durationMs: 120,
        engineUsed: req.action == 'upscale_ai'
            ? (req.model ?? 'Real-ESRGAN AI')
            : req.engine,
        targetFormat: req.targetFormat.toUpperCase(),
      );
    };
    BackendService().testWorkflowHandler = (req) async {
      String primarySourceName = 'Dokumen.pdf';
      for (final pool in req.pools) {
        for (final slot in pool.slots) {
          if (!slot.isInherited &&
              slot.fileName != null &&
              slot.fileName!.trim().isNotEmpty) {
            primarySourceName = slot.fileName!.trim();
            break;
          }
          if (slot.isInherited && slot.resolvedInheritedRefs.isNotEmpty) {
            primarySourceName = slot.resolvedInheritedRefs.first.fileName;
            break;
          }
        }
        if (primarySourceName != 'Dokumen.pdf') break;
      }
      final suggested = AppStateService().buildOutputFileName(
        primarySourceName,
        'PDF',
        customSuffix: req.outputSuffix,
      );
      return BackendBatchResult(
        files: [
          BackendStagedFile(
            sourceFileName: primarySourceName,
            stagedFilePath: '',
            suggestedFileName: suggested,
            originalBytes: 4096,
            resultBytes: 3072,
            durationMs: 180,
            engineUsed: 'Go Workflow Engine',
            targetFormat: 'PDF',
          ),
        ],
      );
    };
  });

  tearDown(() {
    BackendService().resetTestOverrides();
  });
  testWidgets('App renders correctly and tests PDF Manager workflow without entering range/pages',
      (WidgetTester tester) async {
    // Set a typical desktop window size
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Verify Main Components
    expect(find.text('Pusat Eksekusi Mesin'), findsOneWidget);
    expect(find.text('Media Tools'), findsOneWidget);
    expect(find.text('PDF Manager'), findsOneWidget);
    expect(find.text('Convert Only'), findsOneWidget);
    expect(find.text('Compress & Convert'), findsOneWidget);
    expect(find.text('Upscale AI'), findsOneWidget);

    // 2. Switch to 'Compress & Convert' in Media Tools
    await tester.tap(find.text('Compress & Convert'));
    await tester.pumpAndSettle();
    expect(find.text('Target KB'), findsOneWidget);

    // 3. Switch to 'Upscale AI' in Media Tools
    await tester.tap(find.text('Upscale AI'));
    await tester.pumpAndSettle();
    expect(find.text('Model AI'), findsOneWidget);

    // 4. Switch to PDF Manager
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // Overview screen shows single initial pool with exactly 1 plus box
    expect(find.text('Split Pool'), findsOneWidget);
    expect(find.text('Number Split'), findsOneWidget);
    expect(find.text('Split Pool File'), findsNothing);

    // Verify Kotak 1 cannot be deleted when it is the only slot
    final initialCardGesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await initialCardGesture.addPointer(location: Offset.zero);
    await initialCardGesture.moveTo(tester.getCenter(find.text('File').first));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hapus kotak ini'), findsNothing);
    await initialCardGesture.removePointer();
    await tester.pumpAndSettle();

    // 5. Verify that clicking Pool header opens dropdown menu and does NOT navigate to Range/Pages
    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    // Range and Pages buttons from SplitPoolView should NOT exist
    expect(find.text('Range'), findsNothing);
    expect(find.text('Pages to Split'), findsNothing);

    // Dismiss the popup menu
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 6. Test adding a new slot by tapping the '+' card on the far right of Split Pool
    final initialCount = find.text('Number Split').evaluate().length;

    await tester.tap(find.byTooltip('Tambah slot baru').first);
    await tester.pumpAndSettle();

    // The count of 'Number Split' cards should have increased by 1
    final newCount = find.text('Number Split').evaluate().length;
    expect(newCount, equals(initialCount + 1));

    // 7. Verify Action Buttons exist
    expect(find.text('Mulai Proses'), findsOneWidget);
    expect(find.text('Batal'), findsOneWidget);

    // 8. Test Dynamic Horizontal Scroll: Add slots so total cards exceed the viewport width
    for (int i = 0; i < 11; i++) {
      await tester.tap(find.byTooltip('Tambah slot baru').first, warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    // Now cards row is scrollable and dynamic right arrow appears!
    expect(find.byTooltip('Geser ke kanan'), findsOneWidget);
    await tester.tap(find.byTooltip('Geser ke kanan'));
    await tester.pumpAndSettle();
    // Now left scroll arrow is also illuminated
    expect(find.byTooltip('Geser ke kiri'), findsOneWidget);
    await tester.tap(find.byTooltip('Geser ke kiri'));
    await tester.pumpAndSettle();

    // Test dragging the indicator line directly (geser garis di bawah kotak)
    final indicatorFinder = find.byTooltip('Geser garis ini untuk menggulir file pool');
    expect(indicatorFinder, findsOneWidget);
    await tester.drag(indicatorFinder, const Offset(80, 0));
    await tester.pumpAndSettle();
    await tester.drag(indicatorFinder, const Offset(-80, 0));
    await tester.pumpAndSettle();

    // Dismiss any active SnackBar before testing navigation
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Test deleting a slot box ("kotak plus") via hover (X) button on card 2
    final countBeforeDelete = find.text('Number Split').evaluate().length;
    final cardGesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await cardGesture.addPointer(location: Offset.zero);
    await cardGesture.moveTo(tester.getCenter(find.text('File').at(1)));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Hapus kotak ini'), findsWidgets);
    await tester.tap(find.byTooltip('Hapus kotak ini').first);
    await cardGesture.removePointer();
    await tester.pumpAndSettle();

    final countAfterDelete = find.text('Number Split').evaluate().length;
    expect(countAfterDelete, equals(countBeforeDelete - 1));

    // Clear SnackBar
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 9. Test Navigation into Pages/Range by clicking the label box below the plus box ('Number Split')
    await tester.tap(find.text('Number Split').first);
    await tester.pumpAndSettle();

    // Verify we entered SplitPoolView (Range mode)
    expect(find.text('Range'), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('Split Number 1'), findsOneWidget);
    expect(find.text('Pages to Split'), findsWidgets);
    expect(find.text('+ Add Split Number'), findsOneWidget);
    expect(find.text('Split PDF'), findsOneWidget);
    expect(find.text('Go to Pool'), findsOneWidget);

    // Test returning back to overview by clicking 'Go to Pool'
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();
    expect(find.text('Mulai Proses'), findsOneWidget);

    // 10. Add a new target pool dynamically via DashedContainer (+)
    await tester.tap(find.byTooltip('Tambah Target Pool Baru'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Now Reorder Pool is added, and it inherits 'Split Pool File' from the top pool!
    expect(find.text('Reorder Pool'), findsOneWidget);
    expect(find.text('Split Pool File'), findsOneWidget);

    // Test Navigation into Reorder Pool by clicking 'Order Number'
    await tester.tap(find.text('Order Number').first);
    await tester.pumpAndSettle();

    // Verify we entered ReorderPoolView
    expect(find.text('Order Number 1'), findsOneWidget);
    expect(find.text('Pages to Reorder'), findsWidgets);
    expect(find.text('+ Add Order Number'), findsOneWidget);
    expect(find.text('Reorder PDF'), findsOneWidget);
    expect(find.text('Go to Pool'), findsOneWidget);

    // Return back to overview
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();
    expect(find.text('Mulai Proses'), findsOneWidget);

    // 11. Test Top Pool Inheritance: Deleting top pool makes the new top pool lose inherited slot
    // Delete Pool 0 (Split Pool)
    await tester.tap(find.byTooltip('Hapus Pool Ini').first);
    await tester.pumpAndSettle();

    // The new top pool is Reorder Pool. Its inherited slot '+ File (Pool Atas)' / 'Split Pool File' must be GONE!
    expect(find.text('Split Pool File'), findsNothing);
    expect(find.text('(Pool Atas)'), findsNothing);
  });

  testWidgets('Test Merge Pool and Split Separate Pool navigation and view switching',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // Switch to PDF Manager
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // Add a new target pool so we have Reorder Pool
    await tester.tap(find.byTooltip('Tambah Target Pool Baru'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Add another target pool so we have Merge Pool
    await tester.tap(find.byTooltip('Tambah Target Pool Baru'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Tap 'Merge Number' label under plus box in Merge Pool
    await tester.tap(find.text('Merge Number').first);
    await tester.pumpAndSettle();

    // Verify we entered MergePoolView
    expect(find.text('Merge PDF'), findsOneWidget);
    expect(find.text('Merge File 1'), findsOneWidget);
    expect(find.text('File to Merge'), findsWidgets);
    expect(find.text('+ Add Merge Number'), findsOneWidget);
    expect(find.text('Go to Pool'), findsOneWidget);

    // Switch detail view to 'Split Separate Pool' via header dropdown
    await tester.tap(find.text('Merge Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split Separate Pool').last);
    await tester.pumpAndSettle();

    // Verify it switched to Split Separate Pool in Pages mode
    expect(find.text('Split Separate Pool'), findsOneWidget);
    expect(find.text('Split Number 1'), findsOneWidget);
    expect(find.text('+ Add Split Number'), findsOneWidget);

    // Return to overview
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();
    expect(find.text('Mulai Proses'), findsOneWidget);
  });

  testWidgets('Test Real-time Slot Synchronization between inputs, slot cards, and Go to Pool',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Switch to PDF Manager
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // 2. Tap 'Number Split' to enter Split Pool
    await tester.tap(find.text('Number Split').first);
    await tester.pumpAndSettle();

    expect(find.text('Split Number 1'), findsOneWidget);

    // 3. Type "1, 2, 3" into Split Number 1
    final firstInput = find.byType(TextField).first;
    await tester.enterText(firstInput, '1, 2, 3');
    await tester.pumpAndSettle();

    // Verify slot card above immediately gets "Split 1, 2, 3" and "Hal 1, 2, 3"
    expect(find.text('Split 1, 2, 3'), findsWidgets);
    expect(find.text('Hal 1, 2, 3'), findsWidgets);

    // 4. Tap '+ Add Split Number' to add a second slot
    await tester.tap(find.text('+ Add Split Number'));
    await tester.pumpAndSettle();

    expect(find.text('Split Number 2'), findsOneWidget);

    // 5. Type "9, 10, 12" into Split Number 2
    final secondInput = find.byType(TextField).at(1);
    await tester.enterText(secondInput, '9, 10, 12');
    await tester.pumpAndSettle();

    expect(find.text('Split 9, 10, 12'), findsWidgets);
    expect(find.text('Hal 9, 10, 12'), findsWidgets);

    // 6. Tap 'Go to Pool' to return to overview
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();

    // Verify overview has preserved the slots, labels, and sublabels
    expect(find.text('Mulai Proses'), findsOneWidget);
    expect(find.text('Split 1, 2, 3'), findsOneWidget);
    expect(find.text('Hal 1, 2, 3'), findsOneWidget);
    expect(find.text('Split 9, 10, 12'), findsOneWidget);
    expect(find.text('Hal 9, 10, 12'), findsOneWidget);
  });

  testWidgets('Test Engine Config, Logs & History, and Settings navigation and functions',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Verify Convert Only shows Engine indicator pill
    expect(find.textContaining('Engine Dokumen:'), findsOneWidget);

    // 2. Navigate to Engine Config from Sidebar
    await tester.tap(find.text('Engine Config'));
    await tester.pumpAndSettle();

    expect(find.text('Konfigurasi Engine Dokumen & PDF'), findsOneWidget);
    expect(find.text('Pilih Engine Dokumen Utama'), findsOneWidget);
    expect(find.text('Microsoft Word (MS Word)'), findsOneWidget);
    expect(find.text('LibreOffice (Libre)'), findsOneWidget);

    // Tap LibreOffice card to select it
    await tester.tap(find.text('LibreOffice (Libre)'));
    await tester.pumpAndSettle();

    // Test connection button
    await tester.tap(find.text('Uji Koneksi'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Test "No Time" option in Batas Waktu Eksekusi (Timeout)
    await tester.ensureVisible(find.text('Batas Waktu Eksekusi (Timeout)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('45 Detik'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No Time').last);
    await tester.pumpAndSettle();
    expect(AppStateService().engineTimeoutSeconds, equals(0));
    expect(AppStateService().hasNoEngineTimeout, isTrue);
    expect(AppStateService().engineTimeoutLabel, equals('No Time'));
    expect(find.textContaining('No Time'), findsWidgets);

    // 3. Navigate to Logs & History
    await tester.tap(find.text('Logs & History'));
    await tester.pumpAndSettle();

    expect(find.text('Logs & Riwayat Eksekusi'), findsOneWidget);
    expect(find.textContaining('Riwayat Tugas'), findsOneWidget);
    expect(find.textContaining('Konsol Log Sistem'), findsOneWidget);

    // Switch to System Console
    await tester.tap(find.textContaining('Konsol Log Sistem'));
    await tester.pumpAndSettle();
    expect(find.text('LIVE SYSTEM LOGS (TERMINAL)'), findsOneWidget);

    // 4. Navigate to Settings
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Pengaturan Sistem & Preferensi'), findsOneWidget);
    expect(find.text('Folder Penyimpanan & Hasil Konversi'), findsOneWidget);
    expect(find.text('Reset ke Default'), findsOneWidget);
    expect(find.text('Simpan Pengaturan'), findsOneWidget);

    // Scroll to and tap Simpan Pengaturan
    await tester.ensureVisible(find.text('Simpan Pengaturan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simpan Pengaturan'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Seluruh konfigurasi sistem berhasil disimpan!'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 5. Navigate back to Dashboard
    await tester.tap(find.text('Dasboard'));
    await tester.pumpAndSettle();

    expect(find.text('Pusat Eksekusi Mesin'), findsOneWidget);
    expect(find.text('Media Tools'), findsOneWidget);
  });

  testWidgets('Test Drag and Drop Reordering of Pools, Slots, and Inherited Slots',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Switch to PDF Manager
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // 2. Add second pool (Reorder Pool)
    await tester.tap(find.byTooltip('Tambah Target Pool Baru'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    expect(find.text('Split Pool'), findsOneWidget);
    expect(find.text('Reorder Pool'), findsOneWidget);

    // 3. Test dragging Reorder Pool header above Split Pool
    final poolDragHandles = find.byTooltip('Tahan dan geser untuk mengatur urutan pool');
    expect(poolDragHandles, findsNWidgets(2));

    final dragLocation = tester.getCenter(poolDragHandles.at(1));
    final dropLocation = tester.getCenter(find.text('Split Pool').first);

    final gesture = await tester.startGesture(dragLocation);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(dropLocation);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    // Verify Reorder Pool is now on top and Split Pool is second!
    expect(find.textContaining('Urutan pipeline pool diperbarui'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 4. In the second pool (Split Pool), it now has inherited slot 'Reorder Pool File'
    expect(find.text('Reorder Pool File'), findsOneWidget);

    // 5. Test dragging the inherited slot "+ File (Pool Atas)" within Split Pool
    // First add a normal slot to Split Pool so there are 2 slots
    await tester.tap(find.byTooltip('Tambah slot baru').last);
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Drag the inherited slot card
    final inheritedCard = find.text('Reorder Pool File');
    expect(inheritedCard, findsOneWidget);

    final secondCard = find.text('Number Split').last;
    final inheritedCardCenter = tester.getCenter(inheritedCard);
    final secondCardCenter = tester.getCenter(secondCard);

    final slotGesture = await tester.startGesture(inheritedCardCenter);
    await tester.pump(const Duration(milliseconds: 100));
    await slotGesture.moveTo(secondCardCenter);
    await tester.pump(const Duration(milliseconds: 100));
    await slotGesture.up();
    await tester.pumpAndSettle();

    // Verify both slots remain intact after drag & drop
    expect(find.text('Reorder Pool File'), findsOneWidget);
    expect(find.text('Number Split'), findsWidgets);

    // 6. Enter Detail View of Reorder Pool
    await tester.tap(find.text('Order Number').first);
    await tester.pumpAndSettle();

    // Inside Reorder Pool: Drag handle exists on bottom rows
    expect(find.byTooltip('Tahan dan geser untuk mengubah urutan'), findsOneWidget);

    // Add another order number row
    await tester.tap(find.text('+ Add Order Number'));
    await tester.pumpAndSettle();

    final rowDragHandles = find.byTooltip('Tahan dan geser untuk mengubah urutan');
    expect(rowDragHandles, findsNWidgets(2));

    // Drag row 1 handle onto row 0
    final row1Center = tester.getCenter(rowDragHandles.at(1));
    final row0Center = tester.getCenter(rowDragHandles.at(0));

    final rowGesture = await tester.startGesture(row1Center);
    await tester.pump(const Duration(milliseconds: 100));
    await rowGesture.moveTo(row0Center);
    await tester.pump(const Duration(milliseconds: 100));
    await rowGesture.up();
    await tester.pumpAndSettle();

    // Verify still in Reorder Pool with 2 rows preserved
    expect(find.text('Order Number 1'), findsOneWidget);
    expect(find.text('Order Number 2'), findsOneWidget);

    // Return to overview
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();
    expect(find.text('Mulai Proses'), findsOneWidget);
  });

  testWidgets('Test that all changes and configured data are preserved when switching between windows and tabs',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. In Convert Only: Select JPG as target format
    await tester.tap(find.text('PNG').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('JPG').last);
    await tester.pumpAndSettle();
    expect(find.text('JPG'), findsWidgets);

    // 2. Switch to PDF Manager tab
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // Add target pool (Reorder Pool)
    await tester.tap(find.byTooltip('Tambah Target Pool Baru'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    expect(find.text('Split Pool'), findsOneWidget);
    expect(find.text('Reorder Pool'), findsOneWidget);

    // 3. Switch to Engine Config from Sidebar
    await tester.tap(find.text('Engine Config'));
    await tester.pumpAndSettle();
    expect(find.text('Konfigurasi Engine Dokumen & PDF'), findsOneWidget);

    // Select LibreOffice
    await tester.tap(find.text('LibreOffice (Libre)'));
    await tester.pumpAndSettle();

    // 4. Switch to Settings from Sidebar
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Pengaturan Sistem & Preferensi'), findsOneWidget);

    // 5. Navigate back to Dashboard -> PDF Manager
    await tester.tap(find.text('Dasboard'));
    await tester.pumpAndSettle();

    // Verify both pools are still completely preserved in PDF Manager!
    expect(find.text('Split Pool'), findsOneWidget);
    expect(find.text('Reorder Pool'), findsOneWidget);

    // 6. Navigate to Media Tools tab
    await tester.tap(find.text('Media Tools'));
    await tester.pumpAndSettle();

    // Verify Convert Only kept 'JPG' target format!
    expect(find.text('JPG'), findsWidgets);

    // 7. Navigate back to Engine Config
    await tester.tap(find.text('Engine Config'));
    await tester.pumpAndSettle();

    // Verify LibreOffice remains selected!
    expect(AppStateService().selectedEngine, DocEngineType.libreOffice);
  });

  testWidgets('Test clearing file from slot #1 without deleting slot #1 across all pools',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    // Populate slot 1 of Pool 0 (Split Pool) directly via AppStateService
    final appState = AppStateService();
    appState.pdfPools[0].slots[0].fileName = 'jurnal1.pdf';
    appState.pdfPools[0].slots[0].filePath = r'C:\test\jurnal1.pdf';

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // Switch to PDF Manager
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // Verify jurnal1.pdf is shown and the clear badge is visible
    expect(find.text('jurnal1.pdf'), findsOneWidget);
    final clearBadge = find.byTooltip('Hapus file dari kotak ini');
    expect(clearBadge, findsOneWidget);

    // Tap the (X) badge to remove file from slot #1
    await tester.tap(clearBadge);
    await tester.pumpAndSettle();

    // Verify file is removed, BUT slot #1 box ('Number Split' & '+ File') remains!
    expect(find.text('jurnal1.pdf'), findsNothing);
    expect(find.text('Number Split'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);

    // Also verify clear badge disappears once slot #1 is empty
    expect(find.byTooltip('Hapus file dari kotak ini'), findsNothing);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Now test inside SplitPoolView as well
    appState.pdfPools[0].slots[0].fileName = 'laporan.pdf';
    await tester.tap(find.text('Number Split').first);
    await tester.pumpAndSettle();

    expect(find.text('laporan.pdf'), findsWidgets);
    await tester.tap(find.byTooltip('Hapus file dari kotak ini'));
    await tester.pumpAndSettle();

    expect(find.text('laporan.pdf'), findsNothing);
    expect(find.text('Number Split'), findsOneWidget);
  });

  testWidgets('Test Save Folder Ask-First Setting and Pop-up Save Flow across ALL Media Tools and PDF Manager features',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final appState = AppStateService();
    appState.addConvertOnlyFiles(['dokumen.docx']);
    appState.addCompressFiles(['foto_banner.png']);
    appState.addUpscaleFiles(['avatar.jpg']);
    appState.pdfPools[0].slots[0].fileName = 'laporan_keuangan.pdf';
    appState.pdfPools[0].slots[0].filePath = r'C:\test\laporan_keuangan.pdf';

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Check Settings -> Folder Penyimpanan & Hasil Konversi mode options
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Format Penentuan Folder Simpan'), findsOneWidget);
    expect(find.text('Tanya Dulu Mau Simpan Folder Dimana'), findsOneWidget);
    expect(find.text('Langsung Simpan ke Folder Default'), findsOneWidget);
    expect(appState.saveLocationMode, SaveLocationMode.askEveryTime);

    // Toggle to autoDefaultFolder and back to askEveryTime
    await tester.tap(find.text('Langsung Simpan ke Folder Default'));
    await tester.pumpAndSettle();
    expect(appState.saveLocationMode, SaveLocationMode.autoDefaultFolder);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();

    await tester.tap(find.text('Tanya Dulu Mau Simpan Folder Dimana'));
    await tester.pumpAndSettle();
    expect(appState.saveLocationMode, SaveLocationMode.askEveryTime);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 2. Test Media Tools -> Convert Only Save Folder Pop-up + Manual Filename Edit (auto ext)
    await tester.tap(find.text('Dasboard'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mulai Proses'));
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    expect(find.text('Klik nama file untuk edit manual'), findsOneWidget);
    expect(find.text('Mau disimpan di folder mana?'), findsOneWidget);
    expect(find.text('Pilih Folder...'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputConvert',
    );
    // Validate empty filename guard
    await tester.enterText(
      find.byKey(const Key('save_file_name_field_0')),
      '',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(find.text('Nama file #1 tidak boleh kosong.'), findsOneWidget);

    // Type filename without extension -> auto-appends .png
    await tester.enterText(
      find.byKey(const Key('save_file_name_field_0')),
      'laporan_custom',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(appState.history.first.outputPath, r'D:\OutputConvert\laporan_custom.png');
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 3. Test Media Tools -> Compress & Convert Save Folder Pop-up + Explicit Extension Edit
    await tester.tap(find.text('Compress & Convert'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mulai Proses'));
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputCompress',
    );
    await tester.enterText(
      find.byKey(const Key('save_file_name_field_0')),
      'banner_kustom.jpg',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(appState.history.first.taskType, 'Compress & Convert');
    expect(appState.history.first.outputPath, r'D:\OutputCompress\banner_kustom.jpg');
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 4. Test Media Tools -> Upscale AI Save Folder Pop-up
    await tester.tap(find.text('Upscale AI'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mulai Proses'));
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputUpscale',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(appState.history.first.taskType, 'Upscale AI');
    expect(appState.history.first.outputPath, r'D:\OutputUpscale\avatar_upscaled.png');
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 5. Test PDF Manager Overview Save Folder Pop-up
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mulai Proses'));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputWorkflow',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(
      appState.history.first.outputPath,
      r'D:\OutputWorkflow\laporan_keuangan_workflow.pdf',
    );
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 6. Test Split PDF Save Folder Pop-up
    await tester.tap(find.text('Number Split').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split PDF'));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputSplit',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(appState.history.first.taskType, 'PDF Manager (Split Pool)');
    expect(
      appState.history.first.outputPath,
      r'D:\OutputSplit\laporan_keuangan_split.pdf',
    );
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 7. Test Reorder PDF Save Folder Pop-up
    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder Pool').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reorder PDF'));
    await tester.pumpAndSettle();
    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputReorder',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(appState.history.first.taskType, 'PDF Manager (Reorder)');
    expect(
      appState.history.first.outputPath,
      r'D:\OutputReorder\laporan_keuangan_reordered.pdf',
    );
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 8. Test Merge PDF Save Folder Pop-up
    await tester.tap(find.text('Reorder Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge Pool').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Merge PDF'));
    await tester.pumpAndSettle();
    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      r'D:\OutputMerge',
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    await tester.pumpAndSettle();
    expect(appState.history.first.taskType, 'PDF Manager (Merge)');
    expect(
      appState.history.first.outputPath,
      r'D:\OutputMerge\laporan_keuangan_merged.pdf',
    );
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // 9. Verify autoDefaultFolder skips popup and auto-saves directly
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Langsung Simpan ke Folder Default'));
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();

    await tester.tap(find.text('Dasboard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge PDF'));
    await tester.pumpAndSettle();

    // Pop-up must NOT appear when set to Langsung Simpan ke Folder Default!
    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsNothing);
    expect(
      appState.history.first.outputPath,
      r'C:\Users\ACER\Downloads\MediaWorkflow_Output\laporan_keuangan_merged.pdf',
    );
  });

  test('PdfInspectorService parses classic PDFs, Flate /ObjStm PDFs, and range helpers', () {
    final inspector = PdfInspectorService();

    final classicInfo = inspector.parsePdfBytes(
      _buildSyntheticPdfBytes(12, compressedObjStm: false),
      fileName: 'classic_12.pdf',
    );
    expect(classicInfo.pageCount, equals(12));
    expect(classicInfo.pages.length, equals(12));
    expect(classicInfo.pages.first.paperSizeLabel, equals('A4'));
    expect(classicInfo.isFromDisk, isTrue);

    final objStmInfo = inspector.parsePdfBytes(
      _buildSyntheticPdfBytes(7, compressedObjStm: true),
      fileName: 'compressed_7.pdf',
    );
    expect(objStmInfo.pageCount, equals(7));
    expect(objStmInfo.pages.length, equals(7));

    expect(
      PdfInspectorService.parsePageRangeSpec('1-3, 5, 10-8', 12),
      equals([1, 2, 3, 5, 8, 9, 10]),
    );
    expect(
      PdfInspectorService.formatCompactPageRanges([1, 2, 3, 5, 8, 9, 10]),
      equals('1-3, 5, 8-10'),
    );
    expect(
      PdfInspectorService.parseOrderSpec('3, 1, 2', 5),
      equals([3, 1, 2, 4, 5]),
    );
    expect(
      PdfInspectorService.parseOrderSpec('3, 1, 2', 5, appendMissing: false),
      equals([3, 1, 2]),
    );
  });

  testWidgets(
      'Clicking filled PDF pool boxes navigates directly to page previews across Split, Reorder, and Merge',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final tempDir = Directory.systemTemp.createTempSync('pdf_preview_test_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final doc12File = File('${tempDir.path}${Platform.pathSeparator}dokumen_12hal.pdf');
    final doc20File = File('${tempDir.path}${Platform.pathSeparator}lampiran_20hal.pdf');
    doc12File.writeAsBytesSync(_buildSyntheticPdfBytes(12));
    doc20File.writeAsBytesSync(_buildSyntheticPdfBytes(20));

    final appState = AppStateService();
    // Pool 0: Split Pool with dokumen_12hal.pdf
    appState.pdfPools[0].slots[0].fileName = 'dokumen_12hal.pdf';
    appState.pdfPools[0].slots[0].filePath = doc12File.path;
    appState.pdfPools[0].slots[0].pageCount = 12;

    // Pool 1: Reorder Pool (normal slot stays empty so inherited 12 pages flows cleanly without duplication)
    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_reorder',
        title: 'Reorder Pool',
        slots: [
          PoolSlot(id: 's_reorder_0', label: 'Order Number'),
        ],
      ),
    );

    // Pool 2: Merge Pool with lampiran_20hal.pdf (20 pages) + inherited 12 pages => 32 Hal total
    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_merge',
        title: 'Merge Pool',
        slots: [
          PoolSlot(
            id: 's_merge_0',
            label: 'Merge Number',
            fileName: 'lampiran_20hal.pdf',
            filePath: doc20File.path,
            pageCount: 20,
          ),
        ],
      ),
    );
    appState.updatePdfInheritedSlots();

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Go to PDF Manager Overview
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // Click directly on the filled box 'dokumen_12hal.pdf' in Split Pool (NOT the bottom label)
    await tester.tap(find.text('dokumen_12hal.pdf'));
    await tester.pump();
    // Loading spinner is shown while disk PDF is inspected off the frame
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    for (int i = 0; i < 30; i++) {
      if (PdfInspectorService().getCached('dokumen_12hal.pdf', doc12File.path) !=
          null) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Verify SplitPoolView opened in Range mode showing Page 1 & Page 12
    expect(find.text('12 Halaman'), findsOneWidget);
    expect(find.text('Halaman Pertama • Hal 1'), findsOneWidget);
    expect(find.text('Halaman Terakhir • Hal 12'), findsOneWidget);

    // Open Zoom dialog from first page card
    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    expect(find.byType(PdfPageZoomDialog), findsOneWidget);
    expect(find.text('Halaman 1 dari 12'), findsWidgets);
    await tester.tap(find.text('Berikutnya'));
    await tester.pumpAndSettle();
    expect(find.text('Halaman 2 dari 12'), findsWidgets);
    await tester.tap(find.text('Tutup'));
    await tester.pumpAndSettle();

    // Switch to Pages tab and inspect all 1..12 pages with instant auto-sync to Split Number 1
    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();
    expect(find.text('Dipilih: 0'), findsOneWidget);
    expect(find.text('Hal 1'), findsWidgets);

    // Select page 2 & page 5 -> Split Number 1 writes "2, 5"
    await tester.tap(find.text('Hal 2').first);
    await tester.pumpAndSettle();
    final splitField = tester.widget<TextField>(find.byType(TextField).first);
    expect(splitField.controller?.text, equals('2'));

    await tester.tap(find.text('Hal 5').first);
    await tester.pumpAndSettle();
    expect(splitField.controller?.text, equals('2, 5'));
    expect(find.text('Dipilih (2): 2, 5'), findsOneWidget);
    expect(find.text('Split 2, 5'), findsOneWidget);

    // Add pages 3 & 4 -> contiguous range auto-compacts into "2-5"
    await tester.tap(find.text('Hal 3').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hal 4').first);
    await tester.pumpAndSettle();
    expect(splitField.controller?.text, equals('2-5'));
    expect(find.text('Dipilih (4): 2-5'), findsOneWidget);
    expect(find.text('Split 2-5'), findsOneWidget);

    final gridFinder = find.byType(GridView);
    await tester.drag(gridFinder, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Hal 12'), findsWidgets);

    await tester.tap(find.text('Pilih Semua'));
    await tester.pumpAndSettle();
    expect(splitField.controller?.text, equals('1-12'));
    expect(find.text('Dipilih (12): 1-12'), findsOneWidget);

    await tester.tap(find.text('Hapus Pilihan'));
    await tester.pumpAndSettle();
    expect(splitField.controller?.text, isEmpty);
    expect(find.text('Dipilih: 0'), findsOneWidget);

    // Return to Overview
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();

    // 2. Click populated inherited card ('1 File' in Reorder Pool)
    final reorderInheritedCard = find.text('1 File').first;
    await tester.ensureVisible(reorderInheritedCard);
    await tester.pumpAndSettle();
    await tester.tap(reorderInheritedCard);
    await tester.pump();
    for (int i = 0; i < 30; i++) {
      if (PdfInspectorService().getCached('dokumen_12hal.pdf', doc12File.path) !=
          null) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Verify ReorderPoolView displays all 12 pages and supports deleting pages with [X] beside Zoom
    expect(find.text('12 Halaman'), findsOneWidget);
    expect(find.text('Pos #1 • Hal 1'), findsOneWidget);

    // Delete Hal 2 using the cross button beside Zoom
    await tester.tap(find.byTooltip('Hapus Hal 2'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hapus Hal 2'), findsNothing);
    expect(find.text('Aktif: 11/12 Hal'), findsOneWidget);
    final reorderField = tester.widget<TextField>(find.byType(TextField).first);
    expect(
      reorderField.controller?.text,
      equals('1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12'),
    );
    // Deleted Hal 2 stays removed and Hal 3 shifts into Pos #2
    expect(find.text('Pos #2 • Hal 3'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Reverse only remaining 11 pages
    await tester.tap(find.text('Balik Urutan'));
    await tester.pumpAndSettle();
    expect(find.text('Pos #1 • Hal 12'), findsOneWidget);

    // Reset 1..N restores all 12 pages
    await tester.tap(find.text('Reset 1..N'));
    await tester.pumpAndSettle();
    expect(find.text('Pos #1 • Hal 1'), findsOneWidget);
    expect(find.byTooltip('Hapus Hal 2'), findsOneWidget);
    expect(find.text('Aktif: 11/12 Hal'), findsNothing);

    // Return to Overview
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();

    // 3. Click filled box 'lampiran_20hal.pdf' in Merge Pool
    final mergeFileCard = find.text('lampiran_20hal.pdf');
    await tester.ensureVisible(mergeFileCard);
    await tester.pumpAndSettle();
    await tester.tap(mergeFileCard);
    await tester.pump();
    for (int i = 0; i < 30; i++) {
      if (PdfInspectorService().getCached('lampiran_20hal.pdf', doc20File.path) !=
          null) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // Verify MergePoolView shows Total Merge: 32 Hal (12 inherited + 20 normal) + Start/End pages
    expect(find.text('Antrean Merge: 2 File'), findsOneWidget);
    expect(find.text('Total Merge: 32 Hal'), findsOneWidget);
    expect(find.text('Halaman Awal • Hal 1'), findsOneWidget);
    expect(find.text('Halaman Akhir • Hal 20'), findsOneWidget);

    // Switch to Hasil Merge (Hal 1-32) combined view
    await tester.tap(find.text('Hasil Merge (Hal 1–32)'));
    await tester.pumpAndSettle();
    expect(find.text('Awal Merge • Hal 1'), findsOneWidget);
    expect(find.text('Akhir Merge • Hal 32'), findsOneWidget);
    expect(find.text('32 Hal'), findsOneWidget);
  });

  testWidgets(
      'Split Pool Pages auto-syncs per-file Split Number rows and shows spinning loading indicators',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final inspector = PdfInspectorService();
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'jurnal_utama.pdf',
        pageCount: 10,
        fileSizeBytes: 15000000,
        pages: List.generate(10, (i) => PdfPageMeta(pageNumber: i + 1)),
      ),
    );
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'lampiran_kedua.pdf',
        pageCount: 10,
        fileSizeBytes: 8500000,
        pages: List.generate(10, (i) => PdfPageMeta(pageNumber: i + 1)),
      ),
    );

    final appState = AppStateService();
    appState.pdfPools[0].slots = [
      PoolSlot(
        id: 'split_slot_1',
        label: 'Number Split',
        fileName: 'jurnal_utama.pdf',
        pageCount: 10,
      ),
      PoolSlot(
        id: 'split_slot_2',
        label: 'Number Split',
        fileName: 'lampiran_kedua.pdf',
        pageCount: 10,
      ),
    ];

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('jurnal_utama.pdf'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();

    // Check pages 2 & 5 for file #1 -> Split Number 1 updates to "2, 5"
    await tester.tap(find.text('Hal 2').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hal 5').first);
    await tester.pumpAndSettle();

    final splitInput1 = tester.widget<TextField>(find.byType(TextField).at(0));
    final splitInput2 = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(splitInput1.controller?.text, equals('2, 5'));
    expect(splitInput2.controller?.text, isEmpty);

    // Switch to file #2 ("lampiran_kedua.pdf") and select pages 2..5 -> Split Number 2 writes "2-5"
    await tester.tap(find.text('lampiran_kedua.pdf').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hal 2').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hal 3').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hal 4').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hal 5').first);
    await tester.pumpAndSettle();

    expect(splitInput1.controller?.text, equals('2, 5'));
    expect(splitInput2.controller?.text, equals('2-5'));
    expect(find.text('Split 2, 5'), findsOneWidget);
    expect(find.text('Split 2-5'), findsOneWidget);

    // Return to Overview and verify pool-type dropdown updates bottom labels even when files are loaded
    await tester.tap(find.text('Go to Pool'));
    await tester.pumpAndSettle();

    // Switch Pool 0 from 'Split Pool' -> 'Reorder Pool': 'Split 2, 5' / 'Split 2-5' become 'Order 2, 5' / 'Order 2-5'
    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder Pool').last);
    await tester.pumpAndSettle();

    expect(find.text('Order 2, 5'), findsOneWidget);
    expect(find.text('Order 2-5'), findsOneWidget);
    expect(find.text('Split 2, 5'), findsNothing);

    // Clear pageRange on slot 1 so we also verify default label conversion with an active file
    appState.pdfPools[0].slots[0].pageRange = null;
    appState.pdfPools[0].slots[0].label = 'Number Split';
    // Re-trigger dropdown change: Reorder Pool -> Split Pool -> Reorder Pool -> Merge Pool
    await tester.tap(find.text('Reorder Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split Pool').last);
    await tester.pumpAndSettle();
    expect(find.text('Number Split'), findsOneWidget);
    expect(find.text('jurnal_utama.pdf'), findsOneWidget);

    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder Pool').last);
    await tester.pumpAndSettle();
    expect(find.text('Order Number'), findsOneWidget);
    expect(find.text('Number Split'), findsNothing);

    await tester.tap(find.text('Reorder Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge Pool').last);
    await tester.pumpAndSettle();
    expect(find.text('Merge Number'), findsNWidgets(2));
    expect(find.text('Order Number'), findsNothing);

    // Verify rotating loading UI widgets render cleanly without overflow
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 500,
            child: Column(
              children: [
                PoolThumbnailCard(
                  label: 'Number Split',
                  fileName: 'jurnal_besar.pdf',
                  isLoading: true,
                ),
                Expanded(
                  child: PdfLoadingPreview(fileName: 'jurnal_besar.pdf'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(find.text('Memuat Halaman PDF...'), findsOneWidget);
    expect(find.text('Memuat...'), findsOneWidget);
  });

  testWidgets(
      'All pools render real PDF pages and Zoom viewer supports Maximize, Minimize, and Close (Silang)',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() {
      PdfPageZoomDialog.dismissActive();
      PdfRenderService().clearTestOverrides();
      PdfRenderService().clearAllCaches();
    });

    const docAPath = r'C:\real_docs\laporan_utama.pdf';
    const docBPath = r'C:\real_docs\lampiran_akhir.pdf';

    final inspector = PdfInspectorService();
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'laporan_utama.pdf',
        filePath: docAPath,
        pageCount: 3,
        fileSizeBytes: 2400000,
        pages: [
          PdfPageMeta(
            pageNumber: 1,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docAPath,
            sourcePageNumber: 1,
          ),
          PdfPageMeta(
            pageNumber: 2,
            widthPt: 794,
            heightPt: 595,
            sourceFilePath: docAPath,
            sourcePageNumber: 2,
          ),
          PdfPageMeta(
            pageNumber: 3,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docAPath,
            sourcePageNumber: 3,
          ),
        ],
      ),
    );
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'lampiran_akhir.pdf',
        filePath: docBPath,
        pageCount: 2,
        fileSizeBytes: 1200000,
        pages: [
          PdfPageMeta(
            pageNumber: 1,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docBPath,
            sourcePageNumber: 1,
          ),
          PdfPageMeta(
            pageNumber: 2,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docBPath,
            sourcePageNumber: 2,
          ),
        ],
      ),
    );

    final renderService = PdfRenderService();
    await tester.runAsync(() async {
      // Doc A thumbnails & cards & zoom
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 1,
        quality: PdfRenderQuality.thumb,
        image: await _createTestRenderedImage(111, 150, const Color(0xFF1E88E5)),
      );
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 2,
        quality: PdfRenderQuality.thumb,
        image: await _createTestRenderedImage(112, 150, const Color(0xFF43A047)),
      );
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 3,
        quality: PdfRenderQuality.thumb,
        image: await _createTestRenderedImage(113, 150, const Color(0xFFFB8C00)),
      );
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 1,
        quality: PdfRenderQuality.card,
        image: await _createTestRenderedImage(211, 300, const Color(0xFF1565C0)),
      );
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 3,
        quality: PdfRenderQuality.card,
        image: await _createTestRenderedImage(213, 300, const Color(0xFFE65100)),
      );
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 1,
        quality: PdfRenderQuality.zoom,
        image: await _createTestRenderedImage(411, 580, const Color(0xFF0D47A1)),
      );
      renderService.putTestRenderedPage(
        filePath: docAPath,
        pageNumber: 2,
        quality: PdfRenderQuality.zoom,
        image: await _createTestRenderedImage(412, 580, const Color(0xFF1B5E20)),
      );

      // Doc B cards & zoom
      renderService.putTestRenderedPage(
        filePath: docBPath,
        pageNumber: 1,
        quality: PdfRenderQuality.card,
        image: await _createTestRenderedImage(221, 300, const Color(0xFF6A1B9A)),
      );
      renderService.putTestRenderedPage(
        filePath: docBPath,
        pageNumber: 2,
        quality: PdfRenderQuality.card,
        image: await _createTestRenderedImage(222, 300, const Color(0xFFC62828)),
      );
      renderService.putTestRenderedPage(
        filePath: docBPath,
        pageNumber: 2,
        quality: PdfRenderQuality.zoom,
        image: await _createTestRenderedImage(422, 580, const Color(0xFF8E24AA)),
      );
    });

    final appState = AppStateService();
    appState.pdfPools[0].slots[0].fileName = 'laporan_utama.pdf';
    appState.pdfPools[0].slots[0].filePath = docAPath;
    appState.pdfPools[0].slots[0].pageCount = 3;

    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_reorder_real',
        title: 'Reorder Pool',
        slots: [
          PoolSlot(
            id: 's_reorder_real',
            label: 'Order Number',
            fileName: 'laporan_utama.pdf',
            filePath: docAPath,
            pageCount: 3,
          ),
        ],
      ),
    );
    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_merge_real',
        title: 'Merge Pool',
        slots: [
          PoolSlot(
            id: 's_merge_real',
            label: 'Merge Number',
            fileName: 'lampiran_akhir.pdf',
            filePath: docBPath,
            pageCount: 2,
          ),
        ],
      ),
    );
    appState.updatePdfInheritedSlots();

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Open Split Pool via filled file box
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('laporan_utama.pdf').first);
    await tester.pumpAndSettle();

    // Verify Split Pool Range displays real card images for Page 1 (211) and Page 3 (213)
    var renderedWidths = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((r) => r.image?.width)
        .toList();
    expect(renderedWidths, containsAll([211, 213]));

    // Open Zoom modal -> uses zoom tier (411), test Ctrl+Scroll zoom, Left-Click Drag pan, Maximize / Restore / Minimize / Close
    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .map((r) => r.image?.width),
      contains(411),
    );
    expect(find.text('100%'), findsOneWidget);
    expect(
      find.text(
        'Ctrl + Scroll Mouse untuk Zoom • Tahan Klik Kiri & Geser untuk Drag • Ctrl + R untuk Putar',
      ),
      findsOneWidget,
    );

    // 1a. Scroll wheel WITHOUT Ctrl must NOT zoom
    final canvasCenter =
        tester.getCenter(find.byKey(const Key('pdf_zoom_canvas_listener')));
    final mousePointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mousePointer.hover(canvasCenter));
    await tester.sendEventToBinding(mousePointer.scroll(const Offset(0, -120)));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    // 1b. Ctrl + Scroll Forward (scrollDelta.dy < 0) => Zoom In (100% -> 120% -> 140%)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester
          .sendEventToBinding(mousePointer.scroll(const Offset(0, -120)));
      await tester.pumpAndSettle();
      expect(find.text('120%'), findsOneWidget);

      await tester
          .sendEventToBinding(mousePointer.scroll(const Offset(0, -120)));
      await tester.pumpAndSettle();
      expect(find.text('140%'), findsOneWidget);

      // 1c. Ctrl + Scroll Backward (scrollDelta.dy > 0) => Zoom Out (140% -> 120% -> 100% -> 80%)
      await tester
          .sendEventToBinding(mousePointer.scroll(const Offset(0, 120)));
      await tester.pumpAndSettle();
      expect(find.text('120%'), findsOneWidget);

      await tester
          .sendEventToBinding(mousePointer.scroll(const Offset(0, 120)));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);

      await tester
          .sendEventToBinding(mousePointer.scroll(const Offset(0, 120)));
      await tester.pumpAndSettle();
      expect(find.text('80%'), findsOneWidget);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    // Reset back to 100% by clicking percentage badge
    await tester.tap(find.text('80%'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    // 1d. Hold Left Mouse Button & drag PDF diagonally at 220% zoom (follows mouse direction 1:1)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      for (int i = 0; i < 6; i++) {
        await tester
            .sendEventToBinding(mousePointer.scroll(const Offset(0, -120)));
      }
      await tester.pumpAndSettle();
      expect(find.text('220%'), findsOneWidget);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    final zoomPageFinder = find.byType(PdfRealPagePreview).last;
    final initialRect = tester.getRect(zoomPageFinder);

    // Drag up-left with left mouse button held -> PDF topLeft moves up & left
    final dragLeftGesture = await tester.startGesture(
      canvasCenter,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
      pointer: 20,
    );
    await tester.pump();
    await dragLeftGesture.moveBy(const Offset(-50, -70));
    await tester.pumpAndSettle();
    final afterUpLeftRect = tester.getRect(zoomPageFinder);
    expect(afterUpLeftRect.left, lessThan(initialRect.left));
    expect(afterUpLeftRect.top, lessThan(initialRect.top));

    // While still holding left mouse button, drag down-right -> PDF follows back right & down
    await dragLeftGesture.moveBy(const Offset(35, 45));
    await tester.pumpAndSettle();
    final afterDownRightRect = tester.getRect(zoomPageFinder);
    expect(afterDownRightRect.left, greaterThan(afterUpLeftRect.left));
    expect(afterDownRightRect.top, greaterThan(afterUpLeftRect.top));
    await dragLeftGesture.up();
    await tester.pumpAndSettle();

    // Right-click drag must NOT move the PDF
    final rightClickGesture = await tester.startGesture(
      canvasCenter,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
      pointer: 21,
    );
    await tester.pump();
    await rightClickGesture.moveBy(const Offset(-40, -40));
    await tester.pumpAndSettle();
    expect(tester.getRect(zoomPageFinder), equals(afterDownRightRect));
    await rightClickGesture.up();
    await tester.pumpAndSettle();

    // Reset zoom back to 100% cleanly before window maximize/restore checks
    await tester.tap(find.text('220%'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    final normalSize = tester.getSize(find.byType(AnimatedContainer).last);

    // Maximize button expands viewer near full viewport height/width
    await tester.tap(find.byTooltip('Maximize Pratinjau'));
    await tester.pumpAndSettle();
    final maximizedSize = tester.getSize(find.byType(AnimatedContainer).last);
    expect(maximizedSize.width, greaterThan(normalSize.width));
    expect(maximizedSize.height, greaterThan(normalSize.height));
    expect(find.byTooltip('Kembalikan Ukuran'), findsOneWidget);

    // Restore back to normal floating size
    await tester.tap(find.byTooltip('Kembalikan Ukuran'));
    await tester.pumpAndSettle();
    final restoredSize = tester.getSize(find.byType(AnimatedContainer).last);
    expect(restoredSize.width, equals(normalSize.width));

    // Step to Page 2 (zoom image 412)
    await tester.tap(find.text('Berikutnya'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .map((r) => r.image?.width),
      contains(412),
    );

    // Switch to Pages tab behind minimized Zoom dock -> proves background stays interactive while minimized!
    await tester.tap(find.byTooltip('Minimize Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.textContaining('(Diminimize)'), findsOneWidget);
    expect(find.byTooltip('Pulihkan Pratinjau'), findsOneWidget);
    expect(find.byTooltip('Maximize Pratinjau'), findsOneWidget);
    expect(find.byTooltip('Tutup Pratinjau'), findsOneWidget);

    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();
    expect(find.text('Dipilih: 0'), findsOneWidget);

    // Restore via Maximize directly from minimized dock -> expands back to Page 2 (412)
    await tester.tap(find.byTooltip('Maximize Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.text('Halaman 2 dari 3'), findsOneWidget);
    expect(find.byTooltip('Kembalikan Ukuran'), findsOneWidget);

    // Close via (X) Silang button
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.byType(PdfPageZoomDialog), findsNothing);

    // Verify Split Pool Pages grid displays thumb images 111, 112, 113
    renderedWidths = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((r) => r.image?.width)
        .toList();
    expect(renderedWidths, containsAll([111, 112, 113]));

    // 2. Switch via pool dropdown to Reorder Pool -> displays thumb images 111, 112, 113
    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder Pool').last);
    await tester.pumpAndSettle();
    renderedWidths = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((r) => r.image?.width)
        .toList();
    expect(renderedWidths, containsAll([111, 112, 113]));

    // 3. Switch via pool dropdown to Merge Pool -> verify individual & combined real renders
    await tester.tap(find.text('Reorder Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge Pool').last);
    await tester.pumpAndSettle();

    // Inherited queue item #1 renders docA (211, 213); selecting docB chip renders (221, 222)
    renderedWidths = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((r) => r.image?.width)
        .toList();
    expect(renderedWidths, containsAll([211, 213]));

    await tester.tap(find.textContaining('lampiran_akhir.pdf').first);
    await tester.pumpAndSettle();

    renderedWidths = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((r) => r.image?.width)
        .toList();
    expect(renderedWidths, containsAll([221, 222]));

    // Combined Hasil Merge shows File 1 Page 1 (211) & File N Last Page (222)
    await tester.tap(find.textContaining('Hasil Merge'));
    await tester.pumpAndSettle();
    renderedWidths = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .map((r) => r.image?.width)
        .toList();
    expect(renderedWidths, containsAll([211, 222]));

    // Zoom on 'Akhir Merge' inside Hasil Merge resolves sourceFilePath -> docB page 2 (422)
    await tester.tap(find.text('Zoom').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .map((r) => r.image?.width),
      contains(422),
    );
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.byType(PdfPageZoomDialog), findsNothing);
  });

  testWidgets(
      'Zoom viewer supports Split checkmark & Reorder X/reorder controls, and Reorder Pool supports 1x Undo',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() {
      PdfPageZoomDialog.dismissActive();
      PdfRenderService().clearTestOverrides();
      PdfRenderService().clearAllCaches();
    });

    const docPath = r'C:\real_docs\undangan_3hal.pdf';
    final inspector = PdfInspectorService();
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'undangan_3hal.pdf',
        filePath: docPath,
        pageCount: 3,
        fileSizeBytes: 3600000,
        pages: List<PdfPageMeta>.generate(
          3,
          (i) => PdfPageMeta(
            pageNumber: i + 1,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docPath,
            sourcePageNumber: i + 1,
          ),
        ),
      ),
    );

    final renderService = PdfRenderService();
    await tester.runAsync(() async {
      for (int p = 1; p <= 3; p++) {
        renderService.putTestRenderedPage(
          filePath: docPath,
          pageNumber: p,
          quality: PdfRenderQuality.thumb,
          image: await _createTestRenderedImage(100 + p, 140, Colors.blue),
        );
        renderService.putTestRenderedPage(
          filePath: docPath,
          pageNumber: p,
          quality: PdfRenderQuality.card,
          image: await _createTestRenderedImage(200 + p, 280, Colors.teal),
        );
        renderService.putTestRenderedPage(
          filePath: docPath,
          pageNumber: p,
          quality: PdfRenderQuality.zoom,
          image: await _createTestRenderedImage(400 + p, 560, Colors.indigo),
        );
      }
    });

    final appState = AppStateService();
    appState.pdfPools[0].slots[0].fileName = 'undangan_3hal.pdf';
    appState.pdfPools[0].slots[0].filePath = docPath;
    appState.pdfPools[0].slots[0].pageCount = 3;

    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_reorder_interactive',
        title: 'Reorder Pool',
        slots: [
          PoolSlot(
            id: 's_reorder_interactive',
            label: 'Order Number',
            fileName: 'undangan_3hal.pdf',
            filePath: docPath,
            pageCount: 3,
          ),
        ],
      ),
    );
    appState.updatePdfInheritedSlots();

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // ------------------------------------------------------------------
    // PART 1: Zoom mode Split Checkmark (Range & Pages modes live sync)
    // ------------------------------------------------------------------
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('undangan_3hal.pdf').first);
    await tester.pumpAndSettle();

    // Open Zoom from Range mode
    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();

    final zoomFinder = find.byType(PdfPageZoomDialog);
    expect(zoomFinder, findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Pilih Hal 1 untuk Split')),
      findsOneWidget,
    );

    // Check Hal 1 directly inside Zoom
    await tester.tap(find.byKey(const Key('pdf_zoom_split_check_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Hal 1 Dipilih (Split)')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Dipilih (1): 1')),
      findsOneWidget,
    );
    final splitTextField = tester.widget<TextField>(find.byType(TextField).first);
    expect(splitTextField.controller?.text, equals('1'));

    // Step to Hal 2 via Berikutnya and check Hal 2 -> compacts to "1-2"
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Berikutnya')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf_zoom_split_check_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Dipilih (2): 1-2')),
      findsOneWidget,
    );
    expect(splitTextField.controller?.text, equals('1-2'));

    // Use page jump picker to jump directly to Hal 3 and check Hal 3 -> "1-3"
    await tester.tap(find.byKey(const Key('pdf_zoom_split_page_picker_button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Hal 3')).last,
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Halaman 3 dari 3')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('pdf_zoom_split_check_button')));
    await tester.pumpAndSettle();
    expect(splitTextField.controller?.text, equals('1-3'));

    // Test Hapus Pilihan & Pilih Semua inside Zoom
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Hapus Pilihan')),
    );
    await tester.pumpAndSettle();
    expect(splitTextField.controller?.text, isEmpty);

    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Pilih Semua')),
    );
    await tester.pumpAndSettle();
    expect(splitTextField.controller?.text, equals('1-3'));

    // Jump back to Hal 2 and uncheck Hal 2 -> "1, 3"
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Sebelumnya')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf_zoom_split_check_button')));
    await tester.pumpAndSettle();
    expect(splitTextField.controller?.text, equals('1, 3'));

    // Close Zoom, switch to Pages tab, open Zoom from Pages card & uncheck Hal 1 -> "3"
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();
    expect(find.text('Dipilih (2): 1, 3'), findsOneWidget);

    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf_zoom_split_check_button')));
    await tester.pumpAndSettle();
    expect(splitTextField.controller?.text, equals('3'));
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.text('Dipilih (1): 3'), findsOneWidget);

    // ------------------------------------------------------------------
    // PART 2: Reorder Pool Inner Undo 1x (strictly 1 step back)
    // ------------------------------------------------------------------
    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder Pool').last);
    await tester.pumpAndSettle();

    final reorderTextField = tester.widget<TextField>(find.byType(TextField).first);
    expect(reorderTextField.controller?.text, isEmpty);

    // Initially Undo 1x is disabled
    expect(
      tester.widget<PreviewHeaderButton>(find.byKey(const Key('reorder_undo_button'))).onPressed,
      isNull,
    );

    // Change 1: Balik Urutan -> [3, 2, 1]
    await tester.tap(find.byKey(const Key('reorder_reverse_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('3, 2, 1'));
    expect(
      tester.widget<PreviewHeaderButton>(find.byKey(const Key('reorder_undo_button'))).onPressed,
      isNotNull,
    );

    // Change 2: Delete Hal 2 -> [3, 1]
    await tester.tap(find.byTooltip('Hapus Hal 2'));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('3, 1'));
    expect(find.text('Aktif: 2/3 Hal'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Undo 1x -> restores strictly 1 step back to [3, 2, 1], NOT full Reset [1, 2, 3], then disables
    await tester.tap(find.byKey(const Key('reorder_undo_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('3, 2, 1'));
    expect(find.text('Aktif: 2/3 Hal'), findsNothing);
    expect(find.byTooltip('Hapus Hal 2'), findsOneWidget);
    expect(
      tester.widget<PreviewHeaderButton>(find.byKey(const Key('reorder_undo_button'))).onPressed,
      isNull,
    );

    // Reset 1..N -> clears to [1, 2, 3], and Undo 1x can still step back 1x before the Reset!
    await tester.tap(find.byKey(const Key('reorder_reset_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, isEmpty);
    expect(
      tester.widget<PreviewHeaderButton>(find.byKey(const Key('reorder_undo_button'))).onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('reorder_undo_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('3, 2, 1'));
    expect(
      tester.widget<PreviewHeaderButton>(find.byKey(const Key('reorder_undo_button'))).onPressed,
      isNull,
    );

    // Reset back to clean 1, 2, 3 before entering Zoom mode
    await tester.tap(find.byKey(const Key('reorder_reset_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, isEmpty);

    // ------------------------------------------------------------------
    // PART 3: Zoom Mode Reorder Controls (Geser, Jump, Hapus X, Undo 1x, Reverse, Reset)
    // ------------------------------------------------------------------
    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    expect(zoomFinder, findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 1 / 3 (Hal 1)')),
      findsOneWidget,
    );

    // Move Hal 1 right (Pos #1 -> Pos #2) -> order becomes [2, 1, 3]
    await tester.tap(find.byKey(const Key('pdf_zoom_reorder_move_right_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 2 / 3 (Hal 1)')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Pos #2 / 3')),
      findsOneWidget,
    );
    expect(reorderTextField.controller?.text, equals('2, 1, 3'));

    // Direct jump picker inside Zoom -> move Hal 1 from #2 to #3 -> order [2, 3, 1]
    await tester.tap(find.byKey(const Key('pdf_zoom_reorder_pos_picker_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pindah ke #3 (Hal 3)'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 3 / 3 (Hal 1)')),
      findsOneWidget,
    );
    expect(reorderTextField.controller?.text, equals('2, 3, 1'));

    // Delete current page (Hal 1) via red X ('Hapus') inside Zoom -> [2, 3]
    await tester.tap(find.byKey(const Key('pdf_zoom_reorder_delete_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('2, 3'));
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Aktif: 2/3 Hal')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 2 / 2 (Hal 3)')),
      findsOneWidget,
    );
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pumpAndSettle();

    // Undo 1x inside Zoom -> restores Hal 1 at Pos #3 [2, 3, 1], then Undo 1x disables
    await tester.tap(find.byKey(const Key('pdf_zoom_reorder_undo_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('2, 3, 1'));
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 3 / 3 (Hal 1)')),
      findsOneWidget,
    );
    expect(
      tester.widget<PreviewHeaderButton>(find.byKey(const Key('pdf_zoom_reorder_undo_button'))).onPressed,
      isNull,
    );

    // Balik Urutan inside Zoom -> [1, 3, 2], keeps viewing Hal 1 at Pos #1
    await tester.tap(find.byKey(const Key('pdf_zoom_reorder_reverse_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, equals('1, 3, 2'));
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 1 / 3 (Hal 1)')),
      findsOneWidget,
    );

    // Reset 1..N inside Zoom -> [1, 2, 3], then test Ctrl+Z inside Zoom -> [1, 3, 2]
    await tester.tap(find.byKey(const Key('pdf_zoom_reorder_reset_button')));
    await tester.pumpAndSettle();
    expect(reorderTextField.controller?.text, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.pumpAndSettle();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    expect(reorderTextField.controller?.text, equals('1, 3, 2'));

    // Close Zoom and confirm grid reflects final order [1, 3, 2]
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.byType(PdfPageZoomDialog), findsNothing);
    expect(find.text('Pos #1 • Hal 1'), findsOneWidget);
    expect(find.text('Pos #2 • Hal 3'), findsOneWidget);
    expect(find.text('Pos #3 • Hal 2'), findsOneWidget);
  });

  testWidgets(
      'Rotate works across Split Pool, Reorder Pool, Merge Pool, and Zoom with pipeline inheritance',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() {
      PdfPageZoomDialog.dismissActive();
      PdfRenderService().clearTestOverrides();
      PdfRenderService().clearAllCaches();
    });

    const docAPath = r'C:\rotate_docs\doc_a.pdf';
    const docBPath = r'C:\rotate_docs\doc_b.pdf';
    final inspector = PdfInspectorService();
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'doc_a.pdf',
        filePath: docAPath,
        pageCount: 3,
        fileSizeBytes: 2400000,
        pages: List<PdfPageMeta>.generate(
          3,
          (i) => PdfPageMeta(
            pageNumber: i + 1,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docAPath,
            sourcePageNumber: i + 1,
          ),
        ),
      ),
    );
    inspector.putTestDocument(
      PdfDocumentInfo(
        fileName: 'doc_b.pdf',
        filePath: docBPath,
        pageCount: 3,
        fileSizeBytes: 1800000,
        pages: List<PdfPageMeta>.generate(
          3,
          (i) => PdfPageMeta(
            pageNumber: i + 1,
            widthPt: 595,
            heightPt: 842,
            sourceFilePath: docBPath,
            sourcePageNumber: i + 1,
          ),
        ),
      ),
    );

    final renderService = PdfRenderService();
    await tester.runAsync(() async {
      for (int p = 1; p <= 3; p++) {
        renderService.putTestRenderedPage(
          filePath: docAPath,
          pageNumber: p,
          quality: PdfRenderQuality.thumb,
          image: await _createTestRenderedImage(110 + p, 155, Colors.blue),
        );
        renderService.putTestRenderedPage(
          filePath: docAPath,
          pageNumber: p,
          quality: PdfRenderQuality.card,
          image: await _createTestRenderedImage(210 + p, 297, Colors.teal),
        );
        renderService.putTestRenderedPage(
          filePath: docAPath,
          pageNumber: p,
          quality: PdfRenderQuality.zoom,
          image: await _createTestRenderedImage(410 + p, 580, Colors.indigo),
        );
        renderService.putTestRenderedPage(
          filePath: docBPath,
          pageNumber: p,
          quality: PdfRenderQuality.thumb,
          image: await _createTestRenderedImage(120 + p, 155, Colors.green),
        );
        renderService.putTestRenderedPage(
          filePath: docBPath,
          pageNumber: p,
          quality: PdfRenderQuality.card,
          image: await _createTestRenderedImage(220 + p, 297, Colors.cyan),
        );
        renderService.putTestRenderedPage(
          filePath: docBPath,
          pageNumber: p,
          quality: PdfRenderQuality.zoom,
          image: await _createTestRenderedImage(420 + p, 580, Colors.orange),
        );
      }
    });

    final appState = AppStateService();
    appState.pdfPools[0].slots[0].fileName = 'doc_a.pdf';
    appState.pdfPools[0].slots[0].filePath = docAPath;
    appState.pdfPools[0].slots[0].pageCount = 3;

    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_reorder_rotate',
        title: 'Reorder Pool',
        slots: [
          PoolSlot(
            id: 's_reorder_rotate',
            label: 'Order Number',
          ),
        ],
      ),
    );
    appState.pdfPools.add(
      PoolSectionData(
        id: 'pool_merge_rotate',
        title: 'Merge Pool',
        slots: [
          PoolSlot(
            id: 's_merge_rotate',
            label: 'Merge Number',
            fileName: 'doc_b.pdf',
            filePath: docBPath,
            pageCount: 3,
          ),
        ],
      ),
    );
    appState.updatePdfInheritedSlots();

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // Enter Split Pool detail view
    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('doc_a.pdf').first);
    await tester.pumpAndSettle();

    // ------------------------------------------------------------------
    // 1. Split Pool (Range Mode + Zoom Rotate sync & aspect ratio)
    // ------------------------------------------------------------------
    expect(find.text('A4 • Hal 1 / 3'), findsOneWidget);
    final firstCardPreviewFinder = find.descendant(
      of: find.byType(PdfPageSheetCard).first,
      matching: find.byType(PdfRealPagePreview),
    );
    expect(
      tester
          .widget<RotatedBox>(
            find.descendant(
              of: firstCardPreviewFinder,
              matching: find.byType(RotatedBox),
            ),
          )
          .quarterTurns,
      equals(0),
    );
    final firstCardAspectFinder = find.descendant(
      of: firstCardPreviewFinder,
      matching: find.byType(AspectRatio),
    );
    final portraitCardSize = tester.getSize(firstCardAspectFinder);
    expect(portraitCardSize.width, lessThan(portraitCardSize.height));

    // Rotate Hal 1 +90° directly from Range card -> A4 (L) • 90°
    await tester.tap(find.byTooltip('Putar Kanan Hal 1 (+90°)'));
    await tester.pumpAndSettle();
    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);
    expect(find.byKey(const Key('split_rotate_reset_button')), findsOneWidget);
    expect(find.text('Reset 0° (1)'), findsOneWidget);
    expect(
      tester
          .widget<RotatedBox>(
            find.descendant(
              of: firstCardPreviewFinder,
              matching: find.byType(RotatedBox),
            ),
          )
          .quarterTurns,
      equals(1),
    );
    final landscapeCardSize = tester.getSize(firstCardAspectFinder);
    expect(landscapeCardSize.width, greaterThan(landscapeCardSize.height));

    // Open Zoom on Hal 1 -> reflects 90° & supports button + keyboard shortcuts
    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    final zoomFinder = find.byType(PdfPageZoomDialog);
    expect(zoomFinder, findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.text('90°')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.textContaining('Putar 90°')),
      findsOneWidget,
    );

    // Rotate right in Zoom -> 180° (portrait again)
    await tester.tap(find.byKey(const Key('pdf_zoom_rotate_right_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('180°')),
      findsOneWidget,
    );

    // Ctrl + Shift + R -> rotate left back to 90°
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pumpAndSettle();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    expect(
      find.descendant(of: zoomFinder, matching: find.text('90°')),
      findsOneWidget,
    );

    // Next page (Hal 2) -> Ctrl + R -> 90°, then Reset inside Zoom -> 0°
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Berikutnya')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('0°')),
      findsOneWidget,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pumpAndSettle();
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    expect(
      find.descendant(of: zoomFinder, matching: find.text('90°')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('pdf_zoom_rotate_reset_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('0°')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();

    // ------------------------------------------------------------------
    // 2. Split Pool (Pages Mode: card rotate does NOT toggle Split checkmark)
    // ------------------------------------------------------------------
    await tester.tap(find.text('Pages'));
    await tester.pumpAndSettle();
    expect(find.text('Dipilih: 0'), findsOneWidget);
    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);

    // Tap compact rotate pill on Hal 2 -> rotates Hal 2 WITHOUT checking it!
    await tester.tap(find.byTooltip('Putar Hal 2 (+90°, Klik Kanan -90°)'));
    await tester.pumpAndSettle();
    expect(find.text('A4 (L) • 90° • Hal 2 / 3'), findsOneWidget);
    expect(find.text('Dipilih: 0'), findsOneWidget);
    expect(find.text('Reset 0° (2)'), findsOneWidget);

    // Header batch rotate +90° -> Hal 1 & 2 become 180°, Hal 3 becomes 90°
    await tester.tap(find.byKey(const Key('split_rotate_all_right_button')));
    await tester.pumpAndSettle();
    expect(find.text('Reset 0° (3)'), findsOneWidget);
    expect(find.text('A4 • 180° • Hal 1 / 3'), findsOneWidget);
    expect(find.text('A4 (L) • 90° • Hal 3 / 3'), findsOneWidget);

    // Reset all in Split header, then set Hal 1 = 90° to test inheritance downstream
    await tester.tap(find.byKey(const Key('split_rotate_reset_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('split_rotate_reset_button')), findsNothing);
    await tester.tap(find.byTooltip('Putar Hal 1 (+90°, Klik Kanan -90°)'));
    await tester.pumpAndSettle();
    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);

    // ------------------------------------------------------------------
    // 3. Reorder Pool (Inherits Split Pool Hal 1=90°, persists across Reorder & Undo 1x)
    // ------------------------------------------------------------------
    await tester.tap(find.text('Split Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder Pool').last);
    await tester.pumpAndSettle();

    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);
    expect(find.text('Reset 0° (1)'), findsOneWidget);

    // Reverse order -> Pos #3 • Hal 1 STILL carries 90° rotation
    await tester.tap(find.byKey(const Key('reorder_reverse_button')));
    await tester.pumpAndSettle();
    expect(find.text('Pos #3 • Hal 1'), findsOneWidget);
    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);

    // Rotate Hal 3 (+90°), then Undo 1x order -> both Hal 1 & Hal 3 keep their 90° rotations
    await tester.tap(find.byTooltip('Putar Hal 3 (+90°, Klik Kanan -90°)'));
    await tester.pumpAndSettle();
    expect(find.text('Reset 0° (2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reorder_undo_button')));
    await tester.pumpAndSettle();
    expect(find.text('Pos #1 • Hal 1'), findsOneWidget);
    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);
    expect(find.text('A4 (L) • 90° • Hal 3 / 3'), findsOneWidget);

    // Open Zoom in Reorder Pool & rotate Hal 1 +90° -> 180° (tests Reorder + Rotate sync)
    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Posisi 1 / 3 (Hal 1)')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.text('90°')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('pdf_zoom_rotate_right_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('180°')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.text('A4 • 180° • Hal 1 / 3'), findsOneWidget);

    // ------------------------------------------------------------------
    // 4. Merge Pool (Inherits Reorder Hal 1=180°, Hal 3=90°; Individual + Hasil Merge + Zoom)
    // ------------------------------------------------------------------
    await tester.tap(find.text('Reorder Pool').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Merge Pool').last);
    await tester.pumpAndSettle();

    // Inherited queue item #1 (doc_a.pdf): Hal 1 = 180°, Hal 3 = 90°, Reset 0° (2)
    expect(find.text('A4 • 180° • Hal 1 / 3'), findsOneWidget);
    expect(find.text('A4 (L) • 90° • Hal 3 / 3'), findsOneWidget);
    expect(find.text('Reset 0° (2)'), findsOneWidget);

    // Switch to #2 doc_b.pdf chip, rotate Hal 1 (+90°) on card, then Hal 2 (+90°) via Zoom
    await tester.tap(find.textContaining('doc_b.pdf').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Putar Kanan Hal 1 (+90°)'));
    await tester.pumpAndSettle();
    expect(find.text('A4 (L) • 90° • Hal 1 / 3'), findsOneWidget);
    expect(find.text('Reset 0° (1)'), findsOneWidget);

    await tester.tap(find.text('Zoom').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Berikutnya')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pdf_zoom_rotate_right_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('90°')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.text('Reset 0° (2)'), findsOneWidget);

    // Switch to combined 'Hasil Merge' mode -> 4 rotated pages total across queue
    await tester.tap(find.textContaining('Hasil Merge'));
    await tester.pumpAndSettle();
    expect(find.text('Reset 0° (4)'), findsOneWidget);
    expect(find.text('A4 • 180° • Hal 1 / 6'), findsOneWidget);

    // Rotate 'Akhir Merge • Hal 6' directly (+90°) -> 5 rotated pages
    await tester.tap(find.byTooltip('Putar Kanan Hal 6 (+90°)'));
    await tester.pumpAndSettle();
    expect(find.text('A4 (L) • 90° • Hal 6 / 6'), findsOneWidget);
    expect(find.text('Reset 0° (5)'), findsOneWidget);

    // Open Zoom inside Hasil Merge, step to global page 5 (doc_b Hal 2, currently 90°) & rotate +90° -> 180°
    await tester.tap(find.text('Zoom').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Halaman 6 dari 6')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.text('90°')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Sebelumnya')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: zoomFinder,
        matching: find.textContaining('#2 doc_b.pdf (Hal Asli 2/3)'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('pdf_zoom_rotate_right_button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: zoomFinder,
        matching: find.textContaining('Putar 180°'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();

    // Reset all queue rotations inside Hasil Merge -> all 0°, Reset button hides
    await tester.tap(find.byKey(const Key('merge_rotate_reset_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('merge_rotate_reset_button')), findsNothing);
    expect(find.text('A4 • Hal 1 / 6'), findsOneWidget);
    expect(find.text('A4 • Hal 6 / 6'), findsOneWidget);
  });

  testWidgets('Upscale AI shows manual integer scale input beside each Model AI and sends custom scale',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    BackendCompressTestRequest? capturedReq;
    final prevHandler = BackendService().testCompressHandler;
    BackendService().testCompressHandler = (req) async {
      capturedReq = req;
      return prevHandler!(req);
    };

    final appState = AppStateService();
    appState.addUpscaleFiles(['sample_art.png']);

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    await tester.tap(find.text('Upscale AI'));
    await tester.pumpAndSettle();

    expect(find.text('Model AI'), findsOneWidget);
    expect(find.byKey(const Key('ai_model_selected_scale_input')), findsOneWidget);

    // Default scale uses uniform defaultUpscaleScale (4) without parsing model name
    expect(appState.upscaleModel, equals('realesr-animevideov3-x2'));
    expect(appState.upscaleScale, equals(4));

    // Edit selected model's inline scale box directly to 6
    await tester.enterText(
      find.byKey(const Key('ai_model_selected_scale_input')),
      '6',
    );
    await tester.pumpAndSettle();
    expect(appState.upscaleScale, equals(6));

    // Open Model AI dropdown -> each Model AI name has an integer scale input box on its right
    await tester.tap(find.byKey(const Key('ai_model_dropdown_trigger')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_model_popup_menu')), findsOneWidget);
    for (final model in appState.availableUpscaleModels) {
      expect(find.byKey(Key('ai_model_option_$model')), findsOneWidget);
      expect(find.byKey(Key('ai_model_scale_input_$model')), findsOneWidget);
    }

    // Editing scale box next to realesrgan-x4plus keeps popup open and saves scale 3
    await tester.enterText(
      find.byKey(const Key('ai_model_scale_input_realesrgan-x4plus')),
      '3',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_model_popup_menu')), findsOneWidget);
    expect(appState.getScaleForUpscaleModel('realesrgan-x4plus'), equals(3));

    // Select realesrgan-x4plus row -> closes menu and activates model + manual scale 3
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('ai_model_option_realesrgan-x4plus')),
        matching: find.text('realesrgan-x4plus'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_model_popup_menu')), findsNothing);
    expect(appState.upscaleModel, equals('realesrgan-x4plus'));
    expect(appState.upscaleScale, equals(3));

    // Trigger Mulai Proses and confirm BackendService receives model & custom integer scale
    await tester.tap(find.text('Mulai Proses'));
    await tester.pumpAndSettle();

    expect(capturedReq, isNotNull);
    expect(capturedReq!.action, equals('upscale_ai'));
    expect(capturedReq!.model, equals('realesrgan-x4plus'));
    expect(capturedReq!.scale, equals(3));

    // Close save dialog cleanly
    await tester.tap(find.text('Batal').last);
    await tester.pumpAndSettle();
  });

  testWidgets('Modern bottom AppToast appears non-obstructively after completion, shows folder action, and dismisses via close button',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final appState = AppStateService();
    appState.setSaveLocationMode(SaveLocationMode.autoDefaultFolder);
    appState.setOutputDirectory(r'C:\Users\ACER\Downloads\MediaWorkflow_Output');
    appState.setConvertOnlyFormat('DOCX');
    appState.addConvertOnlyFiles(['FOKBI.pdf']);

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // Run Convert Only directly to auto default folder
    await tester.tap(find.text('Mulai Proses'));
    await tester.pumpAndSettle();

    // Verify modern floating toast card renders with title, badge, folder chip & action buttons
    final toastFinder = find.byKey(const Key('app_toast_card'));
    expect(toastFinder, findsOneWidget);
    expect(find.text('Konversi Berhasil'), findsOneWidget);
    expect(find.text('DOCX'), findsWidgets);
    expect(find.byKey(const Key('app_toast_folder_path')), findsOneWidget);
    expect(find.text(r'C:\Users\ACER\Downloads\MediaWorkflow_Output'), findsOneWidget);
    expect(find.byKey(const Key('app_toast_open_folder_button')), findsOneWidget);
    expect(find.text('Buka Folder'), findsOneWidget);
    expect(find.byKey(const Key('app_toast_close_button')), findsOneWidget);

    // Verify bottom-right placement does NOT overlap centered action buttons ('Mulai Proses' / 'Batal')
    final toastRect = tester.getRect(toastFinder);
    final mulaiRect = tester.getRect(
      find.ancestor(
        of: find.text('Mulai Proses'),
        matching: find.byType(ElevatedButton),
      ),
    );
    final batalRect = tester.getRect(
      find.ancestor(
        of: find.text('Batal'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(
      toastRect.overlaps(mulaiRect),
      isFalse,
      reason: 'toast=$toastRect vs mulai=$mulaiRect',
    );
    expect(
      toastRect.overlaps(batalRect),
      isFalse,
      reason: 'toast=$toastRect vs batal=$batalRect',
    );

    // Clicking Close (X) dismisses the toast cleanly
    await tester.tap(find.byKey(const Key('app_toast_close_button')));
    await tester.pumpAndSettle();
    expect(toastFinder, findsNothing);

    // Also verify all toast variants render cleanly at narrow desktop / dialog sizes without overflow
    final scaffoldCtx = tester.element(find.byType(Scaffold));
    AppToast.showInfo(scaffoldCtx, title: 'Info Uji', message: 'Notifikasi informasi');
    await tester.pumpAndSettle();
    expect(find.text('Info Uji'), findsOneWidget);

    AppToast.showWarning(scaffoldCtx, title: 'Peringatan Uji', message: 'Notifikasi peringatan');
    await tester.pumpAndSettle();
    expect(find.text('Peringatan Uji'), findsOneWidget);
    expect(find.text('Info Uji'), findsNothing);

    AppToast.showError(scaffoldCtx, title: 'Error Uji', message: 'Notifikasi galat');
    await tester.pumpAndSettle();
    expect(find.text('Error Uji'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app_toast_close_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app_toast_card')), findsNothing);
  });

  testWidgets(
      'Media Tools (Convert Only, Compress & Convert, Upscale AI) displays PDF page counts, opens Zoom preview, and leaves non-PDF rows plain',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() {
      PdfPageZoomDialog.dismissActive();
      PdfRenderService().clearTestOverrides();
      PdfRenderService().clearAllCaches();
    });

    final tempDir = Directory.systemTemp.createTempSync('media_pdf_pages_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final jurnalFile =
        File('${tempDir.path}${Platform.pathSeparator}jurnal1.pdf');
    final laporanFile =
        File('${tempDir.path}${Platform.pathSeparator}laporan_12hal.pdf');
    final upscalePdfFile =
        File('${tempDir.path}${Platform.pathSeparator}draft_upscale.pdf');

    jurnalFile.writeAsBytesSync(_buildSyntheticPdfBytes(31));
    laporanFile
        .writeAsBytesSync(_buildSyntheticPdfBytes(12, compressedObjStm: true));
    upscalePdfFile.writeAsBytesSync(_buildSyntheticPdfBytes(5));

    final renderService = PdfRenderService();
    await tester.runAsync(() async {
      renderService.putTestRenderedPage(
        filePath: jurnalFile.path,
        pageNumber: 1,
        quality: PdfRenderQuality.zoom,
        image: await _createTestRenderedImage(411, 580, Colors.indigo),
      );
      renderService.putTestRenderedPage(
        filePath: jurnalFile.path,
        pageNumber: 2,
        quality: PdfRenderQuality.zoom,
        image: await _createTestRenderedImage(412, 580, Colors.teal),
      );
    });

    final appState = AppStateService();
    appState.addConvertOnlyEntries([
      MediaFileEntry(
        name: 'jurnal1.pdf',
        path: jurnalFile.path,
        sizeBytes: 15640000,
      ),
      const MediaFileEntry(
        name: 'dokumen.docx',
        path: r'C:\nonexistent\dokumen.docx',
        sizeBytes: 42000,
      ),
    ]);
    appState.addCompressEntries([
      MediaFileEntry(
        name: 'laporan_12hal.pdf',
        path: laporanFile.path,
        sizeBytes: 850000,
      ),
      const MediaFileEntry(
        name: 'foto.png',
        path: r'C:\nonexistent\foto.png',
        sizeBytes: 310000,
      ),
    ]);
    appState.addUpscaleEntries([
      MediaFileEntry(
        name: 'draft_upscale.pdf',
        path: upscalePdfFile.path,
        sizeBytes: 512000,
      ),
      const MediaFileEntry(
        name: 'anime.png',
        path: r'C:\nonexistent\anime.png',
        sizeBytes: 240000,
      ),
    ]);

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // ------------------------------------------------------------------
    // 1. Convert Only: PDF row shows 31 Halaman + Zoom; DOCX stays plain
    // ------------------------------------------------------------------
    expect(find.byKey(const Key('media_file_page_badge_0')), findsOneWidget);
    expect(find.text('31 Halaman'), findsOneWidget);
    expect(find.byKey(const Key('media_file_zoom_button_0')), findsOneWidget);
    expect(find.byKey(const Key('media_file_page_badge_1')), findsNothing);
    expect(find.byKey(const Key('media_file_zoom_button_1')), findsNothing);

    // Clicking the PDF row directly opens PdfPageZoomDialog (enableRotate: false)
    await tester.tap(find.byKey(const Key('media_file_item_0')));
    await tester.pumpAndSettle();

    final zoomFinder = find.byType(PdfPageZoomDialog);
    expect(zoomFinder, findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Halaman 1 dari 31')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: zoomFinder,
        matching: find.textContaining('Convert Only'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pdf_zoom_rotate_left_button')), findsNothing);
    expect(find.byKey(const Key('pdf_zoom_rotate_right_button')), findsNothing);
    expect(find.byKey(const Key('pdf_zoom_rotate_reset_button')), findsNothing);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .map((r) => r.image?.width),
      contains(411),
    );

    // Step to Page 2 via Berikutnya
    await tester.tap(
      find.descendant(of: zoomFinder, matching: find.text('Berikutnya')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: zoomFinder, matching: find.text('Halaman 2 dari 31')),
      findsOneWidget,
    );
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .map((r) => r.image?.width),
      contains(412),
    );

    // Standalone quick page-jump strip jumps directly to Hal 5
    await tester
        .tap(find.byKey(const Key('pdf_zoom_standalone_page_picker_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: zoomFinder, matching: find.text('Hal 5')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('pdf_zoom_standalone_page_picker_button')),
        matching: find.text('Halaman 5 dari 31'),
      ),
      findsOneWidget,
    );

    // Close via Tutup button
    await tester.tap(find.descendant(of: zoomFinder, matching: find.text('Tutup')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);

    // Clicking the dedicated Zoom pill also opens PdfPageZoomDialog
    await tester.tap(find.byKey(const Key('media_file_zoom_button_0')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsOneWidget);
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);

    // Clicking X remove button removes jurnal1.pdf WITHOUT opening Zoom dialog
    await tester.tap(find.byKey(const Key('media_file_remove_button_0')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);
    expect(find.text('jurnal1.pdf'), findsNothing);
    expect(find.text('dokumen.docx'), findsOneWidget);

    // ------------------------------------------------------------------
    // 2. Compress & Convert: /ObjStm PDF shows 12 Halaman; PNG stays plain
    // ------------------------------------------------------------------
    await tester.tap(find.text('Compress & Convert'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media_file_page_badge_0')), findsOneWidget);
    expect(find.text('12 Halaman'), findsOneWidget);
    expect(find.byKey(const Key('media_file_zoom_button_0')), findsOneWidget);
    expect(find.byKey(const Key('media_file_page_badge_1')), findsNothing);
    expect(find.byKey(const Key('media_file_zoom_button_1')), findsNothing);

    await tester.tap(find.byKey(const Key('media_file_zoom_button_0')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('pdf_zoom_standalone_page_picker_button')),
        matching: find.text('Halaman 1 dari 12'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: zoomFinder,
        matching: find.textContaining('Compress & Convert'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pdf_zoom_rotate_right_button')), findsNothing);

    // Minimize Zoom, then delete laporan_12hal.pdf -> docked overlay auto-dismisses
    await tester.tap(find.byTooltip('Minimize Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.textContaining('(Diminimize)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('media_file_remove_button_0')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);
    expect(find.textContaining('(Diminimize)'), findsNothing);
    expect(find.text('foto.png'), findsOneWidget);

    // ------------------------------------------------------------------
    // 3. Upscale AI: PDF shows 5 Halaman + Zoom; PNG stays plain
    // ------------------------------------------------------------------
    await tester.tap(find.text('Upscale AI'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media_file_page_badge_0')), findsOneWidget);
    expect(find.text('5 Halaman'), findsOneWidget);
    expect(find.byKey(const Key('media_file_zoom_button_0')), findsOneWidget);
    expect(find.byKey(const Key('media_file_page_badge_1')), findsNothing);
    expect(find.byKey(const Key('media_file_zoom_button_1')), findsNothing);

    await tester.tap(find.byKey(const Key('media_file_item_0')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('pdf_zoom_standalone_page_picker_button')),
        matching: find.text('Halaman 1 dari 5'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: zoomFinder,
        matching: find.textContaining('Upscale AI'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pdf_zoom_rotate_left_button')), findsNothing);

    await tester.tap(find.descendant(of: zoomFinder, matching: find.text('Tutup')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);
  });

  testWidgets(
      'Media Tools (Convert Only, Compress & Convert, Upscale AI) allows zooming images like PDFs across all file boxes',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() {
      PdfPageZoomDialog.dismissActive();
      PdfRenderService().clearTestOverrides();
      PdfRenderService().clearAllCaches();
      PaintingBinding.instance.imageCache.clear();
    });

    final tempDir = Directory.systemTemp.createTempSync('media_image_zoom_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<File> writeRealPng(String name, int width, int height, Color color) async {
      final img = await _createTestRenderedImage(width, height, color);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      final file = File('${tempDir.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(data!.buffer.asUint8List());
      return file;
    }

    late final File pdfFile;
    late final File landscapeImgFile;
    late final File portraitImgFile;
    late final File squareImgFile;

    await tester.runAsync(() async {
      pdfFile = File('${tempDir.path}${Platform.pathSeparator}jurnal1.pdf');
      pdfFile.writeAsBytesSync(_buildSyntheticPdfBytes(10));
      landscapeImgFile = await writeRealPng('cover_photo.png', 800, 500, Colors.orange);
      portraitImgFile = await writeRealPng('poster_400x600.png', 400, 600, Colors.purple);
      squareImgFile = await writeRealPng('hero_art.png', 640, 640, Colors.cyan);
    });

    Future<void> pumpUntilImageZoomLoaded(WidgetTester tester) async {
      await tester.pump();
      for (int i = 0; i < 40; i++) {
        if (find.byKey(const Key('image_zoom_raw_image')).evaluate().isNotEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    expect(
      const MediaFileEntry(name: 'bleach.JPEG', path: r'C:\tmp\bleach.JPEG').isImage,
      isTrue,
    );
    expect(
      const MediaFileEntry(name: 'photo.webp', path: r'C:\tmp\photo.webp').isImage,
      isTrue,
    );
    expect(
      const MediaFileEntry(name: 'report.docx', path: r'C:\tmp\report.docx').isImage,
      isFalse,
    );

    final appState = AppStateService();
    appState.addConvertOnlyEntries([
      MediaFileEntry(name: 'jurnal1.pdf', path: pdfFile.path, sizeBytes: 4096),
      MediaFileEntry(name: 'cover_photo.png', path: landscapeImgFile.path),
      const MediaFileEntry(
        name: 'dokumen.docx',
        path: r'C:\nonexistent\dokumen.docx',
        sizeBytes: 12000,
      ),
    ]);
    appState.addCompressEntries([
      MediaFileEntry(name: 'poster_400x600.png', path: portraitImgFile.path, sizeBytes: 9700),
    ]);
    appState.addUpscaleEntries([
      MediaFileEntry(name: 'hero_art.png', path: squareImgFile.path, sizeBytes: 14500),
    ]);

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // ------------------------------------------------------------------
    // 1. Convert Only: PDF has badge+Zoom, PNG image has Zoom (no page badge), DOCX plain
    // ------------------------------------------------------------------
    expect(find.byKey(const Key('media_file_page_badge_0')), findsOneWidget);
    expect(find.byKey(const Key('media_file_zoom_button_0')), findsOneWidget);
    expect(find.byKey(const Key('media_file_page_badge_1')), findsNothing);
    expect(find.byKey(const Key('media_file_zoom_button_1')), findsOneWidget);
    expect(find.byKey(const Key('media_file_page_badge_2')), findsNothing);
    expect(find.byKey(const Key('media_file_zoom_button_2')), findsNothing);

    // Click the image row itself -> opens PdfPageZoomDialog in image mode
    await tester.tap(find.byKey(const Key('media_file_item_1')));
    await pumpUntilImageZoomLoaded(tester);

    final zoomFinder = find.byType(PdfPageZoomDialog);
    expect(zoomFinder, findsOneWidget);
    expect(find.byKey(const Key('image_zoom_raw_image')), findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.textContaining('Convert Only')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: zoomFinder, matching: find.textContaining('800×500 px')),
      findsWidgets,
    );
    expect(find.text('Pratinjau Gambar • 800×500 px'), findsOneWidget);
    expect(find.byKey(const Key('pdf_zoom_rotate_left_button')), findsNothing);
    expect(find.text('Sebelumnya'), findsNothing);
    expect(find.text('Berikutnya'), findsNothing);

    final rawImageWidget =
        tester.widget<RawImage>(find.byKey(const Key('image_zoom_raw_image')));
    expect(rawImageWidget.image?.width, equals(800));
    expect(rawImageWidget.image?.height, equals(500));

    final landscapeSize100 = tester.getSize(find.byKey(const Key('image_zoom_raw_image')));
    expect(landscapeSize100.width, greaterThan(landscapeSize100.height));

    // Zoom In (+) updates zoom to 120% & scales image larger, then reset to 100%
    await tester.tap(find.byTooltip('Perbesar (+ atau Ctrl + Scroll Depan)'));
    await tester.pumpAndSettle();
    expect(find.text('120%'), findsOneWidget);
    final landscapeSize120 = tester.getSize(find.byKey(const Key('image_zoom_raw_image')));
    expect(landscapeSize120.width, greaterThan(landscapeSize100.width));

    await tester.tap(find.text('120%'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    // Minimize -> shows dock bar with dimensions & %, then restore -> close via Tutup
    await tester.tap(find.byTooltip('Minimize Pratinjau'));
    await tester.pumpAndSettle();
    expect(find.textContaining('800×500 px • 100% (Diminimize)'), findsOneWidget);

    await tester.tap(find.byTooltip('Pulihkan Pratinjau'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: zoomFinder, matching: find.text('Tutup')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);

    // Clicking red X removes image without opening Zoom dialog
    await tester.tap(find.byKey(const Key('media_file_remove_button_1')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);
    expect(find.text('cover_photo.png'), findsNothing);

    // ------------------------------------------------------------------
    // 2. Compress & Convert: portrait image opens via Zoom button & auto-dismisses on delete
    // ------------------------------------------------------------------
    await tester.tap(find.text('Compress & Convert'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media_file_zoom_button_0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('media_file_zoom_button_0')));
    await pumpUntilImageZoomLoaded(tester);

    expect(zoomFinder, findsOneWidget);
    expect(find.text('Pratinjau Gambar • 400×600 px'), findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.textContaining('Compress & Convert')),
      findsOneWidget,
    );
    final portraitSize = tester.getSize(find.byKey(const Key('image_zoom_raw_image')));
    expect(portraitSize.height, greaterThan(portraitSize.width));

    await tester.tap(find.byTooltip('Minimize Pratinjau'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('media_file_remove_button_0')));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);
    expect(find.text('poster_400x600.png'), findsNothing);

    // ------------------------------------------------------------------
    // 3. Upscale AI: square image opens Zoom cleanly
    // ------------------------------------------------------------------
    await tester.tap(find.text('Upscale AI'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media_file_zoom_button_0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('media_file_item_0')));
    await pumpUntilImageZoomLoaded(tester);

    expect(zoomFinder, findsOneWidget);
    expect(find.text('Pratinjau Gambar • 640×640 px'), findsOneWidget);
    expect(
      find.descendant(of: zoomFinder, matching: find.textContaining('Upscale AI')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Tutup Pratinjau'));
    await tester.pumpAndSettle();
    expect(zoomFinder, findsNothing);
  });

  testWidgets(
      'Custom dark WindowTitleBar & Sidebar replace Flutter/code chrome with Media Workflow X branding',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => WindowControlService().resetForTest());

    final recordedActions = <String>[];
    WindowControlService().resetForTest();
    WindowControlService().testActionObserver = (action, [arg]) {
      recordedActions.add(arg != null ? '$action:$arg' : action);
    };

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // 1. Custom WindowTitleBar renders cleanly with logo asset, name & caption controls
    final titleBarFinder = find.byType(WindowTitleBar);
    expect(titleBarFinder, findsOneWidget);
    expect(find.byKey(const Key('titlebar_brand_logo')), findsOneWidget);
    expect(find.byKey(const Key('sidebar_brand_logo')), findsOneWidget);
    expect(find.byIcon(Icons.code), findsNothing);
    expect(
      find.descendant(
        of: titleBarFinder,
        matching: find.text('Media Workflow X'),
      ),
      findsOneWidget,
    );
    expect(find.text('Desktop Studio'), findsOneWidget);
    expect(find.text('MEDIA & PDF SUITE'), findsOneWidget);
    expect(find.text('frontend'), findsNothing);

    // Confirm both logo images reference assets/images/media_workflow_x.png
    final brandImages =
        tester.widgetList<Image>(find.byType(Image)).where((img) {
      final provider = img.image;
      return provider is AssetImage &&
          provider.assetName == AppBrandLogo.assetPath;
    }).toList();
    expect(brandImages.length, equals(2));

    // Confirm Sidebar logo sits visually above 'Dasboard'
    final sidebarLogoTop =
        tester.getTopLeft(find.byKey(const Key('sidebar_brand_logo'))).dy;
    final dasboardTop = tester.getTopLeft(find.text('Dasboard')).dy;
    expect(sidebarLogoTop, lessThan(dasboardTop));

    // 2. Test caption button actions (Minimize, Maximize/Restore toggle, Drag, Close)
    await tester.tap(find.byKey(const Key('window_minimize_button')));
    await tester.pumpAndSettle();
    expect(recordedActions, contains('minimize'));

    expect(find.byTooltip('Maximize'), findsOneWidget);
    await tester.tap(find.byKey(const Key('window_maximize_button')));
    await tester.pumpAndSettle();
    expect(recordedActions, contains('toggleMaximize'));
    expect(WindowControlService().isMaximized.value, isTrue);
    expect(find.byTooltip('Restore Down'), findsOneWidget);

    // Dragging titlebar starts native window drag
    await tester.drag(
      find.byKey(const Key('window_titlebar_drag_area')),
      const Offset(40, 12),
    );
    await tester.pumpAndSettle();
    expect(recordedActions, contains('startDragging'));

    // Closing triggers native close
    await tester.tap(find.byKey(const Key('window_close_button')));
    await tester.pumpAndSettle();
    expect(recordedActions, contains('close'));
  });

  testWidgets(
      'Split Separate Pool counts selected pages across all slots, preserves per-file output names, groups in Save popup, and saves flat to chosen folder',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final tempDir = Directory.systemTemp.createTempSync('split_sep_ui_test_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    final jurnalFile =
        File('${tempDir.path}${Platform.pathSeparator}jurnal1.pdf');
    final file2File =
        File('${tempDir.path}${Platform.pathSeparator}file2.pdf');
    final destDir = Directory('${tempDir.path}${Platform.pathSeparator}out');
    jurnalFile.writeAsBytesSync(_buildSyntheticPdfBytes(4));
    file2File.writeAsBytesSync(_buildSyntheticPdfBytes(2));

    // Override testWorkflowHandler for this test so Split Separate outputs match real grouped BackendService contract
    BackendService().testWorkflowHandler = (req) async {
      final stagedDir =
          Directory('${tempDir.path}${Platform.pathSeparator}staged_ui')
            ..createSync(recursive: true);
      final stageJ1 =
          File('${stagedDir.path}${Platform.pathSeparator}j1_p1.pdf')
            ..writeAsBytesSync(utf8.encode('J1_P1'));
      final stageJ2 =
          File('${stagedDir.path}${Platform.pathSeparator}j1_p2.pdf')
            ..writeAsBytesSync(utf8.encode('J1_P2'));
      final stageF2 =
          File('${stagedDir.path}${Platform.pathSeparator}f2_p2.pdf')
            ..writeAsBytesSync(utf8.encode('F2_P2'));
      return BackendBatchResult(
        stagingDirPath: stagedDir.path,
        files: [
          BackendStagedFile(
            sourceFileName: 'jurnal1_p1.pdf',
            stagedFilePath: stageJ1.path,
            suggestedFileName: 'jurnal1_${req.outputSuffix}_p1.pdf',
            groupFileName: 'jurnal1.pdf',
            originalBytes: 14900000,
            resultBytes: 248100,
            durationMs: 120,
            engineUsed: 'PDF Manager Core + QPDF',
            targetFormat: 'PDF',
          ),
          BackendStagedFile(
            sourceFileName: 'jurnal1_p2.pdf',
            stagedFilePath: stageJ2.path,
            suggestedFileName: 'jurnal1_${req.outputSuffix}_p2.pdf',
            groupFileName: 'jurnal1.pdf',
            originalBytes: 14900000,
            resultBytes: 139800,
            durationMs: 120,
            engineUsed: 'PDF Manager Core + QPDF',
            targetFormat: 'PDF',
          ),
          BackendStagedFile(
            sourceFileName: 'file2_p2.pdf',
            stagedFilePath: stageF2.path,
            suggestedFileName: 'file2_${req.outputSuffix}_p2.pdf',
            groupFileName: 'file2.pdf',
            originalBytes: 8500000,
            resultBytes: 4220000,
            durationMs: 120,
            engineUsed: 'PDF Manager Core + QPDF',
            targetFormat: 'PDF',
          ),
        ],
      );
    };

    final appState = AppStateService();
    appState.setSaveLocationMode(SaveLocationMode.askEveryTime);
    appState.pdfPools[0].title = 'Split Separate Pool';
    appState.pdfPools[0].slots = [
      PoolSlot(
        id: 'sep_s1',
        label: 'Split 1-2',
        fileName: 'jurnal1.pdf',
        filePath: jurnalFile.path,
        pageCount: 4,
        pageRange: '1-2',
      ),
      PoolSlot(
        id: 'sep_s2',
        label: 'Split 2',
        fileName: 'file2.pdf',
        filePath: file2File.path,
        pageCount: 2,
        pageRange: '2',
      ),
    ];

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    // Open Slot 2 ('file2.pdf', only 1 page selected) inside Split Separate Pool
    await tester.tap(find.text('file2.pdf'));
    await tester.pump();
    for (int i = 0; i < 30; i++) {
      if (PdfInspectorService().getCached('file2.pdf', file2File.path) != null) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('Split Separate Pool'), findsOneWidget);

    // Execute Split PDF while active slot is file2.pdf -> counts all 3 pages (2 from jurnal1 + 1 from file2)!
    await tester.tap(find.text('Split PDF'));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    expect(
      find.text('Split Separate Pool (Mode: Pages (3 halaman dipilih))'),
      findsOneWidget,
    );
    expect(find.text('File Hasil Siap Disimpan (3):'), findsOneWidget);

    // Group headers appear by original file name
    expect(find.byKey(const Key('save_file_group_header_0')), findsOneWidget);
    expect(find.byKey(const Key('save_file_group_header_1')), findsOneWidget);
    expect(find.text('2 file'), findsOneWidget);
    expect(find.text('1 file'), findsOneWidget);

    // Verify all 3 editable fields carry their true original filename stems!
    final field0 = tester.widget<TextField>(
      find.byKey(const Key('save_file_name_field_0')),
    );
    final field1 = tester.widget<TextField>(
      find.byKey(const Key('save_file_name_field_1')),
    );
    final field2 = tester.widget<TextField>(
      find.byKey(const Key('save_file_name_field_2')),
    );
    expect(field0.controller?.text, equals('jurnal1_split_p1.pdf'));
    expect(field1.controller?.text, equals('jurnal1_split_p2.pdf'));
    expect(field2.controller?.text, equals('file2_split_p2.pdf'));

    // Save into single destination folder (flat, no subfolders!)
    await tester.enterText(
      find.byKey(const Key('save_folder_path_field')),
      destDir.path,
    );
    await tester.tap(find.text('Simpan di Folder Ini'));
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
      if (File('${destDir.path}${Platform.pathSeparator}file2_split_p2.pdf')
          .existsSync()) {
        break;
      }
    }
    await tester.pumpAndSettle();

    expect(
      File('${destDir.path}${Platform.pathSeparator}jurnal1_split_p1.pdf')
          .existsSync(),
      isTrue,
    );
    expect(
      File('${destDir.path}${Platform.pathSeparator}jurnal1_split_p2.pdf')
          .existsSync(),
      isTrue,
    );
    expect(
      File('${destDir.path}${Platform.pathSeparator}file2_split_p2.pdf')
          .existsSync(),
      isTrue,
    );
    // Verify no per-file subfolders were created
    expect(destDir.listSync().whereType<Directory>(), isEmpty);
  });

  testWidgets(
      'Logs & History starts clean without dummy files and folder icon opens exact output location',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final appState = AppStateService();
    appState.resetAll();
    final backend = BackendService();
    backend.resetTestOverrides();
    addTearDown(() => backend.resetTestOverrides());

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // Navigate to Logs & History
    await tester.tap(find.text('Logs & History'));
    await tester.pumpAndSettle();

    // Dummy sample history files & logs must not exist initially
    expect(find.text('Riwayat Tugas (0)'), findsOneWidget);
    expect(find.text('Konsol Log Sistem (0)'), findsOneWidget);
    expect(find.text('Laporan_Tahunan_Media_2026.docx'), findsNothing);
    expect(find.text('Draft_Kontrak_Kerja_Sama.pdf'), findsNothing);
    expect(find.text('Banner_Promosi_UltraHD.png'), findsNothing);
    expect(find.text('Bundle_Dokumen_Arsip.pdf'), findsNothing);
    expect(find.text('Belum ada riwayat tugas yang sesuai'), findsOneWidget);

    await tester.tap(find.text('Konsol Log Sistem (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Konsol log sistem kosong.'), findsOneWidget);

    // Return to Riwayat Tugas tab and add a real completed task
    await tester.tap(find.text('Riwayat Tugas (0)'));
    await tester.pumpAndSettle();

    const expectedPath =
        r'C:\Users\ACER\Downloads\MediaWorkflow_Output\bleach_upscaled.jpeg';
    final openedPaths = <String>[];
    backend.testOpenInExplorerHandler = (path) async {
      openedPaths.add(path);
      return true;
    };

    appState.addTaskHistory(
      taskType: 'Upscale AI',
      fileName: 'bleach_upscaled.jpeg',
      targetFormat: 'JPEG',
      engineUsed: 'realesr-animevideov3-x2',
      status: 'Sukses',
      durationMs: 2824,
      originalSize: '10.5 KB',
      resultSize: '214.7 KB',
      outputPath: expectedPath,
    );
    await tester.pumpAndSettle();

    expect(find.text('Riwayat Tugas (1)'), findsOneWidget);
    expect(find.text('bleach_upscaled.jpeg'), findsOneWidget);

    // Clicking the folder icon calls openInExplorer with the saved file path and does not emit fallback toast
    await tester.tap(find.byIcon(Icons.folder_open_outlined));
    await tester.pumpAndSettle();

    expect(openedPaths, equals([expectedPath]));
    expect(find.text('Lokasi Output File'), findsNothing);
  });

  testWidgets(
      'StatusProgressBar renders informative states, live runtime counter, and freezes total runtime cleanly',
      (WidgetTester tester) async {
    expect(
      StatusProgressBar.formatRuntime(Duration.zero, isProcessing: false),
      equals('0.0s'),
    );
    expect(
      StatusProgressBar.formatRuntime(
        const Duration(milliseconds: 420),
        isProcessing: false,
      ),
      equals('0.42s'),
    );
    expect(
      StatusProgressBar.formatRuntime(
        const Duration(milliseconds: 420),
        isProcessing: true,
      ),
      equals('0.4s'),
    );
    expect(
      StatusProgressBar.formatRuntime(
        const Duration(milliseconds: 65400),
        isProcessing: false,
      ),
      equals('1m 05.4s'),
    );

    bool isProcessing = false;
    double progress = 0.0;
    int completedItems = 0;
    int totalItems = 0;
    bool hasError = false;
    bool wasCancelled = false;
    late StateSetter setHostState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF071924),
          body: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return Padding(
                padding: const EdgeInsets.all(16),
                child: StatusProgressBar(
                  isProcessing: isProcessing,
                  progress: progress,
                  stageLabel: 'CONVERT ONLY',
                  detailText: 'PDF • Microsoft Word (COM)',
                  completedItems: completedItems,
                  totalItems: totalItems,
                  idleMessage: 'Pilih file untuk memulai konversi',
                  processingMessage: 'Mengonversi skripsi.docx...',
                  completedMessage: '1 file output selesai dikonversi ke PDF',
                  hasError: hasError,
                  errorMessage: 'Kegagalan konversi uji',
                  wasCancelled: wasCancelled,
                  cancelledMessage: 'Proses dibatalkan oleh pengguna.',
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Idle state
    expect(find.byKey(const Key('status_progress_badge_text')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_badge_text')))
          .data,
      equals('SIAP'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_percent_text')))
          .data,
      equals('0%'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_runtime_text')))
          .data,
      equals('Runtime: 0.0s'),
    );

    // 2. Transition to Processing -> live timer ticks cleanly across fake clock pumps
    setHostState(() {
      isProcessing = true;
      progress = 0.45;
      completedItems = 1;
      totalItems = 3;
    });
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_badge_text')))
          .data,
      equals('MEMPROSES'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_percent_text')))
          .data,
      equals('45%'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_items_text')))
          .data,
      equals('1/3 file'),
    );

    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_runtime_text')))
          .data,
      equals('Runtime: 0.5s'),
    );

    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_runtime_text')))
          .data,
      equals('Runtime: 1.2s'),
    );

    // 3. Transition to Completed -> stops all repeating timers/animations and freezes runtime at 1.2s
    setHostState(() {
      isProcessing = false;
      progress = 1.0;
      completedItems = 3;
    });
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_badge_text')))
          .data,
      equals('SELESAI'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_percent_text')))
          .data,
      equals('100%'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_items_text')))
          .data,
      equals('3/3 file'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_runtime_text')))
          .data,
      equals('Runtime: 1.2s'),
    );

    // 4. Cancelled & Error states
    setHostState(() {
      progress = 0.4;
      wasCancelled = true;
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_badge_text')))
          .data,
      equals('DIBATALKAN'),
    );

    setHostState(() {
      wasCancelled = false;
      hasError = true;
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('status_progress_badge_text')))
          .data,
      equals('GAGAL'),
    );
  });

  testWidgets(
      'Media Tools and PDF Manager (Overview & Sub-Pool) display modern progress bar and live runtime telemetry',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final tempDir = await Directory.systemTemp.createTemp('mw_progress_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final imgFile = File('${tempDir.path}${Platform.pathSeparator}sample.png')
      ..writeAsBytesSync(const [1, 2, 3, 4]);
    final pdfFile = File('${tempDir.path}${Platform.pathSeparator}doc_test.pdf')
      ..writeAsBytesSync(_buildSyntheticPdfBytes(3));

    final appState = AppStateService();
    appState.resetAll();
    appState.setSaveLocationMode(SaveLocationMode.askEveryTime);

    final backend = BackendService();
    backend.resetTestOverrides();
    addTearDown(() => backend.resetTestOverrides());

    Completer<BackendStagedFile>? convertCompleter;
    backend.testCompressHandler = (req) {
      convertCompleter = Completer<BackendStagedFile>();
      return convertCompleter!.future;
    };

    Completer<BackendBatchResult>? pdfCompleter;
    backend.testWorkflowHandler = (req) {
      pdfCompleter = Completer<BackendBatchResult>();
      return pdfCompleter!.future;
    };

    appState.addConvertOnlyEntries([
      MediaFileEntry(
        name: 'sample.png',
        path: imgFile.path,
        sizeBytes: 4096,
      ),
    ]);

    debugPrint('STEP 1: pumpWidget');
    await tester.pumpWidget(const MediaWorkflowApp());
    await tester.pumpAndSettle();
    debugPrint('STEP 2: settled initial');

    // --- PART A: Media Tools (Convert Only) ---
    final convertBarFinder = find.descendant(
      of: find.byType(ConvertOnlyView),
      matching: find.byType(StatusProgressBar),
    );
    expect(
      find.descendant(of: convertBarFinder, matching: find.text('SIAP')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: convertBarFinder,
        matching: find.text('CONVERT ONLY'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(ConvertOnlyView),
        matching: find.text('Mulai Proses'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      find.descendant(of: convertBarFinder, matching: find.text('MEMPROSES')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: convertBarFinder, matching: find.text('0/1 file')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: convertBarFinder,
        matching: find.text('Runtime: 0.6s'),
      ),
      findsOneWidget,
    );

    debugPrint('STEP 3: complete convert');
    convertCompleter!.complete(
      BackendStagedFile(
        sourceFileName: 'sample.png',
        stagedFilePath: '',
        suggestedFileName: 'sample_converted.png',
        originalBytes: 4096,
        resultBytes: 2048,
        durationMs: 600,
        engineUsed: 'Go Imaging',
        targetFormat: 'PNG',
      ),
    );
    await tester.pumpAndSettle();
    debugPrint('STEP 4: settled save dialog');

    // Save dialog pops up -> cancel dialog and inspect finished StatusProgressBar
    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.tap(find.text('Batal').last);
    await tester.pumpAndSettle();
    debugPrint('STEP 5: settled after cancel dialog');

    expect(
      find.descendant(of: convertBarFinder, matching: find.text('SELESAI')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: convertBarFinder, matching: find.text('100%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: convertBarFinder, matching: find.text('1/1 file')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: convertBarFinder,
        matching: find.textContaining('Runtime:'),
      ),
      findsOneWidget,
    );

    // Idle "Batal" button clears queue and resets StatusProgressBar back to SIAP 0% 0.0s
    await tester.tap(
      find.descendant(
        of: find.byType(ConvertOnlyView),
        matching: find.text('Batal'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: convertBarFinder, matching: find.text('SIAP')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: convertBarFinder, matching: find.text('0%')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: convertBarFinder,
        matching: find.text('Runtime: 0.0s'),
      ),
      findsOneWidget,
    );

    // --- PART B: PDF Manager Overview ---
    appState.pdfPools.first.slots.first
      ..fileName = 'doc_test.pdf'
      ..filePath = pdfFile.path
      ..pageCount = 3
      ..pageRange = '1-2';
    appState.updatePdfInheritedSlots();

    await tester.tap(find.text('PDF Manager'));
    await tester.pumpAndSettle();

    final pdfBarFinder = find.descendant(
      of: find.byType(PdfManagerView),
      matching: find.byType(StatusProgressBar),
    );
    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('PDF MANAGER')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(PdfManagerView),
        matching: find.text('Mulai Proses'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('MEMPROSES')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('0/1 pool')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('Runtime: 0.5s')),
      findsOneWidget,
    );

    pdfCompleter!.complete(
      const BackendBatchResult(
        files: [
          BackendStagedFile(
            sourceFileName: 'doc_test.pdf',
            stagedFilePath: '',
            suggestedFileName: 'doc_test_workflow.pdf',
            originalBytes: 2048,
            resultBytes: 1024,
            durationMs: 500,
            engineUsed: 'PDF Manager Core + QPDF',
            targetFormat: 'PDF',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.tap(find.text('Batal').last);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('SELESAI')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('100%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pdfBarFinder, matching: find.text('1/1 pool')),
      findsOneWidget,
    );

    // --- PART C: PDF Manager Sub-Pool (SplitPoolView) at 1280x720 ---
    debugPrint('STEP 6: tap doc_test.pdf');
    await tester.tap(find.text('doc_test.pdf'));
    await tester.pump();
    for (int i = 0; i < 30; i++) {
      if (PdfInspectorService().getCached('doc_test.pdf', pdfFile.path) != null) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    debugPrint('STEP 7: before split pumpAndSettle');
    await tester.pumpAndSettle();
    debugPrint('STEP 8: after split pumpAndSettle');

    final splitBarFinder = find.descendant(
      of: find.byType(SplitPoolView),
      matching: find.byType(StatusProgressBar),
    );

    await tester.tap(find.text('Split PDF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Compact StatusProgressBar appears cleanly inside SplitPoolView with live runtime & zero overflow
    expect(
      find.descendant(of: splitBarFinder, matching: find.text('MEMPROSES')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: splitBarFinder, matching: find.text('0/1 pool')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: splitBarFinder, matching: find.text('Runtime: 0.4s')),
      findsOneWidget,
    );

    pdfCompleter!.complete(
      const BackendBatchResult(
        files: [
          BackendStagedFile(
            sourceFileName: 'doc_test.pdf',
            stagedFilePath: '',
            suggestedFileName: 'doc_test_split.pdf',
            originalBytes: 2048,
            resultBytes: 1024,
            durationMs: 400,
            engineUsed: 'PDF Manager Core + QPDF',
            targetFormat: 'PDF',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    await tester.tap(find.text('Batal').last);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: splitBarFinder, matching: find.text('SELESAI')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: splitBarFinder, matching: find.text('100%')),
      findsOneWidget,
    );

    // Dismiss compact execution result banner cleanly
    await tester.tap(find.byTooltip('Tutup ringkasan proses'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: splitBarFinder, matching: find.text('SELESAI')),
      findsNothing,
    );
  });
}
