import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pump(WidgetTester tester, Size size, Map<Object?, Object?> state) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bridge = FakeKioskBridge(state)
    ..apps = const [
      InstalledApp(packageName: 'com.example.video', label: 'Video'),
      InstalledApp(packageName: 'com.example.game', label: 'Game'),
    ];
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

Future<void> tapTimer(WidgetTester tester, int times, {Duration gap = const Duration(milliseconds: 150)}) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byKey(const Key('admin-entry')));
    await tester.pump(gap);
  }
  await tester.pumpAndSettle();
}

void main() {
  group('minimal customer screen', () {
    testWidgets('paid screen shows only the timer and the apps', (tester) async {
      await pump(
        tester,
        const Size(360, 800),
        snapshot(mode: 'production', deviceOwner: true, granted: true, remainingMs: 1200000, allowed: ['com.example.video', 'com.example.game']),
      );
      expect(find.byKey(const Key('countdown')), findsOneWidget);
      expect(find.text('Video'), findsOneWidget);
      expect(find.text('Game'), findsOneWidget);
      expect(find.text('Vendo Kiosk'), findsNothing);
      expect(find.byKey(const Key('indicator-controller')), findsNothing);
      expect(find.byKey(const Key('indicator-cloud')), findsNothing);
      expect(find.byKey(const Key('sim-1')), findsNothing);
      expect(find.text('Your apps'), findsNothing);
    });
  });

  group('hidden admin entry', () {
    testWidgets('7 quick taps on the timer open the PIN prompt', (tester) async {
      await pump(tester, const Size(360, 800), snapshot());
      await tapTimer(tester, 6);
      expect(find.text('Administrator PIN'), findsNothing, reason: '6 taps are not enough');
      await tapTimer(tester, 1);
      expect(find.text('Administrator PIN'), findsOneWidget);
    });

    testWidgets('slow taps do not open it', (tester) async {
      await pump(tester, const Size(360, 800), snapshot());
      await tapTimer(tester, 7, gap: const Duration(milliseconds: 900));
      expect(find.text('Administrator PIN'), findsNothing);
    });

    testWidgets('works from the paid screen too', (tester) async {
      await pump(tester, const Size(360, 800), snapshot(granted: true, remainingMs: 600000, allowed: ['com.example.video']));
      await tapTimer(tester, 7);
      expect(find.text('Administrator PIN'), findsOneWidget);
    });
  });

  group('administrator screen', () {
    Future<void> openAdmin(WidgetTester tester) async {
      await tapTimer(tester, 7);
      await tester.enterText(find.byType(TextField), '482915');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
    }

    for (final entry in {
      'phone': const Size(360, 800),
      'phone landscape': const Size(800, 360),
      'tablet portrait': const Size(800, 1280),
      'tablet landscape': const Size(1280, 800),
    }.entries) {
      testWidgets('all sections render without overflow: ${entry.key}', (tester) async {
        await pump(tester, entry.value, snapshot(unlocked: true));
        await openAdmin(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Overview'), findsWidgets);
        final wide = entry.value.width >= 840;
        expect(find.byType(NavigationRail), wide ? findsOneWidget : findsNothing);
        expect(find.byType(NavigationBar), wide ? findsNothing : findsOneWidget);
        for (final (destination, heading) in [
          ('Apps', 'Customer apps'),
          ('Coin box', 'Live status'),
          ('Cloud', 'Connection'),
          ('System', 'Administrator PIN'),
          ('Overview', 'Status of this kiosk at a glance.'),
        ]) {
          await tester.tap(find.text(destination).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$destination on ${entry.key}');
          expect(find.text(heading), findsWidgets, reason: '$destination page');
        }
      });
    }

    testWidgets('lock button closes admin and locks it', (tester) async {
      final bridge = await pump(tester, const Size(360, 800), snapshot(unlocked: true));
      await openAdmin(tester);
      await tester.tap(find.byKey(const Key('admin-lock')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('lockAdmin'));
      expect(find.text('Insert coin to start'), findsOneWidget);
    });

    testWidgets('saving selected apps', (tester) async {
      final bridge = await pump(tester, const Size(360, 800), snapshot(unlocked: true, allowed: []));
      await openAdmin(tester);
      await tester.tap(find.text('Apps').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('select-com.example.video')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unsaved'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-apps')));
      await tester.pump();
      expect(bridge.calls, contains('setAllowed:com.example.video'));
    });
  });
}
