import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/models/pdf_models.dart';
import 'package:frontend/core/services/app_state_service.dart';
import 'package:frontend/core/services/backend_service.dart';
import 'package:frontend/core/services/pdf_inspector_service.dart';
import 'package:frontend/shared/widgets/save_folder_dialog.dart';

Uint8List _buildSyntheticPdfBytes(int pageCount) {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory tempRoot;
  late BackendService backend;
  late AppStateService appState;

  setUp(() {
    appState = AppStateService()..resetAll();
    backend = BackendService()..resetTestOverrides();
    PdfInspectorService().clearCache();
    tempRoot = Directory.systemTemp.createTempSync('mwx_backend_test_');
  });

  tearDown(() {
    backend.resetTestOverrides();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('Bundled engine asset discovery', () {
    test('inspectCapabilities discovers smart_compress_backend.exe, tools, and 5 Real-ESRGAN models', () async {
      final caps = await backend.inspectCapabilities(detectExternalOfficeApps: false);

      expect(caps.engineRootDir, isNotNull);
      expect(caps.hasBackendExe, isTrue, reason: 'smart_compress_backend.exe must be present');
      expect(caps.hasQpdf, isTrue, reason: 'tools/qpdf/bin/qpdf.exe must be present');
      expect(
        caps.hasPdfCompressor,
        isTrue,
        reason: 'tools/pdf_compressor/build/pdf_compressor.exe must be present',
      );
      expect(
        caps.hasRealEsrgan,
        isTrue,
        reason: 'tools/realesrgan/realesrgan-ncnn-vulkan.exe must be present',
      );
      expect(
        caps.realEsrganModels,
        containsAll(BackendService.expectedRealEsrganModels),
      );
      expect(caps.realEsrganModels.length, equals(5));
      expect(caps.hasVisualCppRuntime, isTrue);

      expect(appState.hasQpdf, isTrue);
      expect(appState.hasPdfCompressor, isTrue);
      expect(appState.hasRealEsrgan, isTrue);
      expect(appState.realEsrganModelsCount, equals(5));
      expect(
        appState.availableUpscaleModels,
        containsAll(BackendService.expectedRealEsrganModels),
      );
    });

    test('inspectCapabilities dynamically discovers new .bin/.param models without reading scale from name', () async {
      final fakeEngine = Directory('${tempRoot.path}${Platform.pathSeparator}custom_engine');
      final fakeModels = Directory(
        '${fakeEngine.path}${Platform.pathSeparator}tools${Platform.pathSeparator}realesrgan${Platform.pathSeparator}models',
      );
      await fakeModels.create(recursive: true);
      await File('${fakeModels.path}${Platform.pathSeparator}custom-ultra-x8.bin').writeAsBytes([1]);
      await File('${fakeModels.path}${Platform.pathSeparator}custom-ultra-x8.param').writeAsBytes([1]);
      await File('${fakeModels.path}${Platform.pathSeparator}incomplete-only.bin').writeAsBytes([1]);

      backend.overrideEngineRootDir = fakeEngine.path;
      final caps = await backend.inspectCapabilities(detectExternalOfficeApps: false);

      expect(caps.realEsrganModels, equals(['custom-ultra-x8']));
      expect(appState.availableUpscaleModels, equals(['custom-ultra-x8']));
      expect(appState.upscaleModel, equals('custom-ultra-x8'));
      expect(appState.upscaleScale, equals(BackendService.defaultUpscaleScale));
    });
  });

  group('HTTP /compress integration with ephemeral server', () {
    late HttpServer server;
    late List<Map<String, dynamic>> recordedRequests;
    late Future<Map<String, dynamic>> Function(Map<String, dynamic> body)
        compressHandler;

    setUp(() async {
      recordedRequests = <Map<String, dynamic>>[];
      compressHandler = (body) async {
        final outDir = Directory(body['outputDir'] as String);
        await outDir.create(recursive: true);
        final ext = (body['target_format'] as String? ?? 'png').toLowerCase();
        final outFile = File('${outDir.path}${Platform.pathSeparator}out.$ext');
        await outFile.writeAsBytes([1, 2, 3, 4, 5, 6]);
        return <String, dynamic>{
          'success': true,
          'message': 'Proses berhasil dilaksanakan',
          'files': <String>[outFile.path],
        };
      };

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        if (req.method == 'GET' && req.uri.path == '/compress') {
          req.response.statusCode = HttpStatus.methodNotAllowed;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({'success': false, 'message': 'Method tidak diizinkan'}),
          );
          await req.response.close();
          return;
        }

        final rawBody = await utf8.decoder.bind(req).join();
        final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
        recordedRequests.add(decoded);

        if (req.uri.path == '/compress') {
          final result = await compressHandler(decoded);
          final isOk = result['success'] == true;
          req.response.statusCode = isOk ? HttpStatus.ok : HttpStatus.badRequest;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(result));
          await req.response.close();
          return;
        }

        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      backend.overrideBaseUrl = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('pingHealth succeeds on 405 JSON contract and returns null when unreachable', () async {
      final ms = await backend.pingHealth();
      expect(ms, isNotNull);
      expect(backend.isOnline, isTrue);
      expect(appState.isEngineOnline, isTrue);

      await server.close(force: true);
      final deadMs = await backend.pingHealth(
        timeout: const Duration(milliseconds: 250),
      );
      expect(deadMs, isNull);
    });

    test('compressBatch handles convert_only, convert_compress, upscale_ai, and staging cleanup', () async {
      final sampleImg = File('${tempRoot.path}${Platform.pathSeparator}foto.png');
      await sampleImg.writeAsBytes([10, 20, 30, 40]);

      final samplePdf = File('${tempRoot.path}${Platform.pathSeparator}doc.pdf');
      await samplePdf.writeAsBytes(_buildSyntheticPdfBytes(2));

      // 1. convert_only PNG -> JPG
      final convRes = await backend.compressBatch(
        entries: [
          MediaFileEntry(name: 'foto.png', path: sampleImg.path, sizeBytes: 4),
        ],
        action: 'convert_only',
        targetFormat: 'JPG',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: null,
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext),
      );

      expect(convRes.files.length, equals(1));
      expect(convRes.files.first.suggestedFileName, equals('foto_converted.jpg'));
      expect(File(convRes.files.first.stagedFilePath).existsSync(), isTrue);
      expect(recordedRequests.last['action'], equals('convert_only'));
      expect(recordedRequests.last['target_format'], equals('jpg'));

      final convStaging = Directory(convRes.stagingDirPath!);
      expect(convStaging.existsSync(), isTrue);
      await convRes.cleanupStaging();
      expect(convStaging.existsSync(), isFalse);

      // 2. convert_compress PDF -> PDF (Native)
      final compRes = await backend.compressBatch(
        entries: [
          MediaFileEntry(
            name: 'doc.pdf',
            path: samplePdf.path,
            sizeBytes: samplePdf.lengthSync(),
          ),
        ],
        action: 'convert_compress',
        targetFormat: 'PDF',
        compressionType: 'Native',
        targetKB: 150,
        targetPerPage: true,
        model: null,
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext, customSuffix: 'compressed'),
      );

      expect(compRes.files.single.suggestedFileName, equals('doc_compressed.pdf'));
      expect(recordedRequests.last['action'], equals('convert_compress'));
      expect(recordedRequests.last['compression_type'], equals('native'));
      expect(recordedRequests.last['targetKB'], equals(150));
      expect(recordedRequests.last['is_target_per_page'], isTrue);
      expect(recordedRequests.last['files'], equals([samplePdf.path]));
      await compRes.cleanupStaging();

      // 3. upscale_ai PNG -> PNG without explicit scale uses uniform defaultUpscaleScale (4)
      final defaultUpRes = await backend.compressBatch(
        entries: [
          MediaFileEntry(name: 'foto.png', path: sampleImg.path, sizeBytes: 4),
        ],
        action: 'upscale_ai',
        targetFormat: 'PNG',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: 'realesr-animevideov3-x2',
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext, customSuffix: 'upscaled'),
      );

      expect(defaultUpRes.files.single.suggestedFileName, equals('foto_upscaled.png'));
      expect(recordedRequests.last['action'], equals('upscale_ai'));
      expect(recordedRequests.last['model'], equals('realesr-animevideov3-x2'));
      expect(recordedRequests.last['scale'], equals(BackendService.defaultUpscaleScale));
      await defaultUpRes.cleanupStaging();

      // 4. upscale_ai with explicit manual integer scale passes user scale intact
      final manualUpRes = await backend.compressBatch(
        entries: [
          MediaFileEntry(name: 'foto.png', path: sampleImg.path, sizeBytes: 4),
        ],
        action: 'upscale_ai',
        targetFormat: 'PNG',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: 'realesr-animevideov3-x2',
        scale: 2,
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext, customSuffix: 'upscaled'),
      );

      expect(recordedRequests.last['action'], equals('upscale_ai'));
      expect(recordedRequests.last['model'], equals('realesr-animevideov3-x2'));
      expect(recordedRequests.last['scale'], equals(2));
      await manualUpRes.cleanupStaging();
    });

    test('compressBatch performs .docx -> .pdf -> png 2-step chaining and autoFallback on COM failure', () async {
      final sampleDocx = File('${tempRoot.path}${Platform.pathSeparator}surat.docx');
      await sampleDocx.writeAsBytes([80, 75, 3, 4]);

      compressHandler = (body) async {
        final target = (body['target_format'] as String).toLowerCase();
        final engine = body['engine'] as String;

        if (target == 'pdf' && engine == 'word') {
          return <String, dynamic>{
            'success': false,
            'message': 'COM Word sibuk, silakan coba LibreOffice.',
          };
        }

        final outDir = Directory(body['outputDir'] as String);
        await outDir.create(recursive: true);
        if (target == 'pdf') {
          final pdfOut = File('${outDir.path}${Platform.pathSeparator}surat.pdf');
          await pdfOut.writeAsBytes(_buildSyntheticPdfBytes(2));
          return {'success': true, 'files': [pdfOut.path]};
        }

        final img1 = File('${outDir.path}${Platform.pathSeparator}page_1.png');
        final img2 = File('${outDir.path}${Platform.pathSeparator}page_2.png');
        await img1.writeAsBytes([1, 2, 3]);
        await img2.writeAsBytes([4, 5, 6]);
        return {'success': true, 'files': [img1.path, img2.path]};
      };

      final res = await backend.compressBatch(
        entries: [
          MediaFileEntry(name: 'surat.docx', path: sampleDocx.path, sizeBytes: 4),
        ],
        action: 'convert_only',
        targetFormat: 'PNG',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: null,
        engine: 'word',
        autoFallback: true,
        buildOutputName: (
          input,
          ext, {
          required partIndex,
          required totalParts,
        }) {
          final base = appState.buildOutputFileName(input, ext);
          if (totalParts <= 1) return base;
          final dot = base.lastIndexOf('.');
          return '${base.substring(0, dot)}_hal${partIndex + 1}${base.substring(dot)}';
        },
      );

      // Expected request sequence:
      // 0: convert_only docx -> pdf (word -> failed)
      // 1: convert_only docx -> pdf (libreoffice -> fallback succeeded)
      // 2: convert_only pdf -> png (main step)
      expect(recordedRequests.length, equals(3));
      expect(recordedRequests[0]['engine'], equals('word'));
      expect(recordedRequests[0]['target_format'], equals('pdf'));
      expect(recordedRequests[1]['engine'], equals('libreoffice'));
      expect(recordedRequests[1]['target_format'], equals('pdf'));
      expect(recordedRequests[2]['action'], equals('convert_only'));
      expect(recordedRequests[2]['target_format'], equals('png'));
      expect((recordedRequests[2]['files'] as List<dynamic>).first.toString().endsWith('surat.pdf'), isTrue);

      expect(res.files.length, equals(2));
      expect(res.files[0].suggestedFileName, equals('surat_converted_hal1.png'));
      expect(res.files[1].suggestedFileName, equals('surat_converted_hal2.png'));
      expect(res.files[0].engineUsed, contains('LibreOffice'));
      await res.cleanupStaging();
    });

    test('compressBatch validates input guards, propagates server errors, and supports cancellation', () async {
      final sampleImg = File('${tempRoot.path}${Platform.pathSeparator}img.png');
      await sampleImg.writeAsBytes([1, 2, 3]);
      final sampleDocx = File('${tempRoot.path}${Platform.pathSeparator}doc.docx');
      await sampleDocx.writeAsBytes([80, 75, 3, 4]);
      final samplePdf = File('${tempRoot.path}${Platform.pathSeparator}doc.pdf');
      await samplePdf.writeAsBytes(_buildSyntheticPdfBytes(1));

      // Target KB guard
      await expectLater(
        () => backend.compressBatch(
          entries: [MediaFileEntry(name: 'img.png', path: sampleImg.path)],
          action: 'convert_compress',
          targetFormat: 'JPG',
          compressionType: 'lossy',
          targetKB: 0,
          targetPerPage: false,
          model: null,
          buildOutputName: (i, e, {required partIndex, required totalParts}) => 'x.$e',
        ),
        throwsA(isA<BackendException>()),
      );

      // Same-format PDF -> PDF Convert Only guard
      await expectLater(
        () => backend.compressBatch(
          entries: [MediaFileEntry(name: 'doc.pdf', path: samplePdf.path)],
          action: 'convert_only',
          targetFormat: 'PDF',
          compressionType: null,
          targetKB: null,
          targetPerPage: null,
          model: null,
          buildOutputName: (i, e, {required partIndex, required totalParts}) => 'x.$e',
        ),
        throwsA(isA<BackendException>()),
      );

      // Upscale .docx guard
      await expectLater(
        () => backend.compressBatch(
          entries: [MediaFileEntry(name: 'doc.docx', path: sampleDocx.path)],
          action: 'upscale_ai',
          targetFormat: 'PNG',
          compressionType: null,
          targetKB: null,
          targetPerPage: null,
          model: 'realesrgan-x4plus',
          buildOutputName: (i, e, {required partIndex, required totalParts}) => 'x.$e',
        ),
        throwsA(isA<BackendException>()),
      );

      // Missing file guard
      await expectLater(
        () => backend.compressBatch(
          entries: [
            MediaFileEntry(
              name: 'missing.png',
              path: '${tempRoot.path}${Platform.pathSeparator}does_not_exist.png',
            ),
          ],
          action: 'convert_only',
          targetFormat: 'JPG',
          compressionType: null,
          targetKB: null,
          targetPerPage: null,
          model: null,
          buildOutputName: (i, e, {required partIndex, required totalParts}) => 'x.$e',
        ),
        throwsA(isA<BackendException>()),
      );

      // Server error propagation
      compressHandler = (_) async => {
            'success': false,
            'message': 'Engine internal failure test',
          };
      await expectLater(
        () => backend.compressBatch(
          entries: [MediaFileEntry(name: 'img.png', path: sampleImg.path)],
          action: 'convert_only',
          targetFormat: 'JPG',
          compressionType: null,
          targetKB: null,
          targetPerPage: null,
          model: null,
          buildOutputName: (i, e, {required partIndex, required totalParts}) => 'x.$e',
        ),
        throwsA(
          isA<BackendException>().having(
            (e) => e.message,
            'message',
            contains('Engine internal failure test'),
          ),
        ),
      );

      // Pre-cancelled token
      final token = BackendCancellationToken()..cancel();
      await expectLater(
        () => backend.compressBatch(
          entries: [MediaFileEntry(name: 'img.png', path: sampleImg.path)],
          action: 'convert_only',
          targetFormat: 'JPG',
          compressionType: null,
          targetKB: null,
          targetPerPage: null,
          model: null,
          cancelToken: token,
          buildOutputName: (i, e, {required partIndex, required totalParts}) => 'x.$e',
        ),
        throwsA(isA<BackendCancelledException>()),
      );
    });

    test('compressBatch runs multi-file batches concurrently in bounded pool and preserves exact input order', () async {
      appState.setMaxWorkerThreads(4);
      final files = <MediaFileEntry>[];
      for (int i = 0; i < 4; i++) {
        final f = File('${tempRoot.path}${Platform.pathSeparator}f$i.png');
        await f.writeAsBytes([i + 1, i + 2, i + 3]);
        files.add(MediaFileEntry(name: 'f$i.png', path: f.path, sizeBytes: 3));
      }

      int inFlight = 0;
      int maxInFlight = 0;
      compressHandler = (body) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        try {
          final src = (body['files'] as List<dynamic>).first.toString();
          // Intentionally make file 0 finish LAST to verify deterministic output ordering
          final delayMs = src.endsWith('f0.png') ? 140 : 25;
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          final outDir = Directory(body['outputDir'] as String);
          await outDir.create(recursive: true);
          final outFile = File('${outDir.path}${Platform.pathSeparator}out.jpg');
          await outFile.writeAsBytes([1, 2, 3, 4]);
          return <String, dynamic>{
            'success': true,
            'files': <String>[outFile.path],
          };
        } finally {
          inFlight--;
        }
      };

      final progressSteps = <int>[];
      final res = await backend.compressBatch(
        entries: files,
        action: 'convert_only',
        targetFormat: 'JPG',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: null,
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext),
        onProgress: (completed, total, _) => progressSteps.add(completed),
      );

      expect(maxInFlight, greaterThanOrEqualTo(2));
      expect(
        res.files.map((f) => f.sourceFileName).toList(),
        equals(['f0.png', 'f1.png', 'f2.png', 'f3.png']),
      );
      expect(
        res.files.map((f) => f.suggestedFileName).toList(),
        equals([
          'f0_converted.jpg',
          'f1_converted.jpg',
          'f2_converted.jpg',
          'f3_converted.jpg',
        ]),
      );
      expect(progressSteps.last, equals(4));
      await res.cleanupStaging();
    });

    test('compressBatch caps upscale_ai concurrency at 2 and serializes Office COM conversions', () async {
      appState.setMaxWorkerThreads(6);

      // 1. upscale_ai caps concurrent HTTP workers at 2 (VRAM safety)
      final imgs = <MediaFileEntry>[];
      for (int i = 0; i < 4; i++) {
        final f = File('${tempRoot.path}${Platform.pathSeparator}ai_$i.png');
        await f.writeAsBytes([1, 2, 3]);
        imgs.add(MediaFileEntry(name: 'ai_$i.png', path: f.path, sizeBytes: 3));
      }

      int aiInFlight = 0;
      int aiMaxInFlight = 0;
      compressHandler = (body) async {
        aiInFlight++;
        if (aiInFlight > aiMaxInFlight) aiMaxInFlight = aiInFlight;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final outDir = Directory(body['outputDir'] as String);
          await outDir.create(recursive: true);
          final outFile = File('${outDir.path}${Platform.pathSeparator}up.png');
          await outFile.writeAsBytes([9, 8, 7]);
          return {'success': true, 'files': [outFile.path]};
        } finally {
          aiInFlight--;
        }
      };

      final aiRes = await backend.compressBatch(
        entries: imgs,
        action: 'upscale_ai',
        targetFormat: 'PNG',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: 'realesr-animevideov3-x2',
        scale: 2,
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext, customSuffix: 'upscaled'),
      );
      expect(aiMaxInFlight, equals(2));
      await aiRes.cleanupStaging();

      // 2. Multiple .docx files are serialized client-side via _runWithOfficeLock so timeouts don't stack
      final docs = <MediaFileEntry>[];
      for (int i = 0; i < 3; i++) {
        final d = File('${tempRoot.path}${Platform.pathSeparator}doc_$i.docx');
        await d.writeAsBytes([80, 75, 3, 4]);
        docs.add(MediaFileEntry(name: 'doc_$i.docx', path: d.path, sizeBytes: 4));
      }

      int docInFlight = 0;
      int docMaxInFlight = 0;
      compressHandler = (body) async {
        docInFlight++;
        if (docInFlight > docMaxInFlight) docMaxInFlight = docInFlight;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          final outDir = Directory(body['outputDir'] as String);
          await outDir.create(recursive: true);
          final outFile = File('${outDir.path}${Platform.pathSeparator}doc.pdf');
          await outFile.writeAsBytes(_buildSyntheticPdfBytes(1));
          return {'success': true, 'files': [outFile.path]};
        } finally {
          docInFlight--;
        }
      };

      final docRes = await backend.compressBatch(
        entries: docs,
        action: 'convert_only',
        targetFormat: 'PDF',
        compressionType: null,
        targetKB: null,
        targetPerPage: null,
        model: null,
        buildOutputName: (input, ext, {required partIndex, required totalParts}) =>
            appState.buildOutputFileName(input, ext),
      );
      expect(docMaxInFlight, equals(1));
      expect(docRes.files.length, equals(3));
      await docRes.cleanupStaging();
    });

    test('ensureRunning reuses 3s healthy fast-path without redundant GET /compress pings', () async {
      int getHits = 0;
      final healthServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async => healthServer.close(force: true));
      healthServer.listen((HttpRequest req) async {
        if (req.method == 'GET' && req.uri.path == '/compress') {
          getHits++;
          req.response.statusCode = HttpStatus.methodNotAllowed;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({'success': false, 'message': 'Method tidak diizinkan'}),
          );
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      backend.resetTestOverrides();
      backend.overrideBaseUrl = 'http://127.0.0.1:${healthServer.port}';

      expect(await backend.ensureRunning(), isTrue);
      expect(getHits, equals(1));

      // Second call within 3s uses health cache fast-path
      expect(await backend.ensureRunning(), isTrue);
      expect(getHits, equals(1));

      // Explicit pingHealth always performs live health probe
      expect(await backend.pingHealth(), isNotNull);
      expect(getHits, equals(2));
    });
  });

  group('Real QPDF rotation, PDF Manager multi-pool /pdf-workflow, and SaveDestinationHelper', () {
    late HttpServer server;
    late List<Map<String, dynamic>> workflowRequests;
    late bool advertiseRotationsApplied;

    setUp(() async {
      workflowRequests = <Map<String, dynamic>>[];
      advertiseRotationsApplied = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        if (req.method == 'GET' && req.uri.path == '/compress') {
          req.response.statusCode = HttpStatus.methodNotAllowed;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({'success': false, 'message': 'Method tidak diizinkan'}),
          );
          await req.response.close();
          return;
        }

        if (req.uri.path == '/pdf-workflow') {
          final body = jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>;
          workflowRequests.add(body);

          final outDir = Directory(body['outputDir'] as String);
          await outDir.create(recursive: true);

          final steps = body['steps'] as List<dynamic>;
          final step = steps.first as Map<String, dynamic>;
          final action = step['action'] as String;
          final producedFiles = <String>[];

          if (action == 'split_separated') {
            final pages = step['pages'] as List<dynamic>;
            final outputId = step['outputId'] as String;
            for (final p in pages) {
              final f = File(
                '${outDir.path}${Platform.pathSeparator}${outputId}_p$p.pdf',
              );
              await f.writeAsBytes(_buildSyntheticPdfBytes(1));
              producedFiles.add(f.path);
            }
          } else if (action == 'split') {
            final splits = step['splits'] as List<dynamic>;
            final total = splits.fold<int>(
              0,
              (sum, item) => sum + ((item['pages'] as List<dynamic>).length),
            );
            final f = File('${outDir.path}${Platform.pathSeparator}split_out.pdf');
            await f.writeAsBytes(_buildSyntheticPdfBytes(total));
            producedFiles.add(f.path);
          } else if (action == 'reorder') {
            final reorders = step['reorders'] as List<dynamic>;
            final total = reorders.fold<int>(
              0,
              (sum, item) => sum + ((item['newOrder'] as List<dynamic>).length),
            );
            final f = File('${outDir.path}${Platform.pathSeparator}reorder_out.pdf');
            await f.writeAsBytes(_buildSyntheticPdfBytes(total));
            producedFiles.add(f.path);
          } else if (action == 'merge') {
            final f = File('${outDir.path}${Platform.pathSeparator}merge_out.pdf');
            await f.writeAsBytes(_buildSyntheticPdfBytes(4));
            producedFiles.add(f.path);
          }

          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'success': true,
              'files': producedFiles,
              if (advertiseRotationsApplied) 'rotations_applied': true,
            }),
          );
          await req.response.close();
          return;
        }

        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });

      backend.overrideBaseUrl = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('applyQpdfRotations rotates real PDF pages clockwise and supports in-place writes', () async {
      await backend.inspectCapabilities(detectExternalOfficeApps: false);

      final inputPdf = File('${tempRoot.path}${Platform.pathSeparator}base3.pdf');
      final rotatedPdf = File('${tempRoot.path}${Platform.pathSeparator}rotated3.pdf');
      await inputPdf.writeAsBytes(_buildSyntheticPdfBytes(3));

      await backend.applyQpdfRotations(
        inputPdfPath: inputPdf.path,
        outputPdfPath: rotatedPdf.path,
        oneBasedPageDeltas: {1: 90, 2: 180, 3: 270},
      );

      expect(rotatedPdf.existsSync(), isTrue);
      expect(rotatedPdf.lengthSync(), greaterThan(0));

      final inspected = await PdfInspectorService().inspectFile(
        fileName: 'rotated3.pdf',
        filePath: rotatedPdf.path,
      );
      expect(inspected.pageCount, equals(3));
      expect(inspected.pages[0].rotation, equals(90));
      expect(inspected.pages[1].rotation, equals(180));
      expect(inspected.pages[2].rotation, equals(270));

      // Apply +90 in-place onto page 1 => 180
      await backend.applyQpdfRotations(
        inputPdfPath: rotatedPdf.path,
        outputPdfPath: rotatedPdf.path,
        oneBasedPageDeltas: {1: 90},
      );
      PdfInspectorService().clearCache();
      final inspectedTwice = await PdfInspectorService().inspectFile(
        fileName: 'rotated3.pdf',
        filePath: rotatedPdf.path,
      );
      expect(inspectedTwice.pages[0].rotation, equals(180));
    });

    test('executePdfWorkflow chains Split -> Reorder -> Merge with QPDF rotations', () async {
      await backend.inspectCapabilities(detectExternalOfficeApps: false);

      final docA = File('${tempRoot.path}${Platform.pathSeparator}docA.pdf');
      final docB = File('${tempRoot.path}${Platform.pathSeparator}docB.pdf');
      await docA.writeAsBytes(_buildSyntheticPdfBytes(4));
      await docB.writeAsBytes(_buildSyntheticPdfBytes(2));

      appState.pdfPools
        ..clear()
        ..addAll([
        PoolSectionData(
          id: 'p_split',
          title: 'Split Pool',
          slots: [
            PoolSlot(
              id: 's_split_0',
              label: 'Number Split',
              fileName: 'docA.pdf',
              filePath: docA.path,
              pageCount: 4,
              pageRange: '1-2',
              pageRotations: {1: 90},
            ),
          ],
        ),
        PoolSectionData(
          id: 'p_reorder',
          title: 'Reorder Pool',
          slots: [
            PoolSlot(
              id: 's_reorder_0',
              label: 'Order Number',
              pageRange: '2, 1',
            ),
          ],
        ),
        PoolSectionData(
          id: 'p_merge',
          title: 'Merge Pool',
          slots: [
            PoolSlot(
              id: 's_merge_0',
              label: 'Merge Number',
              fileName: 'docB.pdf',
              filePath: docB.path,
              pageCount: 2,
              pageRotations: {2: 180},
            ),
          ],
        ),
      ]);
      appState.updatePdfInheritedSlots();

      final result = await backend.executePdfWorkflow(
        pools: appState.pdfPools,
        taskModeLabel: 'PDF Manager Workflow',
        outputSuffix: 'workflow',
      );

      expect(workflowRequests.length, equals(3));
      expect(
        workflowRequests[0]['steps'][0]['action'],
        equals('split'),
      );
      expect(
        workflowRequests[0]['steps'][0]['splits'][0]['pages'],
        equals([1, 2]),
      );
      expect(
        workflowRequests[1]['steps'][0]['action'],
        equals('reorder'),
      );
      expect(
        workflowRequests[1]['steps'][0]['reorders'][0]['newOrder'],
        equals([2, 1]),
      );
      expect(
        workflowRequests[2]['steps'][0]['action'],
        equals('merge'),
      );

      expect(result.files.length, equals(1));
      expect(result.files.single.suggestedFileName, equals('docA_workflow.pdf'));

      final outPdf = File(result.files.single.stagedFilePath);
      expect(outPdf.existsSync(), isTrue);

      final outInfo = await PdfInspectorService().inspectFile(
        fileName: 'docA_workflow.pdf',
        filePath: outPdf.path,
      );
      // After merge step: upstream rotated Hal 1 (orig 1 -> moved to pos 2) had 90°, plus docB page 2 -> outPos 4 has 180°.
      // Let's verify exact QPDF rotation metadata on output page 4 is 180°.
      expect(outInfo.pages[3].rotation, equals(180));

      final stagingDir = Directory(result.stagingDirPath!);
      expect(stagingDir.existsSync(), isTrue);
      await result.cleanupStaging();
      expect(stagingDir.existsSync(), isFalse);
    });

    test('executePdfWorkflow produces distinct non-colliding files for Split Separate Pool', () async {
      await backend.inspectCapabilities(detectExternalOfficeApps: false);

      final docA = File('${tempRoot.path}${Platform.pathSeparator}multi.pdf');
      await docA.writeAsBytes(_buildSyntheticPdfBytes(4));

      final sepPool = PoolSectionData(
        id: 'p_sep',
        title: 'Split Separate Pool',
        slots: [
          PoolSlot(
            id: 's_sep_0',
            label: 'Number Split',
            fileName: 'multi.pdf',
            filePath: docA.path,
            pageCount: 4,
            pageRange: '1, 3',
            pageRotations: {3: 90},
          ),
        ],
      );

      final result = await backend.executePdfWorkflow(
        pools: [sepPool],
        taskModeLabel: 'PDF Manager (Split Separate)',
        outputSuffix: 'split_sep',
      );

      expect(workflowRequests.length, equals(1));
      expect(workflowRequests.first['steps'][0]['action'], equals('split_separated'));
      expect(result.files.length, equals(2));
      expect(result.files[0].suggestedFileName, equals('multi_split_sep_p1.pdf'));
      expect(result.files[1].suggestedFileName, equals('multi_split_sep_p3.pdf'));
      expect(
        result.files[0].stagedFilePath,
        isNot(equals(result.files[1].stagedFilePath)),
      );
      expect(File(result.files[0].stagedFilePath).existsSync(), isTrue);
      expect(File(result.files[1].stagedFilePath).existsSync(), isTrue);

      final page3Info = await PdfInspectorService().inspectFile(
        fileName: 'multi_split_sep_p3.pdf',
        filePath: result.files[1].stagedFilePath,
      );
      expect(page3Info.pages.single.rotation, equals(90));

      await result.cleanupStaging();
    });

    test('executePdfWorkflow sends rotations map to backend and skips redundant QPDF pass when rotations_applied is true', () async {
      advertiseRotationsApplied = true;
      // Point overrideEngineRootDir to a dummy folder WITH tools/ but WITHOUT qpdf.exe so we prove QPDF subprocess is skipped!
      final noQpdfDir = Directory('${tempRoot.path}${Platform.pathSeparator}no_qpdf_dir');
      await Directory('${noQpdfDir.path}${Platform.pathSeparator}tools').create(recursive: true);
      backend.overrideEngineRootDir = noQpdfDir.path;
      await backend.inspectCapabilities(detectExternalOfficeApps: false);
      expect(backend.capabilities.hasQpdf, isFalse);

      final docA = File('${tempRoot.path}${Platform.pathSeparator}fastA.pdf');
      final docB = File('${tempRoot.path}${Platform.pathSeparator}fastB.pdf');
      await docA.writeAsBytes(_buildSyntheticPdfBytes(4));
      await docB.writeAsBytes(_buildSyntheticPdfBytes(2));

      final splitSepPool = PoolSectionData(
        id: 'p_sep_fast',
        title: 'Split Separate Pool',
        slots: [
          PoolSlot(
            id: 's_0',
            label: 'Number Split',
            fileName: 'fastA.pdf',
            filePath: docA.path,
            pageCount: 4,
            pageRange: '1-2',
            pageRotations: {2: 90},
          ),
          PoolSlot(
            id: 's_1',
            label: 'Number Split',
            fileName: 'fastB.pdf',
            filePath: docB.path,
            pageCount: 2,
            pageRange: '2',
            pageRotations: {2: 180},
          ),
        ],
      );

      final res = await backend.executePdfWorkflow(
        pools: [splitSepPool],
        taskModeLabel: 'PDF Manager (Fast Separate)',
        outputSuffix: 'fast_sep',
      );

      expect(workflowRequests.length, equals(2));
      // Target requests may finish concurrently; match by outputId
      final reqMap = <String, Map<String, dynamic>>{
        for (final r in workflowRequests)
          (r['steps'][0]['outputId'] as String): r['steps'][0] as Map<String, dynamic>,
      };
      expect(reqMap['sep_0']?['rotations'], equals({'2': 90}));
      expect(reqMap['sep_1']?['rotations'], equals({'1': 180}));

      expect(res.files.length, equals(3));
      expect(res.files[0].sourceFileName, equals('fastA_p1.pdf'));
      expect(res.files[1].sourceFileName, equals('fastA_p2.pdf'));
      expect(res.files[2].sourceFileName, equals('fastB_p2.pdf'));
      expect(res.files[0].suggestedFileName, equals('fastA_fast_sep_p1.pdf'));
      expect(res.files[1].suggestedFileName, equals('fastA_fast_sep_p2.pdf'));
      expect(res.files[2].suggestedFileName, equals('fastB_fast_sep_p2.pdf'));
      expect(res.files[0].groupFileName, equals('fastA.pdf'));
      expect(res.files[1].groupFileName, equals('fastA.pdf'));
      expect(res.files[2].groupFileName, equals('fastB.pdf'));
      expect(
        {
          res.files[0].stagedFilePath,
          res.files[1].stagedFilePath,
          res.files[2].stagedFilePath,
        }.length,
        equals(3),
      );
      expect(File(res.files[0].stagedFilePath).existsSync(), isTrue);
      expect(File(res.files[1].stagedFilePath).existsSync(), isTrue);
      expect(File(res.files[2].stagedFilePath).existsSync(), isTrue);
      await res.cleanupStaging();
    });

    test('Split Separate Pool preserves each source file original name, groups interleaved files cleanly, and handles inherited multi-file streams', () async {
      await backend.inspectCapabilities(detectExternalOfficeApps: false);

      final jurnalFile = File('${tempRoot.path}${Platform.pathSeparator}jurnal1.pdf');
      final file2File = File('${tempRoot.path}${Platform.pathSeparator}file2.pdf');
      await jurnalFile.writeAsBytes(_buildSyntheticPdfBytes(5));
      await file2File.writeAsBytes(_buildSyntheticPdfBytes(2));

      // 1. Interleaved slots: jurnal1 (1-2), file2 (2), jurnal1 (4) -> clustered by original filename
      final interleavedSepPool = PoolSectionData(
        id: 'p_sep_interleaved',
        title: 'Split Separate Pool',
        slots: [
          PoolSlot(
            id: 's_j1',
            label: 'Split 1-2',
            fileName: 'jurnal1.pdf',
            filePath: jurnalFile.path,
            pageCount: 5,
            pageRange: '1-2',
          ),
          PoolSlot(
            id: 's_f2',
            label: 'Split 2',
            fileName: 'file2.pdf',
            filePath: file2File.path,
            pageCount: 2,
            pageRange: '2',
          ),
          PoolSlot(
            id: 's_j2',
            label: 'Split 4',
            fileName: 'jurnal1.pdf',
            filePath: jurnalFile.path,
            pageCount: 5,
            pageRange: '4',
          ),
        ],
      );

      final res1 = await backend.executePdfWorkflow(
        pools: [interleavedSepPool],
        taskModeLabel: 'PDF Manager (Split Separate Pool)',
        outputSuffix: 'split',
      );

      expect(res1.files.length, equals(4));
      expect(
        res1.files.map((f) => f.suggestedFileName).toList(),
        equals([
          'jurnal1_split_p1.pdf',
          'jurnal1_split_p2.pdf',
          'jurnal1_split_p4.pdf',
          'file2_split_p2.pdf',
        ]),
      );
      expect(
        res1.files.map((f) => f.groupFileName).toList(),
        equals([
          'jurnal1.pdf',
          'jurnal1.pdf',
          'jurnal1.pdf',
          'file2.pdf',
        ]),
      );
      await res1.cleanupStaging();

      // 2. Chained Merge (jurnal1 2p + file2 2p) -> Split Separate Pool retains true per-page source names
      final jurnal2p = File('${tempRoot.path}${Platform.pathSeparator}jurnal_2p.pdf');
      await jurnal2p.writeAsBytes(_buildSyntheticPdfBytes(2));

      final mergePool = PoolSectionData(
        id: 'p_merge_src',
        title: 'Merge Pool',
        slots: [
          PoolSlot(
            id: 'm_0',
            label: 'Merge Number',
            fileName: 'jurnal1.pdf',
            filePath: jurnal2p.path,
            pageCount: 2,
          ),
          PoolSlot(
            id: 'm_1',
            label: 'Merge Number',
            fileName: 'file2.pdf',
            filePath: file2File.path,
            pageCount: 2,
          ),
        ],
      );
      appState.pdfPools
        ..clear()
        ..add(mergePool)
        ..add(
          PoolSectionData(
            id: 'p_sep_downstream',
            title: 'Split Separate Pool',
            slots: [
              PoolSlot(
                id: 's_inh',
                label: 'Merge Pool File',
                isInherited: true,
              ),
            ],
          ),
        );
      appState.updatePdfInheritedSlots();

      final res2 = await backend.executePdfWorkflow(
        pools: appState.pdfPools,
        taskModeLabel: 'PDF Manager (Merge -> Split Separate)',
        outputSuffix: 'workflow',
      );

      expect(
        res2.files.map((f) => f.suggestedFileName).toList(),
        equals([
          'jurnal1_workflow_p1.pdf',
          'jurnal1_workflow_p2.pdf',
          'file2_workflow_p1.pdf',
          'file2_workflow_p2.pdf',
        ]),
      );
      expect(
        res2.files.map((f) => f.groupFileName).toList(),
        equals([
          'jurnal1.pdf',
          'jurnal1.pdf',
          'file2.pdf',
          'file2.pdf',
        ]),
      );
      await res2.cleanupStaging();

      // 3. Non-Split-Separate final pool (Split Separate -> Merge) leaves groupFileName null
      appState.pdfPools
        ..clear()
        ..add(
          PoolSectionData(
            id: 'p_sep_only_upstream',
            title: 'Split Separate Pool',
            slots: [
              PoolSlot(
                id: 'su_0',
                label: 'Split 1',
                fileName: 'jurnal1.pdf',
                filePath: jurnal2p.path,
                pageCount: 2,
                pageRange: '1',
              ),
              PoolSlot(
                id: 'su_1',
                label: 'Split 2',
                fileName: 'file2.pdf',
                filePath: file2File.path,
                pageCount: 2,
                pageRange: '2',
              ),
            ],
          ),
        )
        ..add(
          PoolSectionData(
            id: 'p_merge_final',
            title: 'Merge Pool',
            slots: [
              PoolSlot(
                id: 'mf_inh',
                label: 'Split Separate Pool File',
                isInherited: true,
              ),
            ],
          ),
        );
      appState.updatePdfInheritedSlots();

      final res3 = await backend.executePdfWorkflow(
        pools: appState.pdfPools,
        taskModeLabel: 'PDF Manager (Split Separate -> Merge)',
        outputSuffix: 'workflow',
      );
      expect(res3.files.length, equals(1));
      expect(res3.files.single.groupFileName, isNull);
      expect(res3.files.single.suggestedFileName, equals('jurnal1_workflow.pdf'));
      await res3.cleanupStaging();
    });

    test('PdfInspectorService coalesces concurrent inspectFile calls for identical file path', () async {
      final doc = File('${tempRoot.path}${Platform.pathSeparator}concurrent_doc.pdf');
      await doc.writeAsBytes(_buildSyntheticPdfBytes(7));

      final futures = List.generate(
        6,
        (_) => PdfInspectorService().inspectFile(
          fileName: 'concurrent_doc.pdf',
          filePath: doc.path,
        ),
      );
      final results = await Future.wait(futures);
      for (final info in results) {
        expect(info.pageCount, equals(7));
        expect(identical(info, results.first), isTrue);
      }
    });
  });

  group('SaveDestinationHelper staging copy and cleanup', () {
    testWidgets('SaveDestinationHelper copies real staged files with collision suffixes and cleans staging on save or cancel', (tester) async {
      final destDir = Directory('${tempRoot.path}${Platform.pathSeparator}dest_out');
      appState.setOutputDirectory(destDir.path);
      appState.setSaveLocationMode(SaveLocationMode.autoDefaultFolder);
      appState.setOverwriteExisting(false);

      late BuildContext capturedCtx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                capturedCtx = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      ({Directory dir, File file}) createStagedSync(String content) {
        final d = Directory.systemTemp.createTempSync('mwx_save_stage_');
        final f = File('${d.path}${Platform.pathSeparator}item.png');
        f.writeAsBytesSync(utf8.encode(content));
        return (dir: d, file: f);
      }

      // 1. First save writes report_converted.png
      final stage1 = createStagedSync('IMAGE_BYTES_1');
      await tester.runAsync(() async {
        await SaveDestinationHelper.handleProcessCompletion(
          capturedCtx,
          taskTitle: 'Convert PNG',
          outputItems: [
            SaveOutputItem(
              sourceFileName: 'report.jpg',
              outputFileName: 'report_converted.png',
              taskType: 'Convert PNG',
              targetFormat: 'PNG',
              engineUsed: 'Media Image/Document Pipeline',
              originalSize: '1 KB',
              resultSize: '13 B',
              durationMs: 100,
              stagedFilePath: stage1.file.path,
            ),
          ],
          onCleanupStaging: () async {
            if (stage1.dir.existsSync()) {
              stage1.dir.deleteSync(recursive: true);
            }
          },
        );
      });
      await tester.pumpAndSettle();

      final saved1 = File('${destDir.path}${Platform.pathSeparator}report_converted.png');
      expect(saved1.existsSync(), isTrue);
      expect(utf8.decode(saved1.readAsBytesSync()), equals('IMAGE_BYTES_1'));
      expect(stage1.dir.existsSync(), isFalse);
      expect(appState.history.first.outputPath, equals(saved1.path));

      // 2. Second save with same filename & overwriteExisting == false writes report_converted_1.png
      final stage2 = createStagedSync('IMAGE_BYTES_2');
      await tester.runAsync(() async {
        await SaveDestinationHelper.handleProcessCompletion(
          capturedCtx,
          taskTitle: 'Convert PNG',
          outputItems: [
            SaveOutputItem(
              sourceFileName: 'report.jpg',
              outputFileName: 'report_converted.png',
              taskType: 'Convert PNG',
              targetFormat: 'PNG',
              engineUsed: 'Media Image/Document Pipeline',
              originalSize: '1 KB',
              resultSize: '13 B',
              durationMs: 100,
              stagedFilePath: stage2.file.path,
            ),
          ],
          onCleanupStaging: () async {
            if (stage2.dir.existsSync()) {
              stage2.dir.deleteSync(recursive: true);
            }
          },
        );
      });
      await tester.pumpAndSettle();

      final saved2 = File('${destDir.path}${Platform.pathSeparator}report_converted_1.png');
      expect(saved2.existsSync(), isTrue);
      expect(utf8.decode(saved2.readAsBytesSync()), equals('IMAGE_BYTES_2'));
      expect(utf8.decode(saved1.readAsBytesSync()), equals('IMAGE_BYTES_1'));
      expect(stage2.dir.existsSync(), isFalse);

      // 3. Cancel in askEveryTime mode still deletes staging dir!
      appState.setSaveLocationMode(SaveLocationMode.askEveryTime);
      final stage3 = createStagedSync('IMAGE_BYTES_3');
      var cleanupCalled = false;
      final completionFuture = SaveDestinationHelper.handleProcessCompletion(
        capturedCtx,
        taskTitle: 'Convert PNG',
        outputItems: [
          SaveOutputItem(
            sourceFileName: 'report.jpg',
            outputFileName: 'report_converted.png',
            taskType: 'Convert PNG',
            targetFormat: 'PNG',
            engineUsed: 'Media Image/Document Pipeline',
            originalSize: '1 KB',
            resultSize: '13 B',
            durationMs: 100,
            stagedFilePath: stage3.file.path,
          ),
        ],
        onCleanupStaging: () async {
          cleanupCalled = true;
          if (stage3.dir.existsSync()) {
            stage3.dir.deleteSync(recursive: true);
          }
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();

      final canceledFolder = await completionFuture;
      expect(canceledFolder, isNull);
      expect(cleanupCalled, isTrue);
      expect(stage3.dir.existsSync(), isFalse);

      // 4. Parallel batch save handles 12 files cleanly including intra-batch duplicate filenames
      appState.setSaveLocationMode(SaveLocationMode.autoDefaultFolder);
      appState.setOverwriteExisting(false);
      final batchDir = Directory.systemTemp.createTempSync('mwx_save_batch_');
      final batchItems = <SaveOutputItem>[];
      for (int i = 0; i < 12; i++) {
        final f = File('${batchDir.path}${Platform.pathSeparator}part_$i.pdf');
        f.writeAsBytesSync(utf8.encode('PDF_BATCH_$i'));
        batchItems.add(
          SaveOutputItem(
            sourceFileName: 'source_$i.pdf',
            outputFileName: i < 2 ? 'dup_out.pdf' : 'part_$i.pdf',
            taskType: 'PDF Manager (Split Separate)',
            targetFormat: 'PDF',
            engineUsed: 'PDF Manager Core + QPDF',
            originalSize: '1 KB',
            resultSize: '12 B',
            durationMs: 50,
            stagedFilePath: f.path,
          ),
        );
      }
      await tester.runAsync(() async {
        await SaveDestinationHelper.handleProcessCompletion(
          capturedCtx,
          taskTitle: 'Batch Split Separate',
          outputItems: batchItems,
          onCleanupStaging: () async {
            if (batchDir.existsSync()) {
              batchDir.deleteSync(recursive: true);
            }
          },
        );
      });
      await tester.pumpAndSettle();

      expect(
        utf8.decode(
          File('${destDir.path}${Platform.pathSeparator}dup_out.pdf')
              .readAsBytesSync(),
        ),
        equals('PDF_BATCH_0'),
      );
      expect(
        utf8.decode(
          File('${destDir.path}${Platform.pathSeparator}dup_out_1.pdf')
              .readAsBytesSync(),
        ),
        equals('PDF_BATCH_1'),
      );
      for (int i = 2; i < 12; i++) {
        expect(
          utf8.decode(
            File('${destDir.path}${Platform.pathSeparator}part_$i.pdf')
                .readAsBytesSync(),
          ),
          equals('PDF_BATCH_$i'),
        );
      }
      expect(batchDir.existsSync(), isFalse);
    });
  });
}
