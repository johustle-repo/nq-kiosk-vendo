import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Size classes for the kiosk screens (Material window-size breakpoints).
enum ScreenClass { compact, medium, expanded }

/// Layout decisions derived from the available space. Everything that depends
/// on screen size goes through here so phones and tablets stay consistent.
class Responsive {
  const Responsive(this.width, this.height);

  factory Responsive.of(BoxConstraints c) =>
      Responsive(c.maxWidth, c.maxHeight.isFinite ? c.maxHeight : 800);

  final double width;
  final double height;

  ScreenClass get screenClass => width < 600
      ? ScreenClass.compact
      : width < 840
      ? ScreenClass.medium
      : ScreenClass.expanded;

  bool get isCompact => screenClass == ScreenClass.compact;
  bool get isExpanded => screenClass == ScreenClass.expanded;

  /// A phone turned sideways: wide but very short.
  bool get isLandscapePhone => width > height && height < 520;

  /// Use side-by-side columns (tablet landscape, desktop, landscape phone).
  bool get twoColumns => isExpanded || isLandscapePhone;

  double get gutter => switch (screenClass) {
    ScreenClass.compact => 16,
    ScreenClass.medium => 28,
    ScreenClass.expanded => 40,
  };

  double get maxContentWidth => 1280;

  /// Countdown digit size that fits the space (FittedBox scales further if needed).
  double get timerSize {
    if (isLandscapePhone) return math.min(height * 0.17, 64);
    return switch (screenClass) {
      ScreenClass.compact => math.min(width * 0.15, 68),
      ScreenClass.medium => 88,
      ScreenClass.expanded => 100,
    };
  }

  double get coinSize {
    if (isLandscapePhone) return 64;
    return switch (screenClass) {
      ScreenClass.compact => 76,
      ScreenClass.medium => 104,
      ScreenClass.expanded => 120,
    };
  }

  /// Minimum app tile width; the grid fits as many columns as possible.
  double get appTileMinWidth => isLandscapePhone
      ? 112
      : switch (screenClass) {
          ScreenClass.compact => 104,
          ScreenClass.medium => 120,
          ScreenClass.expanded => 136,
        };

  /// Tile width / height: shorter tiles where vertical space is scarce.
  double get appTileAspect =>
      isLandscapePhone ? 1.05 : (isCompact ? 0.78 : 0.9);

  /// Very short screens (landscape phones) get a slimmer header and banner.
  bool get isShort => height < 520;

  int appColumns(double gridWidth) =>
      (gridWidth / appTileMinWidth).floor().clamp(2, 8);

  /// Width of the timer side panel in two-column layouts.
  double get sidePanelWidth => isLandscapePhone
      ? math.min(width * 0.42, 340)
      : math.min(width * 0.30, 360);
}

/// Caps very large system font settings so the kiosk layout cannot break,
/// while still honouring moderate accessibility scaling.
Widget clampTextScale(BuildContext context, Widget? child, {double max = 1.3}) {
  final mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(
      textScaler: mq.textScaler.clamp(minScaleFactor: 1.0, maxScaleFactor: max),
    ),
    child: child ?? const SizedBox.shrink(),
  );
}
