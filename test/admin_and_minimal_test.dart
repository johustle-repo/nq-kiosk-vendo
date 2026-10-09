import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pump(
  WidgetTester tester,
  Size size,
  Map<Object?, Object?> state,
) async {
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

Future<void> tapTimer(
  WidgetTester tester,
  int times, {
  Duration gap = const Duration(milliseconds: 150),
}) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.byKey(const Key('admin-entry')));
    await tester.pump(gap);
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the dashboard opens admin without the PIN', (tester) async {
    final bridge = await pump(
      tester,
      const Size(1280, 800),
      snapshot(mode: 'production', deviceOwner: true),
    );
    expect(find.text('Overview'), findsNothing);
    bridge.push(
      snapshot(
        mode: 'production',
        deviceOwner: true,
        unlocked: true,
        adminOpenSeq: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Administrator PIN'), findsNothing);
    expect(find.text('Overview'), findsWidgets);
  });

  testWidgets('a dashboard request from before start-up does not open admin', (
    tester,
  ) async {
    await pump(
      tester,
      const Size(1280, 800),
      snapshot(
        mode: 'production',
        deviceOwner: true,
        unlocked: true,
        adminOpenSeq: 3,
      ),
    );
    expect(find.text('Overview'), findsNothing);
  });

  group('minimal customer screen', () {
    testWidgets('paid screen shows only the timer and the apps', (
      tester,
    ) async {
      await pump(
        tester,
        const Size(360, 800),
        snapshot(
          mode: 'production',
          deviceOwner: true,
          granted: true,
          remainingMs: 1200000,
          allowed: ['com.example.video', 'com.example.game'],
        ),
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
    testWidgets('10 quick taps on the timer open the PIN prompt', (
      tester,
    ) async {
      await pump(tester, const Size(360, 800), snapshot());
      await tapTimer(tester, 9);
      expect(
        find.text('Administrator PIN'),
        findsNothing,
        reason: '9 taps are not enough',
      );
      await tapTimer(tester, 1);
      expect(find.text('Administrator PIN'), findsOneWidget);
    });

    testWidgets('off on a tablet enrolled in the dashboard', (tester) async {
      await pump(tester, const Size(360, 800), snapshot(cloudEnrolled: true));
      await tapTimer(tester, 10);
      expect(find.text('Administrator PIN'), findsNothing);
    });

    testWidgets('on for an enrolled tablet when the dashboard enabled it', (
      tester,
    ) async {
      await pump(
        tester,
        const Size(360, 800),
        snapshot(cloudEnrolled: true, tapAdmin: true),
      );
      await tapTimer(tester, 10);
      expect(find.text('Administrator PIN'), findsOneWidget);
    });

    testWidgets('slow taps do not open it', (tester) async {
      await pump(tester, const Size(360, 800), snapshot());
      await tapTimer(tester, 10, gap: const Duration(milliseconds: 900));
      expect(find.text('Administrator PIN'), findsNothing);
    });

    testWidgets('works from the paid screen too', (tester) async {
      await pump(
        tester,
        const Size(360, 800),
        snapshot(
          granted: true,
          remainingMs: 600000,
          allowed: ['com.example.video'],
        ),
      );
      await tapTimer(tester, 10);
      expect(find.text('Administrator PIN'), findsOneWidget);
    });
  });

  group('administrator screen', () {
    Future<void> openAdmin(WidgetTester tester) async {
      await tapTimer(tester, 10);
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
      testWidgets('all sections render without overflow: ${entry.key}', (
        tester,
      ) async {
        await pump(tester, entry.value, snapshot(unlocked: true));
        await openAdmin(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Overview'), findsWidgets);
        final wide = entry.value.width >= 840;
        expect(
          find.byType(NavigationRail),
          wide ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationBar),
          wide ? findsNothing : findsOneWidget,
        );
        for (final (destination, heading) in [
          ('Apps', 'Customer apps'),
          ('Coin box', 'Live status'),
          ('Cloud', 'Connection'),
          ('System', 'Administrator PIN'),
          ('Overview', 'Status of this kiosk at a glance.'),
        ]) {
          await tester.tap(find.text(destination).last);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$destination on ${entry.key}',
          );
          expect(find.text(heading), findsWidgets, reason: '$destination page');
        }
      });
    }

    testWidgets('charger relay settings on the coin box page', (tester) async {
      final bridge = await pump(
        tester,
        const Size(1280, 800),
        snapshot(
          unlocked: true,
          batteryPct: 15,
          chargeRequested: true,
          chargeRelayOn: true,
        ),
      );
      await openAdmin(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Coin box'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('auto-charge')),
        300,
        scrollable: find
            .ancestor(
              of: find.text('Live status'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Charger relay (D6)'), findsOneWidget);
      expect(find.text('CHARGING'), findsOneWidget);
      expect(find.text('15% · charging'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('auto-charge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('auto-charge')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('autoCharge:false:20:90'));
    });

    testWidgets('ad blocking switch on the system page', (tester) async {
      final bridge = await pump(
        tester,
        const Size(1280, 800),
        snapshot(mode: 'production', deviceOwner: true, unlocked: true),
      );
      await openAdmin(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('System'),
        ),
      );
      await tester.pumpAndSettle();
      final ads = find.byKey(const Key('block-ads'));
      await tester.scrollUntilVisible(
        ads,
        300,
        scrollable: find
            .ancestor(
              of: find.text('Administrator PIN').first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(ads);
      await tester.pumpAndSettle();
      expect(find.text('Ad blocking'), findsOneWidget);
      await tester.tap(ads);
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('blockAds:false'));
    });

    testWidgets('lock button closes admin and locks it', (tester) async {
      final bridge = await pump(
        tester,
        const Size(360, 800),
        snapshot(unlocked: true),
      );
      await openAdmin(tester);
      await tester.tap(find.byKey(const Key('admin-lock')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('lockAdmin'));
      expect(find.text('Insert coin to start'), findsOneWidget);
    });

    testWidgets('saving selected apps', (tester) async {
      final bridge = await pump(
        tester,
        const Size(360, 800),
        snapshot(unlocked: true, allowed: []),
      );
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
