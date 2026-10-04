import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pump(WidgetTester tester, Map<Object?, Object?> state) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bridge = FakeKioskBridge(state)..apps = const [InstalledApp(packageName: 'com.example.video', label: 'Video')];
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  testWidgets('idle payment screen goes dark; touches do not wake it; a coin does', (tester) async {
    final bridge = await pump(tester, snapshot(allowed: ['com.example.video']));
    expect(bridge.calls, contains('awake:true'));
    await tester.pump(const Duration(seconds: 59));
    expect(find.byKey(const Key('sleep-overlay')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('sleep-overlay')), findsOneWidget);
    expect(bridge.calls.last, 'awake:false');

    // A single touch keeps it dark.
    await tester.tap(find.byKey(const Key('sleep-overlay')));
    await tester.pump();
    expect(find.byKey(const Key('sleep-overlay')), findsOneWidget);

    // Coin inserted: the paid screen appears and the screen is turned back on.
    bridge.calls.clear();
    bridge.push(snapshot(granted: true, remainingMs: 240000, allowed: ['com.example.video']));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sleep-overlay')), findsNothing);
    expect(find.text('Video'), findsOneWidget);
    expect(bridge.calls, contains('awake:true'));
  });

  testWidgets('touches before the timeout keep the screen awake', (tester) async {
    await pump(tester, snapshot());
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 40));
      await tester.tap(find.text('Insert coin to start'));
    }
    await tester.pump(const Duration(seconds: 40));
    expect(find.byKey(const Key('sleep-overlay')), findsNothing);
    await tester.pump(const Duration(seconds: 25));
    expect(find.byKey(const Key('sleep-overlay')), findsOneWidget);
  });

  testWidgets('7 taps on the dark screen open the admin PIN prompt', (tester) async {
    await pump(tester, snapshot());
    await tester.pump(const Duration(seconds: 61));
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.byKey(const Key('admin-entry')));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    expect(find.text('Administrator PIN'), findsOneWidget);
  });

  testWidgets('sleep can be turned off', (tester) async {
    await pump(tester, snapshot(idleSleepS: 0));
    await tester.pump(const Duration(minutes: 10));
    expect(find.byKey(const Key('sleep-overlay')), findsNothing);
  });

  testWidgets('admin can change the sleep delay', (tester) async {
    final bridge = await pump(tester, snapshot(unlocked: true));
    for (var i = 0; i < 7; i++) {
      await tester.tap(find.byKey(const Key('admin-entry')));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '482915');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('idle-sleep')), 200, scrollable: find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('idle-sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After 2 minutes').last);
    await tester.pumpAndSettle();
    expect(bridge.calls, contains('idleSleep:120'));
  });
}
