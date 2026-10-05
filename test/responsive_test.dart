import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

/// Real device sizes (logical pixels) in both orientations.
const sizes = <String, Size>{
  'small phone portrait': Size(360, 640),
  'TECNO Spark 30C portrait': Size(360, 800),
  'large phone portrait': Size(412, 915),
  'phone landscape': Size(800, 360),
  'tablet portrait': Size(800, 1280),
  'tablet landscape': Size(1280, 800),
  'large tablet landscape': Size(1366, 1024),
};

Future<FakeKioskBridge> pump(WidgetTester tester, Size size, Map<Object?, Object?> state, {double textScale = 1.0}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final bridge = FakeKioskBridge(state);
  bridge.apps = [
    for (var i = 0; i < 9; i++) InstalledApp(packageName: 'com.example.app$i', label: 'Application number $i'),
  ];
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  for (final entry in sizes.entries) {
    for (final scale in [1.0, 2.0]) {
      final label = '${entry.key} @ text x$scale';

      testWidgets('payment screen fits: $label', (tester) async {
        await pump(tester, entry.value, snapshot(), textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.text('Insert coin to start'), findsOneWidget);
        expect(find.byKey(const Key('countdown')), findsOneWidget);
        expect(find.byKey(const Key('rate-20')), findsOneWidget);
      });

      testWidgets('launcher fits: $label', (tester) async {
        await pump(tester, entry.value, snapshot(granted: true, remainingMs: 200000, allowed: [
          for (var i = 0; i < 9; i++) 'com.example.app$i',
        ]), textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('countdown')), findsOneWidget);
        expect(find.byKey(const Key('low-time-banner')), findsOneWidget);
        if (entry.key == 'phone landscape' && scale > 1) {
          // Extreme case (360 px tall + forced large text): apps may start just below the edge.
          await tester.scrollUntilVisible(find.text('Application number 0'), 120, scrollable: find.byType(Scrollable).last);
        }
        expect(find.text('Application number 0'), findsOneWidget);
      });
    }
  }

  testWidgets('tablet landscape uses two columns on the payment screen', (tester) async {
    await pump(tester, const Size(1280, 800), snapshot());
    final timer = tester.getCenter(find.byKey(const Key('countdown')));
    final rates = tester.getCenter(find.byKey(const Key('rate-1')));
    expect(rates.dx, greaterThan(timer.dx + 200), reason: 'rates beside the timer');
  });

  testWidgets('phone portrait stacks the payment screen in one column', (tester) async {
    await pump(tester, const Size(360, 800), snapshot());
    final timer = tester.getCenter(find.byKey(const Key('countdown')));
    final rates = tester.getCenter(find.byKey(const Key('rate-1')));
    expect(rates.dy, greaterThan(timer.dy), reason: 'rates below the timer');
  });

  testWidgets('tablet launcher: timer on top, apps centred below it', (tester) async {
    await pump(tester, const Size(1280, 800), snapshot(granted: true, remainingMs: 1200000, allowed: ['com.example.app0']));
    final timer = tester.getCenter(find.byKey(const Key('countdown')));
    final app = tester.getCenter(find.text('Application number 0'));
    expect(timer.dx, closeTo(640, 2), reason: 'timer centred');
    expect(app.dy, greaterThan(timer.dy + 100), reason: 'apps below the timer');
    expect(app.dx, closeTo(640, 2), reason: 'a single app is centred');
  });

  testWidgets('phone grid fits 3 apps per row; tablet at least 4', (tester) async {
    final allowed = [for (var i = 0; i < 9; i++) 'com.example.app$i'];
    await pump(tester, const Size(360, 800), snapshot(granted: true, remainingMs: 1200000, allowed: allowed));
    final y0 = tester.getCenter(find.text('Application number 0')).dy;
    expect(tester.getCenter(find.text('Application number 2')).dy, y0, reason: '3 per row on a phone');
    await pump(tester, const Size(1280, 800), snapshot(granted: true, remainingMs: 1200000, allowed: allowed));
    final t0 = tester.getCenter(find.text('Application number 0')).dy;
    expect(tester.getCenter(find.text('Application number 3')).dy, t0, reason: '4+ per row on a tablet');
  });
}
