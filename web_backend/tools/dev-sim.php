<?php

declare(strict_types=1);

// LOCAL DEVELOPMENT ONLY — simulates the ESP8266 writing device_status so the
// browser kiosk can be tested without hardware or the production database.
//
//   php web_backend/tools/dev-sim.php init          # create dev DB, config.php, token
//   php web_backend/tools/dev-sim.php coin 5        # insert a 5-pulse coin (+20 min)
//   php web_backend/tools/dev-sim.php run           # keep "uploading" every 10 s; Ctrl+C → status turns stale after 60 s
//
// Uses web_backend/vendo_web/dev.sqlite and writes web_backend/vendo_web/config.php
// (both git-ignored). Never deploy them.

if (PHP_SAPI !== 'cli') {
    exit(1);
}
$dir = dirname(__DIR__) . '/vendo_web';
$dbFile = $dir . '/dev.sqlite';
$cmd = $argv[1] ?? 'help';
const DEVICE = 'vendo-001';
const SECONDS_PER_PULSE = 240;

function pdo(string $file): PDO
{
    $p = new PDO('sqlite:' . $file, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    return $p;
}

/** Remaining time "on the controller" right now, derived from the last upload. */
function currentStatus(PDO $p): array
{
    $r = $p->query("SELECT remaining_seconds, sequence_number, boot_id, CAST(strftime('%s','now') AS INTEGER) - CAST(strftime('%s', updated_at) AS INTEGER) AS age FROM device_status WHERE device_id = 'vendo-001'")->fetch(PDO::FETCH_ASSOC);
    return ['remaining' => max(0, (int) $r['remaining_seconds'] - (int) $r['age']), 'seq' => (int) $r['sequence_number'], 'boot' => $r['boot_id']];
}

switch ($cmd) {
    case 'init':
        @unlink($dbFile);
        $p = pdo($dbFile);
        // Stand-in for the production table written by api/status.php.
        $p->exec("CREATE TABLE device_status (device_id TEXT PRIMARY KEY, remaining_seconds INTEGER NOT NULL, boot_id TEXT NOT NULL,
                  sequence_number INTEGER NOT NULL, last_pulses INTEGER NOT NULL, updated_at TEXT NOT NULL)");
        $sql = (string) file_get_contents($dir . '/migrations/001_web_kiosk_tokens.sql');
        $sql = preg_replace('/^\s*--.*$/m', '', $sql);
        $sql = str_replace('INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT', $sql);
        $sql = preg_replace('/\)\s*ENGINE=[^;]*;/', ');', $sql);
        $p->exec(str_replace(' UNSIGNED', '', $sql));
        $boot = bin2hex(random_bytes(4));
        $p->prepare("INSERT INTO device_status VALUES (?, 0, ?, 0, 0, datetime('now'))")->execute([DEVICE, $boot]);

        $publicId = bin2hex(random_bytes(8));
        $secret = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
        $p->prepare("INSERT INTO web_kiosk_tokens (public_id, token_hash, device_code, label, created_at) VALUES (?, ?, ?, 'dev', datetime('now'))")
            ->execute([$publicId, hash('sha256', $secret), DEVICE]);

        $config = "<?php\n// LOCAL DEVELOPMENT config written by tools/dev-sim.php — do not deploy.\nreturn [\n"
            . "    'db' => ['dsn' => " . var_export('sqlite:' . str_replace('\\', '/', $dbFile), true) . "],\n"
            . "    'status_source' => ['table' => 'device_status', 'device_column' => 'device_id', 'remaining_column' => 'remaining_seconds',\n"
            . "        'boot_column' => 'boot_id', 'sequence_column' => 'sequence_number', 'pulses_column' => 'last_pulses',\n"
            . "        'updated_column' => 'updated_at', 'updated_type' => 'datetime'],\n"
            . "    'stale_after_seconds' => 60,\n    'rate_limit_per_minute' => 60,\n"
            . "    'cors_allowed_origins' => ['http://localhost:5173'],\n];\n";
        file_put_contents($dir . '/config.php', $config);
        echo "Dev database: $dbFile\nConfig:       $dir/config.php (CORS origin http://localhost:5173)\n\n";
        echo "Browser token for vendo-001 (paste into the web kiosk):\n\n  vkw_{$publicId}_{$secret}\n";
        break;

    case 'coin':
        $pulses = max(1, (int) ($argv[2] ?? 1));
        $p = pdo($dbFile);
        $c = currentStatus($p);
        $p->prepare("UPDATE device_status SET remaining_seconds = ?, sequence_number = ?, last_pulses = ?, updated_at = datetime('now') WHERE device_id = ?")
            ->execute([$c['remaining'] + $pulses * SECONDS_PER_PULSE, $c['seq'] + 1, $pulses, DEVICE]);
        printf("Coin: %d pulse(s) → +%d min, remaining now %d s, seq %d\n", $pulses, $pulses * SECONDS_PER_PULSE / 60, $c['remaining'] + $pulses * SECONDS_PER_PULSE, $c['seq'] + 1);
        break;

    case 'run':
        $p = pdo($dbFile);
        echo "Uploading status every 10 s (Ctrl+C to stop; then status turns stale)...\n";
        while (true) {
            $c = currentStatus($p);
            $p->prepare("UPDATE device_status SET remaining_seconds = ?, updated_at = datetime('now') WHERE device_id = ?")->execute([$c['remaining'], DEVICE]);
            printf("[%s] upload remaining=%d seq=%d\n", date('H:i:s'), $c['remaining'], $c['seq']);
            sleep(10);
        }

    default:
        echo "Usage: php dev-sim.php init | coin <pulses> | run\n";
}
