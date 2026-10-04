import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bridge/kiosk_bridge.dart';
import 'model/kiosk_state.dart';

/// Holds the latest native state for the widget tree.
class KioskController extends ChangeNotifier {
  KioskController(this.bridge) {
    _sub = bridge.states.listen(
      _onState,
      onError: (Object e) => debugPrint('state stream error: $e'),
    );
    bridge.getState().then(
      _onState,
      onError: (Object e) {
        debugPrint('getState failed: $e');
        _loadError = e;
        notifyListeners();
      },
    );
  }

  final KioskBridge bridge;
  StreamSubscription<KioskState>? _sub;
  KioskState _state = const KioskState();

  KioskState get state => _state;

  /// Set when the native layer did not answer (e.g. missing platform implementation).
  Object? get loadError => _loadError;
  Object? _loadError;

  void _onState(KioskState s) {
    _state = s;
    _loadError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
