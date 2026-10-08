import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Stands in for a page that is built in a later step.
class PlaceholderPage extends StatelessWidget {
  final String title;
  final IconData icon;

  const PlaceholderPage({super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 40, color: AppColors.textMuted),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text('This page is built in a later step.', style: TextStyle(color: AppColors.textSecondary)),
      ]),
    );
  }
}
