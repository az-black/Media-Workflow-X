// Media Workflow X - Modern Flutter Desktop Application
// Entry Point for Media Processing Suite (Smart Compression, Conversion, PDF Manager, AI Upscaler)
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'core/services/app_state_service.dart';
import 'core/services/backend_service.dart';
import 'core/services/window_control_service.dart';
import 'core/theme/app_theme.dart';
import 'features/dashboard/presentation/screens/main_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppStateService().loadFromStorageSync();
  runApp(const MediaWorkflowApp());
}

class MediaWorkflowApp extends StatefulWidget {
  const MediaWorkflowApp({super.key});

  @override
  State<MediaWorkflowApp> createState() => _MediaWorkflowAppState();
}

class _MediaWorkflowAppState extends State<MediaWorkflowApp> {
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    if (!BackendService.isRunningUnderFlutterTest()) {
      unawaited(WindowControlService().initialize());
      unawaited(BackendService().startupInitialize());
      _lifecycleListener = AppLifecycleListener(
        onStateChange: (state) {
          if (state == AppLifecycleState.paused ||
              state == AppLifecycleState.inactive ||
              state == AppLifecycleState.detached) {
            AppStateService().flushSaveSync();
          }
        },
        onExitRequested: () async {
          AppStateService().flushSaveSync();
          await BackendService().stopOwnedBackend();
          return ui.AppExitResponse.exit;
        },
      );
    }
  }

  @override
  void dispose() {
    AppStateService().flushSaveSync();
    _lifecycleListener?.dispose();
    if (!BackendService.isRunningUnderFlutterTest()) {
      unawaited(BackendService().stopOwnedBackend());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Workflow X',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainScreen(),
    );
  }
}
