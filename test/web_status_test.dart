import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vendo_kiosk/src/bridge/kiosk_bridge.dart';
import 'package:vendo_kiosk/src/web/cloud_status.dart';
import 'package:vendo_kiosk/src/web/status_client.dart';
import 'package:vendo_kiosk/src/web/status_poller.dart';
import 'package:vendo_kiosk/src/web/token_store.dart';
import 'package:vendo_kiosk/src/web/web_kiosk_app.dart';

const token =
    'vkw_0123456789abcdef_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Map<String, Object?> body({
  int remaining = 480,
  int age = 0,
  int seq = 1,
  int pulses = 1,
  String boot = 'a1b2c3d4',
  int serverTime = 1000000,
  bool stale = false,
  bool available = true,
}) => {
  'ok': true,
  'device': 'vendo-001',
  'status_available': available,
  'remaining_seconds': available ? remaining : null,
  'boot_id': available ? boot : null,
  'sequence_number': available ? seq : null,
  'last_pulses': available ? pulses : null,
  'age_seconds': available ? age : null,
  'stale': stale,
  'stale_after_seconds': 60,
  'server_time': serverTime,
};

CloudStatus st({
  int remaining = 480,
  int age = 0,
  int seq = 1,
  int pulses = 1,
  String boot = 'a1b2c3d4',
  int serverTime = 1000000,
}) => CloudStatus.fromJson(
  body(
    remaining: remaining,
    age: age,
    seq: seq,
    pulses: pulses,
    boot: boot,
    serverTime: serverTime,
  ),
);

void main() {
  group('CloudStatusTracker', () {
    test('accounts for server-reported age and local elapsed time', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 480, age: 4));
      expect(t.remainingMs(), 476000);
      now = 10000;
      expect(t.remainingMs(), 466000);
      expect(t.currentAgeSeconds(), 14);
    });

    test('repeated responses do not add credit again', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      expect(
        t.apply(st(remaining: 480, age: 0, serverTime: 1000)),
        StatusUpdateKind.first,
      );
      for (var i = 1; i <= 10; i++) {
        now = i * 3000;
        // Same upload polled again: server_time and age grow together.
        expect(
          t.apply(st(remaining: 480, age: i * 3, serverTime: 1000 + i * 3)),
          StatusUpdateKind.repeated,
        );
      }
      expect(t.remainingMs(), 450000);
      expect(t.creditEvents, 0);
    });

    test('a new upload of the same session updates without adding', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 480, serverTime: 1000));
      now = 15000;
      expect(
        t.apply(st(remaining: 465, serverTime: 1015)),
        StatusUpdateKind.updated,
      );
      expect(t.remainingMs(), 465000);
      expect(t.creditEvents, 0);
    });

    test('a higher sequence number is a coin', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 100, seq: 1, serverTime: 1000));
      now = 5000;
      expect(
        t.apply(st(remaining: 95 + 1200, seq: 2, pulses: 5, serverTime: 1005)),
        StatusUpdateKind.creditAdded,
      );
      expect(t.lastCreditPulses, 5);
      expect(t.remainingMs(), 1295000);
    });

    test(
      'upload counter going up without a coin is not a coin (original firmware)',
      () {
        var now = 0;
        final t = CloudStatusTracker(clockMs: () => now);
        t.apply(st(remaining: 600, seq: 10, serverTime: 1000));
        for (var i = 1; i <= 5; i++) {
          now = i * 10000;
          // "sequence" counts uploads; remaining just keeps counting down.
          expect(
            t.apply(
              st(
                remaining: 600 - i * 10,
                seq: 10 + i,
                serverTime: 1000 + i * 10,
              ),
            ),
            StatusUpdateKind.updated,
          );
        }
        expect(t.creditEvents, 0);
        expect(t.remainingMs(), 550000);
      },
    );

    test('a coin is detected from the jump in remaining time', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 100, seq: 3, serverTime: 1000));
      now = 2000;
      expect(
        t.apply(st(remaining: 98 + 240, seq: 4, pulses: 1, serverTime: 1002)),
        StatusUpdateKind.creditAdded,
      );
      expect(t.lastCreditPulses, 1);
      expect(t.creditEvents, 1);
    });

    test('an older upload arriving late is ignored', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 300, seq: 3, serverTime: 2000));
      now = 1000;
      expect(
        t.apply(st(remaining: 900, seq: 2, serverTime: 1990)),
        StatusUpdateKind.olderIgnored,
      );
      expect(t.remainingMs(), 299000);
    });

    test('controller restart (new boot id) replaces the baseline', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 600, seq: 9, boot: 'aaaaaaaa'));
      expect(
        t.apply(
          st(remaining: 0, seq: 0, boot: 'bbbbbbbb', serverTime: 1000100),
        ),
        StatusUpdateKind.bootChanged,
      );
      expect(t.remainingMs(), 0);
    });

    test('expires at zero and never goes negative', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 5));
      now = 60000;
      expect(t.remainingMs(), 0);
    });

    test('stale when the server says so or when age passes the threshold', () {
      var now = 0;
      final t = CloudStatusTracker(clockMs: () => now);
      t.apply(st(remaining: 3000, age: 50));
      expect(t.isStale, isFalse);
      now = 11000;
      expect(t.isStale, isTrue);
    });

    test('no status yet', () {
      final t = CloudStatusTracker(clockMs: () => 0);
      expect(
        t.apply(CloudStatus.fromJson(body(available: false))),
        StatusUpdateKind.unavailable,
      );
      expect(t.remainingMs(), 0);
      expect(t.isStale, isTrue);
    });

    test('rejects malformed responses', () {
      expect(
        () => CloudStatus.fromJson({
          'ok': true,
          'status_available': true,
          'server_time': 1,
        }),
        throwsFormatException,
      );
      expect(() => CloudStatus.fromJson({'ok': false}), throwsFormatException);
    });
  });

  group('KioskStatusClient', () {
    Uri? lastUri;
    Map<String, String>? lastHeaders;
    KioskStatusClient client(http.Client c) => KioskStatusClient(
      httpClient: c,
      endpoint: Uri.parse(
        'https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php',
      ),
      token: token,
      device: 'vendo-001',
    );

    test('sends the web token and device; parses status', () async {
      final c = MockClient((req) async {
        lastUri = req.url;
        lastHeaders = req.headers;
        return http.Response(jsonEncode(body()), 200);
      });
      final s = await client(c).fetch();
      expect(s.remainingSeconds, 480);
      expect(
        lastUri.toString(),
        'https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php?device=vendo-001',
      );
      expect(lastHeaders!['Authorization'], 'Bearer $token');
    });

    test('long-poll request carries what the browser already has', () async {
      final c = MockClient((req) async {
        lastUri = req.url;
        return http.Response(
          jsonEncode(body(seq: 4, serverTime: 2000, age: 3)),
          200,
        );
      });
      final cl = KioskStatusClient(
        httpClient: c,
        endpoint: Uri.parse(
          'https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php',
        ),
        token: token,
        device: 'vendo-001',
        longPollSeconds: 20,
      );
      await cl.fetch();
      expect(
        lastUri!.queryParameters.containsKey('wait'),
        isFalse,
        reason: 'nothing to compare yet',
      );
      await cl.fetch(st(seq: 4, serverTime: 2000, age: 3));
      expect(lastUri!.queryParameters, {
        'device': 'vendo-001',
        'wait': '20',
        'since_boot': 'a1b2c3d4',
        'since_seq': '4',
        'since_reported': '1997',
      });
    });

    test('maps HTTP failures to error codes', () async {
      for (final (code, expected) in [
        (401, 'unauthorized'),
        (403, 'forbidden'),
        (429, 'rate_limited'),
        (503, 'server'),
        (404, 'http_404'),
      ]) {
        final c = MockClient((_) async => http.Response('{}', code));
        await expectLater(
          client(c).fetch(),
          throwsA(isA<StatusError>().having((e) => e.code, 'code', expected)),
        );
      }
      final spa = MockClient(
        (_) async => http.Response(
          '<!DOCTYPE html><html>app shell</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        client(spa).fetch(),
        throwsA(isA<StatusError>().having((e) => e.code, 'code', 'not_api')),
      );
      final broken = MockClient((_) async => http.Response('not json', 200));
      await expectLater(
        client(broken).fetch(),
        throwsA(
          isA<StatusError>().having((e) => e.code, 'code', 'bad_response'),
        ),
      );
      final offline = MockClient(
        (_) async => throw http.ClientException('XMLHttpRequest error.'),
      );
      await expectLater(
        client(offline).fetch(),
        throwsA(isA<StatusError>().having((e) => e.code, 'code', 'network')),
      );
    });

    test('token paste clean-up and specific problems', () {
      expect(
        KioskStatusClient.normalizeToken(
          '  "${token.substring(0, 30)}\r\n${token.substring(30)}"  ',
        ),
        token,
      );
      expect(KioskStatusClient.normalizeToken('Bearer $token'), token);
      expect(KioskStatusClient.tokenProblem(token), isNull);
      expect(
        KioskStatusClient.tokenProblem('esp-upload-secret'),
        contains('must start with "vkw_"'),
      );
      expect(
        KioskStatusClient.tokenProblem(token.substring(0, 57)),
        contains('64 characters but this is 57'),
      );
      expect(
        KioskStatusClient.tokenProblem('${token.substring(0, 63)}!'),
        contains('not allowed'),
      );
    });

    test('same-origin endpoint in production, override for development', () {
      final page = Uri.parse(
        'https://vendo-kiosk.ebnleadgen.online/some/route?x=1',
      );
      expect(
        const WebKioskConfig().endpoint(page).toString(),
        'https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php',
      );
      // Debug build on localhost without VENDO_API_BASE → local PHP API; release → same origin.
      final local = Uri.parse('http://localhost:58981/');
      expect(
        const WebKioskConfig().endpoint(local, debugBuild: true).toString(),
        'http://127.0.0.1:8000/api/kiosk-status.php',
      );
      expect(
        const WebKioskConfig().endpoint(local, debugBuild: false).toString(),
        'http://localhost:58981/api/kiosk-status.php',
      );
      expect(
        const WebKioskConfig().endpoint(page, debugBuild: true).toString(),
        'https://vendo-kiosk.ebnleadgen.online/api/kiosk-status.php',
      );
      expect(
        const WebKioskConfig(
          apiBase: 'http://127.0.0.1:8000',
        ).endpoint(Uri.parse('http://localhost:5173/')).toString(),
        'http://127.0.0.1:8000/api/kiosk-status.php',
      );
    });
  });

  group('StatusPoller', () {
    test('never has more than one request in flight', () {
      fakeAsync((async) {
        var inFlight = 0;
        var maxInFlight = 0;
        var calls = 0;
        Future<CloudStatus> slowFetch(CloudStatus? since) async {
          calls++;
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(
            const Duration(seconds: 5),
          ); // slower than the 3 s interval
          inFlight--;
          return st();
        }

        final p = StatusPoller(
          fetch: slowFetch,
          tracker: CloudStatusTracker(),
          clockMs: () => async.elapsed.inMilliseconds,
        );
        p.start();
        p.start(); // starting twice must not create a second loop
        async.elapse(const Duration(seconds: 30));
        p.stop();
        expect(maxInFlight, 1);
        // 5 s per request; a slow (long-poll-like) answer is followed by the next
        // request after only the 250 ms minimum gap: starts at 0, 5.25, 10.5, 15.75, 21, 26.25 s.
        expect(calls, 6);
      });
    });

    test('polls every 3 s when responses are fast and counts failures', () {
      fakeAsync((async) {
        var calls = 0;
        Future<CloudStatus> fetch(CloudStatus? since) async {
          calls++;
          if (calls == 2 || calls == 3) throw const StatusError('network');
          return st();
        }

        final p = StatusPoller(
          fetch: fetch,
          tracker: CloudStatusTracker(),
          clockMs: () => async.elapsed.inMilliseconds,
        );
        p.start();
        async.elapse(const Duration(milliseconds: 6100));
        expect(calls, 3);
        expect(p.consecutiveFailures, 2);
        expect(p.lastError?.code, 'network');
        async.elapse(const Duration(seconds: 3));
        expect(calls, 4);
        expect(p.consecutiveFailures, 0);
        p.stop();
      });
    });

    test(
      'new data is followed by an immediate request; unchanged fast answers keep 3 s spacing',
      () {
        fakeAsync((async) {
          final starts = <int>[];
          var seq = 1;
          Future<CloudStatus> fetch(CloudStatus? since) async {
            starts.add(async.elapsed.inMilliseconds);
            return st(seq: seq, serverTime: 1000 + seq);
          }

          final p = StatusPoller(
            fetch: fetch,
            tracker: CloudStatusTracker(),
            clockMs: () => async.elapsed.inMilliseconds,
          );
          p.start();
          async.elapse(const Duration(milliseconds: 100));
          expect(starts, [0]);
          async.elapse(
            const Duration(milliseconds: 300),
          ); // first answer is "new" → next after 250 ms
          expect(starts, [0, 250]);
          async.elapse(
            const Duration(seconds: 2),
          ); // unchanged answers from a server without long-poll: no hammering
          expect(starts.length, 2);
          seq = 2; // a coin arrives
          async.elapse(const Duration(milliseconds: 1000));
          expect(starts.length, 3); // 3.25 s: picks up the coin
          async.elapse(const Duration(milliseconds: 300));
          expect(starts.length, 4); // and asks again right away
          p.stop();
        });
      },
    );

    test('stops on unauthorized (a new token is needed)', () {
      fakeAsync((async) {
        var calls = 0;
        final p = StatusPoller(
          fetch: (_) async {
            calls++;
            throw const StatusError('unauthorized');
          },
          tracker: CloudStatusTracker(),
        );
        p.start();
        async.elapse(const Duration(seconds: 30));
        expect(calls, 1);
        expect(p.running, isFalse);
      });
    });
  });

  group('platform guard', () {
    test('Android platform channels are refused off-Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(MethodChannelKioskBridge.supported, isFalse);
        await expectLater(
          MethodChannelKioskBridge().getState(),
          throwsA(isA<KioskException>()),
        );
        await expectLater(
          MethodChannelKioskBridge().simulateCoin(1),
          throwsA(isA<KioskException>()),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('WebKioskApp', () {
    Future<void> pump(
      WidgetTester tester,
      http.Client client, {
      String? stored = token,
    }) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        WebKioskApp(
          config: const WebKioskConfig(),
          tokenStore: MemoryTokenStore(stored),
          httpClient: client,
          pageUri: Uri.parse('https://vendo-kiosk.ebnleadgen.online/'),
          clockMs: () => tester.binding.clock.now().millisecondsSinceEpoch,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }

    testWidgets('shows the browser demo notice and asks for a token', (
      tester,
    ) async {
      await pump(
        tester,
        MockClient((_) async => http.Response('{}', 500)),
        stored: null,
      );
      expect(find.text(browserDemoNotice), findsOneWidget);
      expect(
        find.text('Browser demo: Android kiosk enforcement unavailable'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('token-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('token-field')),
        'esp-upload-secret',
      );
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pump();
      expect(find.textContaining('must start with "vkw_"'), findsOneWidget);
      // A token broken across two lines by the terminal is accepted.
      await tester.enterText(
        find.byKey(const Key('token-field')),
        '${token.substring(0, 40)}\n${token.substring(40)}',
      );
      await tester.tap(find.byKey(const Key('connect')));
      await tester.pump();
      expect(find.byKey(const Key('token-field')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('payment screen with countdown in HH:MM:SS and preview tiles', (
      tester,
    ) async {
      await pump(
        tester,
        MockClient(
          (_) async =>
              http.Response(jsonEncode(body(remaining: 1200, age: 0)), 200),
        ),
      );
      expect(find.text('Time remaining'), findsOneWidget);
      expect(find.text('00:20:00'), findsOneWidget);
      expect(find.textContaining('Server: connected'), findsOneWidget);
      expect(find.textContaining('PREVIEW — not launchable'), findsNWidgets(4));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('00:19:58'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a coin shows up within about a second (long-poll)', (
      tester,
    ) async {
      var n = 0;
      final client = MockClient((req) async {
        n++;
        if (n == 1)
          return http.Response(
            jsonEncode(body(remaining: 0, seq: 1, serverTime: 5000)),
            200,
          );
        if (n == 2) {
          // Server holds the long-poll; the coin box uploads 0.8 s later.
          expect(req.url.queryParameters['wait'], '20');
          await Future<void>.delayed(const Duration(milliseconds: 800));
          return http.Response(
            jsonEncode(
              body(remaining: 1200, seq: 2, pulses: 5, serverTime: 5001),
            ),
            200,
          );
        }
        await Future<void>.delayed(const Duration(seconds: 20));
        return http.Response(
          jsonEncode(
            body(remaining: 1200, seq: 2, pulses: 5, serverTime: 5001, age: 20),
          ),
          200,
        );
      });
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        WebKioskApp(
          config: const WebKioskConfig(),
          tokenStore: MemoryTokenStore(token),
          httpClient: client,
          pageUri: Uri.parse('https://vendo-kiosk.ebnleadgen.online/'),
          clockMs: () => tester.binding.clock.now().millisecondsSinceEpoch,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Insert coin to start'), findsOneWidget);
      await tester.pump(
        const Duration(milliseconds: 300),
      ); // second (long-poll) request starts
      await tester.pump(
        const Duration(milliseconds: 900),
      ); // coin upload lands; UI repaints
      expect(find.text('Time remaining'), findsOneWidget);
      expect(find.text('00:20:00'), findsOneWidget);
      expect(find.textContaining('Coin received: +20 min'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(
        const Duration(seconds: 40),
      ); // let the held long-poll request finish
    });

    testWidgets('no time: insert coin prompt', (tester) async {
      await pump(
        tester,
        MockClient(
          (_) async => http.Response(jsonEncode(body(remaining: 0)), 200),
        ),
      );
      expect(find.text('Insert coin to start'), findsOneWidget);
      expect(find.text('00:00:00'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('shows connection failures', (tester) async {
      await pump(
        tester,
        MockClient(
          (_) async => throw http.ClientException('XMLHttpRequest error.'),
        ),
      );
      expect(find.byKey(const Key('error-banner')), findsOneWidget);
      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
      expect(find.textContaining('connection failed'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('shows stale device status', (tester) async {
      await pump(
        tester,
        MockClient(
          (_) async => http.Response(
            jsonEncode(body(remaining: 900, age: 120, stale: true)),
            200,
          ),
        ),
      );
      expect(find.byKey(const Key('stale-banner')), findsOneWidget);
      expect(find.textContaining('STALE'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('rejected token offers re-entry', (tester) async {
      await pump(
        tester,
        MockClient(
          (_) async =>
              http.Response('{"ok":false,"error":"unauthorized"}', 401),
        ),
      );
      expect(find.textContaining('Access token rejected'), findsOneWidget);
      await tester.tap(find.text('Enter a different token'));
      await tester.pump();
      expect(find.byKey(const Key('token-field')), findsOneWidget);
    });
  });
}
