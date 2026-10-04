import 'dart:async';

import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/model/kiosk_state.dart';

/// In-memory stand-in for the Android side, for widget tests.
class FakeKioskBridge implements KioskBridge {
  FakeKioskBridge(Map<Object?, Object?> initial) : _state = KioskState.fromMap(initial);

  final _controller = StreamController<KioskState>.broadcast();
  KioskState _state;
  final calls = <String>[];
  List<InstalledApp> apps = const [];
  Object? simulateError;
  Object? setModeError;

  void push(Map<Object?, Object?> m) {
    _state = KioskState.fromMap(m);
    _controller.add(_state);
  }

  @override
  Stream<KioskState> get states => _controller.stream;

  @override
  Future<KioskState> getState() async => _state;

  @override
  Future<List<InstalledApp>> listApps({required bool onlyAllowed, bool includeIcons = true}) async {
    calls.add('listApps:$onlyAllowed');
    return onlyAllowed ? apps.where((a) => _state.allowedPackages.contains(a.packageName)).toList() : apps;
  }

  @override
  Future<void> launchApp(String packageName) async => calls.add('launch:$packageName');

  @override
  Future<String> createPin(String pin) async {
    calls.add('createPin');
    if (pin == '123456') throw KioskException('invalid_argument', 'PIN cannot be a simple sequence.');
    return 'ABCD-EFGH-JKMN-PQRS';
  }

  int failures = 0;

  @override
  Future<PinResult> verifyPin(String pin) async {
    calls.add('verifyPin');
    if (pin == '482915') return const PinResult(ok: true);
    failures++;
    return PinResult(ok: false, failures: failures, lockoutMs: failures >= 4 ? 30000 : 0);
  }

  @override
  Future<PinResult> recoverWithCode(String code, String newPin) async => const PinResult(ok: false);

  @override
  Future<String> changePin(String pin) async => 'NEWC-ODEX-XXXX-YYYY';

  @override
  Future<void> lockAdmin() async => calls.add('lockAdmin');

  @override
  Future<void> setMode(KioskMode mode) async {
    calls.add('setMode:${mode.name}');
    if (setModeError != null) throw setModeError!;
  }

  @override
  Future<void> setAllowedPackages(List<String> packages) async => calls.add('setAllowed:${packages.join(',')}');

  @override
  Future<void> setLossTimeout(int seconds) async => calls.add('loss:$seconds');

  @override
  Future<void> setLockAdb(bool lock) async {}

  @override
  Future<String> pairController(String address, String code) async => 'vk-test';

  @override
  Future<void> setControllerAddress(String address) async {}

  @override
  Future<void> unpairController() async {}

  @override
  Future<void> endSession() async {}

  @override
  Future<String> enrollCloud(String code) async => 'abc';

  @override
  Future<void> unenrollCloud() async {}

  @override
  Future<void> simulateCoin(int pulses) async {
    calls.add('simulate:$pulses');
    if (simulateError != null) throw simulateError!;
  }

  @override
  Future<List<String>> exitKiosk() async => const [];

  @override
  Future<bool> removeDeviceOwner() async => true;

  @override
  Future<Map<String, Object?>> diagnostics() async => const {'sdkInt': 34};

  @override
  Future<void> requestNotificationPermission() async {}

  @override
  Future<void> useAsHomeApp() async => calls.add('useAsHomeApp');

  @override
  Future<void> restoreNormalHome() async => calls.add('restoreNormalHome');

  @override
  Future<void> setScreenAwake(bool awake) async => calls.add('awake:$awake');

  @override
  Future<void> setIdleSleep(int seconds) async => calls.add('idleSleep:$seconds');

  @override
  Future<void> openLockScreenSettings() async => calls.add('openLockScreenSettings');
}

/// Builds a native-style snapshot map with sensible defaults.
Map<Object?, Object?> snapshot({
  String mode = 'demo',
  bool deviceOwner = false,
  bool granted = false,
  int remainingMs = 0,
  String? reason = 'no_time',
  bool paired = true,
  String link = 'connected',
  int? lastOkAgoMs = 500,
  String cloudLink = 'ok',
  bool cloudEnrolled = true,
  int? expiredAgoMs,
  String? expiredReason,
  List<String> allowed = const ['com.example.video'],
  bool hasPin = true,
  bool unlocked = false,
  int secondsPerPulse = 240,
  int? seq,
  int? lastCreditAgoMs,
  int? lastAddedS,
  bool isDefaultHome = false,
  int idleSleepS = 60,
}) =>
    {
      'mode': mode,
      'deviceOwner': deviceOwner,
      'lockTask': deviceOwner && mode == 'production' ? 'locked' : 'none',
      'policyProblems': <Object?>[],
      'access': {'granted': granted, 'remainingMs': remainingMs, 'source': granted ? 'controller' : null, 'reason': granted ? null : reason},
      'expiredAgoMs': expiredAgoMs,
      'expiredReason': expiredReason,
      'controller': {
        'paired': paired,
        'address': '192.168.1.50:80',
        'deviceId': 'vk-abc',
        'link': link,
        'lastOkAgoMs': lastOkAgoMs,
        'secondsPerPulse': secondsPerPulse,
        'seq': seq,
        'lastCreditAgoMs': lastCreditAgoMs,
        'lastAddedS': lastAddedS,
      },
      'cloud': {'enrolled': cloudEnrolled, 'link': cloudLink, 'configVersion': 1},
      'settings': {'allowedPackages': allowed, 'lossTimeoutS': 30, 'lockAdb': false, 'isDefaultHome': isDefaultHome, 'idleSleepS': idleSleepS},
      'admin': {'hasPin': hasPin, 'unlocked': unlocked, 'lockoutMs': 0},
      'demoRemainingMs': 0,
    };
