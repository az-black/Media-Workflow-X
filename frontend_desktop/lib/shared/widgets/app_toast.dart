import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/services/backend_service.dart';

enum AppToastType {
  success,
  info,
  warning,
  error,
}

class AppToast {
  AppToast._();

  static void showSuccess(
    BuildContext context, {
    required String message,
    String title = 'Proses Berhasil',
    String? badgeLabel,
    String? folderPath,
    Duration? duration,
  }) {
    show(
      context,
      message: message,
      title: title,
      type: AppToastType.success,
      badgeLabel: badgeLabel,
      folderPath: folderPath,
      duration: duration,
    );
  }

  static void showInfo(
    BuildContext context, {
    required String message,
    String title = 'Informasi',
    String? badgeLabel,
    String? folderPath,
    Duration? duration,
  }) {
    show(
      context,
      message: message,
      title: title,
      type: AppToastType.info,
      badgeLabel: badgeLabel,
      folderPath: folderPath,
      duration: duration,
    );
  }

  static void showWarning(
    BuildContext context, {
    required String message,
    String title = 'Perhatian',
    String? badgeLabel,
    Duration? duration,
  }) {
    show(
      context,
      message: message,
      title: title,
      type: AppToastType.warning,
      badgeLabel: badgeLabel,
      duration: duration,
    );
  }

  static void showError(
    BuildContext context, {
    required String message,
    String title = 'Proses Gagal',
    String? badgeLabel,
    Duration? duration,
  }) {
    show(
      context,
      message: message,
      title: title,
      type: AppToastType.error,
      badgeLabel: badgeLabel,
      duration: duration,
    );
  }

  static void show(
    BuildContext context, {
    required String message,
    String? title,
    AppToastType type = AppToastType.info,
    String? badgeLabel,
    String? folderPath,
    Duration? duration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final hasFolder = folderPath != null && folderPath.trim().isNotEmpty;
    final resolvedDuration = duration ??
        switch (type) {
          AppToastType.success =>
            Duration(seconds: hasFolder ? 6 : 3),
          AppToastType.error => const Duration(seconds: 5),
          AppToastType.warning => const Duration(seconds: 3),
          AppToastType.info => const Duration(seconds: 3),
        };

    final resolvedTitle = title ??
        switch (type) {
          AppToastType.success => 'Proses Berhasil',
          AppToastType.info => 'Informasi',
          AppToastType.warning => 'Perhatian',
          AppToastType.error => 'Proses Gagal',
        };

    final screenWidth = MediaQuery.sizeOf(context).width;
    final EdgeInsets margin;
    if (screenWidth >= 900) {
      final cardWidth = (screenWidth * 0.256).clamp(324.0, 384.0).toDouble();
      final leftMargin =
          (screenWidth - cardWidth - 14).clamp(16.0, double.infinity);
      margin = EdgeInsets.only(left: leftMargin, right: 14, bottom: 16);
    } else if (screenWidth >= 540) {
      final cardWidth = 420.0;
      final sideMargin = ((screenWidth - cardWidth) / 2).clamp(16.0, 400.0).toDouble();
      margin = EdgeInsets.fromLTRB(sideMargin, 0, sideMargin, 16);
    } else {
      margin = const EdgeInsets.fromLTRB(12, 0, 12, 12);
    }

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        margin: margin,
        dismissDirection: DismissDirection.horizontal,
        duration: resolvedDuration,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        content: _AppToastCard(
          type: type,
          title: resolvedTitle,
          message: message,
          badgeLabel: badgeLabel,
          folderPath: hasFolder ? folderPath.trim() : null,
          fallbackMessenger: messenger,
        ),
      ),
    );
  }
}

class _ToastPalette {
  final Color bgStart;
  final Color bgEnd;
  final Color accentStart;
  final Color accentEnd;
  final Color borderColor;
  final Color glowColor;
  final IconData icon;

  const _ToastPalette({
    required this.bgStart,
    required this.bgEnd,
    required this.accentStart,
    required this.accentEnd,
    required this.borderColor,
    required this.glowColor,
    required this.icon,
  });

  factory _ToastPalette.of(AppToastType type) {
    switch (type) {
      case AppToastType.success:
        return _ToastPalette(
          bgStart: const Color(0xFF0E3242),
          bgEnd: const Color(0xFF071A26),
          accentStart: const Color(0xFF00E5B0),
          accentEnd: AppColors.primaryCyan,
          borderColor: const Color(0xFF00E5B0).withValues(alpha: 0.62),
          glowColor: const Color(0xFF00E5B0).withValues(alpha: 0.20),
          icon: Icons.check_rounded,
        );
      case AppToastType.info:
        return _ToastPalette(
          bgStart: const Color(0xFF0E2B3E),
          bgEnd: const Color(0xFF071925),
          accentStart: AppColors.primaryCyan,
          accentEnd: AppColors.secondaryCyan,
          borderColor: AppColors.primaryCyan.withValues(alpha: 0.55),
          glowColor: AppColors.primaryCyan.withValues(alpha: 0.18),
          icon: Icons.info_outline_rounded,
        );
      case AppToastType.warning:
        return _ToastPalette(
          bgStart: const Color(0xFF282114),
          bgEnd: const Color(0xFF14151D),
          accentStart: const Color(0xFFFFB74D),
          accentEnd: AppColors.accentAmber,
          borderColor: AppColors.accentAmber.withValues(alpha: 0.58),
          glowColor: AppColors.accentAmber.withValues(alpha: 0.16),
          icon: Icons.warning_amber_rounded,
        );
      case AppToastType.error:
        return _ToastPalette(
          bgStart: const Color(0xFF2D141B),
          bgEnd: const Color(0xFF150E14),
          accentStart: const Color(0xFFFF6B6B),
          accentEnd: AppColors.accentRed,
          borderColor: const Color(0xFFFF5252).withValues(alpha: 0.60),
          glowColor: AppColors.accentRed.withValues(alpha: 0.18),
          icon: Icons.error_outline_rounded,
        );
    }
  }
}

class _AppToastCard extends StatefulWidget {
  final AppToastType type;
  final String title;
  final String message;
  final String? badgeLabel;
  final String? folderPath;
  final ScaffoldMessengerState fallbackMessenger;

  const _AppToastCard({
    required this.type,
    required this.title,
    required this.message,
    this.badgeLabel,
    this.folderPath,
    required this.fallbackMessenger,
  });

  @override
  State<_AppToastCard> createState() => _AppToastCardState();
}

class _AppToastCardState extends State<_AppToastCard> {
  bool _closeHovered = false;
  bool _openHovered = false;

  void _dismiss(BuildContext context) {
    final messenger =
        ScaffoldMessenger.maybeOf(context) ?? widget.fallbackMessenger;
    messenger.hideCurrentSnackBar();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _ToastPalette.of(widget.type);
    final hasBadge =
        widget.badgeLabel != null && widget.badgeLabel!.trim().isNotEmpty;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      builder: (context, anim, child) {
        return Transform.translate(
          offset: Offset(0, (1 - anim) * 10),
          child: Opacity(
            opacity: anim.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
      child: Container(
        key: const Key('app_toast_card'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [palette.bgStart, palette.bgEnd],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.borderColor, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.50),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: palette.glowColor,
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Stack(
            children: [
              // Subtle top-left radial highlight sheen
              Positioned(
                top: -28,
                left: -20,
                child: IgnorePointer(
                  child: Container(
                    width: 110,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          palette.accentStart.withValues(alpha: 0.14),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 11, 11, 11),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header row: glowing icon badge + title + optional tag + close button
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(9),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                palette.accentStart.withValues(alpha: 0.26),
                                palette.accentEnd.withValues(alpha: 0.12),
                              ],
                            ),
                            border: Border.all(
                              color: palette.accentStart.withValues(alpha: 0.55),
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            palette.icon,
                            color: palette.accentStart,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textWhite,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        if (hasBadge) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: palette.accentStart.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: palette.accentStart.withValues(alpha: 0.45),
                                width: 0.9,
                              ),
                            ),
                            child: Text(
                              widget.badgeLabel!.trim(),
                              style: TextStyle(
                                color: palette.accentStart,
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.35,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        MouseRegion(
                          onEnter: (_) => setState(() => _closeHovered = true),
                          onExit: (_) => setState(() => _closeHovered = false),
                          cursor: SystemMouseCursors.click,
                          child: Tooltip(
                            message: 'Tutup Notifikasi',
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: const Key('app_toast_close_button'),
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => _dismiss(context),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: _closeHovered
                                        ? Colors.white.withValues(alpha: 0.12)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Icon(
                                    Icons.close_rounded,
                                    size: 15,
                                    color: _closeHovered
                                        ? Colors.white
                                        : Colors.white60,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),

                    // Body description aligned cleanly under title
                    Padding(
                      padding: const EdgeInsets.only(left: 37),
                      child: Text(
                        widget.message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFDCEBF4),
                          fontSize: 11.5,
                          height: 1.38,
                        ),
                      ),
                    ),

                    // Optional saved destination folder chip + open explorer button
                    if (widget.folderPath != null) ...[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(left: 37),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF041018).withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: palette.accentEnd.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_rounded,
                                size: 13.5,
                                color: palette.accentEnd,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Tooltip(
                                  message: widget.folderPath!,
                                  child: Text(
                                    widget.folderPath!,
                                    key: const Key('app_toast_folder_path'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              MouseRegion(
                                onEnter: (_) =>
                                    setState(() => _openHovered = true),
                                onExit: (_) =>
                                    setState(() => _openHovered = false),
                                cursor: SystemMouseCursors.click,
                                child: Tooltip(
                                  message:
                                      'Buka folder penyimpanan di File Explorer',
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      key: const Key(
                                        'app_toast_open_folder_button',
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                      onTap: () => BackendService()
                                          .openInExplorer(widget.folderPath!),
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 120),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 3.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: palette.accentEnd.withValues(
                                            alpha: _openHovered ? 0.28 : 0.16,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                            color: palette.accentEnd.withValues(
                                              alpha: _openHovered ? 0.8 : 0.45,
                                            ),
                                            width: 0.9,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.open_in_new_rounded,
                                              size: 11,
                                              color: palette.accentEnd,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              'Buka Folder',
                                              style: TextStyle(
                                                color: palette.accentEnd,
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Left vertical glowing accent bar
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [palette.accentStart, palette.accentEnd],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
