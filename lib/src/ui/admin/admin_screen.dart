import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../bridge/kiosk_bridge.dart';
import '../../kiosk_controller.dart';
import '../../model/kiosk_state.dart';
import '../../model/rates.dart';
import '../theme.dart';
import '../widgets.dart';
import 'admin_ui.dart';
import 'pin_dialog.dart';

part 'wifi_page.dart';

const provisioningCommand =
    'adb shell dpm set-device-owner online.ebnleadgen.vendokiosk/.kiosk.KioskDeviceAdminReceiver';

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Destination('Overview', Icons.dashboard_outlined, Icons.dashboard),
  _Destination('Apps', Icons.apps_outlined, Icons.apps),
  _Destination('Coin box', Icons.memory_outlined, Icons.memory),
  _Destination('Wi-Fi', Icons.wifi_outlined, Icons.wifi),
  _Destination('Cloud', Icons.cloud_outlined, Icons.cloud),
  _Destination('System', Icons.settings_outlined, Icons.settings),
];

/// Administrator settings. Every action is re-checked natively against the
/// unlocked admin session; this screen only collects input.
///
/// Phones: bottom navigation bar. Tablets (≥ 840 dp): navigation rail.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.controller});

  final KioskController controller;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  int _index = 0;

  Future<void> _lockAndClose() async {
    await widget.controller.bridge.lockAdmin();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _page(int i) => switch (i) {
    0 => _OverviewPage(controller: widget.controller),
    1 => _AppsPage(controller: widget.controller),
    2 => _CoinBoxPage(controller: widget.controller),
    3 => _WifiPage(controller: widget.controller),
    4 => _CloudPage(controller: widget.controller),
    _ => _SystemPage(controller: widget.controller, onLock: _lockAndClose),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final s = widget.controller.state;
        return LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 840;
            final body = !s.adminUnlocked
                ? _Relock(onClose: () => Navigator.of(context).pop())
                : KeyedSubtree(key: ValueKey(_index), child: _page(_index));
            return Scaffold(
              appBar: AppBar(
                titleSpacing: wide ? 24 : 16,
                title: Row(
                  children: [
                    Image.asset(
                      kCoinAsset,
                      width: 28,
                      height: 28,
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(
                        'Administrator',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ModeBadge(state: s),
                  ],
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: TextButton.icon(
                      key: const Key('admin-lock'),
                      onPressed: _lockAndClose,
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Lock'),
                    ),
                  ),
                ],
                bottom: const PreferredSize(
                  preferredSize: Size.fromHeight(1),
                  child: Divider(height: 1),
                ),
              ),
              body: wide
                  ? Row(
                      children: [
                        NavigationRail(
                          backgroundColor: KioskPalette.background,
                          extended: box.maxWidth >= 1100,
                          minExtendedWidth: 200,
                          selectedIndex: _index,
                          onDestinationSelected: (i) =>
                              setState(() => _index = i),
                          labelType: box.maxWidth >= 1100
                              ? null
                              : NavigationRailLabelType.all,
                          destinations: [
                            for (final d in _destinations)
                              NavigationRailDestination(
                                icon: Icon(d.icon),
                                selectedIcon: Icon(d.selectedIcon),
                                label: Text(d.label),
                              ),
                          ],
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: body),
                      ],
                    )
                  : body,
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      backgroundColor: KioskPalette.surface,
                      indicatorColor: KioskPalette.accent.withValues(
                        alpha: 0.2,
                      ),
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysShow,
                      destinations: [
                        for (final d in _destinations)
                          NavigationDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(
                              d.selectedIcon,
                              color: KioskPalette.accent,
                            ),
                            label: d.label,
                          ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.state});

  final KioskState state;

  @override
  Widget build(BuildContext context) => switch (state.mode) {
    KioskMode.production => const StatusBadge(
      'PRODUCTION',
      color: KioskPalette.ok,
      icon: Icons.lock,
    ),
    KioskMode.demo => const StatusBadge(
      'DEMO',
      color: KioskPalette.warn,
      icon: Icons.science_outlined,
    ),
    KioskMode.unconfigured => const StatusBadge(
      'SETUP',
      color: KioskPalette.textMuted,
    ),
  };
}

class _Relock extends StatelessWidget {
  const _Relock({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_clock, size: 48, color: KioskPalette.textMuted),
        const SizedBox(height: 12),
        const Text('Administrator session timed out.'),
        const SizedBox(height: 16),
        FilledButton(onPressed: onClose, child: const Text('Close')),
      ],
    ),
  );
}

/// Scrollable, centred page body with a readable maximum width.
class _Page extends StatelessWidget {
  const _Page({required this.children, this.title, this.subtitle});

  final String? title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, box) {
        final pad = box.maxWidth < 600 ? 16.0 : 28.0;
        return ListView(
          padding: EdgeInsets.symmetric(
            horizontal: box.maxWidth > 900 + 2 * pad
                ? (box.maxWidth - 900) / 2
                : pad,
            vertical: 20,
          ),
          children: [
            if (title != null) ...[
              Text(
                title!,
                style: t.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: KioskPalette.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: t.bodyMedium?.copyWith(color: KioskPalette.textMuted),
                ),
              ],
              const SizedBox(height: 20),
            ],
            ...children,
          ],
        );
      },
    );
  }
}

// ======================================================================= Overview

class _OverviewPage extends StatelessWidget {
  const _OverviewPage({required this.controller});

  final KioskController controller;

  (String, Color) _controllerStatus(KioskState s) {
    if (!s.controllerPaired) return ('Not paired', KioskPalette.danger);
    return switch (s.controllerLink) {
      ControllerLink.connected => ('Connected', KioskPalette.ok),
      ControllerLink.degraded => ('Reconnecting', KioskPalette.warn),
      ControllerLink.lost => ('Disconnected', KioskPalette.danger),
      ControllerLink.never => ('Connecting…', KioskPalette.warn),
    };
  }

  (String, Color) _cloudStatus(KioskState s) => switch (s.cloudLink) {
    CloudLink.ok => ('Online', KioskPalette.ok),
    CloudLink.offline => ('Offline', KioskPalette.warn),
    CloudLink.unauthorized => ('Revoked', KioskPalette.danger),
    CloudLink.error => ('Error', KioskPalette.warn),
    CloudLink.disabled => ('Not enrolled', KioskPalette.textMuted),
  };

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    final b = controller.bridge;
    final (ctlText, ctlColor) = _controllerStatus(s);
    final (cloudText, cloudColor) = _cloudStatus(s);
    final tiles = [
      StatTile(
        icon: Icons.memory,
        label: 'Coin box',
        value: ctlText,
        color: ctlColor,
      ),
      StatTile(
        icon: Icons.cloud_outlined,
        label: 'Cloud',
        value: cloudText,
        color: cloudColor,
      ),
      StatTile(
        icon: Icons.timer_outlined,
        label: 'Customer time',
        value: s.accessGranted ? formatHms(s.remainingMs) : 'No time',
        color: s.accessGranted ? KioskPalette.accent : KioskPalette.textMuted,
      ),
      StatTile(
        icon: Icons.apps,
        label: 'Allowed apps',
        value: '${s.allowedPackages.length}',
        color: s.allowedPackages.isEmpty
            ? KioskPalette.warn
            : KioskPalette.text,
      ),
    ];

    return _Page(
      title: 'Overview',
      subtitle: 'Status of this kiosk at a glance.',
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final cols = box.maxWidth >= 640 ? 4 : 2;
            const gap = 12.0;
            final w = (box.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final t in tiles) SizedBox(width: w, child: t)],
            );
          },
        ),
        const SizedBox(height: 16),
        if (s.policyProblems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: AdminNote(
              s.policyProblems.join('\n'),
              icon: Icons.warning_amber_rounded,
              color: KioskPalette.warn,
            ),
          ),
        if (!s.isProduction)
          AdminSection(
            icon: Icons.home_outlined,
            title: 'Home button',
            description:
                'Make Vendo Kiosk the Home app so pressing Home returns customers to the kiosk. '
                'Android asks you to confirm. In demo mode this is a convenience, not a security lock.',
            children: [
              InfoRow(
                'Home button opens',
                s.isDefaultHome
                    ? 'Vendo Kiosk'
                    : "the phone's normal home screen",
                valueColor: s.isDefaultHome
                    ? KioskPalette.ok
                    : KioskPalette.warn,
                last: true,
              ),
              const SizedBox(height: 14),
              ActionButtons(
                children: [
                  if (!s.isDefaultHome)
                    FilledButton.icon(
                      key: const Key('use-as-home'),
                      icon: const Icon(Icons.home),
                      label: const Text('Use Vendo Kiosk as Home app'),
                      onPressed: () => adminRun(context, b.useAsHomeApp),
                    ),
                  if (s.isDefaultHome)
                    OutlinedButton.icon(
                      key: const Key('restore-home'),
                      icon: const Icon(Icons.home_outlined),
                      label: const Text("Restore the phone's normal Home app"),
                      onPressed: () => adminRun(
                        context,
                        b.restoreNormalHome,
                        success:
                            'Home button returns to the normal home screen',
                      ),
                    ),
                ],
              ),
            ],
          ),
        AdminSection(
          icon: Icons.verified_user_outlined,
          title: 'Kiosk mode',
          description: s.isProduction
              ? 'Production: only verified time from the paired coin box unlocks apps. Settings, notifications and other apps are blocked.'
              : 'Demo: simulated coins are allowed and other apps are not blocked. Production requires Device Owner.',
          children: [
            InfoRow(
              'Mode',
              s.isProduction
                  ? 'Production'
                  : s.isDemo
                  ? 'Demo'
                  : 'Setup',
            ),
            InfoRow(
              'Device Owner',
              s.deviceOwner ? 'Yes (verified by Android)' : 'No',
              valueColor: s.deviceOwner ? KioskPalette.ok : KioskPalette.warn,
            ),
            InfoRow('Lock task', s.lockTask, last: true),
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                if (!s.isProduction)
                  FilledButton.icon(
                    key: const Key('enable-production'),
                    icon: const Icon(Icons.lock),
                    label: const Text('Enable production kiosk'),
                    onPressed: () async {
                      if (!s.deviceOwner) {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => const ProvisioningHelpDialog(),
                        );
                        return;
                      }
                      if (!await adminConfirm(
                        context,
                        'Enable production kiosk?',
                        'The phone will be locked to this kiosk. Settings, notifications and unapproved apps become unavailable. '
                            'Keep your administrator PIN and recovery code safe.',
                      )) {
                        return;
                      }
                      if (context.mounted) {
                        await adminRun(
                          context,
                          () => b.setMode(KioskMode.production),
                          success: 'Production kiosk enabled',
                        );
                      }
                    },
                  ),
                if (s.isProduction)
                  OutlinedButton.icon(
                    key: const Key('exit-kiosk'),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Exit kiosk'),
                    onPressed: () async {
                      if (!await adminConfirm(
                        context,
                        'Exit kiosk mode?',
                        'Lock task and restrictions are removed and the app switches to demo mode. '
                            'The app stays Device Owner so you can re-enable production later.',
                        action: 'Exit kiosk',
                      )) {
                        return;
                      }
                      if (!context.mounted) return;
                      await adminRun(
                        context,
                        () async {
                          final problems = await b.exitKiosk();
                          if (problems.isNotEmpty) {
                            throw KioskException(
                              'partial',
                              problems.join('; '),
                            );
                          }
                        },
                        success:
                            'Kiosk released. The phone can be used normally.',
                      );
                    },
                  ),
                if (!s.isDemo && !s.isProduction)
                  OutlinedButton(
                    onPressed: () =>
                        adminRun(context, () => b.setMode(KioskMode.demo)),
                    child: const Text('Use demo mode'),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Provisioning guide'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ProvisioningHelpDialog(),
                  ),
                ),
              ],
            ),
          ],
        ),
        const AdminSection(
          icon: Icons.touch_app_outlined,
          title: 'Opening these settings',
          children: [
            AdminNote(
              'On the kiosk screen, tap the timer 7 times within 4 seconds, then enter the PIN. '
              'Customers see nothing. Forgot the PIN? Tap “Forgot PIN?” and use the recovery code.',
              icon: Icons.lightbulb_outline,
              color: KioskPalette.accent,
            ),
          ],
        ),
        if (s.deviceOwner)
          AdminSection(
            icon: Icons.warning_amber_rounded,
            title: 'Danger zone',
            accent: KioskPalette.danger,
            description:
                'Removing Device Owner turns off all kiosk management. Re-enabling production later '
                'requires provisioning again, which usually means a factory reset.',
            children: [
              ActionButtons(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KioskPalette.danger,
                      side: const BorderSide(color: KioskPalette.danger),
                    ),
                    icon: const Icon(Icons.delete_forever),
                    label: const Text('Remove Device Owner'),
                    onPressed: () async {
                      if (!await adminConfirm(
                        context,
                        'Remove Device Owner?',
                        'This removes all kiosk management and cannot be undone without re-provisioning.',
                        action: 'Remove',
                        destructive: true,
                      )) {
                        return;
                      }
                      if (context.mounted) {
                        await adminRun(context, () async {
                          if (!await b.removeDeviceOwner()) {
                            throw KioskException(
                              'failed',
                              'Device Owner was not removed',
                            );
                          }
                        }, success: 'Device Owner removed');
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}

class ProvisioningHelpDialog extends StatelessWidget {
  const ProvisioningHelpDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: KioskPalette.surfaceHigh,
      title: const Text('Device Owner provisioning'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Production kiosk mode needs this app to be the Device Owner. Android only allows that on a '
              'phone with NO accounts (Google, TECNO/Transsion, etc.) and no secondary users.',
            ),
            const SizedBox(height: 10),
            Text(
              'WARNING: The reliable way to get there is a factory reset, which ERASES ALL DATA on the phone. '
              'Back up first. This app will never reset the phone for you.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '1. Factory reset (or remove every account in Settings → Accounts).\n'
              '2. Skip adding a Google account during setup. Do not set a screen lock.\n'
              '3. Enable Developer options and USB debugging.\n'
              '4. Install this APK, then from a computer run:',
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: KioskPalette.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: SelectableText(
                      provisioningCommand,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy),
                    onPressed: () => Clipboard.setData(
                      const ClipboardData(text: provisioningCommand),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '5. Reopen this app and enable production mode. Full guide: docs/DEVICE_OWNER_PROVISIONING.md',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ======================================================================= Apps

/// Google Play for the administrator: install a game or app, come back, then
/// approve it below. Customers never get Play.
/// Tablet-wide screen brightness. The slider applies as it moves, so the
/// administrator sees the result; needs Device Owner.
class _BrightnessSection extends StatefulWidget {
  const _BrightnessSection({required this.state, required this.bridge});

  final KioskState state;
  final KioskBridge bridge;

  @override
  State<_BrightnessSection> createState() => _BrightnessSectionState();
}

class _BrightnessSectionState extends State<_BrightnessSection> {
  double? _dragging; // percent while the slider is held
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  void _preview(double v) {
    setState(() => _dragging = v);
    // Live preview, at most ~10 updates a second.
    final now = DateTime.now();
    if (now.difference(_lastSent).inMilliseconds < 100) return;
    _lastSent = now;
    widget.bridge.setBrightness(v.round(), auto: false).catchError((_) {});
  }

  Future<void> _commit(double v) async {
    await adminRun(
      context,
      () => widget.bridge.setBrightness(v.round(), auto: false),
    );
    if (mounted) setState(() => _dragging = null);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final owner = s.deviceOwner;
    final value = (_dragging ?? s.brightnessPct.toDouble()).clamp(1.0, 100.0);
    return AdminSection(
      icon: Icons.brightness_6_outlined,
      title: 'Screen brightness',
      trailing: StatusBadge(
        s.brightnessAuto ? 'AUTO' : '${value.round()}%',
        color: KioskPalette.ok,
      ),
      children: [
        Row(
          children: [
            const Icon(Icons.brightness_low, color: KioskPalette.textMuted),
            Expanded(
              child: Slider(
                key: const Key('brightness'),
                value: value,
                min: 1,
                max: 100,
                divisions: 99,
                label: '${value.round()}%',
                onChanged: owner && !s.brightnessAuto ? _preview : null,
                onChangeEnd: owner && !s.brightnessAuto ? _commit : null,
              ),
            ),
            const Icon(Icons.brightness_high, color: KioskPalette.textMuted),
          ],
        ),
        SwitchListTile(
          key: const Key('brightness-auto'),
          contentPadding: EdgeInsets.zero,
          value: s.brightnessAuto,
          title: const Text('Automatic brightness'),
          subtitle: Text(
            owner
                ? 'Android adjusts the screen to the room light. Turn it off to set a fixed level. '
                      'Applies to every app on the tablet; customers cannot change it.'
                : 'Needs this app to be the device owner (production setup).',
            style: const TextStyle(color: KioskPalette.textMuted),
          ),
          onChanged: owner
              ? (v) => adminRun(
                  context,
                  () => widget.bridge.setBrightness(
                    s.brightnessPct.clamp(1, 100),
                    auto: v,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}

class _InstallAppsSection extends StatelessWidget {
  const _InstallAppsSection({required this.controller, required this.onRefresh});

  final KioskController controller;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    final b = controller.bridge;
    final open = s.appStoreOpenS > 0;
    final left = '${s.appStoreOpenS ~/ 60}:${(s.appStoreOpenS % 60).toString().padLeft(2, '0')}';
    return AdminSection(
      icon: Icons.shop_outlined,
      title: 'Install apps from Google Play',
      trailing: open
          ? StatusBadge('OPEN · $left', color: KioskPalette.ok)
          : null,
      description:
          'Opens Google Play for you for 15 minutes (or until you lock admin). Install the app, press '
          'Home to come back, tap Refresh list, then select it below and Save.',
      children: [
        ActionButtons(
          children: [
            FilledButton.icon(
              key: const Key('open-play'),
              icon: const Icon(Icons.shop),
              label: Text(open ? 'Go to Google Play' : 'Open Google Play'),
              onPressed: () => adminRun(context, b.openAppStore),
            ),
            if (open)
              OutlinedButton.icon(
                key: const Key('close-play'),
                icon: const Icon(Icons.close),
                label: const Text('Close Google Play'),
                onPressed: () => adminRun(context, b.closeAppStore),
              ),
            OutlinedButton.icon(
              key: const Key('refresh-apps'),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh list'),
              onPressed: onRefresh,
            ),
          ],
        ),
        if (!s.allowAccounts) ...[
          const SizedBox(height: 10),
          const AdminNote(
            'Account sign-in is turned off (System page). Google Play needs a Google account on the '
            'tablet; turn sign-in on to add one.',
            color: KioskPalette.warn,
          ),
        ],
      ],
    );
  }
}

class _AppsPage extends StatefulWidget {
  const _AppsPage({required this.controller});

  final KioskController controller;

  @override
  State<_AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<_AppsPage> {
  late Future<List<InstalledApp>> _apps = widget.controller.bridge.listApps(
    onlyAllowed: false,
  );
  late Set<String> _selected = widget.controller.state.allowedPackages.toSet();
  String _filter = '';
  bool _onlySelected = false;

  bool get _dirty =>
      _selected.length != widget.controller.state.allowedPackages.length ||
      !_selected.containsAll(widget.controller.state.allowedPackages);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final pad = box.maxWidth < 600 ? 16.0 : 28.0;
              final side = box.maxWidth > 900 + 2 * pad
                  ? (box.maxWidth - 900) / 2
                  : pad;
              return CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(side, 20, side, 8),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Customer apps',
                            style: t.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: KioskPalette.text,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Choose the installed apps customers may open during paid time.',
                            style: t.bodyMedium?.copyWith(
                              color: KioskPalette.textMuted,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _InstallAppsSection(
                            controller: widget.controller,
                            onRefresh: () => setState(
                              () => _apps = widget.controller.bridge.listApps(
                                onlyAllowed: false,
                              ),
                            ),
                          ),
                          TextField(
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Search apps',
                            ),
                            onChanged: (v) =>
                                setState(() => _filter = v.toLowerCase()),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('All apps'),
                                selected: !_onlySelected,
                                onSelected: (_) =>
                                    setState(() => _onlySelected = false),
                              ),
                              ChoiceChip(
                                label: Text('Selected (${_selected.length})'),
                                selected: _onlySelected,
                                onSelected: (_) =>
                                    setState(() => _onlySelected = true),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  FutureBuilder<List<InstalledApp>>(
                    future: _apps,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return SliverToBoxAdapter(
                          child: Center(child: Text(errorText(snap.error!))),
                        );
                      }
                      if (!snap.hasData) {
                        return const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        );
                      }
                      final apps = snap.data!
                          .where(
                            (a) =>
                                !_onlySelected ||
                                _selected.contains(a.packageName),
                          )
                          .where(
                            (a) =>
                                _filter.isEmpty ||
                                a.label.toLowerCase().contains(_filter) ||
                                a.packageName.contains(_filter),
                          )
                          .toList();
                      if (apps.isEmpty) {
                        return const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('No apps match.')),
                          ),
                        );
                      }
                      return SliverPadding(
                        padding: EdgeInsets.fromLTRB(side, 4, side, 24),
                        sliver: SliverList.separated(
                          itemCount: apps.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final a = apps[i];
                            final on = _selected.contains(a.packageName);
                            return Material(
                              color: on
                                  ? KioskPalette.accent.withValues(alpha: 0.08)
                                  : KioskPalette.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: on
                                      ? KioskPalette.accent.withValues(
                                          alpha: 0.5,
                                        )
                                      : KioskPalette.outline,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: CheckboxListTile(
                                key: Key('select-${a.packageName}'),
                                value: on,
                                onChanged: (v) => setState(
                                  () => v == true
                                      ? _selected.add(a.packageName)
                                      : _selected.remove(a.packageName),
                                ),
                                secondary: SizedBox.square(
                                  dimension: 40,
                                  child: a.icon != null
                                      ? Image.memory(a.icon!)
                                      : const Icon(Icons.apps),
                                ),
                                title: Text(
                                  a.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  a.packageName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: KioskPalette.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),
        // Sticky save bar.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: const BoxDecoration(
            color: KioskPalette.surface,
            border: Border(top: BorderSide(color: KioskPalette.outline)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _dirty
                        ? '${_selected.length} selected · unsaved'
                        : '${_selected.length} selected',
                    style: TextStyle(
                      color: _dirty
                          ? KioskPalette.warn
                          : KioskPalette.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload',
                  onPressed: () => setState(() {
                    _apps = widget.controller.bridge.listApps(
                      onlyAllowed: false,
                    );
                    _selected = widget.controller.state.allowedPackages.toSet();
                  }),
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const Key('save-apps'),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                  onPressed: () => adminRun(
                    context,
                    () => widget.controller.bridge.setAllowedPackages(
                      _selected.toList()..sort(),
                    ),
                    success: 'Allowed apps saved',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ======================================================================= Coin box

class _CoinBoxPage extends StatefulWidget {
  const _CoinBoxPage({required this.controller});

  final KioskController controller;

  @override
  State<_CoinBoxPage> createState() => _CoinBoxPageState();
}

class _CoinBoxPageState extends State<_CoinBoxPage> {
  late final _address = TextEditingController(
    text:
        widget.controller.state.controllerAddress?.replaceAll(':80', '') ?? '',
  );
  final _code = TextEditingController();
  late final _timeout = TextEditingController(
    text: widget.controller.state.lossTimeoutS.toString(),
  );
  late int _station = widget.controller.state.controllerStation;
  bool _busy = false;

  /// Tablets the chosen coin box serves (from its reply); 4 until known.
  int _maxStations = 4;
  List<CoinBoxInfo>? _found;
  bool _finding = false;
  CoinBoxTest? _test;
  bool _testing = false;

  Future<void> _find() async {
    setState(() => _finding = true);
    await adminRun(context, () async {
      final found = await widget.controller.bridge.findCoinBoxes();
      if (!mounted) return;
      setState(() => _found = found);
      if (found.length == 1) _use(found.single);
    });
    if (mounted) setState(() => _finding = false);
  }

  void _use(CoinBoxInfo box) => setState(() {
    _address.text = box.host;
    _maxStations = box.stations;
    // A kiosk's own coin box (one tablet) knows its tablet as Tablet 1.
    if (_station > box.stations) _station = 1;
  });

  Future<void> _testNow() async {
    setState(() => _testing = true);
    try {
      final t = await widget.controller.bridge.testCoinBox(
        _address.text.trim().isEmpty ? null : _address.text.trim(),
      );
      if (mounted) setState(() => _test = t);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  void dispose() {
    _address.dispose();
    _code.dispose();
    _timeout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.state;
    final b = widget.controller.bridge;
    final (linkText, linkColor) = !s.controllerPaired
        ? ('NOT PAIRED', KioskPalette.danger)
        : switch (s.controllerLink) {
            ControllerLink.connected => ('CONNECTED', KioskPalette.ok),
            ControllerLink.degraded => ('RECONNECTING', KioskPalette.warn),
            ControllerLink.lost => ('DISCONNECTED', KioskPalette.danger),
            ControllerLink.never => ('CONNECTING', KioskPalette.warn),
          };
    return _Page(
      title: 'Coin box',
      subtitle:
          'The ESP8266 coin controller on your local Wi-Fi. It decides paid time.',
      children: [
        AdminSection(
          icon: Icons.sensors,
          title: 'Live status',
          trailing: StatusBadge(linkText, color: linkColor),
          children: [
            InfoRow('Controller', s.controllerDeviceId, mono: true),
            InfoRow('Address', s.controllerAddress, mono: true),
            InfoRow(
              'This tablet',
              s.controllerPaired ? 'Tablet ${s.controllerStation}' : null,
            ),
            InfoRow(
              'Next coins go to',
              !s.controllerPaired
                  ? null
                  : s.selectedStation == 0
                  ? (s.heldPulses > 0
                        ? 'Nobody (₱${s.heldPulses} held)'
                        : 'Nobody')
                  : 'Tablet ${s.selectedStation} (${s.selectedTtlS} s)',
            ),
            InfoRow(
              'Remaining (verified)',
              s.accessSource == 'controller' ? formatHms(s.remainingMs) : '—',
            ),
            InfoRow(
              'Free time from dashboard',
              s.dashboardRemainingMs > 0
                  ? formatHms(s.dashboardRemainingMs)
                  : null,
            ),
            InfoRow(
              'Rate',
              '${s.secondsPerPulse} s per peso (${Rates.describeDuration(s.secondsPerPulse)})',
            ),
            InfoRow(
              'Last report',
              s.controllerLastOkAgoMs == null
                  ? 'never'
                  : '${s.controllerLastOkAgoMs! ~/ 1000} s ago',
            ),
            InfoRow(
              'Last error',
              s.controllerLastError,
              valueColor: s.controllerLastError == null
                  ? null
                  : KioskPalette.warn,
              last: !s.controllerResumed,
            ),
            if (s.controllerResumed)
              const InfoRow(
                'Note',
                'Restored a saved session after restarting',
                last: true,
              ),
            if (_test != null) ...[
              const SizedBox(height: 8),
              CoinBoxTestView(test: _test!),
            ],
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                OutlinedButton.icon(
                  key: const Key('coinbox-test'),
                  onPressed: _testing ? null : _testNow,
                  icon: _testing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: const Text('Test connection'),
                ),
              ],
            ),
          ],
        ),
        AdminSection(
          icon: Icons.link,
          title: s.controllerPaired
              ? 'Re-pair or change address'
              : 'Pair this tablet',
          description:
              'Tablet and coin box must be on the same Wi-Fi. With its own coin box, pair as Tablet 1. A coin '
              'box shared by up to 4 tablets needs each tablet\'s own number. Get a 6-digit code from the coin box hotspot (Pair tablet tab) or by '
              'holding its FLASH button for 3 seconds (valid 2 minutes), then enter it here. Pairing replaces '
              'any tablet with the same number.',
          children: [
            ActionButtons(
              children: [
                OutlinedButton.icon(
                  key: const Key('coinbox-find'),
                  onPressed: _finding ? null : _find,
                  icon: _finding
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(
                    _finding ? 'Searching this Wi-Fi…' : 'Find coin box',
                  ),
                ),
              ],
            ),
            if (_found != null) ...[
              const SizedBox(height: 8),
              if (_found!.isEmpty)
                const AdminNote(
                  'No coin box found on this Wi-Fi. Check that the coin box is powered and on the same '
                  'network (Wi-Fi page), then search again.',
                  color: KioskPalette.warn,
                ),
              for (final box in _found!)
                ListTile(
                  key: Key('found-${box.deviceId}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.memory,
                    color: box.host == _address.text.trim()
                        ? KioskPalette.accent
                        : KioskPalette.textMuted,
                  ),
                  title: Text('${box.deviceId} · ${box.host}'),
                  subtitle: Text(
                    [
                      'firmware ${box.fwVersion}',
                      box.stations == 1
                          ? 'one tablet'
                          : '${box.stations} tablets',
                      if (box.mine) 'paired with this tablet',
                      if (box.pairingOpen == true) 'pairing open',
                    ].join(' · '),
                  ),
                  onTap: () => _use(box),
                ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              key: ValueKey('pair-station-$_maxStations-$_station'),
              initialValue: _station.clamp(1, _maxStations),
              decoration: InputDecoration(
                labelText: 'Tablet number',
                helperText: _maxStations == 1
                    ? 'This coin box serves one tablet: Tablet 1'
                    : null,
              ),
              items: [
                for (var n = 1; n <= _maxStations; n++)
                  DropdownMenuItem(value: n, child: Text('Tablet $n')),
              ],
              onChanged: (v) => setState(() => _station = v ?? 1),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Controller IP address',
                hintText: '192.168.1.50',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Pairing code',
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                FilledButton.icon(
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('Pair'),
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await adminRun(context, () async {
                            final id = await b.pairController(
                              _address.text,
                              _code.text,
                              _station,
                            );
                            _code.clear();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Paired with $id as Tablet $_station',
                                  ),
                                ),
                              );
                            }
                          });
                          if (mounted) setState(() => _busy = false);
                        },
                ),
                if (s.controllerPaired)
                  OutlinedButton(
                    onPressed: () => adminRun(
                      context,
                      () => b.setControllerAddress(_address.text),
                      success: 'Address updated',
                    ),
                    child: const Text('Update address only'),
                  ),
              ],
            ),
          ],
        ),
        AdminSection(
          icon: Icons.wifi_off_outlined,
          title: 'Connection-loss timeout',
          description:
              'If no verified report arrives for this long, production mode stops customer access and '
              'returns to the payment screen.',
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _timeout,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Seconds (5–600)',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () {
                    final v = int.tryParse(_timeout.text);
                    if (v == null || v < 5 || v > 600) {
                      showError(context, 'Enter 5 to 600 seconds');
                      return;
                    }
                    adminRun(
                      context,
                      () => b.setLossTimeout(v),
                      success: 'Saved',
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
        _ChargeSection(state: s, bridge: b),
        if (s.controllerPaired)
          AdminSection(
            icon: Icons.warning_amber_rounded,
            title: 'Session and pairing',
            accent: KioskPalette.danger,
            children: [
              ActionButtons(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KioskPalette.warn,
                    ),
                    icon: const Icon(Icons.timer_off_outlined),
                    label: const Text('End current session'),
                    onPressed: () async {
                      if (await adminConfirm(
                            context,
                            'End current session?',
                            'Remaining paid time on the coin box is set to zero.',
                            action: 'End session',
                            destructive: true,
                          ) &&
                          context.mounted) {
                        await adminRun(
                          context,
                          b.endSession,
                          success: 'Session ended',
                        );
                      }
                    },
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KioskPalette.danger,
                    ),
                    icon: const Icon(Icons.link_off),
                    label: const Text('Unpair'),
                    onPressed: () async {
                      if (await adminConfirm(
                            context,
                            'Unpair coin box?',
                            'Paid access stops until a coin box is paired again.',
                            action: 'Unpair',
                            destructive: true,
                          ) &&
                          context.mounted) {
                        await adminRun(
                          context,
                          b.unpairController,
                          success: 'Unpaired',
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}

// ======================================================================= Cloud

/// Charger relay on the coin box (D6): the tablet asks for it when its
/// battery drops below the start level and releases it at the stop level.
class _ChargeSection extends StatelessWidget {
  const _ChargeSection({required this.state, required this.bridge});

  final KioskState state;
  final KioskBridge bridge;

  static const _starts = [10, 15, 20, 25, 30, 40, 50];
  static const _stops = [60, 70, 80, 90, 100];

  @override
  Widget build(BuildContext context) {
    final s = state;
    final b = bridge;
    Future<void> save({bool? enabled, int? start, int? stop}) => adminRun(
      context,
      () => b.setAutoCharge(
        enabled: enabled ?? s.autoCharge,
        startPct: start ?? s.chargeStartPct,
        stopPct: stop ?? s.chargeStopPct,
      ),
      success: 'Saved',
    );
    final relay = switch (s.chargeRelayOn) {
      true => 'ON',
      false => 'OFF',
      null =>
        s.controllerPaired ? 'Waiting for the coin box' : 'Coin box not paired',
    };
    final err = s.chargeLastError == 'coin_box_outdated'
        ? 'Coin box firmware is older than 2.2.0'
        : s.chargeLastError;
    return AdminSection(
      icon: Icons.battery_charging_full,
      title: 'Charger relay (D6)',
      trailing: s.chargeRelayOn == true
          ? const StatusBadge('CHARGING', color: KioskPalette.ok)
          : null,
      description:
          'The coin box switches its D6 relay on when this tablet\'s battery drops below the start '
          'level and off again when it reaches the stop level. Wire the tablet charger through the relay.',
      children: [
        SwitchListTile(
          key: const Key('auto-charge'),
          contentPadding: EdgeInsets.zero,
          value: s.autoCharge,
          title: const Text('Charge automatically'),
          onChanged: (v) => save(enabled: v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                key: const Key('charge-start'),
                isExpanded: true,
                initialValue: _starts.contains(s.chargeStartPct)
                    ? s.chargeStartPct
                    : 20,
                decoration: const InputDecoration(labelText: 'Start below'),
                items: [
                  for (final p in _starts)
                    DropdownMenuItem(value: p, child: Text('$p%')),
                ],
                onChanged: s.autoCharge
                    ? (v) {
                        if (v != null) save(start: v);
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                key: const Key('charge-stop'),
                isExpanded: true,
                initialValue: _stops.contains(s.chargeStopPct)
                    ? s.chargeStopPct
                    : 90,
                decoration: const InputDecoration(labelText: 'Stop at'),
                items: [
                  for (final p in _stops)
                    DropdownMenuItem(value: p, child: Text('$p%')),
                ],
                onChanged: s.autoCharge
                    ? (v) {
                        if (v != null) save(stop: v);
                      }
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        InfoRow(
          'Battery',
          s.batteryPct < 0
              ? null
              : '${s.batteryPct}%${s.batteryCharging ? ' · charging' : ''}',
          valueColor: s.batteryPct >= 0 && s.batteryPct < s.chargeStartPct
              ? KioskPalette.warn
              : null,
        ),
        InfoRow(
          'Relay',
          relay,
          valueColor: s.chargeRelayOn == true ? KioskPalette.ok : null,
          last: err == null,
        ),
        if (err != null)
          InfoRow('Last error', err, valueColor: KioskPalette.warn, last: true),
      ],
    );
  }
}

class _CloudPage extends StatefulWidget {
  const _CloudPage({required this.controller});

  final KioskController controller;

  @override
  State<_CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<_CloudPage> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.state;
    final b = widget.controller.bridge;
    final (text, color) = switch (s.cloudLink) {
      CloudLink.ok => ('ONLINE', KioskPalette.ok),
      CloudLink.offline => ('OFFLINE', KioskPalette.warn),
      CloudLink.unauthorized => ('REVOKED', KioskPalette.danger),
      CloudLink.error => ('ERROR', KioskPalette.warn),
      CloudLink.disabled => ('NOT ENROLLED', KioskPalette.textMuted),
    };
    return _Page(
      title: 'Cloud',
      subtitle:
          'Reporting to vendo-kiosk.ebnleadgen.online. The cloud never grants paid time; '
          'an internet outage does not stop the kiosk.',
      children: [
        AdminSection(
          icon: Icons.cloud_outlined,
          title: 'Connection',
          trailing: StatusBadge(text, color: color),
          children: [
            InfoRow('Enrolled', s.cloudEnrolled ? 'Yes' : 'No'),
            InfoRow(
              'Last success',
              s.cloudLastOkAgoMs == null
                  ? 'never'
                  : '${s.cloudLastOkAgoMs! ~/ 1000} s ago',
            ),
            InfoRow('Last error', s.cloudLastError),
            InfoRow(
              'Config version applied',
              '${s.cloudConfigVersion}',
              last: true,
            ),
          ],
        ),
        AdminSection(
          icon: Icons.qr_code_2,
          title: s.cloudEnrolled ? 'Re-enroll' : 'Enroll this phone',
          description:
              'In the dashboard open the kiosk → “Generate phone code”, then enter it here '
              '(valid 30 minutes, single use).',
          children: [
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Enrollment code',
                hintText: 'XXXXX-XXXXX',
              ),
            ),
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await adminRun(context, () async {
                            await b.enrollCloud(_code.text);
                            _code.clear();
                          }, success: 'Enrolled');
                          if (mounted) setState(() => _busy = false);
                        },
                  child: const Text('Enroll'),
                ),
                if (s.cloudEnrolled)
                  OutlinedButton(
                    onPressed: () => adminRun(
                      context,
                      b.unenrollCloud,
                      success: 'Cloud reporting disabled',
                    ),
                    child: const Text('Forget credential'),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ======================================================================= System

class _SystemPage extends StatefulWidget {
  const _SystemPage({required this.controller, required this.onLock});

  final KioskController controller;
  final VoidCallback onLock;

  @override
  State<_SystemPage> createState() => _SystemPageState();
}

class _SystemPageState extends State<_SystemPage> {
  final _pin = TextEditingController();
  final _confirmPin = TextEditingController();
  Future<Map<String, Object?>>? _diag;

  @override
  void dispose() {
    _pin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.state;
    final b = widget.controller.bridge;
    return _Page(
      title: 'System',
      subtitle: 'Security, recovery and diagnostics.',
      children: [
        AdminSection(
          icon: Icons.password,
          title: 'Administrator PIN',
          description:
              'Changing the PIN issues a new recovery code. Write it down somewhere safe.',
          children: [
            PinField(controller: _pin, label: 'New PIN'),
            const SizedBox(height: 10),
            PinField(controller: _confirmPin, label: 'Confirm new PIN'),
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                FilledButton(
                  onPressed: () async {
                    if (_pin.text != _confirmPin.text) {
                      showError(context, 'PINs do not match');
                      return;
                    }
                    try {
                      final code = await b.changePin(_pin.text);
                      _pin.clear();
                      _confirmPin.clear();
                      if (!context.mounted) return;
                      await showDialog<void>(
                        context: context,
                        builder: (c) => AlertDialog(
                          backgroundColor: KioskPalette.surfaceHigh,
                          title: const Text('PIN changed'),
                          content: RecoveryCodeNotice(code: code),
                          actions: [
                            FilledButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('I saved it'),
                            ),
                          ],
                        ),
                      );
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: const Text('Change PIN'),
                ),
              ],
            ),
          ],
        ),
        AdminSection(
          icon: Icons.brightness_low_outlined,
          title: 'Screen',
          description:
              'With no paid time, the kiosk logo is shown after this long without touches, '
              'then the display switches off. A touch on the logo returns to the payment screen; '
              'a coin or the power button turns the display back on.',
          children: [
            DropdownButtonFormField<int>(
              key: const Key('idle-sleep'),
              isExpanded: true,
              initialValue: const [0, 30, 60, 120, 300].contains(s.idleSleepS)
                  ? s.idleSleepS
                  : 60,
              decoration: const InputDecoration(
                labelText: 'Show logo when idle',
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Never')),
                DropdownMenuItem(value: 30, child: Text('After 30 seconds')),
                DropdownMenuItem(value: 60, child: Text('After 1 minute')),
                DropdownMenuItem(value: 120, child: Text('After 2 minutes')),
                DropdownMenuItem(value: 300, child: Text('After 5 minutes')),
              ],
              onChanged: (v) {
                if (v != null) {
                  adminRun(context, () => b.setIdleSleep(v), success: 'Saved');
                }
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('screen-off'),
              isExpanded: true,
              initialValue:
                  const [0, 30, 60, 120, 300, 600].contains(s.screenOffS)
                  ? s.screenOffS
                  : 60,
              decoration: const InputDecoration(
                labelText: 'Turn the screen off',
              ),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Never (logo stays on)')),
                DropdownMenuItem(value: 30, child: Text('30 seconds after the logo')),
                DropdownMenuItem(value: 60, child: Text('1 minute after the logo')),
                DropdownMenuItem(value: 120, child: Text('2 minutes after the logo')),
                DropdownMenuItem(value: 300, child: Text('5 minutes after the logo')),
                DropdownMenuItem(value: 600, child: Text('10 minutes after the logo')),
              ],
              onChanged: (v) {
                if (v != null) {
                  adminRun(context, () => b.setScreenOff(v), success: 'Saved');
                }
              },
            ),
            const SizedBox(height: 12),
            InfoRow(
              'Lock screen',
              s.screenLockSecure
                  ? 'PIN / pattern (asks for the code)'
                  : 'None or swipe (kiosk skips it)',
              valueColor: s.screenLockSecure
                  ? KioskPalette.warn
                  : KioskPalette.ok,
              last: true,
            ),
            if (s.screenLockSecure) ...[
              const SizedBox(height: 10),
              const AdminNote(
                'Remove the PIN/pattern so the kiosk wakes straight to the coin screen: '
                'Settings → Security → Screen lock → None.',
                icon: Icons.lock_open,
                color: KioskPalette.warn,
              ),
              if (!s.isProduction) ...[
                const SizedBox(height: 12),
                ActionButtons(
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.settings),
                      label: const Text('Open lock screen settings'),
                      onPressed: () =>
                          adminRun(context, b.openLockScreenSettings),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
        AdminSection(
          icon: Icons.account_circle_outlined,
          title: 'Game and social logins',
          children: [
            SwitchListTile(
              key: const Key('allow-accounts'),
              contentPadding: EdgeInsets.zero,
              value: s.allowAccounts,
              title: const Text('Allow Facebook and Google sign-in'),
              subtitle: const Text(
                'Lets customers log in to games and social apps (Facebook, Google Play Games, TikTok). '
                'A login can stay on the tablet for the next customer, so remind customers to log out. '
                'Settings and app stores stay blocked either way.',
                style: TextStyle(color: KioskPalette.textMuted),
              ),
              onChanged: (v) => adminRun(context, () => b.setAllowAccounts(v)),
            ),
          ],
        ),
        _BrightnessSection(state: s, bridge: b),
        AdminSection(
          icon: Icons.volume_up_outlined,
          title: 'Sounds',
          children: [
            SwitchListTile(
              key: const Key('sounds'),
              contentPadding: EdgeInsets.zero,
              value: s.sounds,
              title: const Text('Coin chime and time warnings'),
              subtitle: const Text(
                'A chime when a coin adds time, a beep at 5 minutes left, three beeps at 1 minute and a '
                'tone when time is up. Follows the tablet\'s notification volume.',
                style: TextStyle(color: KioskPalette.textMuted),
              ),
              onChanged: (v) => adminRun(context, () => b.setSounds(v)),
            ),
          ],
        ),
        AdminSection(
          icon: Icons.block,
          title: 'Ad blocking',
          trailing: s.isProduction
              ? StatusBadge(
                  s.adBlockActive ? 'ON' : 'OFF',
                  color: s.adBlockActive ? KioskPalette.ok : KioskPalette.warn,
                )
              : null,
          children: [
            SwitchListTile(
              key: const Key('block-ads'),
              contentPadding: EdgeInsets.zero,
              value: s.blockAds,
              title: const Text('Block ads in games and apps'),
              subtitle: const Text(
                'Production only. Uses an ad-blocking DNS (AdGuard) for the whole tablet, so most '
                'game ads never load. Games that need a video ad for a reward may skip the reward.',
                style: TextStyle(color: KioskPalette.textMuted),
              ),
              onChanged: (v) => adminRun(context, () => b.setBlockAds(v)),
            ),
            if (s.adBlockProblem != null) ...[
              const SizedBox(height: 8),
              AdminNote(
                s.adBlockProblem!,
                icon: Icons.warning_amber_rounded,
                color: KioskPalette.warn,
              ),
            ],
          ],
        ),
        AdminSection(
          icon: Icons.usb,
          title: 'USB debugging',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.lockAdb,
              title: const Text('Disable USB debugging in production'),
              subtitle: const Text(
                'More secure, but removes the ADB recovery path. Leave off until physical testing is complete.',
                style: TextStyle(color: KioskPalette.textMuted),
              ),
              onChanged: (v) => adminRun(context, () => b.setLockAdb(v)),
            ),
            SwitchListTile(
              key: const Key('keep-wireless-adb'),
              contentPadding: EdgeInsets.zero,
              value: s.keepWirelessAdb,
              title: const Text('Keep wireless debugging on'),
              subtitle: Text(
                'Android switches wireless debugging off by itself (screen off, restarts). '
                'This turns it back on within 30 seconds so the app can be updated remotely. '
                'Only computers already paired can connect. '
                'Now: ${s.wirelessAdbOn ? 'on' : 'off'}.',
                style: const TextStyle(color: KioskPalette.textMuted),
              ),
              onChanged: (v) => adminRun(context, () => b.setKeepWirelessAdb(v)),
            ),
          ],
        ),
        const AdminSection(
          icon: Icons.health_and_safety_outlined,
          title: 'Recovery',
          children: [
            AdminNote(
              'Forgot the PIN: on the PIN prompt tap “Forgot PIN?” and enter the recovery code. '
              'Lost both: with USB debugging on, an authorised computer can send the ADB recovery command '
              '(docs/RECOVERY.md). Otherwise only a factory reset from recovery mode works (erases the phone).',
            ),
          ],
        ),
        AdminSection(
          icon: Icons.bug_report_outlined,
          title: 'Diagnostics',
          trailing: TextButton(
            onPressed: () => setState(() => _diag = b.diagnostics()),
            child: Text(_diag == null ? 'Load' : 'Refresh'),
          ),
          children: [
            if (_diag == null)
              const Text(
                'Device and policy details for troubleshooting.',
                style: TextStyle(color: KioskPalette.textMuted),
              )
            else
              FutureBuilder<Map<String, Object?>>(
                future: _diag,
                builder: (context, snap) {
                  if (snap.hasError) return Text(errorText(snap.error!));
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final entries = snap.data!.entries.toList();
                  return Column(
                    children: [
                      for (var i = 0; i < entries.length; i++)
                        InfoRow(
                          entries[i].key,
                          entries[i].value is List
                              ? (entries[i].value as List).join(', ')
                              : '${entries[i].value}',
                          mono: true,
                          last: i == entries.length - 1,
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
        FilledButton.tonalIcon(
          onPressed: widget.onLock,
          icon: const Icon(Icons.lock_outline),
          label: const Text('Lock administrator settings'),
        ),
      ],
    );
  }
}
