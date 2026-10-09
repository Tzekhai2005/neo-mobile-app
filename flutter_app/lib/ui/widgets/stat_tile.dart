import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A big number with a name and one line under it, like "3 · Events today". Tapped
/// it goes to the page that explains the number.
class StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final String line;
  final VoidCallback onTap;

  const StatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    required this.line,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 20, color: AppColors.accent),
              const Spacer(),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
            ]),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: AppColors.navy)),
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(line, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ]),
        ),
      ),
    );
  }
}
