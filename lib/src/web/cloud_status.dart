import 'dart:math' as math;

/// One response of GET /api/kiosk-status.php.
class CloudStatus {
  const CloudStatus({
    required this.device,
    required this.available,
    required this.remainingSeconds,
    required this.bootId,
    required this.sequenceNumber,
    required this.lastPulses,
    required this.ageSeconds,
    required this.stale,
    required this.staleAfterSeconds,
    required this.serverTime,
  });

  final String device;
  final bool available;
  final int remainingSeconds;
  final String bootId;
  final int sequenceNumber;
  final int lastPulses;

  /// Seconds between the controller's upload and the server answering (server clock).
  final int ageSeconds;
  final bool stale;
  final int staleAfterSeconds;
  final int serverTime;

  /// When the controller uploaded this status, on the server's clock. Identical
  /// for repeated responses about the same upload.
  int get reportedAt => serverTime - ageSeconds;

  static int _int(Object? v, String field) {
    if (v is int) return v;
    if (v is num && v == v.roundToDouble()) return v.toInt();
    throw FormatException('Field "$field" is not an integer');
  }

  factory CloudStatus.fromJson(Map<String, Object?> j) {
    if (j['ok'] != true) throw const FormatException('Response is not ok');
    final available = j['status_available'] == true;
    final serverTime = _int(j['server_time'], 'server_time');
    final staleAfter = j['stale_after_seconds'] == null
        ? 60
        : _int(j['stale_after_seconds'], 'stale_after_seconds');
    if (!available) {
      return CloudStatus(
        device: (j['device'] as String?) ?? '',
        available: false,
        remainingSeconds: 0,
        bootId: '',
        sequenceNumber: 0,
        lastPulses: 0,
        ageSeconds: 0,
        stale: true,
        staleAfterSeconds: staleAfter,
        serverTime: serverTime,
      );
    }
    final boot = j['boot_id'];
    if (boot is! String) {
      throw const FormatException('Field "boot_id" is missing');
    }
    return CloudStatus(
      device: (j['device'] as String?) ?? '',
      available: true,
      remainingSeconds: math.max(
        0,
        _int(j['remaining_seconds'], 'remaining_seconds'),
      ),
      bootId: boot,
      sequenceNumber: _int(j['sequence_number'], 'sequence_number'),
      lastPulses: math.max(0, _int(j['last_pulses'], 'last_pulses')),
      ageSeconds: math.max(0, _int(j['age_seconds'], 'age_seconds')),
      stale: j['stale'] == true,
      staleAfterSeconds: staleAfter,
      serverTime: serverTime,
    );
  }
}

enum StatusUpdateKind {
  first,
  updated,
  repeated,
  creditAdded,
  bootChanged,
  olderIgnored,
  unavailable,
}

/// Turns polled cloud status into a smooth local countdown.
///
/// * Estimate = remaining_seconds − age_seconds at receipt, then minus the time
///   elapsed locally (monotonic clock) since that receipt.
/// * The browser never adds time. A repeated response about the same upload
///   (same boot, sequence and upload time) keeps the existing baseline, so
///   polling every 3 s cannot add credit again.
/// * A response about an OLDER upload than the current baseline is ignored.
/// * A new boot id (controller restart) replaces the baseline.
/// * A coin is detected when the reported time is clearly MORE than the current
///   estimate (by [creditThresholdMs]). The sequence number is not used for
///   this because some firmware increments it on every upload, not per coin.
class CloudStatusTracker {
  CloudStatusTracker({int Function()? clockMs, this.creditThresholdMs = 30000})
    : _clock = clockMs ?? _monotonicMs;

  /// Smallest increase treated as a coin (one pulse is 240 s; rounding and
  /// upload jitter are a few seconds).
  final int creditThresholdMs;

  static final Stopwatch _sw = Stopwatch()..start();
  static int _monotonicMs() => _sw.elapsedMilliseconds;

  final int Function() _clock;

  CloudStatus? _baseline;
  int _baselineRemainingMs = 0;
  int _baselineAtMs = 0;

  CloudStatus? _latest;
  int _latestAtMs = 0;

  int? lastCreditPulses;
  int creditEvents = 0;

  /// The status the countdown is based on.
  CloudStatus? get baseline => _baseline;

  /// The most recent response (may be a repeat of [baseline]); used for age/stale display.
  CloudStatus? get latest => _latest;

  StatusUpdateKind apply(CloudStatus s) {
    final now = _clock();
    final prev = _baseline;
    if (!s.available) {
      _latest = s;
      _latestAtMs = now;
      _baseline = null;
      _baselineRemainingMs = 0;
      _baselineAtMs = now;
      return StatusUpdateKind.unavailable;
    }
    if (prev != null && prev.bootId == s.bootId) {
      if (s.reportedAt < prev.reportedAt ||
          s.sequenceNumber < prev.sequenceNumber) {
        return StatusUpdateKind.olderIgnored;
      }
      if (s.reportedAt == prev.reportedAt &&
          s.sequenceNumber == prev.sequenceNumber &&
          s.remainingSeconds == prev.remainingSeconds) {
        _latest = s;
        _latestAtMs = now;
        return StatusUpdateKind.repeated;
      }
    }
    final newRemainingMs =
        math.max(0, s.remainingSeconds - s.ageSeconds) * 1000;
    final StatusUpdateKind kind;
    if (prev == null) {
      kind = StatusUpdateKind.first;
    } else if (prev.bootId != s.bootId) {
      kind = StatusUpdateKind.bootChanged;
    } else if (newRemainingMs - remainingMs() >= creditThresholdMs) {
      kind = StatusUpdateKind.creditAdded;
    } else {
      kind = StatusUpdateKind.updated;
    }
    if (kind == StatusUpdateKind.creditAdded) {
      lastCreditPulses = s.lastPulses;
      creditEvents++;
    }
    _baseline = s;
    _baselineRemainingMs = newRemainingMs;
    _baselineAtMs = now;
    _latest = s;
    _latestAtMs = now;
    return kind;
  }

  /// Estimated remaining time right now.
  int remainingMs() {
    if (_baseline == null) return 0;
    return math.max(0, _baselineRemainingMs - (_clock() - _baselineAtMs));
  }

  /// Age of the controller's last upload right now (server age + local elapsed).
  int? currentAgeSeconds() {
    final l = _latest;
    if (l == null || !l.available) return null;
    return l.ageSeconds + (_clock() - _latestAtMs) ~/ 1000;
  }

  /// Stale when the server said so, or when the age has since passed the threshold.
  bool get isStale {
    final l = _latest;
    if (l == null) return false;
    if (!l.available) return true;
    return l.stale || (currentAgeSeconds() ?? 0) > l.staleAfterSeconds;
  }
}
