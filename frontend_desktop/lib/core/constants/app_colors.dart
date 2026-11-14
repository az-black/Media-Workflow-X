import 'package:flutter/material.dart';

class AppColors {
  // Backgrounds
  static const Color background = Color(0xFF071924);
  static const Color sidebarBackground = Color(0xFF05121B);
  static const Color headerBackground = Color(0xFF02070C);
  static const Color cardBackground = Color(0xFF0A2230);
  static const Color cardHover = Color(0xFF0F2E40);
  static const Color surface = Color(0xFF0D2A3B);
  static const Color surfaceLight = Color(0xFF14384E);

  // Cyan Accents
  static const Color primaryCyan = Color(0xFF00C8E8);
  static const Color secondaryCyan = Color(0xFF009AB6);
  static const Color borderCyan = Color(0xFF00C8E8);
  static const Color borderCyanMuted = Color(0x5500C8E8);
  static const Color cyanGlow = Color(0x3300C8E8);

  // Buttons
  static const Color darkTealButton = Color(0xFF103A4A);
  static const Color darkTealButtonHover = Color(0xFF164E63);

  // Status & Utility
  static const Color textWhite = Colors.white;
  static const Color textMuted = Color(0xFF8CA5B5);
  static const Color textDark = Color(0xFF0F1E28);
  static const Color accentGreen = Color(0xFF4CAF50);
  static const Color accentRed = Color(0xFFE53935);
  static const Color accentBlue = Color(0xFF1E88E5);
  static const Color accentAmber = Color(0xFFFFA000);

  // Shadows
  static List<BoxShadow> get cardShadow => [
        const BoxShadow(
          color: Colors.black38,
          blurRadius: 8,
          offset: Offset(0, 3),
        ),
      ];

  static List<BoxShadow> get cyanGlowShadow => [
        BoxShadow(
          color: primaryCyan.withValues(alpha: 0.25),
          blurRadius: 10,
          spreadRadius: 1,
        ),
      ];
}
