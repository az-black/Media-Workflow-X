import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/services/window_control_service.dart';
import 'app_brand_logo.dart';

class WindowTitleBar extends StatelessWidget {
  static const double barHeight = 34.0;

  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final windowService = WindowControlService();

    return ValueListenableBuilder<bool>(
      valueListenable: windowService.isMaximized,
      builder: (context, isMaximized, _) {
        return Container(
          height: barHeight,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0xFF030B12),
                Color(0xFF05131E),
                Color(0xFF030B13),
              ],
            ),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
          ),
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      key: const Key('window_titlebar_drag_area'),
                      behavior: HitTestBehavior.translucent,
                      onDoubleTap: () => windowService.toggleMaximize(),
                      onPanStart: (_) => windowService.startDragging(),
                      onSecondaryTapUp: (_) => windowService.showSystemMenu(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            const AppBrandLogo(
                              key: Key('titlebar_brand_logo'),
                              size: 22,
                              borderRadius: 6,
                              showBorder: true,
                              showGlow: false,
                            ),
                            const SizedBox(width: 9),
                            const Text(
                              'Media Workflow X',
                              style: TextStyle(
                                color: AppColors.textWhite,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.35,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primaryCyan
                                    .withValues(alpha: 0.11),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: AppColors.primaryCyan
                                      .withValues(alpha: 0.32),
                                ),
                              ),
                              child: const Text(
                                'Desktop Studio',
                                style: TextStyle(
                                  color: AppColors.primaryCyan,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _WindowCaptionButton(
                    key: const Key('window_minimize_button'),
                    tooltip: 'Minimize',
                    icon: Icons.remove_rounded,
                    iconSize: 15,
                    onTap: () => windowService.minimize(),
                  ),
                  _WindowCaptionButton(
                    key: const Key('window_maximize_button'),
                    tooltip: isMaximized ? 'Restore Down' : 'Maximize',
                    icon: isMaximized
                        ? Icons.filter_none_rounded
                        : Icons.crop_square_rounded,
                    iconSize: isMaximized ? 12.5 : 14,
                    onTap: () => windowService.toggleMaximize(),
                  ),
                  _WindowCaptionButton(
                    key: const Key('window_close_button'),
                    tooltip: 'Tutup Aplikasi',
                    icon: Icons.close_rounded,
                    iconSize: 15.5,
                    isClose: true,
                    onTap: () => windowService.close(),
                  ),
                ],
              ),

              // Subtle top-edge native resize handles when window is restored
              if (!isMaximized)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 4,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 8,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeUpLeftDownRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanStart: (_) =>
                                windowService.startResize('topLeft'),
                          ),
                        ),
                      ),
                      Expanded(
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeUpDown,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanStart: (_) => windowService.startResize('top'),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 8,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeUpRightDownLeft,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onPanStart: (_) =>
                                windowService.startResize('topRight'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _WindowCaptionButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final bool isClose;
  final VoidCallback onTap;

  const _WindowCaptionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.iconSize,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WindowCaptionButton> createState() => _WindowCaptionButtonState();
}

class _WindowCaptionButtonState extends State<_WindowCaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = _hovered
        ? (widget.isClose
            ? const Color(0xFFE81123)
            : Colors.white.withValues(alpha: 0.09))
        : Colors.transparent;

    final fgColor = _hovered
        ? Colors.white
        : (widget.isClose ? Colors.white70 : Colors.white70);

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            width: 44,
            height: WindowTitleBar.barHeight,
            color: bgColor,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: fgColor,
            ),
          ),
        ),
      ),
    );
  }
}
