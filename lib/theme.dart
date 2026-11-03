import 'package:flutter/material.dart';

/// Paleta oscura y de bajo brillo pensada para usar de noche.
class AppColors {
  static const background = Color(0xFF0B0D12);
  static const surface = Color(0xFF151922);
  static const surfaceHigh = Color(0xFF1E2430);
  static const accent = Color(0xFF7FA8D9);
  static const textPrimary = Color(0xFFD6DCE6);
  static const textSecondary = Color(0xFF8790A0);
  static const connected = Color(0xFF3DDC84);
  static const connecting = Color(0xFFF2B33D);
  static const danger = Color(0xFFE53935);
  static const dangerDark = Color(0xFF7A1010);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    surface: AppColors.surface,
    primary: AppColors.accent,
    error: AppColors.danger,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
