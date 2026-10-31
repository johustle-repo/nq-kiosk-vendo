import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';
import 'package:vendo_kiosk/src/ui/admin/admin_ui.dart';

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

/// Scrolls the admin page until [target] is built and visible.
Future<void> scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    // The page's own scroll view (text fields have one of their own).
    scrollable: find
        .ancestor(of: find.byType(AdminSection).first, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
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
      final bridge = await pump(
        tester,
        const Size(360, 800),
        snapshot(cloudEnrolled: true),
      );
      bridge.wifi = const WifiStatus(enabled: true, connected: true);
      await tapTimer(tester, 10);
      expect(find.text('Administrator PIN'), findsNothing);
    });

    testWidgets('on for an enrolled tablet that is off Wi-Fi', (tester) async {
      final bridge = await pump(
        tester,
        const Size(360, 800),
        snapshot(cloudEnrolled: true),
      );
      bridge.wifi = const WifiStatus(enabled: true);
      await tapTimer(tester, 10);
      expect(find.text('Administrator PIN'), findsOneWidget);
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
      await tester.ensureVisible(find.byKey(const Key('charge-now')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('charge-now')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('manualCharge:true'));
    });

    testWidgets('stop charging while charge now is on', (tester) async {
      final bridge = await pump(
        tester,
        const Size(1280, 800),
        snapshot(
          unlocked: true,
          batteryPct: 60,
          chargeRequested: true,
          chargeRelayOn: true,
          chargeManual: true,
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
        find.byKey(const Key('charge-stop-now')),
        300,
        scrollable: find
            .ancestor(
              of: find.text('Live status'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.byKey(const Key('charge-now')), findsNothing);
      expect(find.text('ON (charge now)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('charge-stop-now')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('charge-stop-now')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('manualCharge:false'));
    });

    for (final opens in [true, false]) {
      testWidgets('shut down opens the power menu (opens: $opens)', (
        tester,
      ) async {
        final bridge = await pump(
          tester,
          const Size(1280, 800),
          snapshot(unlocked: true),
        );
        bridge.powerMenuOpens = opens;
        await openAdmin(tester);
        await tester.scrollUntilVisible(
          find.byKey(const Key('shut-down')),
          300,
          scrollable: find
              .ancestor(
                of: find.text('Status of this kiosk at a glance.'),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(find.byKey(const Key('shut-down')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shut-down')));
        await tester.pumpAndSettle();
        expect(bridge.calls, contains('powerMenu'));
        expect(
          find.text('Use the power button'),
          opens ? findsNothing : findsOneWidget,
        );
      });
    }

    testWidgets('Wi-Fi page shows the connection, tests the coin box and joins a network', (
      tester,
    ) async {
      final bridge = await pump(
        tester,
        const Size(1280, 800),
        snapshot(unlocked: true),
      );
      bridge
        ..wifi = const WifiStatus(
          enabled: true,
          connected: true,
          ssid: 'Shop-WiFi',
          ip: '192.168.0.110',
          gateway: '192.168.0.1',
          rssi: -48,
          frequencyMhz: 2437,
          internet: true,
          defaultIsWifi: true,
          deviceOwner: true,
        )
        ..networks = const [
          WifiNetwork(ssid: 'Shop-WiFi', rssi: -48, connected: true),
          WifiNetwork(ssid: 'Shop 5G', rssi: -60, frequencyMhz: 5180),
        ];
      await openAdmin(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Wi-Fi'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CONNECTED'), findsOneWidget);
      expect(find.text('Shop-WiFi'), findsOneWidget);
      expect(find.text('Excellent (-48 dBm)'), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('wifi-scan')));
      await tester.tap(find.byKey(const Key('wifi-scan')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('wifiScan'));
      await scrollTo(tester, find.byKey(const Key('wifi-Shop 5G')));
      await tester.tap(find.byKey(const Key('wifi-Shop 5G')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('wifi-password')), 'secret123');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wifi-join')));
      await tester.pump();
      expect(bridge.calls, contains('wifiConnect:Shop 5G:wpa2'));
      // Let the status re-checks after joining finish.
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
    });

    testWidgets('coin box page finds a one-tablet coin box and pairs as Tablet 1', (
      tester,
    ) async {
      final bridge = await pump(
        tester,
        const Size(1280, 800),
        snapshot(unlocked: true),
      );
      bridge.coinBoxes = const [
        CoinBoxInfo(
          address: '192.168.0.106:80',
          deviceId: 'vk-f6e705',
          fwVersion: '2.4.0',
          stations: 1,
          paired: [false],
          pairingOpen: true,
        ),
      ];
      await openAdmin(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Coin box'),
        ),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('coinbox-find')));
      await tester.tap(find.byKey(const Key('coinbox-find')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('findCoinBoxes'));
      expect(find.text('vk-f6e705 · 192.168.0.106'), findsOneWidget);
      expect(find.text('192.168.0.106'), findsOneWidget); // filled into the address field
      expect(find.text('This coin box serves one tablet: Tablet 1'), findsOneWidget);
    });

    testWidgets('apps page opens Google Play for the administrator', (tester) async {
      final bridge = await pump(
        tester,
        const Size(1280, 800),
        snapshot(unlocked: true),
      );
      await openAdmin(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('Apps'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Install apps from Google Play'), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-play')));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('openAppStore'));
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
      await scrollTo(tester, ads);
      await tester.ensureVisible(ads);
      await tester.pumpAndSettle();
      expect(find.text('Ad blocking'), findsOneWidget);
      await tester.tap(ads);
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('blockAds:false'));
    });

    testWidgets('brightness slider and automatic switch on the system page', (
      tester,
    ) async {
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
      final auto = find.byKey(const Key('brightness-auto'));
      await scrollTo(tester, auto);
      expect(find.text('Screen brightness'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);

      final slider = find.byKey(const Key('brightness'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('brightness:1:false'));

      await tester.tap(auto);
      await tester.pumpAndSettle();
      expect(bridge.calls, contains('brightness:60:true'));
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
      await scrollTo(tester, find.byKey(const Key('select-com.example.video')));
      await tester.tap(find.byKey(const Key('select-com.example.video')));
      await tester.pumpAndSettle();
      expect(find.textContaining('unsaved'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save-apps')));
      await tester.pump();
      expect(bridge.calls, contains('setAllowed:com.example.video'));
    });
  });
}
