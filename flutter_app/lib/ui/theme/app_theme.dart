import 'package:flutter/material.dart';

/// Every colour in the app, in one place. The values come from the Epile-X
/// website (neuravancelabs.com): white and pale blue surfaces, navy text, one
/// bright blue accent. Change them here and every page follows. The font is the
/// phone's own.
abstract final class AppColors {
  // Surfaces.
  static const background = Color(0xFFFCFEFF);
  static const surface = Color(0xFFFFFFFF); // cards and tiles
  static const surfaceSoft = Color(0xFFE8F6FF); // tinted bands
  static const surfaceHigh = Color(0xFFEAF3FB); // quiet fills (chips, rows)
  static const border = Color(0xFFDAE2EB);

  // Text.
  static const text = Color(0xFF02102B);
  static const textSecondary = Color(0xFF3A485D);
  static const textMuted = Color(0xFF5F6E84);

  // Brand: navy for strong elements, blue for the accent.
  static const navy = Color(0xFF05173F);
  static const onNavy = Color(0xFFF8FAFC);
  static const accent = Color(0xFF2885EF);
  static const accentSoft = Color(0xFFD1E7FF);
  static const onAccent = Color(0xFFFFFFFF);

  // Signal traces: one colour per EEG channel, one per motion axis. Dark enough
  // to read on a white lane.
  static const channel = [Color(0xFF1A7F8E), Color(0xFF6B4FBB), Color(0xFFC77700), Color(0xFF2E8B57)];
  static const axis = [Color(0xFF2885EF), Color(0xFFD98A00), Color(0xFFD4472B)]; // x, y, z

  // Status. The website has no green or amber, so these two are our own.
  static const success = Color(0xFF1E9E63);
  static const warning = Color(0xFFD98A00);
  static const danger = Color(0xFFE62C2C);
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppColors.navy,
    onPrimary: AppColors.onNavy,
    secondary: AppColors.accent,
    onSecondary: AppColors.onAccent,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    error: AppColors.danger,
    outline: AppColors.border,
  );
  final base = ThemeData(brightness: Brightness.light, useMaterial3: true);
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    dividerColor: AppColors.border,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.accentSoft,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
          color: states.contains(WidgetState.selected) ? AppColors.navy : AppColors.textSecondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? AppColors.navy : AppColors.textSecondary,
        ),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.surface, surfaceTintColor: Colors.transparent),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: AppColors.accent)),
  );
}
