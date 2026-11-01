import 'package:flutter/material.dart';

import '../core/model/score.dart';

/// Stavelight visual identity: deep lake-teal with a warm brass accent, calm surfaces.
class SlColors {
  static const seed = Color(0xFF1E6A73);
  static const brass = Color(0xFFC9892B);

  /// Hand colors are always paired with a shape/label (never color alone).
  static Color hand(Hand h, Brightness b, {bool highContrast = false}) {
    final dark = b == Brightness.dark;
    return switch (h) {
      Hand.right => highContrast ? (dark ? const Color(0xFF6FE3FF) : const Color(0xFF00518C)) : (dark ? const Color(0xFF5CC8D4) : const Color(0xFF1B7F8C)),
      Hand.left => highContrast ? (dark ? const Color(0xFFFFC14D) : const Color(0xFF8A4B00)) : (dark ? const Color(0xFFE8A84A) : const Color(0xFFB66E12)),
      Hand.unassigned => dark ? const Color(0xFFB7A6E0) : const Color(0xFF6A55A8),
    };
  }

  static const good = Color(0xFF2E8B57);
  static const warn = Color(0xFFC77700);
  static const bad = Color(0xFFC0392B);
  static const unsure = Color(0xFF7A7F87);
}

ThemeData buildTheme(Brightness brightness, {bool highContrast = false}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: SlColors.seed,
    brightness: brightness,
    secondary: SlColors.brass,
    contrastLevel: highContrast ? 1.0 : 0.0,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  return base.copyWith(
    scaffoldBackgroundColor: brightness == Brightness.light ? const Color(0xFFF6F4EF) : const Color(0xFF0F1416),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: brightness == Brightness.light ? Colors.white : const Color(0xFF182024),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(64, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(64, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    sliderTheme: base.sliderTheme.copyWith(showValueIndicator: ShowValueIndicator.onDrag),
  );
}
