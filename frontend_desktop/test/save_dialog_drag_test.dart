import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/services/app_state_service.dart';
import 'package:frontend/shared/widgets/save_folder_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SaveDestinationDialog is draggable and resets on double tap', (tester) async {
    final appState = AppStateService();
    appState.setOutputDirectory('C:\\TestOutput');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => const SaveDestinationDialog(
                      taskTitle: 'Compress & Convert (JPG • 350 KB)',
                      summaryNote: 'Test summary note',
                      outputItems: [
                        SaveOutputItem(
                          sourceFileName: 'chef2.png',
                          outputFileName: 'chef2_compressed.jpg',
                          taskType: 'Compress & Convert',
                          targetFormat: 'JPG',
                          engineUsed: 'Media Image Pipeline',
                          originalSize: '2.28 MB',
                          resultSize: '349.1 KB',
                          durationMs: 260,
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Open Dialog'),
              );
            },
          ),
        ),
      ),
    );

    // Open the dialog
    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    expect(find.text('Proses Selesai — Pilih Folder Simpan'), findsOneWidget);
    expect(find.text('Geser'), findsOneWidget);

    // Find our dialog's Transform widget by Key
    final transformFinder = find.byKey(const Key('save_destination_dialog_transform'));
    expect(transformFinder, findsOneWidget);

    // Initial offset is zero
    Transform transformWidget = tester.widget<Transform>(transformFinder);
    expect(transformWidget.transform.getTranslation().x, equals(0.0));
    expect(transformWidget.transform.getTranslation().y, equals(0.0));

    // Drag by the header
    final headerFinder = find.text('Proses Selesai — Pilih Folder Simpan');
    await tester.drag(headerFinder, const Offset(80.0, 50.0));
    await tester.pumpAndSettle();

    transformWidget = tester.widget<Transform>(transformFinder);
    expect(transformWidget.transform.getTranslation().x, greaterThan(20.0));
    expect(transformWidget.transform.getTranslation().y, greaterThan(20.0));

    // Double tap the header to reset position to center
    await tester.tap(headerFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(headerFinder);
    await tester.pumpAndSettle();

    transformWidget = tester.widget<Transform>(transformFinder);
    expect(transformWidget.transform.getTranslation().x, equals(0.0));
    expect(transformWidget.transform.getTranslation().y, equals(0.0));
    // Drag by the bottom handle 'Drag untuk geser'
    final bottomHandleFinder = find.text('Drag untuk geser');
    expect(bottomHandleFinder, findsOneWidget);
    await tester.drag(bottomHandleFinder, const Offset(-50.0, -30.0));
    await tester.pumpAndSettle();

    transformWidget = tester.widget<Transform>(transformFinder);
    expect(transformWidget.transform.getTranslation().x, lessThan(0.0));
    expect(transformWidget.transform.getTranslation().y, lessThan(0.0));

    // Double tap to reset
    await tester.tap(bottomHandleFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(bottomHandleFinder);
    await tester.pumpAndSettle();

    transformWidget = tester.widget<Transform>(transformFinder);
    expect(transformWidget.transform.getTranslation().x, equals(0.0));
    expect(transformWidget.transform.getTranslation().y, equals(0.0));
  });
}
