import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class CustomDropdown extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  final double? width;
  final double height;
  final bool showSelectedSubtitle;

  const CustomDropdown({
    super.key,
    required this.icon,
    required this.label,
    required this.items,
    required this.onChanged,
    this.value,
    this.width,
    this.height = 44,
    this.showSelectedSubtitle = false,
  });

  @override
  State<CustomDropdown> createState() => _CustomDropdownState();
}

class _CustomDropdownState extends State<CustomDropdown> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        width: widget.width,
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: _isHovered ? AppColors.cardHover : AppColors.cardBackground,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _isHovered ? AppColors.primaryCyan : AppColors.borderCyan,
            width: 1.5,
          ),
          boxShadow: _isHovered ? AppColors.cyanGlowShadow : null,
        ),
        child: PopupMenuButton<String>(
          tooltip: widget.label,
          color: AppColors.surface,
          position: PopupMenuPosition.under,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.borderCyan, width: 1.5),
          ),
          onSelected: widget.onChanged,
          itemBuilder: (context) {
            return widget.items.map((item) {
              final isSelected = item == widget.value;
              return PopupMenuItem<String>(
                value: item,
                height: 38,
                child: Row(
                  children: [
                    Icon(
                      isSelected ? Icons.check : Icons.circle_outlined,
                      size: 14,
                      color: isSelected ? AppColors.primaryCyan : Colors.white30,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item,
                        style: TextStyle(
                          color: isSelected ? AppColors.primaryCyan : Colors.white,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList();
          },
          child: Row(
            children: [
              Icon(widget.icon, color: AppColors.primaryCyan, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textWhite,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (widget.value != null && widget.showSelectedSubtitle)
                      Text(
                        widget.value!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.primaryCyan,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_drop_down,
                color: AppColors.primaryCyan,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
