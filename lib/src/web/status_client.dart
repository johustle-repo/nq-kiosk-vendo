import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'cloud_status.dart';

/// Configuration from --dart-define (compile time).
class WebKioskConfig {
  const WebKioskConfig({
    this.apiBase = '',
    this.device = 'vendo-001',
    this.pollInterval = const Duration(seconds: 3),
    this.longPollSeconds = 20,
  });

  /// Empty = same origin as the web app (production). For local development
  /// pass e.g. --dart-define=VENDO_API_BASE=http://127.0.0.1:8000
  final String apiBase;
  final String device;
  final Duration pollInterval;

  /// How long the server may hold a request open waiting for a newer upload
  /// (0 = plain polling). The server caps this with its own setting.
  final int longPollSeconds;

  factory WebKioskConfig.fromEnvironment() => const WebKioskConfig(
    apiBase: String.fromEnvironment('VENDO_API_BASE'),
    device: String.fromEnvironment('VENDO_DEVICE', defaultValue: 'vendo-001'),
    longPollSeconds: int.fromEnvironment(
      'VENDO_LONG_POLL_SECONDS',
      defaultValue: 20,
    ),
  );

  /// Local PHP API used by DEBUG builds served from localhost when no
  /// VENDO_API_BASE was given (e.g. started with the IDE's Run button).
  /// Release builds always use the same origin.
  static const localDevApi = 'http://127.0.0.1:8000';

  Uri endpoint(Uri pageUri, {bool debugBuild = kDebugMode}) {
    final Uri base;
    if (apiBase.isNotEmpty) {
      base = Uri.parse(apiBase);
    } else if (kDebugMode &&
        debugBuild &&
        (pageUri.host == 'localhost' || pageUri.host == '127.0.0.1')) {
      base = Uri.parse(localDevApi);
    } else {
      base = pageUri;
    }
    return base.resolve('/api/kiosk-status.php');
  }
}

class StatusError implements Exception {
  const StatusError(this.code, [this.detail]);

  /// unauthorized, forbidden, rate_limited, server, network, timeout, bad_response or `http_NNN`.
  final String code;
  final String? detail;

  /// Errors that polling cannot fix by retrying.
  bool get isFatal => code == 'unauthorized' || code == 'forbidden';

  @override
  String toString() => detail == null ? code : '$code: $detail';
}

/// Fetches status with the web/kiosk token (never the ESP8266 upload token).
class KioskStatusClient {
  KioskStatusClient({
    required this.httpClient,
    required this.endpoint,
    required this.token,
    required this.device,
    this.timeout = const Duration(seconds: 8),
    this.longPollSeconds = 0,
  });

  final http.Client httpClient;
  final Uri endpoint;
  final String token;
  final String device;
  final Duration timeout;
  final int longPollSeconds;

  static bool looksLikeToken(String t) =>
      RegExp(r'^vkw_[0-9a-f]{16}_[A-Za-z0-9_-]{43}$').hasMatch(t.trim());

  /// Cleans up common copy/paste damage. Tokens never contain whitespace,
  /// quotes or a "Bearer " prefix, so removing them is always safe.
  static String normalizeToken(String input) {
    var t = input.replaceAll(RegExp(r'\s+'), '');
    t = t.replaceAll(RegExp('["\'`]'), '');
    if (t.toLowerCase().startsWith('bearer')) t = t.substring(6);
    if (t.toLowerCase().startsWith('authorization:bearer')) t = t.substring(20);
    return t;
  }

  /// Why [token] (already normalized) is not a valid web token, or null if it is.
  static String? tokenProblem(String token) {
    if (token.isEmpty) return 'Paste the access token.';
    if (looksLikeToken(token)) return null;
    if (!token.startsWith('vkw_')) {
      return 'This is not a browser kiosk token: it must start with "vkw_" '
          '(the coin controller\'s upload key or a device token "vkd_…" will not work).';
    }
    if (token.length != 64) {
      return 'The token should be 64 characters but this is ${token.length}. '
          'Part of it is missing or extra — copy the whole line again.';
    }
    return 'The token contains characters that are not allowed. Copy it again from the token tool output.';
  }

  /// Fetches the status. When [since] is given and long-polling is enabled, the
  /// server answers as soon as a newer upload than [since] exists (or after
  /// [longPollSeconds]).
  Future<CloudStatus> fetch([CloudStatus? since]) async {
    final params = {'device': device};
    final waiting = since != null && since.available && longPollSeconds > 0;
    if (waiting) {
      params.addAll({
        'wait': '$longPollSeconds',
        'since_boot': since.bootId,
        'since_seq': '${since.sequenceNumber}',
        'since_reported': '${since.reportedAt}',
      });
    }
    final uri = endpoint.replace(queryParameters: params);
    final http.Response res;
    try {
      res = await httpClient
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(
            waiting ? timeout + Duration(seconds: longPollSeconds) : timeout,
          );
    } on TimeoutException {
      throw const StatusError('timeout');
    } catch (e) {
      // In browsers, CORS refusals and offline networks both surface here.
      throw StatusError('network', e.toString());
    }
    switch (res.statusCode) {
      case 200:
        // A web page instead of JSON: the request reached a static/SPA server
        // (e.g. `flutter run` without VENDO_API_BASE, or a rewrite to index.html).
        final type = res.headers['content-type'] ?? '';
        if (type.contains('text/html') || res.body.trimLeft().startsWith('<')) {
          throw StatusError('not_api', endpoint.toString());
        }
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is! Map<String, Object?>) {
            throw const FormatException('not an object');
          }
          return CloudStatus.fromJson(decoded);
        } on FormatException catch (e) {
          throw StatusError('bad_response', e.message);
        }
      case 401:
        throw const StatusError('unauthorized');
      case 403:
        throw const StatusError('forbidden');
      case 429:
        throw const StatusError('rate_limited');
      default:
        throw StatusError(
          res.statusCode >= 500 ? 'server' : 'http_${res.statusCode}',
        );
    }
  }
}
