<?php

declare(strict_types=1);

// Tests for GET /api/kiosk-status.php.   php web_backend/tests/run.php

require __DIR__ . '/../vendo_web/kiosk_status_lib.php';

use VendoWeb\KioskStatusEndpoint;

$fail = 0;
$pass = 0;
function check(bool $c, string $m): void
{
    global $fail, $pass;
    $c ? $pass++ : $fail++;
    if (!$c) {
        fwrite(STDERR, "  FAIL $m\n");
    }
}

const ORIGIN = 'http://localhost:5173';

function setup(): array
{
    $pdo = new PDO('sqlite::memory:', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $pdo->exec("CREATE TABLE device_status (device_id TEXT, remaining_seconds INTEGER, boot_id TEXT, sequence_number INTEGER, last_pulses INTEGER, updated_at TEXT)");
    // Simulated ESP8266 upload credential table: must never be accepted here.
    $pdo->exec("CREATE TABLE esp_devices (device_id TEXT, upload_token TEXT)");
    $pdo->exec("INSERT INTO esp_devices VALUES ('vendo-001', 'esp-upload-secret-123')");
    $sql = (string) file_get_contents(__DIR__ . '/../vendo_web/migrations/001_web_kiosk_tokens.sql');
    $sql = preg_replace('/^\s*--.*$/m', '', $sql);
    $sql = str_replace('INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT', $sql);
    $sql = preg_replace('/\)\s*ENGINE=[^;]*;/', ');', $sql);
    $pdo->exec(str_replace(' UNSIGNED', '', $sql));
    $config = [
        'status_source' => ['table' => 'device_status', 'device_column' => 'device_id', 'remaining_column' => 'remaining_seconds',
            'boot_column' => 'boot_id', 'sequence_column' => 'sequence_number', 'pulses_column' => 'last_pulses',
            'updated_column' => 'updated_at', 'updated_type' => 'datetime'],
        'stale_after_seconds' => 60,
        'rate_limit_per_minute' => 5,
        'cors_allowed_origins' => [ORIGIN],
    ];
    return [$pdo, $config];
}

function token(PDO $pdo, string $device, ?string $expires = null, ?string $revoked = null): string
{
    $id = bin2hex(random_bytes(8));
    $secret = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
    $pdo->prepare('INSERT INTO web_kiosk_tokens (public_id, token_hash, device_code, label, created_at, expires_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
        ->execute([$id, hash('sha256', $secret), $device, 't', gmdate('Y-m-d H:i:s'), $expires, $revoked]);
    return "vkw_{$id}_{$secret}";
}

function call(PDO $pdo, array $config, string $method = 'GET', array $query = [], array $headers = []): array
{
    $r = (new KioskStatusEndpoint($pdo, $config))->handle($method, $query, $headers, '203.0.113.1');
    $r['json'] = json_decode($r['body'], true);
    return $r;
}

function status(PDO $pdo, string $device, int $remaining, int $ageSeconds, int $seq = 3, int $pulses = 1, string $boot = 'a1b2c3d4'): void
{
    $pdo->prepare("INSERT INTO device_status VALUES (?, ?, ?, ?, ?, datetime('now', ?))")
        ->execute([$device, $remaining, $boot, $seq, $pulses, "-$ageSeconds seconds"]);
}

echo "kiosk-status endpoint tests\n";

// --- happy path and fields
[$pdo, $cfg] = setup();
status($pdo, 'vendo-001', 480, 4, 7, 2);
$t = token($pdo, 'vendo-001');
$r = call($pdo, $cfg, 'GET', ['device' => 'vendo-001'], ['authorization' => "Bearer $t"]);
check($r['status'] === 200, 'valid token → 200');
$j = $r['json'];
check($j['remaining_seconds'] === 480 && $j['boot_id'] === 'a1b2c3d4' && $j['sequence_number'] === 7 && $j['last_pulses'] === 2, 'fields');
check($j['age_seconds'] >= 4 && $j['age_seconds'] <= 6, 'server-calculated age ~4 s (got ' . $j['age_seconds'] . ')');
check($j['stale'] === false && $j['status_available'] === true, 'fresh');
check(!isset($r['headers']['Access-Control-Allow-Origin']), 'no CORS header without Origin');
check(!str_contains($r['body'], 'esp-upload-secret'), 'no ESP secret in response');

// --- latest row wins when device_status keeps history
status($pdo, 'vendo-001', 900, 1, 8, 5);
$j = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t"])['json'];
check($j['remaining_seconds'] === 900 && $j['sequence_number'] === 8, 'newest row used; device param optional');

// --- X-Kiosk-Token fallback header
check(call($pdo, $cfg, 'GET', [], ['x-kiosk-token' => $t])['status'] === 200, 'X-Kiosk-Token accepted');

// --- authentication separation and failures
[$pdo, $cfg] = setup();
status($pdo, 'vendo-001', 100, 1);
check(call($pdo, $cfg)['status'] === 401, 'no token → 401');
check(call($pdo, $cfg, 'GET', [], ['authorization' => 'Bearer esp-upload-secret-123'])['status'] === 401, 'ESP8266 upload token rejected');
check(call($pdo, $cfg, 'GET', [], ['authorization' => 'Bearer vkw_0000000000000000_' . str_repeat('A', 43)])['status'] === 401, 'unknown token → 401');
$t = token($pdo, 'vendo-001');
$tampered = substr($t, 0, -1) . (substr($t, -1) === 'A' ? 'B' : 'A');
check(call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $tampered"])['status'] === 401, 'tampered secret → 401');
$rev = token($pdo, 'vendo-001', null, gmdate('Y-m-d H:i:s'));
check(call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $rev"])['status'] === 401, 'revoked → 401');
$exp = token($pdo, 'vendo-001', gmdate('Y-m-d H:i:s', time() - 1));
check(call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $exp"])['status'] === 401, 'expired → 401');

// --- ownership: token bound to one device
status($pdo, 'vendo-002', 999, 1);
$r = call($pdo, $cfg, 'GET', ['device' => 'vendo-002'], ['authorization' => "Bearer $t"]);
check($r['status'] === 403 && $r['json']['error'] === 'forbidden_device', 'other device → 403');
check(!str_contains($r['body'], '999'), 'other device data not leaked');
$t2 = token($pdo, 'vendo-002');
$j = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t2"])['json'];
check($j['device'] === 'vendo-002' && $j['remaining_seconds'] === 999, 'token reads only its bound device');

// --- stale and missing status
[$pdo, $cfg] = setup();
status($pdo, 'vendo-001', 300, 120);
$t = token($pdo, 'vendo-001');
$j = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t"])['json'];
check($j['stale'] === true && $j['age_seconds'] >= 120, 'stale after 60 s');
$t3 = token($pdo, 'vendo-404');
$j = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t3"])['json'];
check($j['status_available'] === false && $j['remaining_seconds'] === null && $j['stale'] === true, 'no status yet');

// --- CORS
[$pdo, $cfg] = setup();
status($pdo, 'vendo-001', 60, 0);
$t = token($pdo, 'vendo-001');
$r = call($pdo, $cfg, 'OPTIONS', [], ['origin' => ORIGIN]);
check($r['status'] === 204 && ($r['headers']['Access-Control-Allow-Origin'] ?? '') === ORIGIN, 'preflight from dev origin → 204');
check(str_contains($r['headers']['Access-Control-Allow-Headers'] ?? '', 'Authorization'), 'preflight allows Authorization');
$r = call($pdo, $cfg, 'OPTIONS', [], ['origin' => 'https://evil.example']);
check($r['status'] === 403 && !isset($r['headers']['Access-Control-Allow-Origin']), 'preflight from other origin refused');
$r = call($pdo, $cfg, 'GET', [], ['origin' => ORIGIN, 'authorization' => "Bearer $t"]);
check(($r['headers']['Access-Control-Allow-Origin'] ?? '') === ORIGIN && ($r['headers']['Vary'] ?? '') === 'Origin', 'GET echoes exact origin + Vary');
$r = call($pdo, $cfg, 'GET', [], ['origin' => 'https://evil.example', 'authorization' => "Bearer $t"]);
check(!isset($r['headers']['Access-Control-Allow-Origin']), 'GET from other origin gets no CORS header');
$r = call($pdo, $cfg, 'GET', [], ['origin' => ORIGIN]);
check($r['status'] === 401 && isset($r['headers']['Access-Control-Allow-Origin']), '401 readable by allowed dev origin');
check(call($pdo, $cfg, 'POST', [], ['authorization' => "Bearer $t"])['status'] === 405, 'POST → 405');

// --- rate limit (5/min in this config)
[$pdo, $cfg] = setup();
status($pdo, 'vendo-001', 60, 0);
$t = token($pdo, 'vendo-001');
$codes = [];
for ($i = 0; $i < 6; $i++) {
    $codes[] = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t"])['status'];
}
check($codes === [200, 200, 200, 200, 200, 429], 'rate limit → 429 on 6th (' . implode(',', $codes) . ')');

// --- misconfigured column mapping fails closed
[$pdo, $cfg] = setup();
status($pdo, 'vendo-001', 60, 0);
$t = token($pdo, 'vendo-001');
$cfg['status_source']['remaining_column'] = 'remaining_s';
$r = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t"]);
check($r['status'] === 500 && $r['json']['error'] === 'status_source_misconfigured', 'wrong column → 500, no data');
$cfg['status_source']['table'] = 'device_status; DROP TABLE x';
check(call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t"])['status'] === 500, 'injection in identifier rejected');

// --- long-poll: returns immediately on a newer upload, otherwise waits
[$pdo, $cfg] = setup();
$cfg['rate_limit_per_minute'] = 100;
status($pdo, 'vendo-001', 600, 0, 4, 1);
$t = token($pdo, 'vendo-001');
$first = call($pdo, $cfg, 'GET', [], ['authorization' => "Bearer $t"])['json'];
$since = ['wait' => '20', 'since_boot' => $first['boot_id'], 'since_seq' => (string) $first['sequence_number'],
    'since_reported' => (string) ($first['server_time'] - $first['age_seconds'])];

$sleeps = 0;
$sleeper = function (int $ms) use (&$sleeps): void {
    $sleeps++;
};
$r = (new KioskStatusEndpoint($pdo, $cfg, null, $sleeper))->handle('GET', $since, ['authorization' => "Bearer $t"], '1.1.1.1');
check($r['status'] === 200 && $sleeps === intdiv(20000, 300), "unchanged → waits the full window ($sleeps checks)");

$sleeps = 0;
$coinAfter = function (int $ms) use (&$sleeps, $pdo): void {
    $sleeps++;
    if ($sleeps === 2) { // a coin is uploaded ~0.6 s into the wait
        $pdo->exec("UPDATE device_status SET remaining_seconds = 1800, sequence_number = 5, last_pulses = 5, updated_at = datetime('now', '+1 seconds')");
    }
};
$r = (new KioskStatusEndpoint($pdo, $cfg, null, $coinAfter))->handle('GET', $since, ['authorization' => "Bearer $t"], '1.1.1.1');
$j = json_decode($r['body'], true);
check($sleeps === 2 && $j['sequence_number'] === 5 && $j['remaining_seconds'] === 1800, "coin → answered right after the upload ($sleeps checks)");

$sleeps = 0;
$r = (new KioskStatusEndpoint($pdo, $cfg, null, $sleeper))->handle('GET', ['wait' => '20'], ['authorization' => "Bearer $t"], '1.1.1.1');
check($sleeps === 0, 'client with no status yet gets an immediate answer');

$cfg0 = $cfg;
$cfg0['long_poll_max_seconds'] = 0;
$sleeps = 0;
(new KioskStatusEndpoint($pdo, $cfg0, null, $sleeper))->handle('GET', $since, ['authorization' => "Bearer $t"], '1.1.1.1');
check($sleeps === 0, 'long_poll_max_seconds = 0 disables waiting');

$sleeps = 0;
(new KioskStatusEndpoint($pdo, $cfg, null, $sleeper))->handle('GET', ['wait' => '999'] + $since, ['authorization' => "Bearer $t"], '1.1.1.1');
check($sleeps <= intdiv(25000, 300), 'wait is capped');

echo "\n$pass checks passed, $fail failed\n";
exit($fail === 0 ? 0 : 1);
