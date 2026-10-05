import 'dart:async';

import 'package:flutter/material.dart';

import '../model/rates.dart';
import 'theme.dart';

/// The big remaining-time card. Turns amber at ≤5 min and red at ≤1 min.
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
    final color = timeLevelColor(level);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.20), KioskPalette.surface],
        ),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                level == TimeLevel.none ? Icons.timer_outlined : Icons.timer,
                color: color,
                size: 22,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          CountdownText(
            remainingMs: remainingMs,
            size: size,
            color: level == TimeLevel.none ? null : color,
          ),
          if (footer != null) ...[const SizedBox(height: 10), footer!],
        ],
      ),
    );
  }
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
    final color = timeLevelColor(level);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [color.withValues(alpha: 0.20), KioskPalette.surface],
        ),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.timer, color: color, size: 22),
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
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (hint != null) ...[const SizedBox(height: 6), hint!],
        ],
      ),
    );
  }
}

/// Small "Insert coin to start" call to action. Only a real coin starts a
/// session, so tapping it just explains what to do (or wakes the idle screen).
class InsertCoinButton extends StatelessWidget {
  const InsertCoinButton({super.key, this.onPressed, this.large = false});

  final VoidCallback? onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) => FilledButton(
    key: const Key('insert-coin-button'),
    onPressed: onPressed ??
        () => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Drop a coin in the slot. Your time starts right away.'),
              duration: Duration(seconds: 3),
            ),
          ),
    style: FilledButton.styleFrom(
      backgroundColor: KioskPalette.accentDeep,
      foregroundColor: Colors.white,
      minimumSize: Size(0, large ? 56 : 40),
      padding: EdgeInsets.symmetric(horizontal: large ? 34 : 22, vertical: large ? 14 : 10),
      textStyle: TextStyle(fontSize: large ? 21 : 16, fontWeight: FontWeight.w700),
      shape: const StadiumBorder(),
    ),
    child: const Text('Insert coin to start'),
  );
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
      padding: EdgeInsets.symmetric(horizontal: height * 0.22, vertical: height * 0.1),
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

/// Rates as one clean card: a row per coin, value on the right. [large] is
/// for tablets, where the default sizes read too small from a distance.
class RateTable extends StatelessWidget {
  const RateTable({super.key, required this.secondsPerPulse, this.large = false});

  final int secondsPerPulse;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final badge = large ? 44.0 : 32.0;
    final label = large ? 20.0 : 16.0;
    final value = large ? 24.0 : 17.0;
    return Container(
      decoration: BoxDecoration(
        color: KioskPalette.surface,
        borderRadius: BorderRadius.circular(large ? 28 : 22),
        border: Border.all(color: KioskPalette.outline),
      ),
      padding: EdgeInsets.fromLTRB(large ? 28 : 18, large ? 22 : 14, large ? 28 : 18, large ? 20 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.sell_outlined, size: large ? 24 : 18, color: KioskPalette.coin),
              SizedBox(width: large ? 10 : 8),
              Text(
                'Rates',
                style: TextStyle(fontSize: large ? 22 : 17, fontWeight: FontWeight.w800, color: KioskPalette.text),
              ),
            ],
          ),
          SizedBox(height: large ? 10 : 6),
          for (var i = 0; i < Rates.displayPulses.length; i++)
            Container(
              padding: EdgeInsets.symmetric(vertical: large ? 16 : 11),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : const Border(top: BorderSide(color: KioskPalette.outline, width: 0.6)),
              ),
              child: Row(
                children: [
                  Container(
                    width: badge,
                    height: badge,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: KioskPalette.coin.withValues(alpha: 0.15),
                      border: Border.all(color: KioskPalette.coin.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      '${Rates.displayPulses[i]}',
                      style: TextStyle(
                        color: KioskPalette.coin,
                        fontWeight: FontWeight.w800,
                        fontSize: badge * 0.4,
                      ),
                    ),
                  ),
                  SizedBox(width: large ? 16 : 12),
                  Expanded(
                    child: Text(
                      'peso${Rates.displayPulses[i] == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: label, color: KioskPalette.textMuted),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Rates.describeDuration(
                        Rates.secondsFor(Rates.displayPulses[i], secondsPerPulse: secondsPerPulse),
                      ),
                      key: Key('rate-${Rates.displayPulses[i]}'),
                      style: TextStyle(fontSize: value, fontWeight: FontWeight.w800, color: KioskPalette.text),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: large ? 8 : 4),
          Row(
            children: [
              Icon(Icons.add_circle_outline, size: large ? 20 : 16, color: KioskPalette.accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Additional coins extend your time.',
                  style: TextStyle(fontSize: large ? 16 : 13, color: KioskPalette.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tablet rates: one centred row of peso cards (₱1 / 4 min, ...).
class RateStrip extends StatelessWidget {
  const RateStrip({super.key, required this.secondsPerPulse});

  final int secondsPerPulse;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          for (var i = 0; i < Rates.displayPulses.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
                decoration: BoxDecoration(
                  color: KioskPalette.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: KioskPalette.outline),
                ),
                child: Column(
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '₱${Rates.displayPulses[i]}',
                        style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: KioskPalette.coin),
                      ),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        Rates.describeDuration(
                          Rates.secondsFor(Rates.displayPulses[i], secondsPerPulse: secondsPerPulse),
                        ),
                        key: Key('rate-${Rates.displayPulses[i]}'),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: KioskPalette.text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 14),
      const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_circle_outline, size: 18, color: KioskPalette.accent),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Additional coins extend your time.',
              style: TextStyle(fontSize: 16, color: KioskPalette.textMuted),
            ),
          ),
        ],
      ),
    ],
  );
}

/// 12-hour clock text, e.g. "1:42 PM".
String clockText(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Compact remaining-time display for the payment screen ([large] on tablets).
class TimePill extends StatelessWidget {
  const TimePill({super.key, required this.remainingMs, this.large = false});

  final int remainingMs;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final color = remainingMs > 0
        ? timeLevelColor(timeLevel(remainingMs))
        : KioskPalette.textMuted;
    return Center(
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 32 : 20, vertical: large ? 16 : 10),
        decoration: BoxDecoration(
          color: KioskPalette.surface,
          borderRadius: BorderRadius.circular(60),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: large ? 30 : 20, color: color),
            SizedBox(width: large ? 14 : 10),
            Text(
              'TIME',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                fontSize: large ? 17 : 13,
              ),
            ),
            SizedBox(width: large ? 18 : 12),
            Flexible(
              child: CountdownText(
                remainingMs: remainingMs,
                size: large ? 52 : 30,
                color: remainingMs > 0 ? color : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Why the kiosk cannot take coins right now: a calm card with a short title
/// and the full explanation, instead of a wall of headline text.
class StatusNotice extends StatelessWidget {
  const StatusNotice({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.color = KioskPalette.warn,
    this.large = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final iconBox = large ? 88.0 : 64.0;
    return Container(
      padding: EdgeInsets.all(large ? 32 : 20),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(large ? 28 : 22),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconBox,
            height: iconBox,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.16)),
            child: Icon(icon, size: iconBox * 0.52, color: color),
          ),
          SizedBox(height: large ? 20 : 14),
          Text(
            title,
            key: const Key('payment-headline'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: large ? 34 : 24, fontWeight: FontWeight.w900, color: KioskPalette.text),
          ),
          SizedBox(height: large ? 10 : 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: large ? 19 : 15, height: 1.35, color: KioskPalette.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Hidden administrator entry: tap the wrapped widget (the timer) [taps]
/// times within [window]. Nothing is shown to customers; the PIN is still
/// required afterwards.
class AdminEntry extends StatefulWidget {
  const AdminEntry({
    super.key,
    required this.onTriggered,
    required this.child,
    this.taps = 7,
    this.window = const Duration(seconds: 4),
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
    'preview_only':
        'Not available in the browser preview. Install the Android APK.',
  };
  for (final entry in known.entries) {
    if (s.contains(entry.key)) return entry.value;
  }
  return s.replaceFirst('KioskException: ', '');
}
