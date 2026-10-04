import 'dart:js_interop';

import 'token_store.dart';

extension type _Storage._(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

@JS('localStorage')
external _Storage get _localStorage;

@JS('sessionStorage')
external _Storage get _sessionStorage;

TokenStore createTokenStore() => _BrowserTokenStore();

class _BrowserTokenStore implements TokenStore {
  static const _key = 'vendo_kiosk_web_token';

  // Storage can throw (private mode, blocked site data): fail soft.
  T? _safe<T>(T Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }

  @override
  String? read() =>
      _safe<String?>(() => _sessionStorage.getItem(_key)) ??
      _safe<String?>(() => _localStorage.getItem(_key));

  @override
  void write(String token, {required bool remember}) {
    clear();
    _safe(
      () => (remember ? _localStorage : _sessionStorage).setItem(_key, token),
    );
  }

  @override
  void clear() {
    _safe(() => _sessionStorage.removeItem(_key));
    _safe(() => _localStorage.removeItem(_key));
  }
}
