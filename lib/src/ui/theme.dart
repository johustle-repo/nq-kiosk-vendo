import 'package:flutter/material.dart';

const kBrandSeed = Color(0xFF018E4E); // VeNdO logo green

/// Fixed kiosk palette (dark, high contrast, readable from a distance).
/// Colours taken from the VeNdO logo: charcoal letters (#36383A), the green
/// "N" (#018E4E) and its circuit highlights (#01C166), and the gold peso coin.
class KioskPalette {
  static const background = Color(0xFF17181A);
  static const surface = Color(0xFF222427);
  static const surfaceHigh = Color(0xFF2D3033);
  static const outline = Color(0xFF42464A);
  static const accent = Color(0xFF1FC370);
  static const accentDeep = Color(0xFF018E4E);
  static const charcoal = Color(0xFF36383A);
  static const logoBackground = Color(0xFFFEFEFE);
  static const coin = Color(0xFFF2B22E);
  static const ok = Color(0xFF34D27B);
  static const warn = Color(0xFFF59E0B);
  static const danger = Color(0xFFF87171);
  static const textMuted = Color(0xFFA4A9AE);
}

/// How urgent the remaining time is (drives the timer card colours).
enum TimeLevel { none, normal, low, critical }

TimeLevel timeLevel(int remainingMs) {
  if (remainingMs <= 0) return TimeLevel.none;
  if (remainingMs <= 60000) return TimeLevel.critical;
  if (remainingMs <= 300000) return TimeLevel.low;
  return TimeLevel.normal;
}

Color timeLevelColor(TimeLevel l) => switch (l) {
  TimeLevel.none => KioskPalette.textMuted,
  TimeLevel.normal => KioskPalette.accent,
  TimeLevel.low => KioskPalette.warn,
  TimeLevel.critical => KioskPalette.danger,
};

ThemeData buildTheme(Brightness brightness) {
  // The kiosk always uses the dark palette; [brightness] is kept for callers.
  final scheme =
      ColorScheme.fromSeed(
        seedColor: kBrandSeed,
        brightness: Brightness.dark,
      ).copyWith(
        primary: KioskPalette.accent,
        onPrimary: const Color(0xFF032313),
        primaryContainer: KioskPalette.accentDeep,
        onPrimaryContainer: const Color(0xFFD2F6E2),
        surface: KioskPalette.surface,
        surfaceContainerHighest: KioskPalette.surfaceHigh,
        outline: KioskPalette.outline,
        error: KioskPalette.danger,
      );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: Brightness.dark,
  );
  return base.copyWith(
    scaffoldBackgroundColor: KioskPalette.background,
    textTheme: base.textTheme.apply(
      bodyColor: const Color(0xFFE8E9EA),
      displayColor: Colors.white,
    ),
    cardTheme: CardThemeData(
      color: KioskPalette.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: KioskPalette.outline),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: KioskPalette.background,
      elevation: 0,
      centerTitle: false,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: KioskPalette.surfaceHigh,
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        side: const BorderSide(color: KioskPalette.outline),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: KioskPalette.surfaceHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: const DividerThemeData(color: KioskPalette.outline),
  );
}

/// Large monospace digits for the countdown.
TextStyle timerStyle(BuildContext context, double size, {Color? color}) =>
    TextStyle(
      fontSize: size,
      fontWeight: FontWeight.w800,
      fontFeatures: const [FontFeature.tabularFigures()],
      letterSpacing: 3,
      height: 1.0,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );
