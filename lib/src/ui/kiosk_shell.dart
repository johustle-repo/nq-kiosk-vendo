import 'package:flutter/material.dart';

import '../kiosk_controller.dart';
import '../model/kiosk_state.dart';
import 'admin/admin_screen.dart';
import 'admin/pin_dialog.dart';
import 'coin_claim.dart';
import 'idle_sleep.dart';
import 'launcher_screen.dart';
import 'payment_screen.dart';
import 'setup_screen.dart';

/// Chooses the customer screen from native state. Back navigation never
/// leaves the kiosk (the system Back gesture is also contained by lock task).
///
/// Admin opens after the hidden 10-tap gesture + PIN, or straight away when
/// the cloud dashboard asks for it (the native layer has already unlocked).
class KioskShell extends StatefulWidget {
  const KioskShell({super.key, required this.controller});

  final KioskController controller;

  @override
  State<KioskShell> createState() => _KioskShellState();
}

class _KioskShellState extends State<KioskShell> {
  KioskController get controller => widget.controller;
  bool _adminOpen = false;
  int? _seenOpenSeq;

  @override
  void initState() {
    super.initState();
    if (controller.state.loaded) _seenOpenSeq = controller.state.adminOpenSeq;
    controller.addListener(_onState);
  }

  @override
  void dispose() {
    controller.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final s = controller.state;
    if (!s.loaded) return;
    final seq = s.adminOpenSeq;
    final first = _seenOpenSeq == null;
    final changed = seq != _seenOpenSeq;
    _seenOpenSeq = seq;
    // Only a new request after start-up; never on the first state.
    if (!first && changed && s.adminUnlocked && !_adminOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pushAdmin(context);
      });
    }
  }

  /// Hidden 10-tap entry (the PIN is still required). On a tablet enrolled in
  /// the dashboard it is off unless the dashboard's "Enable 10 taps" turned it
  /// on; locking admin turns it off again. A tablet not enrolled yet keeps it,
  /// or nobody could set it up.
  Future<void> openAdmin(BuildContext context) async {
    final s = controller.state;
    if (s.cloudEnrolled && !s.tapAdmin) return;
    final ok = await showPinDialog(context, controller.bridge);
    if (!ok || !context.mounted) return;
    await _pushAdmin(context);
  }

  Future<void> _pushAdmin(BuildContext context) async {
    if (_adminOpen) return;
    _adminOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AdminScreen(controller: controller),
        ),
      );
    } finally {
      _adminOpen = false;
    }
    await controller.bridge.lockAdmin();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final s = controller.state;
          if (!s.loaded) {
            final err = controller.loadError;
            if (err != null) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'The kiosk service did not respond.\n\n$err\n\n'
                      'Vendo Kiosk must run as the Android APK on the kiosk phone.',
                      key: const Key('load-error'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              );
            }
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final Widget screen;
          if (s.mode == KioskMode.unconfigured) {
            screen = SetupScreen(
              key: const ValueKey('setup'),
              controller: controller,
            );
          } else if (s.accessGranted) {
            screen = LauncherScreen(
              key: const ValueKey('launcher'),
              controller: controller,
              onAdmin: () => openAdmin(context),
            );
          } else {
            screen = IdleSleep(
              key: const ValueKey('payment'),
              bridge: controller.bridge,
              // Never cover a problem (e.g. coin box not paired) with the
              // "Insert coin" logo screen: coins would not unlock anything.
              seconds: _paymentProblem(s) ? 0 : s.idleSleepS,
              screenOffSeconds: s.screenOffS,
              onInsertCoin: () => claimCoinBox(context, controller),
              child: PaymentScreen(
                controller: controller,
                onAdmin: () => openAdmin(context),
              ),
            );
          }
          // Smooth hand-over between payment, launcher and setup.
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: screen,
          );
        },
      ),
    );
  }
}

bool _paymentProblem(KioskState s) =>
    s.productionBlocked ||
    s.denyReason == 'controller_lost' ||
    s.denyReason == 'controller_not_paired';
