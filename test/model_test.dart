import 'package:flutter_test/flutter_test.dart';
import 'package:vendo_kiosk/src/model/kiosk_state.dart';
import 'package:vendo_kiosk/src/model/rates.dart';

import 'fake_bridge.dart';

void main() {
  group('Rates', () {
    test('1, 5, 10 and 20 pulses at 240 s per pulse', () {
      expect(Rates.secondsFor(1), 240);
      expect(Rates.secondsFor(5), 1200);
      expect(Rates.secondsFor(10), 2400);
      expect(Rates.secondsFor(20), 4800);
      expect(Rates.describeDuration(240), '4 min');
      expect(Rates.describeDuration(1200), '20 min');
      expect(Rates.describeDuration(2400), '40 min');
      expect(Rates.describeDuration(4800), '1 h 20 min');
    });

    test('follows a different controller rate', () {
      expect(Rates.secondsFor(5, secondsPerPulse: 300), 1500);
      expect(Rates.describeDuration(270), '4 min 30 s');
    });

    test('rejects invalid input', () {
      expect(() => Rates.secondsFor(-1), throwsArgumentError);
      expect(() => Rates.secondsFor(1, secondsPerPulse: 0), throwsArgumentError);
    });
  });

  group('formatHms', () {
    test('formats and rounds partial seconds up', () {
      expect(formatHms(0), '00:00:00');
      expect(formatHms(-5), '00:00:00');
      expect(formatHms(1), '00:00:01');
      expect(formatHms(240000), '00:04:00');
      expect(formatHms(4800000), '01:20:00');
      expect(formatHms(36000000 + 59999), '10:01:00');
    });
  });

  group('KioskState.fromMap', () {
    test('parses a full native snapshot', () {
      final s = KioskState.fromMap(snapshot(mode: 'production', deviceOwner: true, granted: true, remainingMs: 1000, cloudLink: 'offline'));
      expect(s.loaded, isTrue);
      expect(s.isProduction, isTrue);
      expect(s.accessGranted, isTrue);
      expect(s.remainingMs, 1000);
      expect(s.controllerLink, ControllerLink.connected);
      expect(s.cloudLink, CloudLink.offline);
      expect(s.allowedPackages, ['com.example.video']);
      expect(s.productionBlocked, isFalse);
    });

    test('production without Device Owner is blocked', () {
      final s = KioskState.fromMap(snapshot(mode: 'production', deviceOwner: false));
      expect(s.productionBlocked, isTrue);
      expect(s.isDemo, isFalse);
    });

    test('unknown values fall back safely', () {
      final s = KioskState.fromMap({'mode': 'weird', 'controller': {'link': 'nope'}, 'cloud': {'link': '??'}});
      expect(s.mode, KioskMode.unconfigured);
      expect(s.controllerLink, ControllerLink.never);
      expect(s.cloudLink, CloudLink.disabled);
      expect(s.accessGranted, isFalse);
    });

    test('recently expired only when denied', () {
      expect(KioskState.fromMap(snapshot(expiredAgoMs: 1000)).recentlyExpired, isTrue);
      expect(KioskState.fromMap(snapshot(expiredAgoMs: 500000)).recentlyExpired, isFalse);
      expect(KioskState.fromMap(snapshot(granted: true, expiredAgoMs: 1000)).recentlyExpired, isFalse);
    });
  });
}
