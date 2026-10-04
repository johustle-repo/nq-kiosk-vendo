import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'cloud_status.dart';
import 'status_client.dart';

/// Fetches status with at most ONE request in flight; the next request is
/// scheduled only after the previous one finished, so requests never overlap.
///
/// With long-polling the server holds each request until a newer upload exists,
/// so a coin shows up as soon as it reaches the database. Scheduling:
///  * new data (coin, new upload, restart) → ask again right away (≥ [minGap]);
///  * unchanged answer → keep at least [interval] between request starts
///    (a long-poll answer already waited, so it continues immediately);
///  * failure → wait [interval] before retrying.
class StatusPoller extends ChangeNotifier {
  StatusPoller({
    required this.fetch,
    required this.tracker,
    this.interval = const Duration(seconds: 3),
    this.minGap = const Duration(milliseconds: 250),
    int Function()? clockMs,
  }) : _clock = clockMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Receives what the browser already has, for long-polling.
  final Future<CloudStatus> Function(CloudStatus? since) fetch;
  final CloudStatusTracker tracker;
  final Duration interval;
  final Duration minGap;
  final int Function() _clock;

  bool _running = false;
  bool _inFlight = false;
  bool _disposed = false;
  Timer? _next;

  int consecutiveFailures = 0;
  StatusError? lastError;
  StatusUpdateKind? lastUpdate;
  bool everSucceeded = false;
  int requestCount = 0;

  bool get running => _running;
  bool get inFlight => _inFlight;

  void start() {
    if (_running) return;
    _running = true;
    _poll();
  }

  void stop() {
    _running = false;
    _next?.cancel();
    _next = null;
  }

  Future<void> _poll() async {
    if (!_running || _inFlight) return; // never overlap
    _inFlight = true;
    requestCount++;
    final started = _clock();
    var delayMs = interval.inMilliseconds;
    try {
      final s = await fetch(tracker.latest);
      final kind = tracker.apply(s);
      lastUpdate = kind;
      consecutiveFailures = 0;
      lastError = null;
      everSucceeded = true;
      final elapsed = _clock() - started;
      final changed =
          kind != StatusUpdateKind.repeated &&
          kind != StatusUpdateKind.unavailable &&
          kind != StatusUpdateKind.olderIgnored;
      delayMs = changed ? 0 : math.max(0, interval.inMilliseconds - elapsed);
    } on StatusError catch (e) {
      consecutiveFailures++;
      lastError = e;
      if (e.isFatal) {
        _running = false; // a new token is needed; retrying cannot help
      }
    } catch (e) {
      consecutiveFailures++;
      lastError = StatusError('bad_response', e.toString());
    } finally {
      _inFlight = false;
    }
    // A held long-poll can finish after the screen was closed: drop the result.
    if (_disposed) return;
    if (_running) {
      _next = Timer(
        Duration(milliseconds: math.max(minGap.inMilliseconds, delayMs)),
        _poll,
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
