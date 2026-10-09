import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/bridge/preview_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';
import 'package:vendo_kiosk/src/model/kiosk_state.dart';

import 'fake_bridge.dart';

/// A bridge whose native side is missing, like a web build of the Android app.
class _MissingNativeBridge extends FakeKioskBridge {
  _MissingNativeBridge() : super(snapshot());

  @override
  Future<KioskState> getState() async =>
      throw KioskException('MissingPluginException');
}

void main() {
  group('PreviewKioskBridge (web/desktop)', () {
    test('is demo-only and refuses production', () async {
      final b = PreviewKioskBridge();
      addTearDown(b.dispose);
      final s = await b.getState();
      expect(s.preview, isTrue);
      expect(s.deviceOwner, isFalse);
      await b.createPin('482915');
      expect(
        () => b.setMode(KioskMode.production),
        throwsA(isA<KioskException>()),
      );
      expect(
        () => b.simulateCoin(1),
        throwsA(isA<KioskException>()),
        reason: 'not in demo yet',
      );
      await b.setMode(KioskMode.demo);
      await b.simulateCoin(5);
      final after = await b.getState();
      expect(after.accessGranted, isTrue);
      expect(after.remainingMs, greaterThan(1190000));
      expect(
        () => b.launchApp('preview.sample.video'),
        throwsA(isA<KioskException>()),
      );
    });
  });

  testWidgets(
    'missing native layer shows an error instead of spinning forever',
    (tester) async {
      await tester.pumpWidget(
        VendoKioskApp(controller: KioskController(_MissingNativeBridge())),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('load-error')), findsOneWidget);
      expect(find.textContaining('Android APK'), findsOneWidget);
    },
  );

  testWidgets('preview banner is shown on the payment screen', (tester) async {
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final bridge = FakeKioskBridge({
      ...snapshot(mode: 'demo'),
      'preview': true,
    });
    await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
    await tester.pumpAndSettle();
    expect(find.textContaining('BROWSER PREVIEW'), findsOneWidget);
  });
}
