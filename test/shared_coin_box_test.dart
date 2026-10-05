import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/main.dart';
import 'package:vendo_kiosk/src/kiosk_controller.dart';

import 'fake_bridge.dart';

Future<FakeKioskBridge> pumpApp(WidgetTester tester, Map<Object?, Object?> state) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bridge = FakeKioskBridge(state);
  await tester.pumpWidget(VendoKioskApp(controller: KioskController(bridge)));
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  testWidgets('shows the tablet number and asks for the staff when not selected', (tester) async {
    await pumpApp(tester, snapshot(mode: 'production', deviceOwner: true, station: 2, selectedStation: 3));
    expect(find.byKey(const Key('tablet-badge')), findsOneWidget);
    expect(find.text('Tablet 2'), findsOneWidget);
    expect(find.text('Ask the staff to select Tablet 2, then insert your coins.'), findsOneWidget);
  });

  testWidgets('says the coin box is ready when the attendant selected this tablet', (tester) async {
    await pumpApp(tester, snapshot(mode: 'production', deviceOwner: true, station: 2, selectedStation: 2));
    expect(find.text('The coin box is ready for Tablet 2. Insert your coins now.'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('demo mode keeps the single-tablet wording', (tester) async {
    await pumpApp(tester, snapshot(mode: 'demo', station: 2));
    expect(find.byKey(const Key('tablet-badge')), findsNothing);
    expect(find.text('Drop a coin in the slot. Your time starts right away.'), findsOneWidget);
  });

  testWidgets('the paid launcher shows the tablet number', (tester) async {
    await pumpApp(tester, snapshot(mode: 'production', deviceOwner: true, granted: true, remainingMs: 600000, station: 3));
    expect(find.textContaining('TABLET 3'), findsOneWidget);
  });
}
