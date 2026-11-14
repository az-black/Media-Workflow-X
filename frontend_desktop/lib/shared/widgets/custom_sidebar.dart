import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/app_state_service.dart';
import 'app_brand_logo.dart';

class CustomSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;

  const CustomSidebar({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppStateService(),
      builder: (context, _) {
        final appState = AppStateService();
        final engineText = 'Engine: ${appState.engineShortName}';

        return Container(
          width: 200,
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border(
              right: BorderSide(
                color: Colors.white.withValues(alpha: 0.07),
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Brand Logo & App Name (di atas menu Dasboard)
              Container(
                margin: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF0A2030),
                      Color(0xFF061521),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primaryCyan.withValues(alpha: 0.24),
                  ),
                ),
                child: const Row(
                  children: [
                    AppBrandLogo(
                      key: Key('sidebar_brand_logo'),
                      size: 38,
                      borderRadius: 9,
                      showBorder: true,
                      showGlow: true,
                    ),
                    SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Media Workflow X',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textWhite,
                              fontWeight: FontWeight.bold,
                              fontSize: 11.2,
                              letterSpacing: 0.2,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'MEDIA & PDF SUITE',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.primaryCyan,
                              fontWeight: FontWeight.w700,
                              fontSize: 8.5,
                              letterSpacing: 0.75,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              const SizedBox(height: 10),

              // Menu Items
              _SidebarItem(
                index: 0,
                icon: Icons.dashboard,
                label: 'Dasboard',
                isSelected: selectedIndex == 0,
                onTap: () => onItemSelected(0),
              ),
              _SidebarItem(
                index: 1,
                icon: Icons.tune,
                label: 'Engine Config',
                isSelected: selectedIndex == 1,
                onTap: () => onItemSelected(1),
              ),
              _SidebarItem(
                index: 2,
                icon: Icons.assignment_outlined,
                label: 'Logs & History',
                isSelected: selectedIndex == 2,
                onTap: () => onItemSelected(2),
              ),
              _SidebarItem(
                index: 3,
                icon: Icons.settings_outlined,
                label: 'Settings',
                isSelected: selectedIndex == 3,
                onTap: () => onItemSelected(3),
              ),

              const Spacer(),

              // Bottom Engine Status Indicator
              Tooltip(
                message: 'Klik untuk membuka konfigurasi engine (${appState.engineDisplayName})',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => onItemSelected(1),
                    child: Container(
                      margin: const EdgeInsets.all(12),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selectedIndex == 1 ? AppColors.primaryCyan : Colors.white10,
                        ),
                      ),
                      child: Row(
                        children: [
                          if (appState.isEngineConnecting)
                            const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.orangeAccent,
                              ),
                            )
                          else if (appState.isEngineOnline)
                            const Icon(
                              Icons.check_circle_rounded,
                              size: 12,
                              color: Color(0xFF00E676),
                            )
                          else
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              appState.isEngineOnline
                                  ? '$engineText (Online) ✓'
                                  : (appState.isEngineConnecting
                                      ? '$engineText (Menyiapkan...)'
                                      : '$engineText (Offline)'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const Text(
                            'v1.0',
                            style: TextStyle(
                              color: Colors.white30,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final int index;
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.index,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isSelected
        ? AppColors.primaryCyan
        : (_isHovered ? Colors.white.withValues(alpha: 0.06) : Colors.transparent);

    final fgColor = widget.isSelected ? Colors.black : AppColors.textWhite;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 18,
                    color: widget.isSelected ? Colors.black : AppColors.primaryCyan,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: fgColor,
                        fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
