import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/kiosk_bridge.dart';
import 'theme.dart';
import 'widgets.dart';

/// Attract screen for the payment screen: after [seconds] with no paid time and
/// no touches the kiosk logo is shown full screen at normal brightness. After
/// a further [screenOffSeconds] the display is switched off; a coin or the
/// power button turns it back on (to the logo). A touch on the logo returns to
/// the payment screen; a coin starts the session (the shell swaps to the
/// launcher).
class IdleSleep extends StatefulWidget {
  const IdleSleep({
    super.key,
    required this.bridge,
    required this.seconds,
    required this.child,
    this.screenOffSeconds = 0,
    this.onInsertCoin,
  });

  final KioskBridge bridge;

  /// Also called when the idle screen's "Insert coin" button is tapped.
  final VoidCallback? onInsertCoin;
  final int seconds;

  /// Seconds the logo stays up before the display is switched off (0 = never).
  final int screenOffSeconds;
  final Widget child;

  @override
  State<IdleSleep> createState() => _IdleSleepState();
}

class _IdleSleepState extends State<IdleSleep> with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _offTimer;
  bool _asleep = false;
  bool _screenOff = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setAwake(true);
    _restart();
  }

  void _setAwake(bool awake) =>
      widget.bridge.setScreenAwake(awake).catchError((Object _) {});

  void _restart() {
    _timer?.cancel();
    _offTimer?.cancel();
    if (widget.seconds <= 0) return;
    _timer = Timer(Duration(seconds: widget.seconds), () {
      if (!mounted) return;
      setState(() => _asleep = true);
      _startOffTimer();
    });
  }

  void _startOffTimer() {
    _offTimer?.cancel();
    if (widget.screenOffSeconds <= 0) return;
    _offTimer = Timer(Duration(seconds: widget.screenOffSeconds), () {
      if (!mounted || !_asleep) return;
      _screenOff = true;
      widget.bridge.sleepScreen().catchError((Object _) {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Display back on (power button or a coin): keep it on, and switch it
    // off again later if nobody touches the logo.
    if (state == AppLifecycleState.resumed && _screenOff) {
      _screenOff = false;
      _setAwake(true);
      if (_asleep) _startOffTimer();
    }
  }

  @override
  void didUpdateWidget(IdleSleep old) {
    super.didUpdateWidget(old);
    if (old.seconds != widget.seconds && !_asleep) _restart();
    if (old.screenOffSeconds != widget.screenOffSeconds && _asleep) {
      _startOffTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _offTimer?.cancel();
    super.dispose();
  }

  void _wake() {
    setState(() => _asleep = false);
    _restart();
  }

  @override
  Widget build(BuildContext context) {
    if (_asleep) {
      return GestureDetector(
        key: const Key('idle-logo'),
        behavior: HitTestBehavior.opaque,
        onTap: _wake,
        child: IdleLogo(
          onTap: () {
            _wake();
            widget.onInsertCoin?.call();
          },
        ),
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _restart(),
      child: widget.child,
    );
  }
}

/// Full-screen kiosk logo on the artwork's own background colour.
class IdleLogo extends StatelessWidget {
  const IdleLogo({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KioskPalette.logoBackground,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Image.asset(
                    kLogoAsset,
                    fit: BoxFit.contain,
                    semanticLabel: 'VeNdO — Jo-hustle Smart Android',
                  ),
                ),
                const SizedBox(height: 32),
                InsertCoinButton(onPressed: onTap),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
