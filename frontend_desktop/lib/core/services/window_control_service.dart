import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_state_service.dart';
import 'backend_service.dart';

class WindowControlService {
  static final WindowControlService _instance =
      WindowControlService._internal();
  factory WindowControlService() => _instance;
  WindowControlService._internal();

  static const MethodChannel _channel =
      MethodChannel('media_workflow_x/window');

  final ValueNotifier<bool> isMaximized = ValueNotifier<bool>(false);
  bool _initialized = false;

  /// Test hook invoked alongside native calls when running widget tests.
  @visibleForTesting
  void Function(String action, [String? arg])? testActionObserver;

  bool get _isDesktopWindows =>
      !kIsWeb &&
      !BackendService.isRunningUnderFlutterTest() &&
      Platform.isWindows;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_isDesktopWindows) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWindowMaximizeChanged') {
        final next = call.arguments == true;
        if (isMaximized.value != next) {
          isMaximized.value = next;
        }
      }
    });

    try {
      final result = await _channel.invokeMethod<bool>('isMaximized');
      if (result != null && isMaximized.value != result) {
        isMaximized.value = result;
      }
    } catch (_) {
      // Ignore on unsupported embedders/tests
    }
  }

  Future<void> minimize() async {
    testActionObserver?.call('minimize');
    if (!_isDesktopWindows) return;
    try {
      await _channel.invokeMethod<void>('minimize');
    } catch (_) {}
  }

  Future<void> toggleMaximize() async {
    testActionObserver?.call('toggleMaximize');
    if (!_isDesktopWindows) {
      isMaximized.value = !isMaximized.value;
      return;
    }
    try {
      final result = await _channel.invokeMethod<bool>('toggleMaximize');
      if (result != null) {
        isMaximized.value = result;
      }
    } catch (_) {}
  }

  Future<void> close() async {
    testActionObserver?.call('close');
    try {
      AppStateService().flushSaveSync();
      unawaited(BackendService().stopOwnedBackend());
    } catch (_) {}
    if (!_isDesktopWindows) return;
    try {
      await _channel.invokeMethod<void>('close');
    } catch (_) {}
  }

  Future<void> startDragging() async {
    testActionObserver?.call('startDragging');
    if (!_isDesktopWindows) return;
    try {
      await _channel.invokeMethod<void>('startDragging');
    } catch (_) {}
  }

  Future<void> startResize(String edge) async {
    testActionObserver?.call('startResize', edge);
    if (!_isDesktopWindows) return;
    try {
      await _channel.invokeMethod<void>('startResize', edge);
    } catch (_) {}
  }

  Future<void> showSystemMenu() async {
    testActionObserver?.call('showSystemMenu');
    if (!_isDesktopWindows) return;
    try {
      await _channel.invokeMethod<void>('showSystemMenu');
    } catch (_) {}
  }

  Future<bool> openInExplorer(String path) async {
    testActionObserver?.call('openInExplorer', path);
    if (!_isDesktopWindows) return false;
    try {
      final result = await _channel.invokeMethod<bool>('openInExplorer', path);
      return result == true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  void resetForTest() {
    testActionObserver = null;
    isMaximized.value = false;
    _initialized = false;
  }
}
