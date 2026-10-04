import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../bridge/kiosk_bridge.dart';
import '../theme.dart';
import '../widgets.dart';

/// Asks for the administrator PIN. Returns true when the native side unlocked
/// the admin session. Failed attempts are counted and throttled natively.
Future<bool> showPinDialog(BuildContext context, KioskBridge bridge) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinDialog(bridge: bridge),
  );
  return ok == true;
}

String lockoutText(int ms) {
  final s = (ms / 1000).ceil();
  return s >= 60
      ? 'Too many attempts. Try again in ${(s / 60).ceil()} min.'
      : 'Too many attempts. Try again in $s s.';
}

class PinField extends StatelessWidget {
  const PinField({
    super.key,
    required this.controller,
    required this.label,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    obscureText: true,
    keyboardType: TextInputType.number,
    maxLength: 12,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    style: const TextStyle(fontSize: 24, letterSpacing: 6),
    decoration: InputDecoration(labelText: label, counterText: ''),
    onSubmitted: onSubmitted,
    enableSuggestions: false,
    autocorrect: false,
  );
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.bridge});

  final KioskBridge bridge;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  final _code = TextEditingController();
  final _newPin = TextEditingController();
  bool _busy = false;
  bool _recovery = false;
  String? _message;
  String? _newRecoveryCode;

  @override
  void dispose() {
    _pin.dispose();
    _code.dispose();
    _newPin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final r = _recovery
          ? await widget.bridge.recoverWithCode(_code.text, _newPin.text)
          : await widget.bridge.verifyPin(_pin.text);
      if (!mounted) return;
      if (r.ok) {
        if (r.recoveryCode != null) {
          setState(() => _newRecoveryCode = r.recoveryCode);
          return;
        }
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _message = r.lockoutMs > 0
            ? lockoutText(r.lockoutMs)
            : (_recovery ? 'Recovery code is incorrect.' : 'Incorrect PIN.');
        _pin.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _message = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_newRecoveryCode != null) {
      return AlertDialog(
        title: const Text('PIN changed'),
        content: RecoveryCodeNotice(code: _newRecoveryCode!),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('I saved it'),
          ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: KioskPalette.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: KioskPalette.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _recovery ? Icons.key : Icons.lock_outline,
              color: KioskPalette.accent,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _recovery ? 'Reset PIN with recovery code' : 'Administrator PIN',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_recovery)
              PinField(
                controller: _pin,
                label: 'PIN',
                autofocus: true,
                onSubmitted: (_) => _submit(),
              )
            else ...[
              TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Recovery code (XXXX-XXXX-XXXX-XXXX)',
                ),
                autocorrect: false,
                enableSuggestions: false,
              ),
              const SizedBox(height: 12),
              PinField(controller: _newPin, label: 'New PIN (6-12 digits)'),
            ],
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                key: const Key('pin-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _recovery = !_recovery;
                        _message = null;
                      }),
                child: Text(_recovery ? 'Use PIN instead' : 'Forgot PIN?'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

class RecoveryCodeNotice extends StatelessWidget {
  const RecoveryCodeNotice({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Write down this recovery code and keep it somewhere safe (not on this phone). '
          'It is shown only once and is the only way to reset a forgotten PIN on the device.',
        ),
        const SizedBox(height: 16),
        SelectableText(
          code,
          key: const Key('recovery-code'),
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
