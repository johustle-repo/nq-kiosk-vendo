import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/kiosk_bridge.dart';
import 'theme.dart';
import 'widgets.dart';

/// Attract screen for the payment screen: after [seconds] with no paid time and
/// no touches the kiosk logo is shown full screen, with the display kept on at
/// normal brightness. A touch returns to the payment screen; a coin starts the
/// session (the shell swaps to the launcher).
class IdleSleep extends StatefulWidget {
  const IdleSleep({
    super.key,
    required this.bridge,
    required this.seconds,
    required this.child,
  });

  final KioskBridge bridge;
  final int seconds;
  final Widget child;

  @override
  State<IdleSleep> createState() => _IdleSleepState();
}

class _IdleSleepState extends State<IdleSleep> {
  Timer? _timer;
  bool _asleep = false;

  @override
  void initState() {
    super.initState();
    _setAwake(true);
    _restart();
  }

  void _setAwake(bool awake) =>
      widget.bridge.setScreenAwake(awake).catchError((Object _) {});

  void _restart() {
    _timer?.cancel();
    if (widget.seconds <= 0) return;
    _timer = Timer(Duration(seconds: widget.seconds), () {
      if (!mounted) return;
      setState(() => _asleep = true);
    });
  }

  @override
  void didUpdateWidget(IdleSleep old) {
    super.didUpdateWidget(old);
    if (old.seconds != widget.seconds && !_asleep) _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
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
        child: IdleLogo(onTap: _wake),
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
