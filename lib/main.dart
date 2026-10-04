import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'src/bridge/kiosk_bridge.dart';
import 'src/bridge/preview_bridge.dart';
import 'src/kiosk_controller.dart';
import 'src/ui/kiosk_shell.dart';
import 'src/ui/responsive.dart';
import 'src/ui/theme.dart';
import 'src/web/status_client.dart';
import 'src/web/token_store.dart';
import 'src/web/web_kiosk_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Browser demo: reads the timer from /api/kiosk-status.php. No platform
    // channels, no Android kiosk enforcement.
    runApp(
      WebKioskApp(
        config: WebKioskConfig.fromEnvironment(),
        tokenStore: TokenStore.platform(),
        httpClient: http.Client(),
      ),
    );
    return;
  }
  // The kiosk logic (timing, enforcement, networking) is native Android code.
  // Desktop builds get a clearly labelled, in-memory preview.
  final KioskBridge bridge = defaultTargetPlatform == TargetPlatform.android
      ? MethodChannelKioskBridge()
      : PreviewKioskBridge();
  runApp(VendoKioskApp(controller: KioskController(bridge)));
}

class VendoKioskApp extends StatefulWidget {
  const VendoKioskApp({super.key, required this.controller});

  final KioskController controller;

  @override
  State<VendoKioskApp> createState() => _VendoKioskAppState();
}

class _VendoKioskAppState extends State<VendoKioskApp> {
  @override
  void initState() {
    super.initState();
    // Full screen kiosk: status bar (time, Wi-Fi, signal, battery) and the
    // navigation bar are hidden in every mode. A swipe from an edge shows them
    // briefly; they hide again by themselves. This is cosmetic: production
    // enforcement is done natively (lock task, status bar disabled).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vendo Kiosk',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      builder: (context, child) => clampTextScale(context, child),
      home: KioskShell(controller: widget.controller),
    );
  }
}
