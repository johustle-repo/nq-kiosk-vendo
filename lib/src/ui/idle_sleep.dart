import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/kiosk_bridge.dart';
import 'widgets.dart';

/// Screen saver for the payment screen: after [seconds] with no paid time and
/// no touches the screen goes black and the backlight drops to minimum (Android
/// may then switch the display off). Touches do NOT wake it; a coin does (the
/// shell swaps to the launcher and the native side turns the display on).
/// Tapping the black screen 7 times still opens the admin PIN prompt.
class IdleSleep extends StatefulWidget {
  const IdleSleep({
    super.key,
    required this.bridge,
    required this.seconds,
    required this.onAdmin,
    required this.child,
  });

  final KioskBridge bridge;
  final int seconds;
  final VoidCallback onAdmin;
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
      _setAwake(false);
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
    _setAwake(true); // leaving the payment screen (coin inserted / admin)
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_asleep) {
      return Scaffold(
        key: const Key('sleep-overlay'),
        backgroundColor: Colors.black,
        body: AdminEntry(
          onTriggered: widget.onAdmin,
          child: const SizedBox.expand(),
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
