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

/// The tablet's Wi-Fi connection, for the administrator Wi-Fi page.
class WifiStatus {
  const WifiStatus({
    this.enabled = false,
    this.connected = false,
    this.ssid,
    this.locationReady = false,
    this.ip,
    this.gateway,
    this.rssi,
    this.linkMbps,
    this.frequencyMhz,
    this.internet = false,
    this.defaultIsWifi = false,
    this.deviceOwner = false,
  });

  final bool enabled;
  final bool connected;

  /// Null when not connected, or when Android hides the name (location off).
  final String? ssid;
  final bool locationReady;
  final String? ip;
  final String? gateway;
  final int? rssi;
  final int? linkMbps;
  final int? frequencyMhz;
  final bool internet;

  /// False while Android sends traffic over mobile data (Wi-Fi has no internet).
  final bool defaultIsWifi;
  final bool deviceOwner;

  factory WifiStatus.fromMap(Map<Object?, Object?> m) => WifiStatus(
    enabled: m['enabled'] == true,
    connected: m['connected'] == true,
    ssid: m['ssid'] as String?,
    locationReady: m['locationReady'] == true,
    ip: m['ip'] as String?,
    gateway: m['gateway'] as String?,
    rssi: m['rssi'] as int?,
    linkMbps: m['linkMbps'] as int?,
    frequencyMhz: m['frequencyMhz'] as int?,
    internet: m['internet'] == true,
    defaultIsWifi: m['defaultIsWifi'] == true,
    deviceOwner: m['deviceOwner'] == true,
  );
}

/// A Wi-Fi network in range.
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    this.frequencyMhz = 0,
    this.security = 'wpa2',
    this.connected = false,
  });

  final String ssid;
  final int rssi;
  final int frequencyMhz;

  /// open, wpa2, wpa3, wep or enterprise.
  final String security;
  final bool connected;

  bool get secured => security != 'open';

  factory WifiNetwork.fromMap(Map<Object?, Object?> m) => WifiNetwork(
    ssid: m['ssid'] as String,
    rssi: (m['rssi'] as int?) ?? -100,
    frequencyMhz: (m['frequencyMhz'] as int?) ?? 0,
    security: (m['security'] as String?) ?? 'wpa2',
    connected: m['connected'] == true,
  );
}

/// A coin box that answered on the Wi-Fi (connection test or search).
class CoinBoxInfo {
  const CoinBoxInfo({
    required this.address,
    required this.deviceId,
    this.fwVersion = '',
    this.stations = 1,
    this.paired = const [],
    this.pairingOpen,
    this.mine = false,
  });

  final String address;
  final String deviceId;
  final String fwVersion;

  /// How many tablets the box serves (1 = this kiosk's own coin box).
  final int stations;
  final List<bool> paired;
  final bool? pairingOpen;

  /// The coin box this tablet is paired with.
  final bool mine;

  /// Address without the default port, for the address field.
  String get host => address.endsWith(':80')
      ? address.substring(0, address.length - 3)
      : address;

  factory CoinBoxInfo.fromMap(Map<Object?, Object?> m) => CoinBoxInfo(
    address: m['address'] as String,
    deviceId: m['deviceId'] as String,
    fwVersion: (m['fwVersion'] as String?) ?? '',
    stations: (m['stations'] as int?) ?? 1,
    paired: [for (final p in (m['paired'] as List?) ?? const []) p == true],
    pairingOpen: m['pairingOpen'] as bool?,
    mine: m['mine'] == true,
  );
}

/// Result of reaching the coin box from this tablet.
class CoinBoxTest {
  const CoinBoxTest({
    required this.ok,
    this.address,
    this.ms,
    this.error,
    this.ownIp,
    this.sameNetwork = false,
    this.viaWifi = false,
    this.box,
  });

  final bool ok;
  final String? address;
  final int? ms;
  final String? error;
  final String? ownIp;
  final bool sameNetwork;
  final bool viaWifi;
  final CoinBoxInfo? box;

  factory CoinBoxTest.fromMap(Map<Object?, Object?> m) => CoinBoxTest(
    ok: m['ok'] == true,
    address: m['address'] as String?,
    ms: m['ms'] as int?,
    error: m['error'] as String?,
    ownIp: m['ownIp'] as String?,
    sameNetwork: m['sameNetwork'] == true,
    viaWifi: m['viaWifi'] == true,
    box: m['ok'] == true ? CoinBoxInfo.fromMap(m) : null,
  );
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

  /// Coin chime and low-time beeps for the customer.
  Future<void> setSounds(bool enabled);

  /// Tablet-wide screen brightness (1-100 %) or automatic brightness.
  Future<void> setBrightness(int percent, {required bool auto});

  /// Google Play for the administrator (15 minutes or until admin is locked).
  Future<void> openAppStore();
  Future<void> closeAppStore();

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

  /// Wi-Fi page (administrator, Device Owner): the kiosk hides Settings.
  Future<WifiStatus> wifiStatus();
  Future<List<WifiNetwork>> wifiScan();
  Future<void> wifiConnect(String ssid, String password, String security);
  Future<void> wifiSetEnabled(bool enabled);

  /// Reaches the coin box at [address] (default: the paired one) over the Wi-Fi.
  Future<CoinBoxTest> testCoinBox([String? address]);

  /// Every coin box on this tablet's Wi-Fi (takes up to ~10 s).
  Future<List<CoinBoxInfo>> findCoinBoxes();
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
  Future<void> setSounds(bool enabled) =>
      _call('setSounds', {'enabled': enabled});

  @override
  Future<void> setBrightness(int percent, {required bool auto}) =>
      _call('setBrightness', {'percent': percent, 'auto': auto});

  @override
  Future<void> openAppStore() => _call('openAppStore');

  @override
  Future<void> closeAppStore() => _call('closeAppStore');

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

  @override
  Future<WifiStatus> wifiStatus() async => WifiStatus.fromMap(
    (await _call<Map<Object?, Object?>>('wifiStatus')) ?? const {},
  );

  @override
  Future<List<WifiNetwork>> wifiScan() async => [
    for (final m in (await _call<List<Object?>>('wifiScan')) ?? const [])
      WifiNetwork.fromMap((m as Map).cast<Object?, Object?>()),
  ];

  @override
  Future<void> wifiConnect(String ssid, String password, String security) =>
      _call('wifiConnect', {
        'ssid': ssid,
        'password': password,
        'security': security,
      });

  @override
  Future<void> wifiSetEnabled(bool enabled) =>
      _call('wifiSetEnabled', {'enabled': enabled});

  @override
  Future<CoinBoxTest> testCoinBox([String? address]) async =>
      CoinBoxTest.fromMap(
        (await _call<Map<Object?, Object?>>('testCoinBox', {
              'address': address,
            })) ??
            const {},
      );

  @override
  Future<List<CoinBoxInfo>> findCoinBoxes() async => [
    for (final m in (await _call<List<Object?>>('findCoinBoxes')) ?? const [])
      CoinBoxInfo.fromMap((m as Map).cast<Object?, Object?>()),
  ];
}
