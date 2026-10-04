import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pumpApp(WidgetTester tester, Map<Object?, Object?> initial, {Size size = const Size(800, 1280)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bridge = FakeKioskBridge(initial);
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

/// The hidden admin entry: tap the timer 7 times within 4 seconds.
Future<void> openAdmin(WidgetTester tester) async {
  for (var i = 0; i < 7; i++) {
    await tester.tap(find.byKey(const Key('admin-entry')));
    await tester.pump(const Duration(milliseconds: 150));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('payment screen shows prompt, rates, timer and both indicators', (tester) async {
    await pumpApp(tester, snapshot());
    expect(find.text('Insert coin to start'), findsOneWidget);
    expect(find.text('00:00:00'), findsOneWidget);
    expect(find.byKey(const Key('rate-1')), findsOneWidget);
    String rate(int p) => tester.widget<Text>(find.byKey(Key('rate-$p'))).data!;
    expect(rate(1), '4 min');
    expect(rate(5), '20 min');
    expect(rate(10), '40 min');
    expect(rate(20), '1 h 20 min');
    expect(find.textContaining('Coin controller: connected'), findsOneWidget);
    expect(find.textContaining('Cloud: online'), findsOneWidget);
  });

  testWidgets('demo mode shows a warning and labelled simulated coin buttons', (tester) async {
    final bridge = await pumpApp(tester, snapshot(mode: 'demo'));
    expect(find.byKey(const Key('demo-banner')), findsOneWidget);
    expect(find.textContaining('NOT securely restricted'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('sim-5')));
    await tester.tap(find.byKey(const Key('sim-5')));
    await tester.pump();
    expect(bridge.calls, contains('simulate:5'));
    expect(find.text('SIMULATED COINS · demo only'), findsOneWidget);
    expect(find.text('+5 pulses'), findsOneWidget);
  });

  testWidgets('production mode has no simulated coin buttons', (tester) async {
    await pumpApp(tester, snapshot(mode: 'production', deviceOwner: true));
    expect(find.byKey(const Key('demo-banner')), findsNothing);
    expect(find.byKey(const Key('sim-1')), findsNothing);
    expect(find.text('Insert coin to start'), findsOneWidget);
  });

  testWidgets('production without Device Owner shows a blocking error, not demo', (tester) async {
    await pumpApp(tester, snapshot(mode: 'production', deviceOwner: false, reason: 'not_device_owner'));
    expect(find.byKey(const Key('blocked-banner')), findsOneWidget);
    expect(find.textContaining('requires this app to be the Device Owner'), findsWidgets);
    expect(find.byKey(const Key('sim-1')), findsNothing);
    expect(find.byKey(const Key('demo-banner')), findsNothing);
  });

  testWidgets('paid time shows the launcher with approved apps and countdown', (tester) async {
    final bridge = FakeKioskBridge(snapshot(granted: true, remainingMs: 1200000));
    bridge.apps = const [
      InstalledApp(packageName: 'com.example.video', label: 'Video'),
      InstalledApp(packageName: 'com.example.secret', label: 'Not approved'),
    ];
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
    await tester.pumpAndSettle();
    expect(find.text('00:20:00'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Not approved'), findsNothing);
    await tester.tap(find.byKey(const Key('app-com.example.video')));
    await tester.pump();
    expect(bridge.calls, contains('launch:com.example.video'));
  });

  testWidgets('expiry returns to the payment screen with an expired notice', (tester) async {
    final bridge = await pumpApp(tester, snapshot(granted: true, remainingMs: 5000));
    expect(find.byKey(const Key('countdown')), findsOneWidget);
    expect(find.text('Insert coin to start'), findsNothing);
    bridge.push(snapshot(granted: false, remainingMs: 0, expiredAgoMs: 100, expiredReason: 'no_time'));
    await tester.pumpAndSettle();
    expect(find.text('Insert coin to start'), findsOneWidget);
    expect(find.byKey(const Key('expired-banner')), findsOneWidget);
    expect(find.text('Time expired. Insert a coin to continue.'), findsOneWidget);
  });

  testWidgets('cloud outage with local link working is shown distinctly', (tester) async {
    await pumpApp(tester, snapshot(cloudLink: 'offline'));
    expect(find.textContaining('Coin controller: connected'), findsOneWidget);
    expect(find.textContaining('Cloud: offline'), findsOneWidget);
  });

  testWidgets('local controller loss shows disconnected and the paused message', (tester) async {
    await pumpApp(tester, snapshot(mode: 'production', deviceOwner: true, link: 'lost', lastOkAgoMs: 45000, reason: 'controller_lost'));
    expect(find.textContaining('Coin controller: disconnected (45 s)'), findsOneWidget);
    expect(find.textContaining('Access is paused until it reconnects'), findsOneWidget);
  });

  testWidgets('connecting state before the first report', (tester) async {
    await pumpApp(tester, snapshot(link: 'never', lastOkAgoMs: null));
    expect(find.textContaining('Coin controller: connecting'), findsOneWidget);
  });

  testWidgets('first run requires creating a PIN (no default PIN)', (tester) async {
    final bridge = await pumpApp(tester, snapshot(mode: 'unconfigured', hasPin: false));
    expect(find.text('Step 1 of 2 — create the administrator PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '123456');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tester.tap(find.byKey(const Key('create-pin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setup-error')), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '482915');
    await tester.enterText(find.byType(TextField).at(1), '482915');
    await tester.tap(find.byKey(const Key('create-pin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-code')), findsOneWidget);
    expect(bridge.calls.where((c) => c == 'createPin').length, 2);
  });

  testWidgets('choosing production without Device Owner shows provisioning help', (tester) async {
    final bridge = await pumpApp(tester, snapshot(mode: 'unconfigured', hasPin: true, unlocked: true));
    bridge.setModeError = KioskException('not_device_owner');
    await tester.tap(find.byKey(const Key('choose-production')));
    await tester.pumpAndSettle();
    expect(bridge.calls, contains('setMode:production'));
    expect(find.text('Device Owner provisioning'), findsOneWidget);
    expect(find.textContaining('ERASES ALL DATA'), findsOneWidget);
  });

  testWidgets('wrong admin PIN shows an error and lockout message', (tester) async {
    final bridge = await pumpApp(tester, snapshot());
    await openAdmin(tester);
    expect(find.text('Administrator PIN'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
    }
    expect(bridge.failures, 4);
    expect(find.textContaining('Too many attempts'), findsOneWidget);
  });

  testWidgets('launcher warns when time is low and works on a small phone', (tester) async {
    final bridge = FakeKioskBridge(snapshot(granted: true, remainingMs: 240000));
    bridge.apps = const [InstalledApp(packageName: 'com.example.video', label: 'Video')];
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('low-time-banner')), findsOneWidget);
    expect(find.textContaining('Less than 5 minutes'), findsOneWidget);
    bridge.push(snapshot(granted: true, remainingMs: 30000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Less than a minute'), findsOneWidget);
    bridge.push(snapshot(granted: true, remainingMs: 3600000));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('low-time-banner')), findsNothing);
  });

  testWidgets('admin can make the kiosk the Home app (demo) and restore it', (tester) async {
    final bridge = await pumpApp(tester, snapshot(unlocked: true));
    await openAdmin(tester);
    await tester.enterText(find.byType(TextField), '482915');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text("the phone's normal home screen"), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('use-as-home')));
    await tester.tap(find.byKey(const Key('use-as-home')));
    await tester.pump();
    expect(bridge.calls, contains('useAsHomeApp'));
    bridge.push(snapshot(unlocked: true, isDefaultHome: true));
    await tester.pumpAndSettle();
    expect(find.text('Vendo Kiosk'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('restore-home')));
    await tester.tap(find.byKey(const Key('restore-home')));
    await tester.pump();
    expect(bridge.calls, contains('restoreNormalHome'));
    // Production: the Home app is enforced by policy, so the section is hidden.
    bridge.push(snapshot(mode: 'production', deviceOwner: true, unlocked: true, isDefaultHome: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restore-home')), findsNothing);
  });

  testWidgets('layout works on a small phone', (tester) async {
    await pumpApp(tester, snapshot(), size: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.text('Insert coin to start'), findsOneWidget);
  });
}
