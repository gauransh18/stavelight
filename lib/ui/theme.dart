import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final light = brightness == Brightness.light;
  final seeded = ColorScheme.fromSeed(
    seedColor: SlColors.seed,
    brightness: brightness,
    secondary: SlColors.brass,
    contrastLevel: highContrast ? 1.0 : 0.0,
  );
  // Tonal-spot containers drift towards cyan; keep them in the lake-teal family.
  final scheme = highContrast
      ? seeded
      : seeded.copyWith(
          primary: light ? null : const Color(0xFF8FC9CC),
          primaryContainer: light ? const Color(0xFFD3E8E8) : const Color(0xFF1F4A50),
          onPrimaryContainer: light ? const Color(0xFF0B3D43) : const Color(0xFFD3ECEC),
          secondaryContainer: light ? const Color(0xFFDCEBEA) : const Color(0xFF2A3E41),
          onSecondaryContainer: light ? const Color(0xFF14363A) : const Color(0xFFD6E8E8),
        );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final surface = light ? Colors.white : const Color(0xFF182024);
  final background = light ? const Color(0xFFF6F4EF) : const Color(0xFF0F1416);
  const button = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0);
  return base.copyWith(
    scaffoldBackgroundColor: background,
    textTheme: _tightText(base.textTheme),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // A transparent bar reads as "dark" to the platform and flips the status icons white.
      systemOverlayStyle: light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(64, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), textStyle: button),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: button,
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(textStyle: button.copyWith(fontSize: 15))),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
      highlightElevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      extendedTextStyle: button,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: scheme.outlineVariant),
        selectedBackgroundColor: scheme.primaryContainer,
        selectedForegroundColor: scheme.onPrimaryContainer,
        textStyle: button.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: background, surfaceTintColor: Colors.transparent),
    dialogTheme: DialogThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
    chipTheme: base.chipTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    sliderTheme: base.sliderTheme.copyWith(showValueIndicator: ShowValueIndicator.onDrag),
  );
}

/// Material's default tracking (0.5 on body text) reads loose with SF Pro and Roboto alike.
TextTheme _tightText(TextTheme t) => t.copyWith(
      headlineMedium: t.headlineMedium?.copyWith(letterSpacing: -0.4, fontWeight: FontWeight.w600),
      headlineSmall: t.headlineSmall?.copyWith(letterSpacing: -0.3, fontWeight: FontWeight.w600),
      titleLarge: t.titleLarge?.copyWith(letterSpacing: -0.2, fontWeight: FontWeight.w600),
      titleMedium: t.titleMedium?.copyWith(letterSpacing: 0, fontWeight: FontWeight.w600),
      titleSmall: t.titleSmall?.copyWith(letterSpacing: 0),
      bodyLarge: t.bodyLarge?.copyWith(letterSpacing: 0, height: 1.4),
      bodyMedium: t.bodyMedium?.copyWith(letterSpacing: 0, height: 1.4),
      bodySmall: t.bodySmall?.copyWith(letterSpacing: 0, height: 1.35),
      labelLarge: t.labelLarge?.copyWith(letterSpacing: 0),
      labelMedium: t.labelMedium?.copyWith(letterSpacing: 0),
    );
