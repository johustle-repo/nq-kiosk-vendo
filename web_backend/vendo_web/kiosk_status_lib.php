<?php

declare(strict_types=1);

namespace VendoWeb;

use PDO;
use RuntimeException;

/**
 * GET /api/kiosk-status.php — read-only timer status for the browser kiosk.
 *
 * Authentication: a web/kiosk token  "vkw_<16 hex>_<43 base64url>"  sent as
 * `Authorization: Bearer …` (or `X-Kiosk-Token: …` when a host strips the
 * Authorization header). These tokens live in web_kiosk_tokens, are separate
 * from the ESP8266 upload credential, and are each bound to ONE device code.
 *
 * The response reports what the coin controller last uploaded plus a
 * server-calculated age. It never grants or changes time.
 */
final class KioskStatusEndpoint
{
    private const TOKEN_RE = '/^vkw_([0-9a-f]{16})_([A-Za-z0-9_-]{43})$/';
    private const IDENT_RE = '/^[A-Za-z_][A-Za-z0-9_]{0,63}$/';

    /** Columns verified against the database once per request. */
    private bool $columnsChecked = false;

    /** @var callable(int):void */
    private $sleepMs;

    /**
     * @param array<string,mixed> $config
     * @param (callable(int):void)|null $sleepMs injectable for tests
     */
    public function __construct(
        private readonly PDO $pdo,
        private readonly array $config,
        private readonly ?int $fixedNow = null,
        ?callable $sleepMs = null,
    ) {
        $this->sleepMs = $sleepMs ?? static function (int $ms): void {
            usleep($ms * 1000);
        };
    }

    private function now(): int
    {
        return $this->fixedNow ?? time();
    }

    private function driver(): string
    {
        return (string) $this->pdo->getAttribute(PDO::ATTR_DRIVER_NAME);
    }

    /**
     * @param array<string,string> $query
     * @param array<string,string> $headers lower-case names
     * @return array{status:int, headers:array<string,string>, body:string}
     */
    public function handle(string $method, array $query, array $headers, string $ip): array
    {
        $cors = $this->corsHeaders($headers['origin'] ?? null);

        if ($method === 'OPTIONS') {
            // Preflight: answer only for an explicitly allowed development origin.
            return $cors === []
                ? self::json(403, ['ok' => false, 'error' => 'origin_not_allowed'], ['Vary' => 'Origin'])
                : ['status' => 204, 'headers' => $cors + ['Vary' => 'Origin'], 'body' => ''];
        }
        if ($method !== 'GET') {
            return self::json(405, ['ok' => false, 'error' => 'method_not_allowed'], $cors + ['Allow' => 'GET, OPTIONS']);
        }

        $token = $this->extractToken($headers);
        $row = $token === null ? null : $this->authenticate($token);
        if ($row === null) {
            return self::json(401, ['ok' => false, 'error' => 'unauthorized'], $cors + ['WWW-Authenticate' => 'Bearer']);
        }

        // Ownership: a token may only read the device it is bound to.
        $requested = $query['device'] ?? null;
        if ($requested !== null && !hash_equals((string) $row['device_code'], (string) $requested)) {
            return self::json(403, ['ok' => false, 'error' => 'forbidden_device'], $cors);
        }

        if (!$this->withinRateLimit($row, $ip)) {
            return self::json(429, ['ok' => false, 'error' => 'rate_limited'], $cors + ['Retry-After' => '10']);
        }

        // Long-poll (optional): the client sends what it already has; the server
        // answers as soon as a NEWER upload exists, or after `wait` seconds.
        $maxWait = max(0, min(25, (int) ($this->config['long_poll_max_seconds'] ?? 20)));
        $wait = max(0, min($maxWait, (int) ($query['wait'] ?? 0)));
        $since = [
            'boot' => (string) ($query['since_boot'] ?? ''),
            'seq' => isset($query['since_seq']) && is_numeric($query['since_seq']) ? (int) $query['since_seq'] : null,
            'reported' => isset($query['since_reported']) && is_numeric($query['since_reported']) ? (int) $query['since_reported'] : null,
        ];
        $intervalMs = max(100, min(2000, (int) ($this->config['long_poll_check_ms'] ?? 300)));

        try {
            $device = (string) $row['device_code'];
            $status = $this->readStatus($device);
            if ($wait > 0) {
                if (function_exists('set_time_limit')) {
                    @set_time_limit($wait + 15);
                }
                $checks = intdiv($wait * 1000, $intervalMs);
                for ($i = 0; $i < $checks && !self::isNewer($status, $since); $i++) {
                    ($this->sleepMs)($intervalMs);
                    if (connection_aborted()) {
                        break;
                    }
                    $status = $this->readStatus($device);
                }
            }
        } catch (RuntimeException $e) {
            error_log('[kiosk-status] ' . $e->getMessage());
            return self::json(500, ['ok' => false, 'error' => 'status_source_misconfigured'], $cors);
        }
        return self::json(200, $status, $cors);
    }

    /** True when $status differs from what the client said it already has. */
    private static function isNewer(array $status, array $since): bool
    {
        if ($since['seq'] === null && $since['reported'] === null && $since['boot'] === '') {
            return true; // client has nothing yet
        }
        if (!$status['status_available']) {
            return $since['boot'] !== '';
        }
        $reported = $status['server_time'] - $status['age_seconds'];
        return $status['boot_id'] !== $since['boot']
            || $status['sequence_number'] !== $since['seq']
            || $reported !== $since['reported'];
    }

    // ------------------------------------------------------------------ CORS

    /** @return array<string,string> */
    private function corsHeaders(?string $origin): array
    {
        $allowed = $this->config['cors_allowed_origins'] ?? [];
        if ($origin === null || !is_array($allowed) || !in_array($origin, $allowed, true)) {
            return [];
        }
        return [
            'Access-Control-Allow-Origin' => $origin, // exact echo of an allow-listed origin, never '*'
            'Access-Control-Allow-Methods' => 'GET, OPTIONS',
            'Access-Control-Allow-Headers' => 'Authorization, X-Kiosk-Token',
            'Access-Control-Max-Age' => '600',
            'Vary' => 'Origin',
        ];
    }

    // ------------------------------------------------------------------ auth

    /** @param array<string,string> $headers */
    private function extractToken(array $headers): ?string
    {
        $auth = $headers['authorization'] ?? '';
        if (preg_match('/^Bearer\s+(\S+)$/i', $auth, $m)) {
            return $m[1];
        }
        $alt = $headers['x-kiosk-token'] ?? '';
        return $alt !== '' ? $alt : null;
    }

    /** @return array<string,mixed>|null */
    private function authenticate(string $token): ?array
    {
        // ESP8266 upload tokens or anything else simply do not match this format.
        if (!preg_match(self::TOKEN_RE, $token, $m)) {
            return null;
        }
        $st = $this->pdo->prepare('SELECT * FROM web_kiosk_tokens WHERE public_id = ?');
        $st->execute([$m[1]]);
        $row = $st->fetch(PDO::FETCH_ASSOC);
        if ($row === false || !hash_equals((string) $row['token_hash'], hash('sha256', $m[2]))) {
            return null;
        }
        if ($row['revoked_at'] !== null) {
            return null;
        }
        if ($row['expires_at'] !== null && strtotime($row['expires_at'] . ' UTC') <= $this->now()) {
            return null;
        }
        return $row;
    }

    /** Fixed one-minute window per token, stored on the token row. */
    private function withinRateLimit(array $row, string $ip): bool
    {
        $now = $this->now();
        $limit = (int) ($this->config['rate_limit_per_minute'] ?? 60);
        // Assignment order matters for MySQL (later SETs see earlier ones): hits first.
        $up = $this->pdo->prepare(
            'UPDATE web_kiosk_tokens SET
               window_hits = CASE WHEN window_start + 60 <= ? THEN 1 ELSE window_hits + 1 END,
               window_start = CASE WHEN window_start + 60 <= ? THEN ? ELSE window_start END,
               last_used_at = ?, last_ip = ?
             WHERE id = ?'
        );
        // Bind integers as integers (string binding breaks numeric comparison in some drivers).
        $up->bindValue(1, $now, PDO::PARAM_INT);
        $up->bindValue(2, $now, PDO::PARAM_INT);
        $up->bindValue(3, $now, PDO::PARAM_INT);
        $up->bindValue(4, gmdate('Y-m-d H:i:s', $now));
        $up->bindValue(5, substr($ip, 0, 45));
        $up->bindValue(6, (int) $row['id'], PDO::PARAM_INT);
        $up->execute();
        $st = $this->pdo->prepare('SELECT window_hits FROM web_kiosk_tokens WHERE id = ?');
        $st->execute([$row['id']]);
        return (int) $st->fetchColumn() <= $limit;
    }

    // ------------------------------------------------------------------ status

    /** @return array<string,mixed> */
    private function readStatus(string $deviceCode): array
    {
        $src = $this->config['status_source'] ?? [];
        $cols = [];
        foreach (['table', 'device_column', 'remaining_column', 'boot_column', 'sequence_column', 'pulses_column', 'updated_column'] as $k) {
            $v = (string) ($src[$k] ?? '');
            if (!preg_match(self::IDENT_RE, $v)) {
                throw new RuntimeException("config status_source.$k is not a valid identifier");
            }
            $cols[$k] = $v;
        }
        if (!$this->columnsChecked) {
            $this->assertColumnsExist($cols);
            $this->columnsChecked = true;
        }
        $q = static fn (string $ident): string => '`' . $ident . '`';
        $updated = $q($cols['updated_column']);
        $unix = ($src['updated_type'] ?? 'datetime') === 'unix';
        $mysql = $this->driver() === 'mysql';

        // Age is computed with the DATABASE clock so it matches how the upload
        // endpoint wrote the timestamp (e.g. with NOW()).
        if ($mysql) {
            $nowExpr = 'UNIX_TIMESTAMP()';
            $ageExpr = $unix ? "UNIX_TIMESTAMP() - $updated" : "TIMESTAMPDIFF(SECOND, $updated, NOW())";
        } else {
            $nowExpr = "CAST(strftime('%s','now') AS INTEGER)";
            $ageExpr = $unix ? "CAST(strftime('%s','now') AS INTEGER) - $updated"
                : "CAST(strftime('%s','now') AS INTEGER) - CAST(strftime('%s', $updated) AS INTEGER)";
        }
        $sql = sprintf(
            'SELECT %s AS remaining, %s AS boot, %s AS seq, %s AS pulses, (%s) AS age, %s AS db_now
             FROM %s WHERE %s = ? ORDER BY %s DESC LIMIT 1',
            $q($cols['remaining_column']), $q($cols['boot_column']), $q($cols['sequence_column']),
            $q($cols['pulses_column']), $ageExpr, $nowExpr, $q($cols['table']), $q($cols['device_column']), $updated
        );
        $st = $this->pdo->prepare($sql);
        $st->execute([$deviceCode]);
        $r = $st->fetch(PDO::FETCH_ASSOC);

        $staleAfter = (int) ($this->config['stale_after_seconds'] ?? 60);
        if ($r === false) {
            $dbNow = (int) $this->pdo->query("SELECT $nowExpr")->fetchColumn();
            return [
                'ok' => true,
                'device' => $deviceCode,
                'status_available' => false,
                'remaining_seconds' => null,
                'boot_id' => null,
                'sequence_number' => null,
                'last_pulses' => null,
                'age_seconds' => null,
                'stale' => true,
                'stale_after_seconds' => $staleAfter,
                'server_time' => $dbNow,
            ];
        }
        $age = (int) $r['age'];
        if ($age < -5) {
            // Timestamp in the future: upload endpoint and database disagree on time zone.
            error_log("[kiosk-status] $deviceCode status timestamp is {$age}s in the future; check updated_type / time zones");
        }
        $age = max(0, $age);
        $dbNow = (int) $r['db_now'];
        return [
            'ok' => true,
            'device' => $deviceCode,
            'status_available' => true,
            'remaining_seconds' => max(0, (int) $r['remaining']),
            'boot_id' => substr(preg_replace('/[^\x21-\x7E]/', '', (string) $r['boot']) ?? '', 0, 32),
            'sequence_number' => (int) $r['seq'],
            'last_pulses' => max(0, (int) $r['pulses']),
            'age_seconds' => $age,
            'reported_at' => gmdate('Y-m-d\TH:i:s\Z', $dbNow - $age),
            'stale' => $age > $staleAfter,
            'stale_after_seconds' => $staleAfter,
            'server_time' => $dbNow,
        ];
    }

    /** Fails closed with a precise (logged, not returned) message if the mapping is wrong. */
    private function assertColumnsExist(array $cols): void
    {
        if ($this->driver() === 'mysql') {
            $st = $this->pdo->prepare('SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?');
            $st->execute([$cols['table']]);
            $existing = $st->fetchAll(PDO::FETCH_COLUMN);
        } else {
            $existing = array_column($this->pdo->query('PRAGMA table_info(`' . $cols['table'] . '`)')->fetchAll(PDO::FETCH_ASSOC), 'name');
        }
        if ($existing === []) {
            throw new RuntimeException("table {$cols['table']} not found");
        }
        foreach ($cols as $k => $c) {
            if ($k !== 'table' && !in_array($c, $existing, true)) {
                throw new RuntimeException("column {$cols['table']}.$c (status_source.$k) not found; existing: " . implode(', ', $existing));
            }
        }
    }

    /** @return array{status:int, headers:array<string,string>, body:string} */
    private static function json(int $status, array $body, array $headers = []): array
    {
        return [
            'status' => $status,
            'headers' => $headers + ['Content-Type' => 'application/json; charset=utf-8'],
            'body' => json_encode($body, JSON_UNESCAPED_SLASHES) ?: '{}',
        ];
    }
}

/** Entry point used by public_html/api/kiosk-status.php. */
function run_from_globals(string $configFile): void
{
    header('Cache-Control: no-store, max-age=0');
    header('X-Content-Type-Options: nosniff');
    try {
        if (!is_file($configFile)) {
            throw new RuntimeException('config.php missing');
        }
        $config = require $configFile;
        $db = $config['db'];
        // 'dsn' is for local development only (e.g. sqlite:/path/dev.sqlite from tools/dev-sim.php).
        $pdo = new PDO(
            $db['dsn'] ?? sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $db['host'], (int) ($db['port'] ?? 3306), $db['name']),
            $db['user'] ?? null,
            $db['pass'] ?? null,
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => false]
        );
    } catch (\Throwable $e) {
        error_log('[kiosk-status] startup: ' . $e->getMessage());
        http_response_code(503);
        header('Content-Type: application/json; charset=utf-8');
        echo '{"ok":false,"error":"unavailable"}';
        return;
    }

    $headers = [];
    foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION'] as $k) {
        if (!isset($headers['authorization']) && !empty($_SERVER[$k])) {
            $headers['authorization'] = (string) $_SERVER[$k];
        }
    }
    if (!isset($headers['authorization']) && function_exists('getallheaders')) {
        foreach (getallheaders() as $name => $value) {
            if (strtolower((string) $name) === 'authorization') {
                $headers['authorization'] = (string) $value;
            }
        }
    }
    if (!empty($_SERVER['HTTP_X_KIOSK_TOKEN'])) {
        $headers['x-kiosk-token'] = (string) $_SERVER['HTTP_X_KIOSK_TOKEN'];
    }
    if (!empty($_SERVER['HTTP_ORIGIN'])) {
        $headers['origin'] = (string) $_SERVER['HTTP_ORIGIN'];
    }
    $query = array_map('strval', array_filter($_GET, 'is_scalar'));

    try {
        $r = (new KioskStatusEndpoint($pdo, $config))->handle(
            strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET')),
            $query,
            $headers,
            (string) ($_SERVER['REMOTE_ADDR'] ?? '')
        );
    } catch (\Throwable $e) {
        error_log('[kiosk-status] ' . get_class($e) . ': ' . $e->getMessage());
        $r = ['status' => 500, 'headers' => ['Content-Type' => 'application/json; charset=utf-8'], 'body' => '{"ok":false,"error":"server_error"}'];
    }
    http_response_code($r['status']);
    foreach ($r['headers'] as $k => $v) {
        header("$k: $v");
    }
    echo $r['body'];
}
