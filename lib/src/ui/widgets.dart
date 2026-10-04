import 'dart:async';

import 'package:flutter/material.dart';

import '../model/kiosk_state.dart';
import '../model/rates.dart';
import 'theme.dart';

/// Two independent indicators: the LOCAL coin controller (decides access)
/// and the CLOUD dashboard (reporting only).
class ConnectionIndicators extends StatelessWidget {
  const ConnectionIndicators({super.key, required this.state});

  final KioskState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (ctlText, ctlColor, ctlIcon) = _controller(scheme);
    final (cloudText, cloudColor, cloudIcon) = _cloud(scheme);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Chip(
          key: const Key('indicator-controller'),
          icon: ctlIcon,
          label: 'Coin controller: $ctlText',
          color: ctlColor,
        ),
        _Chip(
          key: const Key('indicator-cloud'),
          icon: cloudIcon,
          label: 'Cloud: $cloudText',
          color: cloudColor,
        ),
      ],
    );
  }

  (String, Color, IconData) _controller(ColorScheme s) {
    if (!state.controllerPaired) {
      return (
        'not paired',
        state.isDemo ? KioskPalette.textMuted : KioskPalette.danger,
        Icons.link_off,
      );
    }
    final age = state.controllerLastOkAgoMs;
    return switch (state.controllerLink) {
      ControllerLink.connected => ('connected', KioskPalette.ok, Icons.sensors),
      ControllerLink.degraded => (
        'reconnecting${age != null ? ' (${age ~/ 1000} s)' : ''}',
        KioskPalette.warn,
        Icons.sync_problem,
      ),
      ControllerLink.lost => (
        'disconnected${age != null ? ' (${age ~/ 1000} s)' : ''}',
        KioskPalette.danger,
        Icons.sensors_off,
      ),
      ControllerLink.never => ('connecting…', KioskPalette.warn, Icons.sync),
    };
  }

  (String, Color, IconData) _cloud(ColorScheme s) => switch (state.cloudLink) {
    CloudLink.ok => ('online', KioskPalette.ok, Icons.cloud_done),
    CloudLink.offline => ('offline', KioskPalette.warn, Icons.cloud_off),
    CloudLink.unauthorized => (
      'credential revoked',
      KioskPalette.danger,
      Icons.cloud_off,
    ),
    CloudLink.error => ('error', KioskPalette.warn, Icons.cloud_off),
    CloudLink.disabled => (
      'not enrolled',
      KioskPalette.textMuted,
      Icons.cloud_outlined,
    ),
  };
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        color: color.withValues(alpha: 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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

/// Round coin badge used as the payment hero.
class CoinBadge extends StatelessWidget {
  const CoinBadge({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const RadialGradient(
        colors: [Color(0xFFFDE68A), KioskPalette.coin, Color(0xFFB45309)],
        stops: [0.0, 0.6, 1.0],
      ),
      boxShadow: [
        BoxShadow(
          color: KioskPalette.coin.withValues(alpha: 0.35),
          blurRadius: 32,
          spreadRadius: 2,
        ),
      ],
    ),
    child: Icon(
      Icons.payments_rounded,
      size: size * 0.5,
      color: const Color(0xFF78350F),
    ),
  );
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

/// Rates as one clean card: a row per coin, value on the right.
class RateTable extends StatelessWidget {
  const RateTable({super.key, required this.secondsPerPulse});

  final int secondsPerPulse;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: KioskPalette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: KioskPalette.outline),
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sell_outlined,
                size: 18,
                color: KioskPalette.coin,
              ),
              const SizedBox(width: 8),
              Text(
                'Rates',
                style: t.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < Rates.displayPulses.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : const Border(
                        top: BorderSide(
                          color: KioskPalette.outline,
                          width: 0.6,
                        ),
                      ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: KioskPalette.coin.withValues(alpha: 0.15),
                    ),
                    child: Text(
                      '${Rates.displayPulses[i]}',
                      style: const TextStyle(
                        color: KioskPalette.coin,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'pulse${Rates.displayPulses[i] == 1 ? '' : 's'}',
                      style: t.bodyLarge?.copyWith(
                        color: KioskPalette.textMuted,
                      ),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Rates.describeDuration(
                        Rates.secondsFor(
                          Rates.displayPulses[i],
                          secondsPerPulse: secondsPerPulse,
                        ),
                      ),
                      key: Key('rate-${Rates.displayPulses[i]}'),
                      style: t.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(
                Icons.add_circle_outline,
                size: 16,
                color: KioskPalette.accent,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Additional coins extend your time.',
                  style: t.bodySmall?.copyWith(color: KioskPalette.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact remaining-time display for the payment screen.
class TimePill extends StatelessWidget {
  const TimePill({super.key, required this.remainingMs});

  final int remainingMs;

  @override
  Widget build(BuildContext context) {
    final color = remainingMs > 0
        ? timeLevelColor(timeLevel(remainingMs))
        : KioskPalette.textMuted;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: KioskPalette.surface,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 20, color: color),
            const SizedBox(width: 10),
            Text(
              'TIME',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: CountdownText(
                remainingMs: remainingMs,
                size: 30,
                color: remainingMs > 0 ? color : null,
              ),
            ),
          ],
        ),
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
                                '+$p pulse${p == 1 ? '' : 's'}',
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
