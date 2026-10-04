import 'token_store_stub.dart'
    if (dart.library.js_interop) 'token_store_web.dart'
    as impl;

/// Where the browser keeps the web/kiosk token.
///
/// Default: sessionStorage (cleared when the tab closes). "Remember on this
/// browser" uses localStorage. The token is read-only and revocable, but anyone
/// with access to this browser profile can read it — use only on a trusted device.
abstract class TokenStore {
  String? read();
  void write(String token, {required bool remember});
  void clear();

  factory TokenStore.platform() => impl.createTokenStore();
}

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this._token]);

  String? _token;
  bool remembered = false;

  @override
  String? read() => _token;

  @override
  void write(String token, {required bool remember}) {
    _token = token;
    remembered = remember;
  }

  @override
  void clear() => _token = null;
}
