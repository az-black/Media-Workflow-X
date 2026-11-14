import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import 'compress_convert_view.dart';
import 'convert_only_view.dart';
import 'upscale_ai_view.dart';

class MediaToolsView extends StatefulWidget {
  const MediaToolsView({super.key});

  @override
  State<MediaToolsView> createState() => _MediaToolsViewState();
}

class _MediaToolsViewState extends State<MediaToolsView> {
  final AppStateService _appState = AppStateService();
  int get _selectedToolCard => _appState.mediaToolsTabIndex;

  @override
  void initState() {
    super.initState();
    _appState.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _appState.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top 3 Action Cards
        Row(
          children: [
            Expanded(
              child: _ActionCard(
                index: 0,
                icon: Icons.sync_alt,
                title: 'Convert Only',
                subtitle: 'Format conversion only\n(e.g., PNG to JPG etc.)',
                isSelected: _selectedToolCard == 0,
                onTap: () => setState(() => _appState.setMediaToolsTabIndex(0)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionCard(
                index: 1,
                icon: Icons.keyboard_double_arrow_right,
                title: 'Compress & Convert',
                subtitle: 'Reduce size and change\nformat',
                isSelected: _selectedToolCard == 1,
                onTap: () => setState(() => _appState.setMediaToolsTabIndex(1)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ActionCard(
                index: 2,
                icon: Icons.auto_awesome,
                title: 'Upscale AI',
                subtitle: 'Enhance image resolution\nwith AI',
                isSelected: _selectedToolCard == 2,
                onTap: () => setState(() => _appState.setMediaToolsTabIndex(2)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Body View
        Expanded(
          child: IndexedStack(
            index: _selectedToolCard,
            children: const [
              ConvertOnlyView(),
              CompressConvertView(),
              UpscaleAiView(),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatefulWidget {
  final int index;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _ActionCard({
    required this.index,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.isSelected
        ? AppColors.primaryCyan
        : (_isHovered ? AppColors.borderCyanMuted : Colors.white12);

    final bgColor = widget.isSelected
        ? AppColors.cardBackground
        : (_isHovered ? AppColors.cardHover : AppColors.cardBackground);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 74,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
              width: widget.isSelected ? 2 : 1.2,
            ),
            boxShadow: widget.isSelected ? AppColors.cyanGlowShadow : AppColors.cardShadow,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.isSelected
                      ? AppColors.primaryCyan.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  border: Border.all(
                    color: widget.isSelected ? AppColors.primaryCyan : Colors.white24,
                    width: 1.5,
                  ),
                ),
                child: Icon(
                  widget.icon,
                  color: AppColors.primaryCyan,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.isSelected ? AppColors.primaryCyan : AppColors.textWhite,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
