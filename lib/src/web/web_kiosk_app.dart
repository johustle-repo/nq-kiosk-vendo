import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../model/rates.dart';
import '../ui/responsive.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'cloud_status.dart';
import 'status_client.dart';
import 'status_poller.dart';
import 'token_store.dart';

const browserDemoNotice = 'Browser demo: Android kiosk enforcement unavailable';

/// Flutter web build: reads the coin timer from GET /api/kiosk-status.php.
/// No native Android functionality is used or available here.
class WebKioskApp extends StatelessWidget {
  const WebKioskApp({
    super.key,
    required this.config,
    required this.tokenStore,
    required this.httpClient,
    this.pageUri,
    this.clockMs,
  });

  final WebKioskConfig config;
  final TokenStore tokenStore;
  final http.Client httpClient;

  /// The page's own URL (same-origin API in production). Defaults to Uri.base.
  final Uri? pageUri;

  /// Monotonic clock override (tests).
  final int Function()? clockMs;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'VeNdO Kiosk (browser demo)',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.dark,
    builder: (context, child) => clampTextScale(context, child),
    home: WebKioskHome(
      config: config,
      tokenStore: tokenStore,
      httpClient: httpClient,
      pageUri: pageUri ?? Uri.base,
      clockMs: clockMs,
    ),
  );
}

class WebKioskHome extends StatefulWidget {
  const WebKioskHome({
    super.key,
    required this.config,
    required this.tokenStore,
    required this.httpClient,
    required this.pageUri,
    this.clockMs,
  });

  final WebKioskConfig config;
  final TokenStore tokenStore;
  final http.Client httpClient;
  final Uri pageUri;
  final int Function()? clockMs;

  @override
  State<WebKioskHome> createState() => _WebKioskHomeState();
}

class _WebKioskHomeState extends State<WebKioskHome> {
  String? _token;

  @override
  void initState() {
    super.initState();
    final t = widget.tokenStore.read();
    _token = t != null && KioskStatusClient.looksLikeToken(t) ? t : null;
  }

  void _setToken(String token, bool remember) {
    widget.tokenStore.write(token, remember: remember);
    setState(() => _token = token);
  }

  void _forgetToken() {
    widget.tokenStore.clear();
    setState(() => _token = null);
  }

  @override
  Widget build(BuildContext context) {
    final token = _token;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _BrowserDemoBanner(),
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Center(child: BrandLogo(height: 48)),
            ),
            Expanded(
              child: token == null
                  ? _TokenScreen(
                      device: widget.config.device,
                      onSubmit: _setToken,
                    )
                  : WebStatusScreen(
                      key: ValueKey(token),
                      config: widget.config,
                      client: KioskStatusClient(
                        httpClient: widget.httpClient,
                        endpoint: widget.config.endpoint(widget.pageUri),
                        token: token,
                        device: widget.config.device,
                        longPollSeconds: widget.config.longPollSeconds,
                      ),
                      onForgetToken: _forgetToken,
                      clockMs: widget.clockMs,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrowserDemoBanner extends StatelessWidget {
  const _BrowserDemoBanner();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      key: const Key('browser-demo-banner'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: s.tertiaryContainer,
      child: Row(
        children: [
          Icon(Icons.public, color: s.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              browserDemoNotice,
              style: TextStyle(
                color: s.onTertiaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ token entry

class _TokenScreen extends StatefulWidget {
  const _TokenScreen({required this.device, required this.onSubmit});

  final String device;
  final void Function(String token, bool remember) onSubmit;

  @override
  State<_TokenScreen> createState() => _TokenScreenState();
}

class _TokenScreenState extends State<_TokenScreen> {
  final _ctl = TextEditingController();
  bool _remember = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final t = KioskStatusClient.normalizeToken(_ctl.text);
    final problem = KioskStatusClient.tokenProblem(t);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    widget.onSubmit(t, _remember);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Connect to ${widget.device}',
                style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter the browser kiosk access token created by the administrator. '
                'It can only read this device\'s timer. It is not the coin controller\'s upload key.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('token-field'),
                controller: _ctl,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Access token (vkw_…, 64 characters)',
                  errorText: _error,
                  errorMaxLines: 3,
                  suffixIcon: IconButton(
                    key: const Key('toggle-token-visibility'),
                    tooltip: _obscure ? 'Show token' : 'Hide token',
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _submit(),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? false),
                title: const Text('Remember on this browser'),
                subtitle: const Text(
                  'Only on a trusted device. Otherwise the token is forgotten when the tab closes.',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('connect'),
                onPressed: _submit,
                child: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ status / payment screen

class WebStatusScreen extends StatefulWidget {
  const WebStatusScreen({
    super.key,
    required this.config,
    required this.client,
    required this.onForgetToken,
    this.clockMs,
  });

  final WebKioskConfig config;
  final KioskStatusClient client;
  final VoidCallback onForgetToken;
  final int Function()? clockMs;

  @override
  State<WebStatusScreen> createState() => _WebStatusScreenState();
}

class _WebStatusScreenState extends State<WebStatusScreen> {
  late final CloudStatusTracker _tracker = CloudStatusTracker(
    clockMs: widget.clockMs,
  );
  late final StatusPoller _poller = StatusPoller(
    fetch: widget.client.fetch,
    tracker: _tracker,
    interval: widget.config.pollInterval,
  );
  Timer? _ticker;
  int _lastShownRemainingMs = 0;
  bool _expired = false;
  int _creditsSeen = 0;

  @override
  void initState() {
    super.initState();
    _poller.addListener(_onPoll);
    _poller.start();
    // Repaint the local countdown; independent of network polling.
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _onTick(),
    );
  }

  void _onTick() {
    if (!mounted) return;
    final r = _tracker.remainingMs();
    if (_lastShownRemainingMs > 0 && r == 0) _expired = true;
    if (r > 0) _expired = false;
    _lastShownRemainingMs = r;
    setState(() {});
  }

  void _onPoll() {
    if (!mounted) return;
    if (_tracker.creditEvents > _creditsSeen) {
      _creditsSeen = _tracker.creditEvents;
      final pulses = _tracker.lastCreditPulses ?? 0;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Coin received: +${Rates.describeDuration(Rates.secondsFor(pulses))} (₱$pulses)',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    _onTick();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _poller.removeListener(_onPoll);
    _poller.dispose();
    super.dispose();
  }

  String _errorText(StatusError e) => switch (e.code) {
    'unauthorized' =>
      'Access token rejected (invalid, expired or revoked). Enter a new token.',
    'forbidden' => 'This token is not allowed to read ${widget.config.device}.',
    'network'
        when widget.client.endpoint.host == '127.0.0.1' &&
            Uri.base.port != 5173 =>
      'The browser blocked the request: this page runs on ${Uri.base.origin}, but the local API only allows '
          'http://localhost:5173. Restart with --web-port 5173 (IDE: run configuration "Web demo (local API)").',
    'network' =>
      'Cannot reach the server (network down, or the browser blocked the request by CORS).',
    'timeout' => 'The server did not answer in time.',
    'rate_limited' => 'Too many requests; slowing down.',
    'server' => 'Server error while reading the device status.',
    'bad_response' =>
      'The server sent an unexpected response (${e.detail ?? 'not valid status JSON'}).',
    'not_api' =>
      'Got a web page instead of the status API from ${e.detail}. '
          'For local testing, start the PHP API (php -S 127.0.0.1:8000 -t web_backend/public_html) and run the app '
          'with --web-port 5173 --dart-define=VENDO_API_BASE=http://127.0.0.1:8000 '
          '(IDE: run configuration "Web demo (local API)").',
    _ => 'Request failed (${e.code}).',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final remaining = _tracker.remainingMs();
    final latest = _tracker.latest;
    final error = _poller.lastError;
    final failing = error != null;
    final stale = _tracker.isStale;
    final age = _tracker.currentAgeSeconds();

    final (serverText, serverColor) = !_poller.everSucceeded && !failing
        ? ('connecting…', Colors.orange.shade800)
        : failing
        ? ('connection failed (${_poller.consecutiveFailures}×)', scheme.error)
        : ('connected', Colors.green.shade700);
    final (deviceText, deviceColor) = latest == null
        ? ('waiting for first status', scheme.outline)
        : !latest.available
        ? ('no status reported yet', scheme.error)
        : stale
        ? ('STALE — last report ${age ?? '?'} s ago', scheme.error)
        : ('reporting (${age ?? 0} s ago)', Colors.green.shade700);

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > 700;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 48 : 16,
            vertical: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Pill(
                    key: const Key('server-indicator'),
                    icon: Icons.cloud,
                    text: 'Server: $serverText',
                    color: serverColor,
                  ),
                  _Pill(
                    key: const Key('device-indicator'),
                    icon: Icons.memory,
                    text: '${widget.config.device}: $deviceText',
                    color: deviceColor,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (failing) ...[
                InfoBanner(
                  key: const Key('error-banner'),
                  icon: Icons.wifi_off,
                  text:
                      '${_errorText(error)}'
                      '${_tracker.baseline != null && !error.isFatal ? ' Showing the last known time; it is not being updated.' : ''}',
                  background: scheme.errorContainer,
                  foreground: scheme.onErrorContainer,
                ),
                if (error.isFatal) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: widget.onForgetToken,
                    child: const Text('Enter a different token'),
                  ),
                ],
                const SizedBox(height: 16),
              ] else if (stale && latest != null) ...[
                InfoBanner(
                  key: const Key('stale-banner'),
                  icon: Icons.history,
                  text: latest.available
                      ? 'The coin controller has not reported for ${age ?? '?'} s. The time shown may be out of date.'
                      : 'The coin controller has not reported any status yet.',
                  background: scheme.errorContainer,
                  foreground: scheme.onErrorContainer,
                ),
                const SizedBox(height: 16),
              ],
              if (_expired && remaining == 0) ...[
                InfoBanner(
                  key: const Key('expired-banner'),
                  icon: Icons.timer_off,
                  text: 'Time expired. Insert a coin to continue.',
                  background: scheme.secondaryContainer,
                  foreground: scheme.onSecondaryContainer,
                ),
                const SizedBox(height: 16),
              ],
              Text(
                remaining > 0 ? 'Time remaining' : 'Insert coin to start',
                key: const Key('headline'),
                textAlign: TextAlign.center,
                style: (wide ? t.displaySmall : t.headlineMedium)?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: CountdownText(
                  remainingMs: remaining,
                  size: wide ? 84 : 60,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Reported by the coin controller via the server, adjusted for report age. '
                '${widget.config.longPollSeconds > 0 ? 'Updates as soon as the coin box reports.' : 'Updates every ${widget.config.pollInterval.inSeconds} s.'}',
                textAlign: TextAlign.center,
                style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Text('Rates', textAlign: TextAlign.center, style: t.titleLarge),
              const SizedBox(height: 8),
              const RateTable(secondsPerPulse: Rates.defaultSecondsPerPulse),
              const SizedBox(height: 24),
              Text('Apps', textAlign: TextAlign.center, style: t.titleLarge),
              const SizedBox(height: 8),
              const _PreviewTiles(),
              const SizedBox(height: 24),
              Center(
                child: TextButton.icon(
                  onPressed: widget.onForgetToken,
                  icon: const Icon(Icons.logout),
                  label: const Text('Forget access token'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: color.withValues(alpha: 0.6)),
      color: color.withValues(alpha: 0.08),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// App tiles are previews only: a browser cannot launch or restrict Android apps.
class _PreviewTiles extends StatelessWidget {
  const _PreviewTiles();

  static const _apps = [
    ('Video', Icons.ondemand_video),
    ('Browser', Icons.language),
    ('Games', Icons.sports_esports),
    ('Music', Icons.music_note),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final (label, icon) in _apps)
          SizedBox(
            width: 140,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: Key('preview-$label'),
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Preview only — apps open on the Android kiosk, not in the browser.',
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Icon(icon, size: 48, color: scheme.outline),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'PREVIEW — not launchable',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
