import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One of the three cards on the start page: an icon, a name and one honest
/// line about the page's state.
class DestinationTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String line;

  /// A small status dot before the line; null for none.
  final Color? dot;
  final VoidCallback onTap;

  const DestinationTile({
    super.key,
    required this.icon,
    required this.label,
    required this.line,
    required this.onTap,
    this.dot,
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
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: AppColors.accent, size: 26),
            const SizedBox(height: 14),
            Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (dot != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 6),
                  child: Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                ),
              Expanded(child: Text(line, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
            ]),
          ]),
        ),
      ),
    );
  }
}
