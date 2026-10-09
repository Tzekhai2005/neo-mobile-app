import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../theme/app_theme.dart';

/// The logo from [kLogoAsset], or the brand name as text when there is none (or
/// the file is missing), so the start page never shows a broken image.
class BrandLogo extends StatelessWidget {
  final double width;

  /// Overrides [kLogoAsset]; empty means text only.
  final String? asset;

  const BrandLogo({super.key, this.width = 200, this.asset});

  @override
  Widget build(BuildContext context) {
    final path = asset ?? kLogoAsset;
    Widget text() => Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            kBrandName,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
          if (kBrandByline.isNotEmpty)
            const Text(kBrandByline, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        ]);
    if (path.isEmpty) return text();
    return Image.asset(
      path,
      width: width,
      fit: BoxFit.contain,
      semanticLabel: kBrandByline.isEmpty ? kBrandName : '$kBrandName $kBrandByline',
      errorBuilder: (_, __, ___) => text(),
    );
  }
}
