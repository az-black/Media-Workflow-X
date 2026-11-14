import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class AppActionButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool isPrimary;
  final double minWidth;

  const AppActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isPrimary = true,
    this.minWidth = 130,
  });

  @override
  State<AppActionButton> createState() => _AppActionButtonState();
}

class _AppActionButtonState extends State<AppActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isPrimary
        ? (_isHovered ? AppColors.darkTealButtonHover : AppColors.darkTealButton)
        : (_isHovered ? Colors.white12 : Colors.transparent);

    final borderColor = widget.isPrimary
        ? (_isHovered ? AppColors.primaryCyan : AppColors.borderCyan)
        : Colors.white24;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        constraints: BoxConstraints(minWidth: widget.minWidth),
        height: 38,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: bgColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(19),
              side: BorderSide(color: borderColor, width: 1.2),
            ),
            elevation: _isHovered && widget.isPrimary ? 4 : 0,
            shadowColor: AppColors.primaryCyan.withValues(alpha: 0.3),
          ),
          onPressed: widget.onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: 16,
                  color: widget.isPrimary ? AppColors.primaryCyan : Colors.white70,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
