import 'package:flutter/material.dart';

const kBrandSeed = Color(0xFF018E4E); // VeNdO logo green

/// Fixed kiosk palette: light, matching the VeNdO logo artwork (charcoal
/// letters #36383A on white, the green "N" #018E4E, the gold peso coin).
class KioskPalette {
  static const background = Color(0xFFF4F5F5);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceHigh = Color(0xFFEDEFF0);
  static const outline = Color(0xFFD9DCDF);
  static const accent = Color(0xFF018E4E);
  static const accentDeep = Color(0xFF017040);
  static const charcoal = Color(0xFF36383A);
  static const text = Color(0xFF1F2123);
  static const logoBackground = Color(0xFFFEFEFE);
  static const coin = Color(0xFFB97D0C);
  static const ok = Color(0xFF138A4C);
  static const warn = Color(0xFFB86E00);
  static const danger = Color(0xFFC62F2B);
  static const textMuted = Color(0xFF5F6468);
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
  // The kiosk always uses the light palette; [brightness] is kept for callers.
  final scheme =
      ColorScheme.fromSeed(
        seedColor: kBrandSeed,
        brightness: Brightness.light,
      ).copyWith(
        primary: KioskPalette.accent,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFD3F2E2),
        onPrimaryContainer: const Color(0xFF00391F),
        onSurface: KioskPalette.text,
        surface: KioskPalette.surface,
        surfaceContainerHighest: KioskPalette.surfaceHigh,
        outline: KioskPalette.outline,
        error: KioskPalette.danger,
      );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: Brightness.light,
  );
  return base.copyWith(
    scaffoldBackgroundColor: KioskPalette.background,
    textTheme: base.textTheme.apply(
      bodyColor: KioskPalette.text,
      displayColor: KioskPalette.text,
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
      backgroundColor: KioskPalette.charcoal,
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
      fillColor: KioskPalette.surface,
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
