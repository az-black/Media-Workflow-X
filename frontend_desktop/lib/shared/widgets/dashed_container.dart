import 'package:flutter/material.dart';

class DashedContainer extends StatefulWidget {
  final Widget? child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final Color borderColor;
  final double borderWidth;
  final double borderRadius;
  final Color? fillColor;
  final Color? hoverFillColor;
  final VoidCallback? onTap;
  final double dashLength;
  final double dashGap;

  const DashedContainer({
    super.key,
    this.child,
    this.width,
    this.height,
    this.padding = EdgeInsets.zero,
    this.borderColor = const Color(0xFF00C8E8),
    this.borderWidth = 1.5,
    this.borderRadius = 10,
    this.fillColor,
    this.hoverFillColor,
    this.onTap,
    this.dashLength = 6.0,
    this.dashGap = 4.0,
  });

  @override
  State<DashedContainer> createState() => _DashedContainerState();
}

class _DashedContainerState extends State<DashedContainer> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final currentFill = _isHovered && widget.hoverFillColor != null
        ? widget.hoverFillColor
        : widget.fillColor;

    Widget content = CustomPaint(
      painter: _DashedRRectPainter(
        color: widget.borderColor,
        strokeWidth: widget.borderWidth,
        radius: widget.borderRadius,
        dashLength: widget.dashLength,
        dashGap: widget.dashGap,
        fillColor: currentFill,
      ),
      child: Container(
        width: widget.width,
        height: widget.height,
        padding: widget.padding,
        child: widget.child,
      ),
    );

    if (widget.onTap != null) {
      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: content,
        ),
      );
    }
    return content;
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double radius;
  final double dashLength;
  final double dashGap;
  final Color? fillColor;

  _DashedRRectPainter({
    required this.color,
    required this.strokeWidth,
    required this.radius,
    required this.dashLength,
    required this.dashGap,
    this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    if (fillColor != null) {
      final fillPaint = Paint()
        ..color = fillColor!
        ..style = PaintingStyle.fill;
      canvas.drawRRect(rrect, fillPaint);
    }

    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final dashPath = Path();
    for (final metric in path.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        final currentLength = (distance + dashLength <= metric.length)
            ? dashLength
            : metric.length - distance;
        dashPath.addPath(
          metric.extractPath(distance, distance + currentLength),
          Offset.zero,
        );
        distance += dashLength + dashGap;
      }
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.radius != radius ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.dashGap != dashGap;
  }
}
