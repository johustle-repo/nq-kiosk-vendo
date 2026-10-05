import 'package:flutter/material.dart';

import '../kiosk_controller.dart';
import '../model/kiosk_state.dart';
import 'admin/admin_screen.dart';
import 'admin/pin_dialog.dart';
import 'widgets.dart';

/// First run: create the administrator PIN (no default PIN exists), then pick
/// Demo or Production mode.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.controller});

  final KioskController controller;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  String? _recoveryCode;
  bool _recoverySaved = false;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _createPin() async {
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'The two PINs do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await widget.controller.bridge.createPin(_pin.text);
      setState(() => _recoveryCode = code);
    } catch (e) {
      setState(
        () => _error = errorText(e).replaceFirst('invalid_argument: ', ''),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseMode(KioskMode mode) async {
    final bridge = widget.controller.bridge;
    if (!widget.controller.state.adminUnlocked) {
      final ok = await showPinDialog(context, bridge);
      if (!ok) return;
    }
    try {
      await bridge.setMode(mode);
      if (mode == KioskMode.demo) await bridge.requestNotificationPermission();
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains('not_device_owner')) {
        await showDialog<void>(
          context: context,
          builder: (_) => const ProvisioningHelpDialog(),
        );
      } else {
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.state;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandLogo(height: 56)),
                  const SizedBox(height: 20),
                  Text(
                    'Vendo Kiosk setup',
                    style: t.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (s.preview) ...[
                    const DemoBanner(preview: true),
                    const SizedBox(height: 16),
                  ],
                  // The one-time recovery code is shown before anything else once created.
                  if (_recoveryCode != null && !_recoverySaved)
                    ..._recoveryStep()
                  else if (!s.hasPin)
                    ..._pinStep(t)
                  else
                    ..._modeStep(s, t),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _pinStep(TextTheme t) => [
    Text('Step 1 of 2 — create the administrator PIN', style: t.titleLarge),
    const SizedBox(height: 8),
    const Text(
      'There is no default PIN. Use 6–12 digits that are not a simple sequence. '
      'Repeated wrong attempts lock PIN entry for increasing periods.',
    ),
    const SizedBox(height: 16),
    PinField(controller: _pin, label: 'New PIN', autofocus: true),
    const SizedBox(height: 12),
    PinField(
      controller: _confirm,
      label: 'Confirm PIN',
      onSubmitted: (_) => _createPin(),
    ),
    if (_error != null) ...[
      const SizedBox(height: 12),
      Text(
        _error!,
        key: const Key('setup-error'),
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ],
    const SizedBox(height: 20),
    FilledButton(
      key: const Key('create-pin'),
      onPressed: _busy ? null : _createPin,
      child: const Text('Create PIN'),
    ),
  ];

  List<Widget> _recoveryStep() => [
    RecoveryCodeNotice(code: _recoveryCode!),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: () => setState(() => _recoverySaved = true),
      child: const Text('I wrote it down'),
    ),
  ];

  List<Widget> _modeStep(KioskState s, TextTheme t) => [
    Text('Step 2 of 2 — choose a mode', style: t.titleLarge),
    const SizedBox(height: 16),
    _ModeCard(
      key: const Key('choose-demo'),
      icon: Icons.science,
      title: 'Demo mode',
      body:
          'For trying the app on a personal phone. Simulated coin buttons, countdown, app selection and launching. '
          'Other apps are NOT securely restricted.',
      onTap: () => _chooseMode(KioskMode.demo),
    ),
    const SizedBox(height: 12),
    _ModeCard(
      key: const Key('choose-production'),
      icon: Icons.lock,
      title: 'Production kiosk mode',
      body: s.deviceOwner
          ? 'Device Owner verified. Enforces lock task mode; only paid time from the coin controller unlocks apps.'
          : 'Requires Device Owner provisioning first (this phone is not provisioned). Tap for instructions.',
      onTap: () => _chooseMode(KioskMode.production),
    ),
  ];
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(body),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
