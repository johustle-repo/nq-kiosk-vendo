import 'rates.dart';

enum KioskMode { unconfigured, demo, production }

enum ControllerLink { never, connected, degraded, lost }

enum CloudLink { disabled, ok, offline, unauthorized, error }

/// Immutable snapshot of the native kiosk engine (see KioskEngine.snapshot()).
class KioskState {
  const KioskState({
    this.mode = KioskMode.unconfigured,
    this.deviceOwner = false,
    this.lockTask = 'none',
    this.policyProblems = const [],
    this.accessGranted = false,
    this.remainingMs = 0,
    this.accessSource,
    this.denyReason,
    this.expiredAgoMs,
    this.expiredReason,
    this.controllerPaired = false,
    this.controllerAddress,
    this.controllerDeviceId,
    this.controllerStation = 1,
    this.selectedStation = 0,
    this.selectedTtlS = 0,
    this.heldPulses = 0,
    this.controllerLink = ControllerLink.never,
    this.controllerLastOkAgoMs,
    this.controllerLastError,
    this.controllerBootId,
    this.controllerSeq,
    this.secondsPerPulse = Rates.defaultSecondsPerPulse,
    this.lastAddedS,
    this.lastPulses,
    this.lastCreditAgoMs,
    this.controllerResumed = false,
    this.cloudEnrolled = false,
    this.cloudLink = CloudLink.disabled,
    this.cloudLastOkAgoMs,
    this.cloudLastError,
    this.cloudConfigVersion = 0,
    this.allowedPackages = const [],
    this.lossTimeoutS = 30,
    this.lockAdb = false,
    this.isDefaultHome = false,
    this.idleSleepS = 60,
    this.screenLockSecure = false,
    this.hasPin = false,
    this.adminUnlocked = false,
    this.pinLockoutMs = 0,
    this.demoRemainingMs = 0,
    this.loaded = false,
    this.preview = false,
  });

  final KioskMode mode;
  final bool deviceOwner;
  final String lockTask;
  final List<String> policyProblems;
  final bool accessGranted;
  final int remainingMs;
  final String? accessSource;
  final String? denyReason;
  final int? expiredAgoMs;
  final String? expiredReason;
  final bool controllerPaired;
  final String? controllerAddress;
  final String? controllerDeviceId;

  /// This tablet's number on the shared coin box (1-4).
  final int controllerStation;

  /// Tablet the coin box sends the next coins to (0 = none: coins are held).
  final int selectedStation;
  final int selectedTtlS;

  /// Coins inserted with no tablet selected, waiting for the attendant.
  final int heldPulses;

  /// The attendant selected this tablet: coins inserted now go here.
  bool get coinBoxReadyForMe => selectedStation != 0 && selectedStation == controllerStation;
  final ControllerLink controllerLink;
  final int? controllerLastOkAgoMs;
  final String? controllerLastError;
  final String? controllerBootId;
  final int? controllerSeq;
  final int secondsPerPulse;
  final int? lastAddedS;
  final int? lastPulses;
  final int? lastCreditAgoMs;
  final bool controllerResumed;
  final bool cloudEnrolled;
  final CloudLink cloudLink;
  final int? cloudLastOkAgoMs;
  final String? cloudLastError;
  final int cloudConfigVersion;
  final List<String> allowedPackages;
  final int lossTimeoutS;
  final bool lockAdb;

  /// Pressing Home currently opens this app.
  final bool isDefaultHome;

  /// Seconds without paid time and touches before the screen sleeps (0 = never).
  final int idleSleepS;

  /// The phone has a PIN/pattern/password lock screen.
  final bool screenLockSecure;
  final bool hasPin;
  final bool adminUnlocked;
  final int pinLockoutMs;
  final int demoRemainingMs;

  /// False until the first snapshot from the native side has arrived.
  final bool loaded;

  /// True on web/desktop: UI preview only, nothing is enforced.
  final bool preview;

  bool get isDemo => mode == KioskMode.demo;
  bool get isProduction => mode == KioskMode.production;

  /// Production configured on a phone that is not Device Owner: a hard error,
  /// never a silent fallback to demo behaviour.
  bool get productionBlocked => isProduction && !deviceOwner;

  bool get recentlyExpired =>
      !accessGranted && expiredAgoMs != null && expiredAgoMs! < 120000;

  static KioskMode _mode(Object? v) => switch (v) {
    'demo' => KioskMode.demo,
    'production' => KioskMode.production,
    _ => KioskMode.unconfigured,
  };

  static ControllerLink _link(Object? v) => switch (v) {
    'connected' => ControllerLink.connected,
    'degraded' => ControllerLink.degraded,
    'lost' => ControllerLink.lost,
    _ => ControllerLink.never,
  };

  static CloudLink _cloud(Object? v) => switch (v) {
    'ok' => CloudLink.ok,
    'offline' => CloudLink.offline,
    'unauthorized' => CloudLink.unauthorized,
    'error' => CloudLink.error,
    _ => CloudLink.disabled,
  };

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  factory KioskState.fromMap(Map<Object?, Object?> m) {
    Map<Object?, Object?> sub(String k) =>
        (m[k] as Map<Object?, Object?>?) ?? const {};
    final access = sub('access');
    final ctl = sub('controller');
    final cloud = sub('cloud');
    final settings = sub('settings');
    final admin = sub('admin');
    return KioskState(
      loaded: true,
      preview: m['preview'] == true,
      mode: _mode(m['mode']),
      deviceOwner: m['deviceOwner'] == true,
      lockTask: (m['lockTask'] as String?) ?? 'none',
      policyProblems: ((m['policyProblems'] as List?) ?? const [])
          .cast<String>(),
      accessGranted: access['granted'] == true,
      remainingMs: _int(access['remainingMs']) ?? 0,
      accessSource: access['source'] as String?,
      denyReason: access['reason'] as String?,
      expiredAgoMs: _int(m['expiredAgoMs']),
      expiredReason: m['expiredReason'] as String?,
      controllerPaired: ctl['paired'] == true,
      controllerAddress: ctl['address'] as String?,
      controllerDeviceId: ctl['deviceId'] as String?,
      controllerStation: _int(ctl['station']) ?? 1,
      selectedStation: _int(ctl['selectedStation']) ?? 0,
      selectedTtlS: _int(ctl['selectedTtlS']) ?? 0,
      heldPulses: _int(ctl['heldPulses']) ?? 0,
      controllerLink: _link(ctl['link']),
      controllerLastOkAgoMs: _int(ctl['lastOkAgoMs']),
      controllerLastError: ctl['lastError'] as String?,
      controllerBootId: ctl['bootId'] as String?,
      controllerSeq: _int(ctl['seq']),
      secondsPerPulse:
          _int(ctl['secondsPerPulse']) ?? Rates.defaultSecondsPerPulse,
      lastAddedS: _int(ctl['lastAddedS']),
      lastPulses: _int(ctl['lastPulses']),
      lastCreditAgoMs: _int(ctl['lastCreditAgoMs']),
      controllerResumed: ctl['resumed'] == true,
      cloudEnrolled: cloud['enrolled'] == true,
      cloudLink: _cloud(cloud['link']),
      cloudLastOkAgoMs: _int(cloud['lastOkAgoMs']),
      cloudLastError: cloud['lastError'] as String?,
      cloudConfigVersion: _int(cloud['configVersion']) ?? 0,
      allowedPackages: ((settings['allowedPackages'] as List?) ?? const [])
          .cast<String>(),
      lossTimeoutS: _int(settings['lossTimeoutS']) ?? 30,
      lockAdb: settings['lockAdb'] == true,
      isDefaultHome: settings['isDefaultHome'] == true,
      idleSleepS: _int(settings['idleSleepS']) ?? 60,
      screenLockSecure: settings['screenLockSecure'] == true,
      hasPin: admin['hasPin'] == true,
      adminUnlocked: admin['unlocked'] == true,
      pinLockoutMs: _int(admin['lockoutMs']) ?? 0,
      demoRemainingMs: _int(m['demoRemainingMs']) ?? 0,
    );
  }
}

/// Human-readable explanation for why customer access is denied.
String denyReasonText(String? reason) => switch (reason) {
  'not_device_owner' =>
    'Production mode requires this app to be the Device Owner. Kiosk access is blocked until provisioning is verified.',
  'controller_not_paired' =>
    'The coin controller is not paired. Ask the administrator.',
  'controller_lost' =>
    'Coin controller disconnected. Access is paused until it reconnects.',
  'unconfigured' => 'Kiosk is not set up yet.',
  _ => 'Insert coin to start',
};
