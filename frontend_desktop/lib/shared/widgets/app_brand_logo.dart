import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';

class AppBrandLogo extends StatelessWidget {
  static const String assetPath = 'assets/images/media_workflow_x.png';

  final double size;
  final double borderRadius;
  final bool showBorder;
  final bool showGlow;

  const AppBrandLogo({
    super.key,
    this.size = 38,
    this.borderRadius = 9,
    this.showBorder = true,
    this.showGlow = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF070F21),
        borderRadius: BorderRadius.circular(borderRadius),
        border: showBorder
            ? Border.all(
                color: AppColors.primaryCyan.withValues(alpha: 0.48),
                width: 1.1,
              )
            : null,
        boxShadow: showGlow
            ? [
                BoxShadow(
                  color: AppColors.primaryCyan.withValues(alpha: 0.24),
                  blurRadius: 10,
                  spreadRadius: 0.5,
                ),
                BoxShadow(
                  color: const Color(0xFFA855F7).withValues(alpha: 0.16),
                  blurRadius: 12,
                  offset: const Offset(2, 2),
                ),
              ]
            : const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          (borderRadius - (showBorder ? 1.0 : 0.0)).clamp(2.0, borderRadius),
        ),
        child: Transform.scale(
          scale: 1.24,
          child: Image.asset(
            assetPath,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => Container(
              color: const Color(0xFF070F21),
              alignment: Alignment.center,
              child: Icon(
                Icons.auto_awesome_rounded,
                color: AppColors.primaryCyan,
                size: size * 0.55,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
