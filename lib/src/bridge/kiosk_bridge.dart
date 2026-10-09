import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/kiosk_state.dart';

class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    this.icon,
  });

  final String packageName;
  final String label;
  final Uint8List? icon;

  factory InstalledApp.fromMap(Map<Object?, Object?> m) => InstalledApp(
    packageName: m['packageName'] as String,
    label: (m['label'] as String?) ?? (m['packageName'] as String),
    icon: m['icon'] as Uint8List?,
  );
}

class PinResult {
  const PinResult({
    required this.ok,
    this.lockoutMs = 0,
    this.failures = 0,
    this.recoveryCode,
  });

  final bool ok;
  final int lockoutMs;
  final int failures;
  final String? recoveryCode;
}

/// Error raised by the native side, with a machine-readable [code].
class KioskException implements Exception {
  KioskException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() =>
      message == null || message == code ? code : '$code: $message';
}

/// Everything the Flutter UI asks of the Android side. All enforcement,
/// timing and networking happens natively; this is a thin command interface.
abstract class KioskBridge {
  Stream<KioskState> get states;
  Future<KioskState> getState();
  Future<List<InstalledApp>> listApps({
    required bool onlyAllowed,
    bool includeIcons = true,
  });
  Future<void> launchApp(String packageName);

  Future<String> createPin(String pin);
  Future<PinResult> verifyPin(String pin);
  Future<PinResult> recoverWithCode(String code, String newPin);
  Future<String> changePin(String pin);
  Future<void> lockAdmin();

  Future<void> setMode(KioskMode mode);
  Future<void> setAllowedPackages(List<String> packages);
  Future<void> setLossTimeout(int seconds);
  Future<void> setLockAdb(bool lock);
  Future<String> pairController(String address, String code, int station);
  Future<void> setControllerAddress(String address);
  Future<void> unpairController();
  Future<void> endSession();

  /// A player tapped "Insert coin": the coin box sends its next coins to this
  /// tablet. Returns how long the claim lasts in seconds; throws
  /// `busy:<tablet>:<seconds>` while another tablet is inserting coins.
  Future<int> claimCoinBox();
  Future<String> enrollCloud(String code);
  Future<void> unenrollCloud();
  Future<void> simulateCoin(int pulses);
  Future<List<String>> exitKiosk();
  Future<bool> removeDeviceOwner();
  Future<Map<String, Object?>> diagnostics();
  Future<void> requestNotificationPermission();

  /// Asks Android to make this app the Home app (demo convenience).
  Future<void> useAsHomeApp();

  /// Gives the Home button back to the phone's normal launcher (demo only).
  Future<void> restoreNormalHome();

  /// Screen saver: false = minimum backlight, screen may turn off.
  Future<void> setScreenAwake(bool awake);

  Future<void> setIdleSleep(int seconds);

  /// Switches the display off now (idle kiosk). A coin or the power button wakes it.
  Future<void> sleepScreen();

  /// Seconds the idle logo stays up before the display is switched off (0 = never).
  Future<void> setScreenOff(int seconds);

  /// Ad-blocking Private DNS in production.
  Future<void> setBlockAds(bool enabled);

  /// Turn wireless debugging back on whenever Android switches it off.
  Future<void> setKeepWirelessAdb(bool enabled);

  /// Customers may sign in to accounts (Facebook/Google login in games and apps).
  Future<void> setAllowAccounts(bool allow);

  /// Charger relay on the coin box: on below [startPct], off at [stopPct].
  Future<void> setAutoCharge({
    required bool enabled,
    required int startPct,
    required int stopPct,
  });

  Future<void> openLockScreenSettings();
}

class MethodChannelKioskBridge implements KioskBridge {
  static const _methods = MethodChannel('vendo_kiosk/native');
  static const _events = EventChannel('vendo_kiosk/state');

  /// Platform channels exist only in the Android app. Every entry point is
  /// guarded so a web or desktop build fails with a clear error instead of a
  /// MissingPluginException.
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  late final Stream<KioskState> _states = !supported
      ? Stream<KioskState>.error(
          KioskException(
            'unsupported_platform',
            'Android kiosk functions are unavailable on this platform',
          ),
        )
      : _events
            .receiveBroadcastStream()
            .map((e) => KioskState.fromMap((e as Map).cast<Object?, Object?>()))
            .asBroadcastStream();

  @override
  Stream<KioskState> get states => _states;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!supported) {
      throw KioskException(
        'unsupported_platform',
        'Android kiosk functions are unavailable on this platform',
      );
    }
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw KioskException(e.code, e.message);
    }
  }

  @override
  Future<KioskState> getState() async =>
      KioskState.fromMap((await _call<Map<Object?, Object?>>('getState'))!);

  @override
  Future<List<InstalledApp>> listApps({
    required bool onlyAllowed,
    bool includeIcons = true,
  }) async {
    final list = await _call<List<Object?>>('listApps', {
      'onlyAllowed': onlyAllowed,
      'includeIcons': includeIcons,
    });
    return (list ?? const [])
        .map((e) => InstalledApp.fromMap((e as Map).cast<Object?, Object?>()))
        .toList();
  }

  @override
  Future<void> launchApp(String packageName) =>
      _call('launchApp', {'packageName': packageName});

  @override
  Future<String> createPin(String pin) async =>
      (await _call<String>('createPin', {'pin': pin}))!;

  PinResult _pin(Map<Object?, Object?>? m) => PinResult(
    ok: m?['ok'] == true,
    lockoutMs: (m?['lockoutMs'] as num?)?.toInt() ?? 0,
    failures: (m?['failures'] as num?)?.toInt() ?? 0,
    recoveryCode: m?['recoveryCode'] as String?,
  );

  @override
  Future<PinResult> verifyPin(String pin) async =>
      _pin(await _call<Map<Object?, Object?>>('verifyPin', {'pin': pin}));

  @override
  Future<PinResult> recoverWithCode(String code, String newPin) async => _pin(
    await _call<Map<Object?, Object?>>('recoverWithCode', {
      'code': code,
      'newPin': newPin,
    }),
  );

  @override
  Future<String> changePin(String pin) async =>
      (await _call<String>('changePin', {'pin': pin}))!;

  @override
  Future<void> lockAdmin() => _call('lockAdmin');

  @override
  Future<void> setMode(KioskMode mode) => _call('setMode', {'mode': mode.name});

  @override
  Future<void> setAllowedPackages(List<String> packages) =>
      _call('setAllowedPackages', {'packages': packages});

  @override
  Future<void> setLossTimeout(int seconds) =>
      _call('setLossTimeout', {'seconds': seconds});

  @override
  Future<void> setLockAdb(bool lock) => _call('setLockAdb', {'lock': lock});

  @override
  Future<String> pairController(
    String address,
    String code,
    int station,
  ) async => (await _call<String>('pairController', {
    'address': address,
    'code': code,
    'station': station,
  }))!;

  @override
  Future<void> setControllerAddress(String address) =>
      _call('setControllerAddress', {'address': address});

  @override
  Future<void> unpairController() => _call('unpairController');

  @override
  Future<int> claimCoinBox() async => (await _call<int>('claimCoinBox')) ?? 0;

  @override
  Future<void> endSession() => _call('endSession');

  @override
  Future<String> enrollCloud(String code) async =>
      (await _call<String>('enrollCloud', {'code': code}))!;

  @override
  Future<void> unenrollCloud() => _call('unenrollCloud');

  @override
  Future<void> simulateCoin(int pulses) =>
      _call('simulateCoin', {'pulses': pulses});

  @override
  Future<List<String>> exitKiosk() async =>
      ((await _call<List<Object?>>('exitKiosk')) ?? const []).cast<String>();

  @override
  Future<bool> removeDeviceOwner() async =>
      (await _call<bool>('removeDeviceOwner')) ?? false;

  @override
  Future<Map<String, Object?>> diagnostics() async =>
      ((await _call<Map<Object?, Object?>>('diagnostics')) ?? const {}).map(
        (k, v) => MapEntry(k.toString(), v),
      );

  @override
  Future<void> requestNotificationPermission() =>
      _call('requestNotificationPermission');

  @override
  Future<void> useAsHomeApp() => _call('useAsHomeApp');

  @override
  Future<void> restoreNormalHome() => _call('restoreNormalHome');

  @override
  Future<void> setScreenAwake(bool awake) =>
      _call('setScreenAwake', {'awake': awake});

  @override
  Future<void> setIdleSleep(int seconds) =>
      _call('setIdleSleep', {'seconds': seconds});

  @override
  Future<void> sleepScreen() => _call('sleepScreen');

  @override
  Future<void> setScreenOff(int seconds) =>
      _call('setScreenOff', {'seconds': seconds});

  @override
  Future<void> setBlockAds(bool enabled) =>
      _call('setBlockAds', {'enabled': enabled});

  @override
  Future<void> setKeepWirelessAdb(bool enabled) =>
      _call('setKeepWirelessAdb', {'enabled': enabled});

  @override
  Future<void> setAllowAccounts(bool allow) =>
      _call('setAllowAccounts', {'allow': allow});

  @override
  Future<void> setAutoCharge({
    required bool enabled,
    required int startPct,
    required int stopPct,
  }) => _call('setAutoCharge', {
    'enabled': enabled,
    'startPct': startPct,
    'stopPct': stopPct,
  });

  @override
  Future<void> openLockScreenSettings() => _call('openLockScreenSettings');
}
