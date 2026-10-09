import 'package:flutter/material.dart';

import '../bridge/kiosk_bridge.dart';
import '../kiosk_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// Shared coin box: "Insert coin" (payment or idle screen) or "Add time"
/// (during a session) asks the coin box to send its next coins
/// to this tablet (first come, first served).
Future<void> claimCoinBox(
  BuildContext context,
  KioskController controller,
) async {
  final s = controller.state;
  if (s.isDemo || !s.controllerPaired) return;
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  final station = s.controllerStation;
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 4)),
    );
  try {
    final ttl = await controller.bridge.claimCoinBox();
    say(
      'Coin box ready for Tablet $station. Insert your coins now'
      '${ttl > 0 ? ' (within $ttl s)' : ''}.',
    );
  } on KioskException catch (e) {
    final busy = RegExp(r'^busy:(\d+):(\d+)$').firstMatch(e.code);
    if (busy != null) {
      final wait = int.parse(busy.group(2)!);
      say(
        'Tablet ${busy.group(1)} is inserting coins right now. '
        'Please try again${wait > 0 ? ' in $wait s' : ''}.',
      );
    } else {
      say(errorText(e));
    }
  } catch (e) {
    say(errorText(e));
  }
}

/// True when coins must be claimed first: production with a paired coin box.
bool needsCoinClaim(KioskController controller) =>
    !controller.state.isDemo && controller.state.controllerPaired;

/// "Add time" during a paid session: claims the shared coin box so the next
/// coins extend this tablet's time (otherwise they would be held).
class AddTimeButton extends StatelessWidget {
  const AddTimeButton({super.key, required this.controller});

  final KioskController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    final ready = s.coinBoxReadyForMe;
    return FilledButton.icon(
      key: const Key('add-time-button'),
      onPressed: () => claimCoinBox(context, controller),
      icon: ready
          ? const Icon(Icons.check_circle, size: 20)
          : Image.asset(kCoinAsset, width: 20, height: 20),
      label: Text(ready ? 'Insert coins now' : 'Add time'),
      style: FilledButton.styleFrom(
        backgroundColor: ready ? KioskPalette.accent : KioskPalette.gold,
        foregroundColor: ready ? Colors.white : KioskPalette.ink,
        minimumSize: const Size(0, 44),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        shape: const StadiumBorder(),
      ),
    );
  }
}
