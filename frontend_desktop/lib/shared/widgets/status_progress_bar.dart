import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/backend_service.dart';

class StatusProgressBar extends StatefulWidget {
  final bool isProcessing;
  final double progress;
  final String? idleMessage;
  final String? processingMessage;
  final String? completedMessage;
  final String? stageLabel;
  final String? detailText;
  final int? completedItems;
  final int? totalItems;
  final String itemUnitLabel;
  final bool hasError;
  final String? errorMessage;
  final bool wasCancelled;
  final String? cancelledMessage;
  final Duration? elapsedOverride;
  final DateTime? startedAt;
  final VoidCallback? onDismissResult;
  final bool compact;
  final double? height;

  const StatusProgressBar({
    super.key,
    required this.isProcessing,
    required this.progress,
    this.idleMessage,
    this.processingMessage,
    this.completedMessage,
    this.stageLabel,
    this.detailText,
    this.completedItems,
    this.totalItems,
    this.itemUnitLabel = 'file',
    this.hasError = false,
    this.errorMessage,
    this.wasCancelled = false,
    this.cancelledMessage,
    this.elapsedOverride,
    this.startedAt,
    this.onDismissResult,
    this.compact = false,
    this.height,
  });

  static String formatRuntime(
    Duration duration, {
    required bool isProcessing,
  }) {
    final totalMs = math.max(0, duration.inMilliseconds);
    if (totalMs < 60000) {
      final seconds = totalMs / 1000.0;
      final decimals =
          (!isProcessing && totalMs > 0 && totalMs < 1000) ? 2 : 1;
      return '${seconds.toStringAsFixed(decimals)}s';
    }
    final minutes = totalMs ~/ 60000;
    final remSeconds = (totalMs % 60000) / 1000.0;
    return '${minutes}m ${remSeconds.toStringAsFixed(1).padLeft(4, '0')}s';
  }

  @override
  State<StatusProgressBar> createState() => _StatusProgressBarState();
}

class _StatusProgressBarState extends State<StatusProgressBar>
    with SingleTickerProviderStateMixin {
  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;
  int _testTickMs = 0;
  Duration? _completedDuration;
  late final AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _syncTimersAndStopwatch(isInit: true);
  }

  @override
  void didUpdateWidget(covariant StatusProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimersAndStopwatch(oldIsProcessing: oldWidget.isProcessing);
  }

  void _syncTimersAndStopwatch({
    bool isInit = false,
    bool? oldIsProcessing,
  }) {
    if (widget.isProcessing) {
      final transitionedToProcessing =
          isInit || (oldIsProcessing == false && widget.isProcessing);
      if (transitionedToProcessing) {
        _completedDuration = null;
        _testTickMs = 0;
        _stopwatch
          ..reset()
          ..start();
      } else if (!_stopwatch.isRunning) {
        _stopwatch.start();
      }

      _ticker ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
        _testTickMs += 100;
        if (mounted) {
          setState(() {});
        }
      });

      if (!_shimmerController.isAnimating) {
        _shimmerController.repeat();
      }
      return;
    }

    // Not processing anymore: strictly stop all repeating timers/animations
    // so tests calling pumpAndSettle() never hang.
    final wasRunning = _ticker != null ||
        _stopwatch.isRunning ||
        (oldIsProcessing == true);
    _ticker?.cancel();
    _ticker = null;
    if (_shimmerController.isAnimating) {
      _shimmerController.stop();
    }

    if (wasRunning) {
      _stopwatch.stop();
      final measuredMs = BackendService.isRunningUnderFlutterTest()
          ? math.max(_stopwatch.elapsedMilliseconds, _testTickMs)
          : _stopwatch.elapsedMilliseconds;
      if (widget.progress >= 1.0 || widget.hasError || widget.wasCancelled) {
        _completedDuration = Duration(milliseconds: measuredMs);
      } else {
        _stopwatch.reset();
        _testTickMs = 0;
        _completedDuration = null;
      }
    } else if (!widget.hasError &&
        !widget.wasCancelled &&
        widget.progress <= 0.0 &&
        widget.elapsedOverride == null) {
      _stopwatch.reset();
      _testTickMs = 0;
      _completedDuration = null;
    }
  }

  Duration get _effectiveElapsed {
    if (widget.isProcessing) {
      if (BackendService.isRunningUnderFlutterTest()) {
        return Duration(
          milliseconds: math.max(_stopwatch.elapsedMilliseconds, _testTickMs),
        );
      }
      if (widget.startedAt != null) {
        final diff = DateTime.now().difference(widget.startedAt!);
        if (!diff.isNegative) {
          return diff;
        }
      }
      return _stopwatch.elapsed;
    }

    if (widget.elapsedOverride != null) {
      return widget.elapsedOverride!;
    }
    return _completedDuration ?? Duration.zero;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    _stopwatch.stop();
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isDone =
        !widget.isProcessing && widget.progress >= 1.0 && !widget.hasError;
    final bool isError = !widget.isProcessing && widget.hasError;
    final bool isCancelled =
        !widget.isProcessing && !widget.hasError && widget.wasCancelled;

    final double clampedProgress = widget.isProcessing
        ? widget.progress.clamp(0.02, 0.99)
        : (isDone ? 1.0 : widget.progress.clamp(0.0, 1.0));
    final int percent = (clampedProgress * 100).round().clamp(0, 100);

    final Color accentColor;
    final String statusBadgeLabel;
    final String primaryMessage;

    if (widget.isProcessing) {
      accentColor = AppColors.primaryCyan;
      statusBadgeLabel = 'MEMPROSES';
      primaryMessage =
          widget.processingMessage ?? 'Memproses tugas... ($percent%)';
    } else if (isError) {
      accentColor = AppColors.accentRed;
      statusBadgeLabel = 'GAGAL';
      primaryMessage = widget.errorMessage ?? 'Proses gagal dijalankan.';
    } else if (isCancelled) {
      accentColor = AppColors.accentAmber;
      statusBadgeLabel = 'DIBATALKAN';
      primaryMessage =
          widget.cancelledMessage ?? 'Proses dibatalkan oleh pengguna.';
    } else if (isDone) {
      accentColor = const Color(0xFF00E676);
      statusBadgeLabel = 'SELESAI';
      primaryMessage = widget.completedMessage ??
          'Proses selesai! Seluruh output siap disimpan.';
    } else {
      accentColor = AppColors.textMuted;
      statusBadgeLabel = 'SIAP';
      primaryMessage = widget.idleMessage ?? 'Siap untuk diproses';
    }

    final Duration elapsed = _effectiveElapsed;
    final String runtimeStr = StatusProgressBar.formatRuntime(
      elapsed,
      isProcessing: widget.isProcessing,
    );
    final bool hasMeasuredRuntime = widget.isProcessing ||
        isDone ||
        isError ||
        isCancelled ||
        elapsed > Duration.zero;

    final bool showItemCounter = widget.totalItems != null &&
        widget.totalItems! > 0 &&
        (widget.isProcessing || isDone || isError || isCancelled);
    final int shownCompleted = isDone
        ? widget.totalItems!
        : (widget.completedItems ?? 0).clamp(0, widget.totalItems ?? 0);

    final double cardVerticalPad = widget.compact ? 6.0 : 8.0;
    final double cardHorizontalPad = widget.compact ? 12.0 : 14.0;
    final double barHeight = widget.compact ? 5.0 : 6.5;

    final String fullTooltip = (widget.detailText != null &&
            widget.detailText!.trim().isNotEmpty)
        ? '$primaryMessage • ${widget.detailText!.trim()}'
        : primaryMessage;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: double.infinity,
      constraints: widget.height != null
          ? BoxConstraints(minHeight: widget.height!)
          : null,
      padding: EdgeInsets.symmetric(
        horizontal: cardHorizontalPad,
        vertical: cardVerticalPad,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.isProcessing
              ? const [Color(0xFF072132), Color(0xFF051520)]
              : isDone
                  ? const [Color(0xFF062322), Color(0xFF051519)]
                  : isError
                      ? const [Color(0xFF231018), Color(0xFF14090E)]
                      : isCancelled
                          ? const [Color(0xFF211A0C), Color(0xFF130F07)]
                          : const [Color(0xFF061925), Color(0xFF04111B)],
        ),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: widget.isProcessing
              ? AppColors.primaryCyan.withValues(alpha: 0.78)
              : isDone
                  ? const Color(0xFF00E676).withValues(alpha: 0.65)
                  : isError
                      ? AppColors.accentRed.withValues(alpha: 0.65)
                      : isCancelled
                          ? AppColors.accentAmber.withValues(alpha: 0.55)
                          : AppColors.primaryCyan.withValues(alpha: 0.25),
          width: widget.isProcessing || isDone ? 1.4 : 1.1,
        ),
        boxShadow: widget.isProcessing
            ? [
                BoxShadow(
                  color: AppColors.primaryCyan.withValues(alpha: 0.16),
                  blurRadius: 12,
                  spreadRadius: 0.5,
                ),
              ]
            : isDone
                ? [
                    BoxShadow(
                      color: const Color(0xFF00E676).withValues(alpha: 0.12),
                      blurRadius: 10,
                    ),
                  ]
                : const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 5,
                      offset: Offset(0, 2),
                    ),
                  ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top Telemetry Row
          Row(
            children: [
              // Status Pill
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.compact ? 7 : 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.55),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.isProcessing) ...[
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                        ),
                      ),
                    ] else
                      Icon(
                        isDone
                            ? Icons.check_circle_rounded
                            : isError
                                ? Icons.error_outline_rounded
                                : isCancelled
                                    ? Icons.cancel_outlined
                                    : Icons.bolt_rounded,
                        color: accentColor,
                        size: 12,
                      ),
                    const SizedBox(width: 5),
                    Text(
                      statusBadgeLabel,
                      key: const Key('status_progress_badge_text'),
                      style: TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.w800,
                        fontSize: widget.compact ? 9.5 : 10,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),

              if (widget.stageLabel != null &&
                  widget.stageLabel!.trim().isNotEmpty &&
                  !widget.compact) ...[
                const SizedBox(width: 7),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    widget.stageLabel!.trim(),
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],

              const SizedBox(width: 9),

              // Main Message + Optional Detail Subtitle
              Expanded(
                child: Tooltip(
                  message: fullTooltip,
                  waitDuration: const Duration(milliseconds: 350),
                  child: RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: primaryMessage,
                          style: TextStyle(
                            color: widget.isProcessing || isDone
                                ? Colors.white
                                : isError
                                    ? const Color(0xFFFFCDD2)
                                    : isCancelled
                                        ? const Color(0xFFFFE082)
                                        : Colors.white.withValues(alpha: 0.88),
                            fontWeight: widget.isProcessing || isDone
                                ? FontWeight.w600
                                : FontWeight.w500,
                            fontSize: widget.compact ? 11.5 : 12,
                            letterSpacing: 0.15,
                          ),
                        ),
                        if (widget.detailText != null &&
                            widget.detailText!.trim().isNotEmpty)
                          TextSpan(
                            text: '  •  ${widget.detailText!.trim()}',
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontWeight: FontWeight.w500,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Completed / Total Item Counter Pill
              if (showItemCounter) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    '$shownCompleted/${widget.totalItems} ${widget.itemUnitLabel}',
                    key: const Key('status_progress_items_text'),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],

              // Runtime Timer Pill
              Tooltip(
                message: widget.isProcessing
                    ? 'Durasi proses sedang berjalan'
                    : (isDone
                        ? 'Total run time proses terakhir'
                        : 'Durasi run time proses'),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 7 : 8,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: hasMeasuredRuntime
                        ? accentColor.withValues(alpha: 0.13)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: hasMeasuredRuntime
                          ? accentColor.withValues(alpha: 0.45)
                          : Colors.white12,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        size: 12.5,
                        color: hasMeasuredRuntime
                            ? accentColor
                            : AppColors.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Runtime: $runtimeStr',
                        key: const Key('status_progress_runtime_text'),
                        style: TextStyle(
                          color: hasMeasuredRuntime
                              ? Colors.white
                              : AppColors.textMuted,
                          fontSize: widget.compact ? 10.5 : 11,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 6),

              // Percentage Readout
              Container(
                constraints: const BoxConstraints(minWidth: 40),
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: (widget.isProcessing || isDone)
                      ? accentColor.withValues(alpha: 0.16)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$percent%',
                  key: const Key('status_progress_percent_text'),
                  style: TextStyle(
                    color: (widget.isProcessing || isDone)
                        ? accentColor
                        : AppColors.textMuted,
                    fontSize: widget.compact ? 10.5 : 11,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),

              if (widget.onDismissResult != null && !widget.isProcessing) ...[
                const SizedBox(width: 5),
                Tooltip(
                  message: 'Tutup ringkasan proses',
                  child: InkWell(
                    onTap: widget.onDismissResult,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),

          SizedBox(height: widget.compact ? 5.0 : 6.0),

          // Bottom Segmented / Shimmering Progress Track
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: clampedProgress),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, _) {
              final fillFactor = animatedValue.clamp(0.0, 1.0);
              return Container(
                height: barHeight,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(barHeight),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(barHeight),
                  child: Stack(
                    children: [
                      if (fillFactor > 0.0)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: fillFactor,
                            heightFactor: 1.0,
                            child: AnimatedBuilder(
                              animation: _shimmerController,
                              builder: (context, _) {
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    DecoratedBox(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: isDone
                                              ? const [
                                                  Color(0xFF00B248),
                                                  Color(0xFF00E676),
                                                  Color(0xFF69F0AE),
                                                ]
                                              : isError
                                                  ? const [
                                                      Color(0xFFB71C1C),
                                                      AppColors.accentRed,
                                                    ]
                                                  : isCancelled
                                                      ? const [
                                                          Color(0xFFE65100),
                                                          AppColors.accentAmber,
                                                        ]
                                                      : const [
                                                          AppColors.secondaryCyan,
                                                          AppColors.primaryCyan,
                                                          Color(0xFF64FFDA),
                                                        ],
                                        ),
                                      ),
                                    ),
                                    if (widget.isProcessing)
                                      FractionallySizedBox(
                                        alignment: Alignment(
                                          -1.6 + (_shimmerController.value * 3.2),
                                          0,
                                        ),
                                        widthFactor: 0.35,
                                        heightFactor: 1.0,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: [
                                                Colors.white.withValues(alpha: 0.0),
                                                Colors.white.withValues(alpha: 0.42),
                                                Colors.white.withValues(alpha: 0.0),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
