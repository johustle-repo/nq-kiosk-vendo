<?php

declare(strict_types=1);

// Backend test suite. Runs the real migrations on in-memory SQLite and drives
// the application through App::handle().   Usage:  php backend/tests/run.php

require __DIR__ . '/../app/bootstrap.php';

use Vendo\App;
use Vendo\ArraySessionStore;
use Vendo\Auth\AdminAuth;
use Vendo\Clock;
use Vendo\Config;
use Vendo\Db;
use Vendo\Request;
use Vendo\Response;

$failures = 0;
$passes = 0;
$current = '';

function check(bool $cond, string $msg): void
{
    global $failures, $passes, $current;
    if ($cond) {
        $passes++;
    } else {
        $failures++;
        fwrite(STDERR, "  FAIL [$current] $msg\n");
    }
}

function test(string $name, callable $fn): void
{
    global $current;
    $current = $name;
    Clock::freeze(1_800_000_000);
    try {
        $fn();
        echo "  ok  $name\n";
    } catch (Throwable $e) {
        check(false, get_class($e) . ': ' . $e->getMessage() . ' @ ' . basename($e->getFile()) . ':' . $e->getLine());
    }
}

function newApp(array $extra = []): App
{
    $config = new Config($extra + [
        'DB_DRIVER' => 'sqlite',
        'DB_PATH' => ':memory:',
        'APP_URL' => 'https://vendo-kiosk.example.test',
        'SETUP_TOKEN' => 'test-setup-token-0123456789abcdef',
    ]);
    $app = new App($config, Db::fromConfig($config));
    $app->migrator->migrate();
    return $app;
}

function api(App $app, string $method, string $path, ?array $body = null, ?string $token = null, string $ip = '203.0.113.5'): array
{
    $headers = ['content-type' => 'application/json'];
    if ($token !== null) {
        $headers['authorization'] = 'Bearer ' . $token;
    }
    $req = new Request($method, $path, [], [], $headers, $body === null ? '' : json_encode($body), $ip, new ArraySessionStore());
    $res = $app->handle($req);
    return [$res->status, json_decode($res->body, true), $res];
}

function web(App $app, ArraySessionStore $s, string $method, string $path, array $post = [], string $ip = '198.51.100.7'): Response
{
    if ($method === 'POST' && !array_key_exists('_csrf', $post)) {
        $post['_csrf'] = $s->get('csrf') ?? '';
    }
    return $app->handle(new Request($method, $path, [], $post, [], '', $ip, $s));
}

/** Creates an admin, logs in, and returns the session. */
function loginAs(App $app, string $username, string $password = 'correct horse battery'): ArraySessionStore
{
    $app->db->exec('INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)', [$username, AdminAuth::hashPassword($password), Clock::sql()]);
    $s = new ArraySessionStore();
    web($app, $s, 'GET', '/login');
    $r = web($app, $s, 'POST', '/login', ['username' => $username, 'password' => $password]);
    check($r->status === 303 && ($r->headers['Location'] ?? '') === '/', "login as $username");
    web($app, $s, 'GET', '/'); // refresh CSRF token for subsequent posts
    return $s;
}

/** Creates a kiosk for the admin and enrolls a device, returning [kioskId, token]. */
function enrolled(App $app, int $adminId, string $type, ?int $kioskId = null): array
{
    $kioskId ??= $app->kiosks->createKiosk($adminId, 'Kiosk ' . $adminId);
    $code = $app->kiosks->createEnrollmentCode($kioskId, $adminId, $type);
    [$st, $body] = api($app, 'POST', '/api/v1/devices/enroll', ['device_type' => $type, 'enrollment_code' => $code, 'name' => "Test $type"]);
    check($st === 201, "enroll $type → 201 (got $st)");
    return [$kioskId, $body['device_token']];
}

function syncBody(string $bootId, int $uptime, array $events = [], array $status = []): array
{
    return [
        'protocol' => 1,
        'boot_id' => $bootId,
        'uptime_ms' => $uptime,
        'fw_version' => '1.0.0',
        'config_version_applied' => 1,
        'status' => $status + ['session' => 'running', 'remaining_s' => 240, 'seq' => count($events), 'session_no' => 1, 'seconds_per_pulse' => 240, 'rate_version' => 1],
        'events' => $events,
    ];
}

function credit(int $seq, int $pulses, int $remainingAfter, int $uptime, int $session = 1): array
{
    return ['seq' => $seq, 'type' => 'credit', 'session_no' => $session, 'pulses' => $pulses, 'seconds' => $pulses * 240,
        'rate_version' => 1, 'remaining_after' => $remainingAfter, 'uptime_ms' => $uptime, 'unix_time' => 0];
}

echo "Vendo backend tests\n";

test('migrations apply cleanly and health reports ok', function () {
    $app = newApp();
    check($app->migrator->pending() === [], 'no pending migrations');
    [$st, $body] = api($app, 'GET', '/api/v1/health');
    check($st === 200 && $body['ok'] === true && $body['database'] === 'ok', 'health ok');
    check($body['api_version'] === 'v1', 'api version');
});

test('health reports 503 when migrations are pending', function () {
    $config = new Config(['DB_DRIVER' => 'sqlite', 'DB_PATH' => ':memory:']);
    $app = new App($config, Db::fromConfig($config));
    [$st, $body] = api($app, 'GET', '/api/v1/health');
    check($st === 503 && $body['pending_migrations'] === 1, 'pending → 503');
});

test('unknown API route is 404 JSON', function () {
    [$st, $body] = api(newApp(), 'GET', '/api/v1/grant-time');
    check($st === 404 && $body['error']['code'] === 'not_found', '404');
});

test('enrollment codes are single-use, typed and expire', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    $k = $app->kiosks->createKiosk(1, 'K');
    $code = $app->kiosks->createEnrollmentCode($k, 1, 'controller');
    [$st] = api($app, 'POST', '/api/v1/devices/enroll', ['device_type' => 'phone', 'enrollment_code' => $code]);
    check($st === 403, 'wrong device type rejected');
    [$st, $b] = api($app, 'POST', '/api/v1/devices/enroll', ['device_type' => 'controller', 'enrollment_code' => strtolower(str_replace('-', ' ', $code))]);
    check($st === 201 && str_starts_with($b['device_token'], 'vkd_'), 'normalised code accepted');
    [$st] = api($app, 'POST', '/api/v1/devices/enroll', ['device_type' => 'controller', 'enrollment_code' => $code]);
    check($st === 403, 'reuse rejected');
    $code2 = $app->kiosks->createEnrollmentCode($k, 1, 'controller');
    Clock::freeze(Clock::now() + 1801);
    [$st] = api($app, 'POST', '/api/v1/devices/enroll', ['device_type' => 'controller', 'enrollment_code' => $code2]);
    check($st === 403, 'expired rejected');
    $row = $app->db->one('SELECT token_hash FROM devices LIMIT 1');
    check(!str_contains(json_encode($row), $b['device_token']), 'plaintext token not stored');
});

test('enrollment is rate limited per IP', function () {
    $app = newApp();
    $last = 0;
    for ($i = 0; $i < 11; $i++) {
        [$last] = api($app, 'POST', '/api/v1/devices/enroll', ['device_type' => 'phone', 'enrollment_code' => 'AAAAA-AAAAA'], null, '192.0.2.9');
    }
    check($last === 429, '11th attempt → 429');
});

test('device API authentication and ownership checks', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    [, $phone] = enrolled($app, 1, 'phone');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 1000));
    check($st === 401, 'no token → 401');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 1000), 'vkd_0000000000000000_' . str_repeat('A', 43));
    check($st === 401, 'unknown token → 401');
    $tampered = substr($ctl, 0, -1) . (substr($ctl, -1) === 'A' ? 'B' : 'A');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 1000), $tampered);
    check($st === 401, 'tampered secret → 401');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 1000), $phone);
    check($st === 401, 'phone token on controller endpoint → 401');
    [$st] = api($app, 'POST', '/api/v1/phone/heartbeat', ['boot_id' => 'bbbbbbbb', 'uptime_ms' => 5], $ctl);
    check($st === 401, 'controller token on phone endpoint → 401');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 1000), $ctl);
    check($st === 200, 'valid controller token → 200');
    $app->db->exec('UPDATE devices SET revoked_at = ? WHERE device_type = ?', [Clock::sql(), 'controller']);
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 2000), $ctl);
    check($st === 401, 'revoked token → 401');
});

test('events are stored to the owning kiosk only', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?), ('b', 'x', ?)", [Clock::sql(), Clock::sql()]);
    [$kA, $ctlA] = enrolled($app, 1, 'controller');
    [$kB] = enrolled($app, 2, 'controller');
    api($app, 'POST', '/api/v1/controller/sync', syncBody('aaaaaaaa', 5000, [credit(1, 1, 240, 4000)]), $ctlA);
    check((int) $app->db->one('SELECT COUNT(*) c FROM coin_events WHERE kiosk_id = ?', [$kA])['c'] === 1, 'A has event');
    check((int) $app->db->one('SELECT COUNT(*) c FROM coin_events WHERE kiosk_id = ?', [$kB])['c'] === 0, 'B has none');
});

test('retried sync does not duplicate credits', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [$k, $ctl] = enrolled($app, 1, 'controller');
    $body = syncBody('a1b2c3d4', 10_000, [credit(1, 1, 240, 9000), credit(2, 5, 1440, 9500)]);
    [$st, $r1] = api($app, 'POST', '/api/v1/controller/sync', $body, $ctl);
    check($st === 200 && $r1['ack']['acked_seqs'] === [1, 2] && $r1['ack']['inserted'] === 2, 'first upload inserted 2');
    [$st, $r2] = api($app, 'POST', '/api/v1/controller/sync', $body, $ctl);
    check($st === 200 && $r2['ack']['acked_seqs'] === [1, 2] && $r2['ack']['inserted'] === 0, 'retry acked, inserted 0');
    $sum = $app->db->one('SELECT COUNT(*) c, SUM(seconds_added) s FROM coin_events WHERE kiosk_id = ?', [$k]);
    check((int) $sum['c'] === 2 && (int) $sum['s'] === 1440, 'two events, 1440 s total');
    $sess = $app->db->one('SELECT * FROM sessions');
    check((int) $sess['total_pulses'] === 6 && (int) $sess['credit_count'] === 2, 'session totals not doubled');
});

test('same seq after controller restart (new boot_id) is a new event', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    api($app, 'POST', '/api/v1/controller/sync', syncBody('11111111', 10_000, [credit(1, 1, 240, 9000)]), $ctl);
    api($app, 'POST', '/api/v1/controller/sync', syncBody('22222222', 3_000, [credit(1, 1, 240, 2000)]), $ctl);
    check((int) $app->db->one('SELECT COUNT(*) c FROM coin_events')['c'] === 2, 'two distinct events');
    check($app->db->one('SELECT status_boot_id b FROM devices')['b'] === '22222222', 'status follows new boot even with lower uptime');
});

test('stale status report does not overwrite newer status', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 20_000, [], ['remaining_s' => 100]), $ctl);
    api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 15_000, [], ['remaining_s' => 900]), $ctl);
    $s = json_decode($app->db->one('SELECT status_json FROM devices')['status_json'], true);
    check($s['remaining_s'] === 100, 'older (lower uptime) report ignored');
});

test('invalid events are rejected individually and malformed bodies are 422', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    $bad = credit(2, 0, 0, 100); // zero-pulse credit
    [$st, $r] = api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 1000, [credit(1, 1, 240, 500), $bad]), $ctl);
    check($st === 200 && $r['ack']['acked_seqs'] === [1] && $r['ack']['rejected_seqs'] === [2], 'bad event rejected');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', ['protocol' => 1, 'boot_id' => 'NOT-HEX', 'uptime_ms' => 1, 'status' => []], $ctl);
    check($st === 422, 'bad boot id → 422');
    [$st] = api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 1, array_fill(0, 33, credit(1, 1, 1, 1))), $ctl);
    check($st === 422, 'too many events → 422');
});

test('sync response never contains paid time for the device', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    [, $r] = api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 1000, [credit(1, 1, 240, 500)]), $ctl);
    $flat = json_encode($r);
    check(!str_contains($flat, 'remaining') && !str_contains($flat, 'grant'), 'no remaining/grant fields');
    check($r['config']['seconds_per_pulse'] === 240, 'rate config returned');
});

test('config versions, ack tracking and rates for future credits only', function () {
    $app = newApp();
    $s = loginAs($app, 'owner');
    [$k, $ctl] = enrolled($app, 1, 'controller');
    [, $phone] = enrolled($app, 1, 'phone', $k);
    api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 1000, [credit(1, 1, 240, 500)]), $ctl);
    $r = web($app, $s, 'POST', "/kiosks/$k/config", ['seconds_per_pulse' => '300', 'local_loss_timeout_s' => '45',
        'controller_sync_interval_s' => '20', 'allowed_packages' => "com.android.chrome\ncom.google.android.youtube\ncom.android.chrome"]);
    check($r->status === 303, 'config saved');
    [, $sync] = api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 2000), $ctl);
    check($sync['config']['version'] === 2 && $sync['config']['seconds_per_pulse'] === 300, 'controller gets v2');
    [, $hb] = api($app, 'POST', '/api/v1/phone/heartbeat', ['boot_id' => 'cafebabe', 'uptime_ms' => 10, 'config_version_applied' => 2, 'mode' => 'production'], $phone);
    check($hb['config']['allowed_packages'] === ['com.android.chrome', 'com.google.android.youtube'], 'deduped package list');
    check($hb['config']['local_loss_timeout_s'] === 45, 'loss timeout');
    check((int) $app->db->one("SELECT config_version_applied v FROM devices WHERE device_type='phone'")['v'] === 2, 'phone ack recorded');
    $old = $app->db->one('SELECT seconds_added FROM coin_events WHERE seq = 1');
    check((int) $old['seconds_added'] === 240, 'existing credit unchanged by new rate');
    check($app->db->one("SELECT action FROM audit_log WHERE action = 'config.updated'") !== null, 'audited');
});

test('config validation rejects bad input', function () {
    $v = Vendo\Service\KioskService::validateConfig(['seconds_per_pulse' => '5', 'local_loss_timeout_s' => '30', 'controller_sync_interval_s' => '15', 'allowed_packages' => 'not a package; rm -rf']);
    check(count($v['errors']) >= 2, 'errors reported');
    $v = Vendo\Service\KioskService::validateConfig(['seconds_per_pulse' => '240', 'local_loss_timeout_s' => '30', 'controller_sync_interval_s' => '15', 'allowed_packages' => '']);
    check($v['errors'] === [] && $v['config']['allowed_packages'] === [], 'empty list ok');
});

test('admin cannot see or modify another admin\'s kiosk or device', function () {
    $app = newApp();
    $sA = loginAs($app, 'alice');
    $sB = loginAs($app, 'bobby');
    [$kA] = enrolled($app, 1, 'controller');
    $devA = (int) $app->db->one('SELECT id FROM devices')['id'];
    check(web($app, $sA, 'GET', "/kiosks/$kA")->status === 200, 'owner can view');
    check(web($app, $sB, 'GET', "/kiosks/$kA")->status === 404, 'other admin 404');
    check(web($app, $sB, 'GET', "/kiosks/$kA/status.json")->status === 404, 'other admin status.json 404');
    check(web($app, $sB, 'POST', "/kiosks/$kA/config", ['seconds_per_pulse' => '10', 'local_loss_timeout_s' => '30', 'controller_sync_interval_s' => '15', 'allowed_packages' => ''])->status === 404, 'other admin config 404');
    check(web($app, $sB, 'POST', "/devices/$devA/revoke")->status === 404, 'other admin revoke 404');
    check($app->db->one('SELECT revoked_at FROM devices')['revoked_at'] === null, 'device not revoked');
    check(web($app, $sB, 'POST', "/kiosks/$kA/enroll-code", ['device_type' => 'phone'])->status === 404, 'other admin enroll 404');
});

test('CSRF token required for cookie-authenticated posts', function () {
    $app = newApp();
    $s = loginAs($app, 'alice');
    $r = web($app, $s, 'POST', '/kiosks', ['name' => 'X', '_csrf' => 'wrong']);
    check($r->status === 419, 'bad token → 419');
    $r = web($app, $s, 'POST', '/kiosks', ['name' => 'X', '_csrf' => '']);
    check($r->status === 419, 'empty token → 419');
    check((int) $app->db->one('SELECT COUNT(*) c FROM kiosks')['c'] === 0, 'nothing created');
    check(web($app, $s, 'POST', '/kiosks', ['name' => 'X'])->status === 303, 'valid token ok');
});

test('unauthenticated dashboard access redirects to login', function () {
    $app = newApp();
    loginAs($app, 'alice');
    $r = web($app, new ArraySessionStore(), 'GET', '/');
    check($r->status === 303 && $r->headers['Location'] === '/login', 'redirect');
    $r = web($app, new ArraySessionStore(), 'GET', '/kiosks/1/status.json');
    check($r->status === 401, 'json 401');
});

test('login is rate limited and regenerates the session', function () {
    $app = newApp();
    $app->db->exec('INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)', ['alice', AdminAuth::hashPassword('correct horse battery'), Clock::sql()]);
    $s = new ArraySessionStore();
    web($app, $s, 'GET', '/login');
    for ($i = 0; $i < 8; $i++) {
        $r = web($app, $s, 'POST', '/login', ['username' => 'alice', 'password' => 'wrong password!']);
        check($r->status === 401, "wrong password $i → 401");
    }
    $r = web($app, $s, 'POST', '/login', ['username' => 'alice', 'password' => 'correct horse battery']);
    check($r->status === 401 && str_contains($r->body, 'Too many'), 'locked out even with right password');
    Clock::freeze(Clock::now() + 901);
    $r = web($app, $s, 'POST', '/login', ['username' => 'alice', 'password' => 'correct horse battery']);
    check($r->status === 303 && $s->regenerations === 1, 'login after window; session regenerated');
});

test('session idle timeout and password change invalidate sessions', function () {
    $app = newApp();
    $s = loginAs($app, 'alice');
    $s2 = new ArraySessionStore();
    web($app, $s2, 'GET', '/login');
    web($app, $s2, 'POST', '/login', ['username' => 'alice', 'password' => 'correct horse battery']);
    web($app, $s, 'GET', '/account');
    $r = web($app, $s, 'POST', '/account', ['current_password' => 'correct horse battery', 'new_password' => 'another long password', 'new_password_confirm' => 'another long password']);
    check($r->status === 303, 'password changed');
    check(web($app, $s2, 'GET', '/')->status === 303, 'other session logged out');
    $s3 = loginAs($app, 'carol');
    Clock::freeze(Clock::now() + AdminAuth::IDLE_TIMEOUT_S + 1);
    check(web($app, $s3, 'GET', '/')->status === 303, 'idle session expired');
});

test('setup requires token, creates first admin once', function () {
    $config = new Config(['DB_DRIVER' => 'sqlite', 'DB_PATH' => ':memory:', 'SETUP_TOKEN' => 'test-setup-token-0123456789abcdef']);
    $app = new App($config, Db::fromConfig($config));
    $s = new ArraySessionStore();
    check(web($app, $s, 'GET', '/')->headers['Location'] === '/setup', 'redirect to setup');
    web($app, $s, 'GET', '/setup');
    $r = web($app, $s, 'POST', '/setup', ['setup_token' => 'wrong', 'username' => 'admin', 'password' => 'long enough password', 'password_confirm' => 'long enough password']);
    check(str_contains($r->body, 'incorrect'), 'wrong token rejected');
    $r = web($app, $s, 'POST', '/setup', ['setup_token' => 'test-setup-token-0123456789abcdef', 'username' => 'admin', 'password' => 'long enough password', 'password_confirm' => 'long enough password']);
    check($r->status === 303 && $app->migrator->pending() === [], 'migrated + created');
    $r = web($app, $s, 'POST', '/setup', ['setup_token' => 'test-setup-token-0123456789abcdef', 'username' => 'evil', 'password' => 'long enough password', 'password_confirm' => 'long enough password']);
    check((int) $app->db->one('SELECT COUNT(*) c FROM admins')['c'] === 1, 'second setup ignored');
});

test('presence marks stale devices offline', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 1000), $ctl);
    $d = $app->db->one('SELECT * FROM devices');
    check(Vendo\Service\KioskService::presence($d, 90) === 'online', 'online');
    Clock::freeze(Clock::now() + 91);
    check(Vendo\Service\KioskService::presence($d, 90) === 'offline', 'offline after threshold');
});

test('session end event closes the session', function () {
    $app = newApp();
    $app->db->exec("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', ?)", [Clock::sql()]);
    [, $ctl] = enrolled($app, 1, 'controller');
    $expire = ['seq' => 2, 'type' => 'expire', 'session_no' => 1, 'uptime_ms' => 250_000, 'remaining_after' => 0];
    api($app, 'POST', '/api/v1/controller/sync', syncBody('abcdef01', 300_000, [credit(1, 1, 240, 10_000), $expire]), $ctl);
    $sess = $app->db->one('SELECT * FROM sessions');
    check($sess['end_reason'] === 'expired' && $sess['ended_at'] !== null, 'session closed');
});

echo "\n$passes checks passed, $failures failed\n";
exit($failures === 0 ? 0 : 1);
