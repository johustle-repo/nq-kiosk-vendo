import 'dart:async';

import '../model/kiosk_state.dart';
import '../model/rates.dart';
import 'kiosk_bridge.dart';

/// UI preview for platforms without the Android native layer (web, desktop).
///
/// Everything is in memory and demo-only: there is no coin controller, no
/// cloud, no app launching and NO kiosk enforcement. Production mode is
/// refused. The real kiosk must be installed as the Android APK.
class PreviewKioskBridge implements KioskBridge {
  PreviewKioskBridge() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  final _controller = StreamController<KioskState>.broadcast();
  late final Timer _ticker;
  final _clock = Stopwatch()..start();

  String _mode = 'unconfigured';
  String? _pin;
  bool _unlocked = false;
  int _demoEndMs = 0;
  bool _wasGranted = false;
  int? _expiredAtMs;
  List<String> _allowed = const [
    'preview.sample.video',
    'preview.sample.browser',
  ];

  static const _sampleApps = [
    InstalledApp(packageName: 'preview.sample.video', label: 'Video (sample)'),
    InstalledApp(
      packageName: 'preview.sample.browser',
      label: 'Browser (sample)',
    ),
    InstalledApp(packageName: 'preview.sample.game', label: 'Game (sample)'),
    InstalledApp(packageName: 'preview.sample.music', label: 'Music (sample)'),
  ];

  int get _now => _clock.elapsedMilliseconds;
  int get _remaining => (_demoEndMs - _now).clamp(0, 1 << 31);

  void _tick() {
    final granted = _mode == 'demo' && _remaining > 0;
    if (_wasGranted && !granted) _expiredAtMs = _now;
    if (!_wasGranted && granted) _expiredAtMs = null;
    _wasGranted = granted;
    _controller.add(_snapshot());
  }

  KioskState _snapshot() {
    final granted = _mode == 'demo' && _remaining > 0;
    return KioskState.fromMap({
      'preview': true,
      'mode': _mode,
      'deviceOwner': false,
      'lockTask': 'none',
      'access': {
        'granted': granted,
        'remainingMs': granted ? _remaining : 0,
        'source': granted ? 'simulated' : null,
        'reason': granted
            ? null
            : (_mode == 'unconfigured' ? 'unconfigured' : 'no_time'),
      },
      'expiredAgoMs': _expiredAtMs == null ? null : _now - _expiredAtMs!,
      'expiredReason': _expiredAtMs == null ? null : 'no_time',
      'controller': {
        'paired': false,
        'link': 'never',
        'secondsPerPulse': Rates.defaultSecondsPerPulse,
      },
      'cloud': {'enrolled': false, 'link': 'disabled'},
      'settings': {
        'allowedPackages': _allowed,
        'lossTimeoutS': 30,
        'lockAdb': false,
      },
      'admin': {'hasPin': _pin != null, 'unlocked': _unlocked, 'lockoutMs': 0},
      'demoRemainingMs': _remaining,
    });
  }

  void _emit() => _tick();

  Never _unsupported() => throw KioskException(
    'preview_only',
    'Not available in the browser/desktop preview. Install the Android APK.',
  );

  @override
  Stream<KioskState> get states => _controller.stream;

  @override
  Future<KioskState> getState() async => _snapshot();

  @override
  Future<List<InstalledApp>> listApps({
    required bool onlyAllowed,
    bool includeIcons = true,
  }) async => onlyAllowed
      ? _sampleApps.where((a) => _allowed.contains(a.packageName)).toList()
      : _sampleApps;

  @override
  Future<void> launchApp(String packageName) async => _unsupported();

  @override
  Future<String> createPin(String pin) async {
    if (pin.length < 6 || !RegExp(r'^\d+$').hasMatch(pin)) {
      throw KioskException(
        'invalid_argument',
        'PIN must be at least 6 digits.',
      );
    }
    _pin = pin;
    _unlocked = true;
    _emit();
    return 'PREV-IEWO-NLYX-XXXX';
  }

  @override
  Future<PinResult> verifyPin(String pin) async {
    final ok = pin == _pin;
    _unlocked = ok;
    _emit();
    return PinResult(ok: ok);
  }

  @override
  Future<PinResult> recoverWithCode(String code, String newPin) async =>
      const PinResult(ok: false);

  @override
  Future<String> changePin(String pin) => createPin(pin);

  @override
  Future<void> lockAdmin() async {
    _unlocked = false;
    _emit();
  }

  @override
  Future<void> setMode(KioskMode mode) async {
    if (mode == KioskMode.production) {
      throw KioskException(
        'not_device_owner',
        'Production kiosk mode requires the Android APK on a Device Owner phone.',
      );
    }
    _mode = mode.name;
    _emit();
  }

  @override
  Future<void> setAllowedPackages(List<String> packages) async {
    _allowed = List.of(packages);
    _emit();
  }

  @override
  Future<void> simulateCoin(int pulses) async {
    if (_mode != 'demo') throw KioskException('simulated_credit_rejected');
    final base = _demoEndMs > _now ? _demoEndMs : _now;
    _demoEndMs = base + Rates.secondsFor(pulses) * 1000;
    _emit();
  }

  @override
  Future<void> endSession() async {
    _demoEndMs = 0;
    _emit();
  }

  @override
  Future<Map<String, Object?>> diagnostics() async => const {
    'platform': 'preview (web/desktop)',
    'enforcement': 'none — install the Android APK',
  };

  @override
  Future<void> setLossTimeout(int seconds) async {}

  @override
  Future<void> setLockAdb(bool lock) async {}

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<String> pairController(String address, String code) async =>
      _unsupported();

  @override
  Future<void> setControllerAddress(String address) async => _unsupported();

  @override
  Future<void> unpairController() async => _unsupported();

  @override
  Future<String> enrollCloud(String code) async => _unsupported();

  @override
  Future<void> unenrollCloud() async => _unsupported();

  @override
  Future<List<String>> exitKiosk() async => _unsupported();

  @override
  Future<bool> removeDeviceOwner() async => _unsupported();

  @override
  Future<void> useAsHomeApp() async => _unsupported();

  @override
  Future<void> restoreNormalHome() async => _unsupported();

  @override
  Future<void> setScreenAwake(bool awake) async {}

  @override
  Future<void> setIdleSleep(int seconds) async => _unsupported();

  @override
  Future<void> openLockScreenSettings() async => _unsupported();

  void dispose() {
    _ticker.cancel();
    _controller.close();
  }
}
