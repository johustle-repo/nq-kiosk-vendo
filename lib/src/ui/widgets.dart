import 'dart:async';

import 'package:flutter/material.dart';

import '../model/rates.dart';
import 'theme.dart';

/// Dark brand panel (charcoal into VeNdO green) with two soft glows. Holds the
/// countdown on every screen so the time is always the focal point.
class HeroPanel extends StatelessWidget {
  const HeroPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.radius = 28,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: KioskPalette.heroGradient,
      boxShadow: kHeroShadow,
    ),
    child: Stack(
      // Passthrough: a stretched panel hands its full height to [child].
      fit: StackFit.passthrough,
      children: [
        const Positioned(
          right: -90,
          top: -110,
          child: _Glow(size: 280, color: KioskPalette.mint, alpha: 0.18),
        ),
        const Positioned(
          left: -80,
          bottom: -130,
          child: _Glow(size: 260, color: KioskPalette.gold, alpha: 0.10),
        ),
        Padding(padding: padding, child: child),
      ],
    ),
  );
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color, required this.alpha});

  final double size;
  final Color color;
  final double alpha;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    ),
  );
}

/// White card with a soft shadow: the container for every light section.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 24,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: KioskPalette.surface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: KioskPalette.outline.withValues(alpha: 0.6)),
      boxShadow: kCardShadow,
    ),
    child: child,
  );
}

/// Section heading: tinted icon square, title and an optional subtitle.
class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.color = KioskPalette.accent,
    this.large = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final box = large ? 42.0 : 34.0;
    return Row(
      children: [
        Container(
          width: box,
          height: box,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(box * 0.32),
          ),
          child: Icon(icon, size: box * 0.55, color: color),
        ),
        SizedBox(width: large ? 14 : 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: large ? 21 : 17,
                  fontWeight: FontWeight.w800,
                  color: KioskPalette.text,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: large ? 14.5 : 12.5,
                    color: KioskPalette.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The big remaining-time card on the dark brand panel. The label and digits
/// turn gold at ≤5 min and coral at ≤1 min.
class TimerCard extends StatelessWidget {
  const TimerCard({
    super.key,
    required this.remainingMs,
    required this.label,
    this.size = 72,
    this.footer,
  });

  final int remainingMs;
  final String label;
  final double size;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final level = timeLevel(remainingMs);
    final color = timeLevelColorOnInk(level);
    final urgent = level == TimeLevel.low || level == TimeLevel.critical;
    return HeroPanel(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _InkLabel(icon: Icons.timer_outlined, text: label, color: color),
          const SizedBox(height: 8),
          CountdownText(
            remainingMs: remainingMs,
            size: size,
            color: urgent ? color : KioskPalette.onInk,
          ),
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    );
  }
}

/// Small uppercase chip used as the label above the countdown.
class _InkLabel extends StatelessWidget {
  const _InkLabel({
    required this.icon,
    required this.text,
    required this.color,
    this.large = false,
  });

  final IconData icon;
  final String text;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: large ? 16 : 12,
      vertical: large ? 7 : 5,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(40),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: large ? 20 : 16),
        const SizedBox(width: 7),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
                fontSize: large ? 15 : 12.5,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Slim one-line timer for phones, so the app grid stays above the fold.
class TimerBar extends StatelessWidget {
  const TimerBar({
    super.key,
    required this.remainingMs,
    required this.label,
    this.hint,
  });

  final int remainingMs;
  final String label;

  /// Optional line under the time (e.g. the low-time warning).
  final Widget? hint;

  @override
  Widget build(BuildContext context) {
    final level = timeLevel(remainingMs);
    final color = timeLevelColorOnInk(level);
    final urgent = level == TimeLevel.low || level == TimeLevel.critical;
    return HeroPanel(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.timer_outlined, color: color, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: CountdownText(
                    remainingMs: remainingMs,
                    size: 40,
                    color: urgent ? color : KioskPalette.onInk,
                  ),
                ),
              ),
            ],
          ),
          if (hint != null) ...[const SizedBox(height: 8), hint!],
        ],
      ),
    );
  }
}

/// The countdown block of the payment screen: label chip and large digits.
class HeroCountdown extends StatelessWidget {
  const HeroCountdown({
    super.key,
    required this.remainingMs,
    this.size = 80,
    this.large = false,
  });

  final int remainingMs;
  final double size;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final level = timeLevel(remainingMs);
    final color = timeLevelColorOnInk(level);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _InkLabel(
          icon: Icons.timer_outlined,
          text: 'Time remaining',
          color: color,
          large: large,
        ),
        SizedBox(height: large ? 16 : 10),
        CountdownText(
          remainingMs: remainingMs,
          size: size,
          color: level == TimeLevel.low || level == TimeLevel.critical
              ? color
              : KioskPalette.onInk,
        ),
      ],
    );
  }
}

/// "Insert coin to start" call to action in VeNdO gold. Only a real coin
/// starts a session, so tapping it just explains what to do.
class InsertCoinButton extends StatelessWidget {
  const InsertCoinButton({super.key, this.onPressed, this.large = false});

  final VoidCallback? onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    key: const Key('insert-coin-button'),
    onPressed:
        onPressed ??
        () => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'Drop a coin in the slot. Your time starts right away.',
              ),
              duration: Duration(seconds: 3),
            ),
          ),
    icon: Image.asset(
      kCoinAsset,
      width: large ? 30 : 22,
      height: large ? 30 : 22,
    ),
    style: FilledButton.styleFrom(
      backgroundColor: KioskPalette.gold,
      foregroundColor: KioskPalette.ink,
      elevation: 0,
      shadowColor: Colors.transparent,
      minimumSize: Size(0, large ? 60 : 46),
      padding: EdgeInsets.symmetric(
        horizontal: large ? 34 : 22,
        vertical: large ? 14 : 10,
      ),
      textStyle: TextStyle(
        fontSize: large ? 21 : 16,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
      shape: const StadiumBorder(),
    ),
    label: const Text('Insert coin to start'),
  );
}

/// Top of the customer screens: the VeNdO wordmark on the left, the tablet
/// badge (shared coin box) and the clock on the right.
class KioskTopBar extends StatelessWidget {
  const KioskTopBar({super.key, this.compact = false, this.trailing});

  final bool compact;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(
        child: Align(
          alignment: Alignment.centerLeft,
          child: BrandLogo(plate: false, height: compact ? 44 : 54),
        ),
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (trailing != null) ...[trailing!, const SizedBox(width: 10)],
                ClockChip(large: !compact),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// Current time in a white pill (refreshes every 15 s).
class ClockChip extends StatefulWidget {
  const ClockChip({super.key, this.large = false});

  final bool large;

  @override
  State<ClockChip> createState() => _ClockChipState();
}

class _ClockChipState extends State<ClockChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final large = widget.large;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 16 : 12,
        vertical: large ? 9 : 7,
      ),
      decoration: BoxDecoration(
        color: KioskPalette.surface,
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: KioskPalette.outline.withValues(alpha: 0.6)),
        boxShadow: kCardShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule,
            size: large ? 20 : 16,
            color: KioskPalette.accent,
          ),
          const SizedBox(width: 7),
          Text(
            clockText(DateTime.now()),
            style: TextStyle(
              fontSize: large ? 17 : 14,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: KioskPalette.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// Rates as one card: a row per coin (gold peso badge, duration on the right)
/// on alternating tints. [large] is for tablets.
class RateTable extends StatelessWidget {
  const RateTable({
    super.key,
    required this.secondsPerPulse,
    this.large = false,
    this.title = 'Rates',
    this.dense = false,
  });

  final int secondsPerPulse;
  final bool large;
  final String title;

  /// Smaller rows and no subtitle (the session sidebar).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final badge = large ? 40.0 : (dense ? 28.0 : 34.0);
    final value = large ? 22.0 : (dense ? 15.0 : 17.0);
    return SurfaceCard(
      radius: large ? 28 : 22,
      padding: EdgeInsets.fromLTRB(
        large ? 22 : 16,
        large ? 16 : 14,
        large ? 22 : 16,
        large ? 14 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(
            icon: Icons.sell_outlined,
            title: title,
            subtitle: dense ? null : 'Pesos in, playtime out',
            color: KioskPalette.coin,
            large: large,
          ),
          SizedBox(height: large ? 10 : 8),
          for (var i = 0; i < Rates.displayPulses.length; i++)
            Container(
              margin: EdgeInsets.only(top: i == 0 ? 0 : 4),
              padding: EdgeInsets.symmetric(
                horizontal: large ? 14 : 10,
                vertical: large ? 6 : (dense ? 3 : 5),
              ),
              decoration: BoxDecoration(
                color: i.isEven
                    ? KioskPalette.background
                    : KioskPalette.surface,
                borderRadius: BorderRadius.circular(large ? 16 : 14),
              ),
              child: Row(
                children: [
                  Container(
                    constraints: BoxConstraints(
                      minWidth: badge * 1.45,
                      minHeight: badge,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(badge),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFD35C), KioskPalette.gold],
                      ),
                      border: Border.all(
                        color: KioskPalette.coin.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      '₱${Rates.displayPulses[i]}',
                      style: TextStyle(
                        color: const Color(0xFF5A3A00),
                        fontWeight: FontWeight.w900,
                        fontSize: badge * 0.42,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: KioskPalette.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          Rates.describeDuration(
                            Rates.secondsFor(
                              Rates.displayPulses[i],
                              secondsPerPulse: secondsPerPulse,
                            ),
                          ),
                          key: Key('rate-${Rates.displayPulses[i]}'),
                          style: TextStyle(
                            fontSize: value,
                            fontWeight: FontWeight.w800,
                            color: KioskPalette.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: large ? 12 : 10),
          Row(
            children: [
              Icon(
                Icons.add_circle_outline,
                size: large ? 18 : 16,
                color: KioskPalette.accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Additional coins extend your time.',
                  style: TextStyle(
                    fontSize: large ? 15 : 13,
                    color: KioskPalette.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Three numbered steps: insert coins, choose an app, top up anytime.
class HowItWorks extends StatelessWidget {
  const HowItWorks({super.key, this.large = false});

  final bool large;

  static const _steps = [
    (Icons.paid_outlined, 'Insert coins', 'Every peso adds time'),
    (Icons.touch_app_outlined, 'Choose an app', 'Tap a game or app'),
    (Icons.more_time, 'Top up anytime', 'More coins, more time'),
  ];

  @override
  Widget build(BuildContext context) => SurfaceCard(
    radius: large ? 28 : 22,
    padding: EdgeInsets.all(large ? 16 : 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          icon: Icons.lightbulb_outline,
          title: 'How it works',
          large: large,
        ),
        SizedBox(height: large ? 16 : 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _steps.length; i++) ...[
              if (i > 0) SizedBox(width: large ? 12 : 8),
              Expanded(
                child: _Step(number: i + 1, step: _steps[i], large: large),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.step, required this.large});

  final int number;
  final (IconData, String, String) step;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final (icon, title, body) = step;
    final box = large ? 44.0 : 40.0;
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: box,
              height: box,
              decoration: BoxDecoration(
                color: KioskPalette.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(box * 0.32),
              ),
              child: Icon(icon, size: box * 0.52, color: KioskPalette.accent),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: KioskPalette.charcoal,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: large ? 10 : 8),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: large ? 15.5 : 13.5,
            fontWeight: FontWeight.w800,
            color: KioskPalette.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: large ? 13.5 : 12,
            color: KioskPalette.textMuted,
            height: 1.25,
          ),
        ),
      ],
    );
  }
}

/// "Tablet 2" badge on a shared coin box; green with a check when the
/// attendant has sent the next coins to this tablet.
class TabletBadge extends StatelessWidget {
  const TabletBadge({super.key, required this.station, this.ready = false});

  final int station;
  final bool ready;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('tablet-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    decoration: BoxDecoration(
      color: ready ? KioskPalette.accent : KioskPalette.surface,
      borderRadius: BorderRadius.circular(40),
      border: Border.all(
        color: ready
            ? KioskPalette.accent
            : KioskPalette.outline.withValues(alpha: 0.6),
      ),
      boxShadow: kCardShadow,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ready ? Icons.check_circle : Icons.tablet_android,
          size: 20,
          color: ready ? Colors.white : KioskPalette.accent,
        ),
        const SizedBox(width: 8),
        Text(
          'Tablet $station',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: ready ? Colors.white : KioskPalette.text,
          ),
        ),
      ],
    ),
  );
}

/// Why the kiosk cannot take coins right now: a short title and the full
/// explanation. [onInk] draws it for the dark hero panel.
class StatusNotice extends StatelessWidget {
  const StatusNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.color = KioskPalette.warn,
    this.large = false,
    this.onInk = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;
  final bool large;
  final bool onInk;

  @override
  Widget build(BuildContext context) {
    final iconBox = large ? 76.0 : 58.0;
    // The warning hues are too dark for the ink panel; use the bright ones.
    final tint = !onInk
        ? color
        : color == KioskPalette.danger
        ? KioskPalette.coral
        : KioskPalette.gold;
    return Container(
      padding: EdgeInsets.all(large ? 26 : 18),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: onInk ? 0.10 : 0.08),
        borderRadius: BorderRadius.circular(large ? 24 : 20),
        border: Border.all(color: tint.withValues(alpha: onInk ? 0.35 : 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconBox,
            height: iconBox,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tint.withValues(alpha: 0.18),
            ),
            child: Icon(icon, size: iconBox * 0.5, color: tint),
          ),
          SizedBox(height: large ? 16 : 12),
          Text(
            title,
            key: const Key('payment-headline'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: large ? 28 : 22,
              fontWeight: FontWeight.w900,
              color: onInk ? KioskPalette.onInk : KioskPalette.text,
            ),
          ),
          SizedBox(height: large ? 8 : 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: large ? 17 : 14.5,
              height: 1.4,
              color: onInk ? KioskPalette.onInkMuted : KioskPalette.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

const kLogoAsset = 'assets/images/vendo_logo.png';
const kCoinAsset = 'assets/images/vendo_coin.png';

/// The VeNdO wordmark on its own light plate (the artwork is dark-on-white, so
/// it needs the plate to read on the charcoal kiosk background).
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.height = 56, this.plate = true});

  final double height;
  final bool plate;

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      kLogoAsset,
      height: height,
      fit: BoxFit.contain,
      semanticLabel: 'VeNdO — Jo-hustle Smart Android',
    );
    if (!plate) return image;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: height * 0.22,
        vertical: height * 0.1,
      ),
      decoration: BoxDecoration(
        color: KioskPalette.logoBackground,
        borderRadius: BorderRadius.circular(height * 0.25),
      ),
      child: image,
    );
  }
}

class CountdownText extends StatelessWidget {
  const CountdownText({
    super.key,
    required this.remainingMs,
    this.size = 56,
    this.color,
  });

  final int remainingMs;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Remaining time ${formatHms(remainingMs)}',
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          formatHms(remainingMs),
          key: const Key('countdown'),
          style: timerStyle(context, size, color: color),
        ),
      ),
    );
  }
}

/// Unmissable demo warning. Demo mode must never look like a secure kiosk.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, this.preview = false});

  /// Web/desktop preview: no Android native layer at all.
  final bool preview;

  @override
  Widget build(BuildContext context) {
    // Slim strip: always visible, but it does not compete with the timer.
    return Container(
      key: const Key('demo-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: KioskPalette.warn.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(color: KioskPalette.warn.withValues(alpha: 0.35)),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.science_outlined,
            size: 16,
            color: KioskPalette.warn,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preview
                  ? 'BROWSER PREVIEW — UI only. No coin controller, no app launching, no kiosk enforcement. '
                        'Install the Android APK for the real kiosk.'
                  : 'DEMO MODE — coins are simulated and other apps are NOT securely restricted.',
              style: const TextStyle(
                color: KioskPalette.warn,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({
    super.key,
    required this.icon,
    required this.text,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: foreground.withValues(alpha: 0.25)),
    ),
    child: Row(
      children: [
        Icon(icon, color: foreground, size: 28),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: foreground,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 12-hour clock text, e.g. "1:42 PM".
String clockText(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Hidden administrator entry: tap the wrapped widget (the timer) [taps]
/// times within [window]. Nothing is shown to customers; the PIN is still
/// required afterwards.
class AdminEntry extends StatefulWidget {
  const AdminEntry({
    super.key,
    required this.onTriggered,
    required this.child,
    this.taps = 10,
    this.window = const Duration(seconds: 5),
  });

  final VoidCallback onTriggered;
  final Widget child;
  final int taps;
  final Duration window;

  @override
  State<AdminEntry> createState() => _AdminEntryState();
}

class _AdminEntryState extends State<AdminEntry> {
  int _count = 0;
  Timer? _window;

  void _onTap() {
    // The window starts at the first tap; after it ends the count resets.
    _window ??= Timer(widget.window, _reset);
    _count++;
    if (_count >= widget.taps) {
      _reset();
      widget.onTriggered();
    }
  }

  void _reset() {
    _window?.cancel();
    _window = null;
    _count = 0;
  }

  @override
  void dispose() {
    _window?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const Key('admin-entry'),
    behavior: HitTestBehavior.opaque,
    onTap: _onTap,
    child: widget.child,
  );
}

class SimulatedCoinButtons extends StatelessWidget {
  const SimulatedCoinButtons({
    super.key,
    required this.secondsPerPulse,
    required this.onCoin,
  });

  final int secondsPerPulse;
  final ValueChanged<int> onCoin;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: KioskPalette.warn.withValues(alpha: 0.4)),
        color: KioskPalette.warn.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.science_outlined,
                size: 16,
                color: KioskPalette.warn,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'SIMULATED COINS · demo only',
                  textAlign: TextAlign.center,
                  style: t.labelLarge?.copyWith(
                    color: KioskPalette.warn,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) {
              const gap = 10.0;
              final cols = box.maxWidth >= 520 ? 4 : 2;
              final w = (box.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final p in Rates.displayPulses)
                    SizedBox(
                      width: w,
                      child: OutlinedButton(
                        key: Key('sim-$p'),
                        onPressed: () => onCoin(p),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 8,
                          ),
                          foregroundColor: KioskPalette.warn,
                          side: BorderSide(
                            color: KioskPalette.warn.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '+₱$p',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                Rates.describeDuration(
                                  Rates.secondsFor(
                                    p,
                                    secondsPerPulse: secondsPerPulse,
                                  ),
                                ),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: KioskPalette.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(errorText(e))));
}

String errorText(Object e) {
  final s = e.toString();
  const known = {
    'admin_locked': 'Administrator session expired. Enter the PIN again.',
    'not_device_owner':
        'This app is not the Device Owner. See the provisioning instructions.',
    'wrong_code': 'Wrong pairing code.',
    'pairing_closed':
        'Pairing is not open. Hold the controller FLASH button for 3 seconds first.',
    'too_many_attempts':
        'Too many wrong codes. Re-open pairing on the controller.',
    'unreachable': 'Cannot reach the controller at that address.',
    'timeout': 'The controller did not answer in time.',
    'bad_address': 'Enter a private IPv4 address such as 192.168.1.50.',
    'invalid_code': 'Enrollment code is invalid, expired or already used.',
    'rate_limited': 'Too many attempts. Wait and try again.',
    'not_allowed': 'No paid time, or the app is not approved.',
    'controller_not_connected': 'Controller is not connected.',
    'lock_task_inactive': 'Kiosk lock was not active. Please try again.',
    'coin_box_outdated':
        'The coin box firmware needs an update for this. Ask the staff.',
    'controller_not_paired': 'The coin box is not paired with this tablet.',
    'preview_only':
        'Not available in the browser preview. Install the Android APK.',
  };
  for (final entry in known.entries) {
    if (s.contains(entry.key)) return entry.value;
  }
  return s.replaceFirst('KioskException: ', '');
}
