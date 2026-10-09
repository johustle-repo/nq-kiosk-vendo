import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pumpApp(
  WidgetTester tester,
  Map<Object?, Object?> state,
) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bridge = FakeKioskBridge(state);
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  testWidgets(
    'shows the tablet number and asks the player to tap Insert coin',
    (tester) async {
      await pumpApp(
        tester,
        snapshot(
          mode: 'production',
          deviceOwner: true,
          station: 2,
          selectedStation: 3,
        ),
      );
      expect(find.byKey(const Key('tablet-badge')), findsOneWidget);
      expect(find.text('Tablet 2'), findsOneWidget);
      expect(
        find.text('Tap "Insert coin to start", then insert your coins.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Insert coin claims the shared coin box for this tablet', (
    tester,
  ) async {
    final bridge = await pumpApp(
      tester,
      snapshot(
        mode: 'production',
        deviceOwner: true,
        station: 2,
        selectedStation: 0,
      ),
    );
    await tester.tap(find.text('Insert coin to start'));
    await tester.pump();
    expect(bridge.claims, 1);
    expect(
      find.text(
        'Coin box ready for Tablet 2. Insert your coins now (within 60 s).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Insert coin says which tablet is busy', (tester) async {
    final bridge = await pumpApp(
      tester,
      snapshot(
        mode: 'production',
        deviceOwner: true,
        station: 2,
        selectedStation: 3,
      ),
    );
    bridge.claimError = 'busy:3:42';
    await tester.tap(find.text('Insert coin to start'));
    await tester.pump();
    expect(
      find.text(
        'Tablet 3 is inserting coins right now. Please try again in 42 s.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('demo mode Insert coin does not claim the coin box', (
    tester,
  ) async {
    final bridge = await pumpApp(tester, snapshot(mode: 'demo', station: 2));
    await tester.tap(find.text('Insert coin to start'));
    await tester.pump();
    expect(bridge.claims, 0);
  });

  testWidgets(
    'says the coin box is ready when the attendant selected this tablet',
    (tester) async {
      await pumpApp(
        tester,
        snapshot(
          mode: 'production',
          deviceOwner: true,
          station: 2,
          selectedStation: 2,
        ),
      );
      expect(
        find.text('The coin box is ready for Tablet 2. Insert your coins now.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    },
  );

  testWidgets('demo mode keeps the single-tablet wording', (tester) async {
    await pumpApp(tester, snapshot(mode: 'demo', station: 2));
    expect(find.byKey(const Key('tablet-badge')), findsNothing);
    expect(
      find.text('Drop a coin in the slot. Your time starts right away.'),
      findsOneWidget,
    );
  });

  testWidgets('the paid launcher shows the tablet number', (tester) async {
    await pumpApp(
      tester,
      snapshot(
        mode: 'production',
        deviceOwner: true,
        granted: true,
        remainingMs: 600000,
        station: 3,
      ),
    );
    expect(find.textContaining('TABLET 3'), findsOneWidget);
  });

  testWidgets('Add time during a session claims the coin box for this tablet', (tester) async {
    final bridge = await pumpApp(
      tester,
      snapshot(mode: 'production', deviceOwner: true, granted: true, remainingMs: 600000, station: 2, selectedStation: 0),
    );
    expect(find.text('Add time'), findsOneWidget);
    await tester.tap(find.text('Add time'));
    await tester.pump();
    expect(bridge.claims, 1);
    expect(find.text('Coin box ready for Tablet 2. Insert your coins now (within 60 s).'), findsOneWidget);
  });

  testWidgets('Add time shows when the coin box is ready for this tablet', (tester) async {
    await pumpApp(
      tester,
      snapshot(mode: 'production', deviceOwner: true, granted: true, remainingMs: 600000, station: 2, selectedStation: 2),
    );
    expect(find.text('Insert coins now'), findsOneWidget);
  });

  testWidgets('demo sessions have no Add time button', (tester) async {
    await pumpApp(tester, snapshot(mode: 'demo', granted: true, remainingMs: 600000));
    expect(find.byKey(const Key('add-time-button')), findsNothing);
  });
}
