import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';

class CustomHeader extends StatelessWidget {
  final String title;

  const CustomHeader({super.key, this.title = 'Pusat Eksekusi Mesin'});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF04101A),
            Color(0xFF05131F),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.06),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Center Title
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textWhite,
                fontWeight: FontWeight.bold,
                fontSize: 14,
                letterSpacing: 1.05,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
