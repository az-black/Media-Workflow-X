import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/app_state_service.dart';
import '../../../../shared/widgets/custom_header.dart';
import '../../../../shared/widgets/custom_sidebar.dart';
import '../../../../shared/widgets/window_title_bar.dart';
import '../../../engine_config/presentation/screens/engine_config_view.dart';
import '../../../logs_history/presentation/screens/logs_history_view.dart';
import '../../../media_tools/presentation/widgets/media_tools_view.dart';
import '../../../pdf_manager/presentation/widgets/pdf_manager_view.dart';
import '../../../settings/presentation/screens/settings_view.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final AppStateService _appState = AppStateService();
  late int _selectedSidebarIndex;
  late int _selectedTopTab;

  @override
  void initState() {
    super.initState();
    _selectedSidebarIndex = _appState.selectedSidebarIndex;
    _selectedTopTab = _appState.selectedTopTab;
    _appState.addListener(_onAppStateChanged);
  }

  @override
  void dispose() {
    _appState.removeListener(_onAppStateChanged);
    super.dispose();
  }

  void _onAppStateChanged() {
    if (mounted) {
      if (_selectedSidebarIndex != _appState.selectedSidebarIndex ||
          _selectedTopTab != _appState.selectedTopTab) {
        setState(() {
          _selectedSidebarIndex = _appState.selectedSidebarIndex;
          _selectedTopTab = _appState.selectedTopTab;
        });
      }
    }
  }

  String get _headerTitle {
    switch (_selectedSidebarIndex) {
      case 1:
        return 'Konfigurasi Engine Dokumen & PDF';
      case 2:
        return 'Logs & Riwayat Eksekusi';
      case 3:
        return 'Pengaturan Sistem & Preferensi';
      case 0:
      default:
        return 'Pusat Eksekusi Mesin';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          // Custom Dark Native-Integrated Window Title Bar
          const WindowTitleBar(),

          Expanded(
            child: Row(
              children: [
                // Left Sidebar
                CustomSidebar(
                  selectedIndex: _selectedSidebarIndex,
                  onItemSelected: (index) {
                    _appState.setSelectedSidebarIndex(index);
                    setState(() => _selectedSidebarIndex = index);
                  },
                ),

                // Main Workspace
                Expanded(
                  child: Column(
                    children: [
                      // Window Workspace Header Bar
                      CustomHeader(title: _headerTitle),

                      // Top Segmented Switcher (Hanya ditampilkan pada Dashboard)
                      if (_selectedSidebarIndex == 0)
                        Container(
                          margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.cardBackground,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: AppColors.primaryCyan,
                              width: 1.5,
                            ),
                            boxShadow: AppColors.cardShadow,
                          ),
                          child: Row(
                            children: [
                              _buildTabButton(0, 'Media Tools'),
                              _buildTabButton(1, 'PDF Manager'),
                            ],
                          ),
                        ),

                      // Main Content View - IndexedStack guarantees state, data, and scroll positions are preserved across all window/tab switches
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                          child: IndexedStack(
                            index: _selectedSidebarIndex,
                            children: [
                              // Index 0: Dashboard (Media Tools & PDF Manager)
                              IndexedStack(
                                index: _selectedTopTab,
                                children: const [
                                  MediaToolsView(),
                                  PdfManagerView(),
                                ],
                              ),
                              // Index 1: Engine Config
                              const EngineConfigView(),
                              // Index 2: Logs & History
                              const LogsHistoryView(),
                              // Index 3: Settings
                              const SettingsView(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton(int index, String label) {
    final isSelected = _selectedTopTab == index;

    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            _appState.setSelectedTopTab(index);
            setState(() => _selectedTopTab = index);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primaryCyan : Colors.transparent,
              borderRadius: BorderRadius.circular(19),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: AppColors.primaryCyan.withValues(alpha: 0.35),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.black : AppColors.textWhite,
                fontWeight: FontWeight.bold,
                fontSize: 14,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
