part of 'admin_screen.dart';

// ======================================================================= Wi-Fi

/// The tablet's Wi-Fi: what it is connected to, whether it reaches the coin
/// box, and joining another network. The kiosk hides Settings, so this is the
/// only way to change Wi-Fi in production.
class _WifiPage extends StatefulWidget {
  const _WifiPage({required this.controller});

  final KioskController controller;

  @override
  State<_WifiPage> createState() => _WifiPageState();
}

class _WifiPageState extends State<_WifiPage> {
  WifiStatus? _status;
  List<WifiNetwork>? _networks;
  CoinBoxTest? _test;
  bool _scanning = false;
  bool _testing = false;
  Timer? _refresh;

  KioskBridge get _b => widget.controller.bridge;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await _b.wifiStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // Shown as "unknown"; the page keeps working.
    }
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    await adminRun(context, () async {
      final n = await _b.wifiScan();
      if (mounted) setState(() => _networks = n);
    });
    if (mounted) setState(() => _scanning = false);
    _load();
  }

  Future<void> _testCoinBox() async {
    setState(() => _testing = true);
    try {
      final t = await _b.testCoinBox();
      if (mounted) setState(() => _test = t);
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _join(WifiNetwork? network) async {
    final r = await showDialog<(String, String, String)>(
      context: context,
      builder: (_) => _JoinWifiDialog(network: network),
    );
    if (r == null || !mounted) return;
    final (ssid, password, security) = r;
    await adminRun(
      context,
      () => _b.wifiConnect(ssid, password, security),
      success: 'Joining $ssid…',
    );
    // Android needs a few seconds to connect and get an address.
    for (final wait in [3, 6, 10]) {
      await Future<void>.delayed(Duration(seconds: wait));
      if (!mounted) return;
      await _load();
      if (_status?.ssid == ssid && _status?.ip != null) break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = _status;
    final s = widget.controller.state;
    final (badge, badgeColor) = w == null
        ? ('CHECKING', KioskPalette.textMuted)
        : !w.enabled
        ? ('WI-FI OFF', KioskPalette.danger)
        : !w.connected
        ? ('NOT CONNECTED', KioskPalette.danger)
        : w.internet
        ? ('CONNECTED', KioskPalette.ok)
        : ('NO INTERNET', KioskPalette.warn);
    final boxHost = s.controllerAddress?.split(':').first;
    final sameNetwork =
        w?.ip != null &&
        boxHost != null &&
        _subnet(w!.ip!) == _subnet(boxHost);

    return _Page(
      title: 'Wi-Fi',
      subtitle:
          'The tablet and its coin box must be on the same Wi-Fi. Settings is hidden in the kiosk, '
          'so join networks here.',
      children: [
        AdminSection(
          icon: Icons.wifi,
          title: 'This tablet',
          trailing: StatusBadge(badge, color: badgeColor),
          children: [
            InfoRow(
              'Network',
              w == null || !w.connected
                  ? null
                  : (w.ssid ?? 'Connected (name hidden until you scan)'),
            ),
            InfoRow(
              'Signal',
              w?.rssi == null ? null : '${_quality(w!.rssi!)} (${w.rssi} dBm)',
              valueColor: w?.rssi != null && w!.rssi! < -75
                  ? KioskPalette.warn
                  : null,
            ),
            InfoRow(
              'Band',
              w?.frequencyMhz == null
                  ? null
                  : '${w!.frequencyMhz! >= 5000 ? '5' : '2.4'} GHz'
                        '${w.linkMbps == null ? '' : ' · ${w.linkMbps} Mbps'}',
            ),
            InfoRow('Tablet IP', w?.ip, mono: true),
            InfoRow('Router', w?.gateway, mono: true),
            InfoRow(
              'Internet',
              w == null || !w.connected
                  ? null
                  : w.internet
                  ? 'Yes'
                  : 'No',
              valueColor: w != null && w.connected && !w.internet
                  ? KioskPalette.warn
                  : null,
              last: true,
            ),
            if (w != null && w.connected && !w.internet) ...[
              const SizedBox(height: 12),
              const AdminNote(
                'This Wi-Fi has no internet. The coin box still works (the app talks to it over this '
                'Wi-Fi), but the dashboard and online apps need internet.',
                icon: Icons.public_off,
                color: KioskPalette.warn,
              ),
            ],
            if (w != null && !w.deviceOwner) ...[
              const SizedBox(height: 12),
              const AdminNote(
                'Joining and scanning need the kiosk to be Device Owner (production setup).',
              ),
            ],
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                if (w != null && w.deviceOwner)
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (w.enabled &&
                          !await adminConfirm(
                            context,
                            'Turn Wi-Fi off?',
                            'The coin box stops reaching this tablet and paid access pauses.',
                            action: 'Turn off',
                            destructive: true,
                          )) {
                        return;
                      }
                      if (!context.mounted) return;
                      await adminRun(context, () => _b.wifiSetEnabled(!w.enabled));
                      await Future<void>.delayed(const Duration(seconds: 2));
                      _load();
                    },
                    icon: Icon(w.enabled ? Icons.wifi_off : Icons.wifi),
                    label: Text(w.enabled ? 'Turn Wi-Fi off' : 'Turn Wi-Fi on'),
                  ),
              ],
            ),
          ],
        ),
        AdminSection(
          icon: Icons.memory,
          title: 'Coin box connection',
          trailing: _test == null
              ? null
              : StatusBadge(
                  _test!.ok ? 'REACHED' : 'FAILED',
                  color: _test!.ok ? KioskPalette.ok : KioskPalette.danger,
                ),
          description:
              'Checks that this tablet reaches its coin box over the Wi-Fi right now.',
          children: [
            InfoRow('Coin box address', s.controllerAddress, mono: true),
            InfoRow(
              'Same network',
              boxHost == null || w?.ip == null
                  ? null
                  : sameNetwork
                  ? 'Yes'
                  : 'No — tablet is on ${_subnet(w!.ip!)}.x',
              valueColor: boxHost != null && w?.ip != null && !sameNetwork
                  ? KioskPalette.danger
                  : null,
              last: _test == null,
            ),
            if (_test != null) CoinBoxTestView(test: _test!),
            const SizedBox(height: 14),
            ActionButtons(
              children: [
                FilledButton.icon(
                  onPressed: _testing || s.controllerAddress == null
                      ? null
                      : _testCoinBox,
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
            if (s.controllerAddress == null) ...[
              const SizedBox(height: 10),
              const AdminNote(
                'Not paired yet. Pair on the Coin box page (it can search this Wi-Fi for the box).',
              ),
            ],
          ],
        ),
        AdminSection(
          icon: Icons.wifi_find,
          title: 'Join a network',
          description:
              'The ESP8266 coin box only uses 2.4 GHz Wi-Fi. Put the tablet on the same router '
              '(its 2.4 or 5 GHz name both work when they are the same network).',
          children: [
            ActionButtons(
              children: [
                FilledButton.icon(
                  key: const Key('wifi-scan'),
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_find),
                  label: Text(_scanning ? 'Scanning…' : 'Scan for networks'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _join(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Hidden network'),
                ),
              ],
            ),
            if (_networks != null) ...[
              const SizedBox(height: 8),
              if (_networks!.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No networks found. Scan again in a few seconds.'),
                ),
              for (final n in _networks!)
                ListTile(
                  key: Key('wifi-${n.ssid}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _signalIcon(n.rssi),
                    color: n.connected ? KioskPalette.accent : KioskPalette.text,
                  ),
                  title: Text(
                    n.ssid,
                    style: TextStyle(
                      fontWeight: n.connected ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    [
                      if (n.connected) 'Connected',
                      _quality(n.rssi),
                      n.frequencyMhz >= 5000 ? '5 GHz' : '2.4 GHz',
                      if (n.security == 'enterprise') 'enterprise (not supported)',
                    ].join(' · '),
                  ),
                  trailing: n.secured
                      ? const Icon(Icons.lock_outline, size: 18)
                      : null,
                  enabled: n.security != 'enterprise' && n.security != 'wep',
                  onTap: n.connected ? null : () => _join(n),
                ),
            ],
          ],
        ),
      ],
    );
  }
}

String _subnet(String ip) => ip.substring(0, ip.lastIndexOf('.'));

String _quality(int rssi) => rssi >= -55
    ? 'Excellent'
    : rssi >= -67
    ? 'Good'
    : rssi >= -75
    ? 'Fair'
    : 'Weak';

IconData _signalIcon(int rssi) => rssi >= -55
    ? Icons.signal_wifi_4_bar
    : rssi >= -67
    ? Icons.network_wifi_3_bar
    : rssi >= -75
    ? Icons.network_wifi_2_bar
    : Icons.network_wifi_1_bar;

/// Password (and, for a hidden network, name and security) for joining Wi-Fi.
class _JoinWifiDialog extends StatefulWidget {
  const _JoinWifiDialog({this.network});

  /// Null for a hidden network typed in by hand.
  final WifiNetwork? network;

  @override
  State<_JoinWifiDialog> createState() => _JoinWifiDialogState();
}

class _JoinWifiDialogState extends State<_JoinWifiDialog> {
  late final _ssid = TextEditingController(text: widget.network?.ssid ?? '');
  final _password = TextEditingController();
  late String _security = widget.network?.security ?? 'wpa2';
  bool _show = false;

  @override
  void dispose() {
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  String? get _error {
    if (_ssid.text.trim().isEmpty) return 'Enter the network name';
    if (_security != 'open' && _password.text.length < 8) {
      return 'Wi-Fi passwords have at least 8 characters';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hidden = widget.network == null;
    return AlertDialog(
      backgroundColor: KioskPalette.surfaceHigh,
      title: Text(hidden ? 'Hidden network' : widget.network!.ssid),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hidden) ...[
              TextField(
                controller: _ssid,
                maxLength: 32,
                decoration: const InputDecoration(
                  labelText: 'Network name (SSID)',
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _security,
                decoration: const InputDecoration(labelText: 'Security'),
                items: const [
                  DropdownMenuItem(value: 'wpa2', child: Text('WPA/WPA2')),
                  DropdownMenuItem(value: 'wpa3', child: Text('WPA3')),
                  DropdownMenuItem(value: 'open', child: Text('None (open)')),
                ],
                onChanged: (v) => setState(() => _security = v ?? 'wpa2'),
              ),
              const SizedBox(height: 12),
            ],
            if (_security != 'open')
              TextField(
                key: const Key('wifi-password'),
                controller: _password,
                obscureText: !_show,
                autofocus: !hidden,
                maxLength: 63,
                decoration: InputDecoration(
                  labelText: 'Password',
                  counterText: '',
                  suffixIcon: IconButton(
                    tooltip: _show ? 'Hide' : 'Show',
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              )
            else
              const Text('This network has no password.'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('wifi-join'),
          onPressed: _error != null
              ? null
              : () => Navigator.pop(context, (
                  _ssid.text.trim(),
                  _password.text,
                  _security,
                )),
          child: const Text('Join'),
        ),
      ],
    );
  }
}

/// Result rows of a coin box connection test, with a hint when it failed.
class CoinBoxTestView extends StatelessWidget {
  const CoinBoxTestView({super.key, required this.test});

  final CoinBoxTest test;

  static String hint(String? error) => switch (error) {
    'timeout' =>
      'No reply. The tablet and coin box are probably on different Wi-Fi networks, or the router '
          'blocks Wi-Fi devices from reaching each other ("AP isolation" / "client isolation" — turn it off).',
    'unreachable' =>
      'Nothing answers at that address. The coin box may have a new IP: hold its FLASH button 1 s '
          'to show it on the LCD, or use "Find coin box" on the Coin box page.',
    'not_a_coin_box' =>
      'Something answers at that address, but it is not a coin box. Check the IP.',
    'bad_address' => 'Enter a private IPv4 address such as 192.168.0.106.',
    'no_wifi' => 'The tablet is not on a Wi-Fi network.',
    _ => 'The coin box did not answer ($error).',
  };

  @override
  Widget build(BuildContext context) {
    final t = test;
    final box = t.box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoRow(
          'Result',
          t.ok
              ? 'Reached in ${t.ms} ms'
              : '${t.error ?? 'failed'}${t.ms == null ? '' : ' after ${t.ms} ms'}',
          valueColor: t.ok ? KioskPalette.ok : KioskPalette.danger,
          last: box == null,
        ),
        if (box != null) ...[
          InfoRow('Coin box', box.deviceId, mono: true),
          InfoRow(
            'Firmware',
            '${box.fwVersion} · ${box.stations == 1 ? 'one tablet' : '${box.stations} tablets'}',
          ),
          InfoRow(
            'Pairing',
            box.pairingOpen == true ? 'Open — enter the code now' : 'Closed',
            last: true,
          ),
        ],
        if (!t.ok) ...[
          const SizedBox(height: 10),
          AdminNote(hint(t.error), color: KioskPalette.danger),
        ],
      ],
    );
  }
}
