import 'token_store.dart';

/// Non-web platforms: nothing persistent (the browser kiosk only runs on web).
TokenStore createTokenStore() => MemoryTokenStore();
