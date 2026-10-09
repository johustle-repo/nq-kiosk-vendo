import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pump(
  WidgetTester tester,
  Map<Object?, Object?> state,
) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bridge = FakeKioskBridge(state)
    ..apps = const [
      InstalledApp(packageName: 'com.example.video', label: 'Video'),
    ];
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  testWidgets(
    'idle payment screen shows the logo with the screen on; a touch returns; a coin starts',
    (tester) async {
      final bridge = await pump(
        tester,
        snapshot(allowed: ['com.example.video']),
      );
      expect(bridge.calls, contains('awake:true'));
      await tester.pump(const Duration(seconds: 59));
      expect(find.byKey(const Key('idle-logo')), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('idle-logo')), findsOneWidget);
      expect(
        find.image(const AssetImage('assets/images/vendo_logo.png')),
        findsOneWidget,
      );
      expect(bridge.calls, isNot(contains('awake:false')));

      // A touch returns to the payment screen, and the idle timer starts over.
      await tester.tap(find.byKey(const Key('idle-logo')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('idle-logo')), findsNothing);
      expect(find.text('Insert coin to start'), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('idle-logo')), findsOneWidget);

      // Coin inserted: the paid screen appears.
      bridge.push(
        snapshot(
          granted: true,
          remainingMs: 240000,
          allowed: ['com.example.video'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('idle-logo')), findsNothing);
      expect(find.text('Video'), findsOneWidget);
    },
  );

  testWidgets('Insert coin on the logo screen claims the shared coin box', (
    tester,
  ) async {
    final bridge = await pump(
      tester,
      snapshot(mode: 'production', deviceOwner: true, station: 2, selectedStation: 0),
    );
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('idle-logo')), findsOneWidget);
    await tester.tap(find.text('Insert coin to start'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('idle-logo')), findsNothing);
    expect(bridge.claims, 1);
  });

  testWidgets('touches before the timeout keep the screen awake', (
    tester,
  ) async {
    await pump(tester, snapshot());
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 40));
      await tester.tap(find.text('Insert coin to start'));
    }
    await tester.pump(const Duration(seconds: 40));
    expect(find.byKey(const Key('idle-logo')), findsNothing);
    await tester.pump(const Duration(seconds: 25));
    expect(find.byKey(const Key('idle-logo')), findsOneWidget);
  });

  testWidgets('admin entry still works after leaving the logo screen', (
    tester,
  ) async {
    await pump(tester, snapshot());
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('idle-logo')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const Key('admin-entry')));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    expect(find.text('Administrator PIN'), findsOneWidget);
  });

  testWidgets('no logo screen while the coin box is not paired', (
    tester,
  ) async {
    await pump(
      tester,
      snapshot(
        mode: 'production',
        deviceOwner: true,
        reason: 'controller_not_paired',
      ),
    );
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('idle-logo')), findsNothing);
    expect(find.text('Coin box not paired'), findsOneWidget);
  });

  testWidgets('the display switches off a while after the logo appears', (
    tester,
  ) async {
    final bridge = await pump(tester, snapshot(screenOffS: 30));
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('idle-logo')), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(bridge.calls, isNot(contains('sleepScreen')));
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.calls.where((c) => c == 'sleepScreen'), hasLength(1));

    // Woken by the power button: kept on, and off again later.
    bridge.calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(bridge.calls, contains('awake:true'));
    expect(find.byKey(const Key('idle-logo')), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    expect(bridge.calls, contains('sleepScreen'));
  });

  testWidgets('a touch on the logo cancels switching the display off', (
    tester,
  ) async {
    final bridge = await pump(tester, snapshot(screenOffS: 30));
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    await tester.tap(find.byKey(const Key('idle-logo')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(bridge.calls, isNot(contains('sleepScreen')));
  });

  testWidgets('screen off can be set to never', (tester) async {
    final bridge = await pump(tester, snapshot(screenOffS: 0));
    await tester.pump(const Duration(minutes: 10));
    expect(find.byKey(const Key('idle-logo')), findsOneWidget);
    expect(bridge.calls, isNot(contains('sleepScreen')));
  });

  testWidgets('admin can change when the display switches off', (tester) async {
    final bridge = await pump(tester, snapshot(unlocked: true));
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const Key('admin-entry')));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '482915');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('screen-off')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screen-off')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 minutes after the logo').last);
    await tester.pumpAndSettle();
    expect(bridge.calls, contains('screenOff:300'));
  });

  testWidgets('the logo screen can be turned off', (tester) async {
    await pump(tester, snapshot(idleSleepS: 0));
    await tester.pump(const Duration(minutes: 10));
    expect(find.byKey(const Key('idle-logo')), findsNothing);
  });

  testWidgets('admin can change the logo delay', (tester) async {
    final bridge = await pump(tester, snapshot(unlocked: true));
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byKey(const Key('admin-entry')));
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '482915');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('idle-sleep')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('idle-sleep')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After 2 minutes').last);
    await tester.pumpAndSettle();
    expect(bridge.calls, contains('idleSleep:120'));
  });
}
