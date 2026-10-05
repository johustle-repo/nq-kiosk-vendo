<?php

declare(strict_types=1);

namespace Vendo\Service;

use Vendo\Auth\DeviceAuth;
use Vendo\Clock;
use Vendo\Db;

final class KioskService
{
    public const DEFAULT_SECONDS_PER_PULSE = 240;
    public const DEFAULT_LOCAL_LOSS_TIMEOUT_S = 30;
    public const DEFAULT_CONTROLLER_SYNC_S = 15;
    public const ENROLL_CODE_TTL_S = 1800;
    private const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

    public function __construct(private readonly Db $db)
    {
    }

    // ---- Kiosks (every lookup is scoped to the owning administrator) ----

    public function createKiosk(int $adminId, string $name): int
    {
        return $this->db->tx(function () use ($adminId, $name): int {
            $id = $this->db->insert(
                'INSERT INTO kiosks (owner_admin_id, name, created_at) VALUES (?, ?, ?)',
                [$adminId, $name, Clock::sql()]
            );
            $this->db->exec(
                'INSERT INTO kiosk_configs (kiosk_id, version, seconds_per_pulse, allowed_packages, local_loss_timeout_s, controller_sync_interval_s, created_by_admin_id, created_at)
                 VALUES (?, 1, ?, ?, ?, ?, ?, ?)',
                [$id, self::DEFAULT_SECONDS_PER_PULSE, '[]', self::DEFAULT_LOCAL_LOSS_TIMEOUT_S, self::DEFAULT_CONTROLLER_SYNC_S, $adminId, Clock::sql()]
            );
            return $id;
        });
    }

    /** @return array<string,mixed>|null */
    public function kioskForAdmin(int $kioskId, int $adminId): ?array
    {
        return $this->db->one('SELECT * FROM kiosks WHERE id = ? AND owner_admin_id = ?', [$kioskId, $adminId]);
    }

    /** @return list<array<string,mixed>> */
    public function kiosksForAdmin(int $adminId): array
    {
        return $this->db->all('SELECT * FROM kiosks WHERE owner_admin_id = ? ORDER BY name', [$adminId]);
    }

    /** @return array<string,mixed>|null */
    public function deviceForAdmin(int $deviceId, int $adminId): ?array
    {
        return $this->db->one(
            'SELECT d.* FROM devices d JOIN kiosks k ON k.id = d.kiosk_id WHERE d.id = ? AND k.owner_admin_id = ?',
            [$deviceId, $adminId]
        );
    }

    // ---- Configuration (versioned, immutable rows) ----

    /** @return array<string,mixed> */
    public function currentConfig(int $kioskId): array
    {
        $row = $this->db->one('SELECT * FROM kiosk_configs WHERE kiosk_id = ? ORDER BY version DESC LIMIT 1', [$kioskId]);
        if ($row === null) {
            throw new \RuntimeException('Kiosk has no configuration');
        }
        $row['allowed_packages'] = json_decode((string) $row['allowed_packages'], true) ?: [];
        return $row;
    }

    /** @return list<array<string,mixed>> */
    public function configHistory(int $kioskId, int $limit = 10): array
    {
        return $this->db->all(
            'SELECT c.*, a.username FROM kiosk_configs c LEFT JOIN admins a ON a.id = c.created_by_admin_id
             WHERE c.kiosk_id = ? ORDER BY c.version DESC LIMIT ' . max(1, min(100, $limit)),
            [$kioskId]
        );
    }

    /**
     * Validates input and returns either errors or a normalised config.
     *
     * @return array{errors:list<string>, config?:array<string,mixed>}
     */
    public static function validateConfig(array $in): array
    {
        $errors = [];
        $spp = filter_var($in['seconds_per_pulse'] ?? null, FILTER_VALIDATE_INT, ['options' => ['min_range' => 10, 'max_range' => 3600]]);
        if ($spp === false) {
            $errors[] = 'Seconds per peso must be a whole number from 10 to 3600.';
        }
        $loss = filter_var($in['local_loss_timeout_s'] ?? null, FILTER_VALIDATE_INT, ['options' => ['min_range' => 5, 'max_range' => 600]]);
        if ($loss === false) {
            $errors[] = 'Connection-loss timeout must be 5 to 600 seconds.';
        }
        $sync = filter_var($in['controller_sync_interval_s'] ?? null, FILTER_VALIDATE_INT, ['options' => ['min_range' => 5, 'max_range' => 300]]);
        if ($sync === false) {
            $errors[] = 'Controller sync interval must be 5 to 300 seconds.';
        }
        $raw = $in['allowed_packages'] ?? '';
        $lines = is_array($raw) ? $raw : preg_split('/[\s,]+/', (string) $raw);
        $packages = [];
        foreach ($lines ?: [] as $p) {
            $p = trim((string) $p);
            if ($p === '') {
                continue;
            }
            if (!self::isPackageName($p)) {
                $errors[] = 'Invalid Android package name: ' . mb_substr($p, 0, 80);
                continue;
            }
            $packages[$p] = true;
        }
        if (count($packages) > 50) {
            $errors[] = 'At most 50 allowed apps per kiosk.';
        }
        if ($errors !== []) {
            return ['errors' => $errors];
        }
        return ['errors' => [], 'config' => [
            'seconds_per_pulse' => $spp,
            'local_loss_timeout_s' => $loss,
            'controller_sync_interval_s' => $sync,
            'allowed_packages' => array_keys($packages),
        ]];
    }

    public static function isPackageName(string $p): bool
    {
        return strlen($p) <= 150 && preg_match('/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/', $p) === 1;
    }

    /** Stores a new configuration version and returns its number. */
    public function saveConfig(int $kioskId, int $adminId, array $config): int
    {
        return $this->db->tx(function () use ($kioskId, $adminId, $config): int {
            $row = $this->db->one('SELECT MAX(version) AS v FROM kiosk_configs WHERE kiosk_id = ?', [$kioskId]);
            $version = (int) ($row['v'] ?? 0) + 1;
            $this->db->exec(
                'INSERT INTO kiosk_configs (kiosk_id, version, seconds_per_pulse, allowed_packages, local_loss_timeout_s, controller_sync_interval_s, created_by_admin_id, created_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                [$kioskId, $version, $config['seconds_per_pulse'], json_encode(array_values($config['allowed_packages'])),
                    $config['local_loss_timeout_s'], $config['controller_sync_interval_s'], $adminId, Clock::sql()]
            );
            return $version;
        });
    }

    // ---- Enrollment ----

    /** Creates a one-time enrollment code. Returns the plaintext code (shown once). */
    public function createEnrollmentCode(int $kioskId, int $adminId, string $deviceType): string
    {
        $chars = '';
        for ($i = 0; $i < 10; $i++) {
            $chars .= self::CODE_ALPHABET[random_int(0, strlen(self::CODE_ALPHABET) - 1)];
        }
        $code = substr($chars, 0, 5) . '-' . substr($chars, 5);
        $this->db->exec(
            'INSERT INTO enrollment_codes (kiosk_id, device_type, code_hash, created_by_admin_id, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)',
            [$kioskId, $deviceType, self::hashCode($code), $adminId, Clock::sql(), Clock::sql(Clock::now() + self::ENROLL_CODE_TTL_S)]
        );
        return $code;
    }

    public static function normaliseCode(string $code): string
    {
        $c = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $code) ?? '');
        return strlen($c) === 10 ? substr($c, 0, 5) . '-' . substr($c, 5) : $c;
    }

    public static function hashCode(string $code): string
    {
        return hash('sha256', 'vendo-enroll:' . self::normaliseCode($code));
    }

    /**
     * Redeems an enrollment code and creates the device.
     *
     * @return array{ok:bool, error?:string, device_id?:int, kiosk_id?:int, public_id?:string, token?:string}
     */
    public function enroll(string $code, string $deviceType, string $name, ?string $hardwareId): array
    {
        return $this->db->tx(function () use ($code, $deviceType, $name, $hardwareId): array {
            $row = $this->db->one('SELECT * FROM enrollment_codes WHERE code_hash = ?', [self::hashCode($code)]);
            if ($row === null || $row['used_at'] !== null || (Clock::parse($row['expires_at']) ?? 0) <= Clock::now()) {
                return ['ok' => false, 'error' => 'invalid_code'];
            }
            if ($row['device_type'] !== $deviceType) {
                return ['ok' => false, 'error' => 'wrong_device_type'];
            }
            // Single use: the conditional update guarantees only one redemption wins.
            $claimed = $this->db->exec('UPDATE enrollment_codes SET used_at = ? WHERE id = ? AND used_at IS NULL', [Clock::sql(), $row['id']]);
            if ($claimed !== 1) {
                return ['ok' => false, 'error' => 'invalid_code'];
            }
            $cred = DeviceAuth::newCredential();
            $deviceId = $this->db->insert(
                'INSERT INTO devices (kiosk_id, device_type, public_id, token_hash, name, hardware_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                [$row['kiosk_id'], $deviceType, $cred['public_id'], $cred['hash'], $name, $hardwareId, Clock::sql()]
            );
            $this->db->exec('UPDATE enrollment_codes SET used_by_device_id = ? WHERE id = ?', [$deviceId, $row['id']]);
            return ['ok' => true, 'device_id' => $deviceId, 'kiosk_id' => (int) $row['kiosk_id'], 'public_id' => $cred['public_id'], 'token' => $cred['token']];
        });
    }

    // ---- Device presentation helpers ----

    /** @return list<array<string,mixed>> */
    public function devicesForKiosk(int $kioskId): array
    {
        return $this->db->all('SELECT * FROM devices WHERE kiosk_id = ? ORDER BY device_type, created_at', [$kioskId]);
    }

    /**
     * Cloud presence of a device: online / offline (stale) / never / revoked.
     * This is only what the device last reported to the cloud; it is never
     * used to authorise paid access.
     */
    public static function presence(array $device, int $staleAfterS): string
    {
        if ($device['revoked_at'] !== null) {
            return 'revoked';
        }
        $seen = Clock::parse($device['last_seen_at'] ?? null);
        if ($seen === null) {
            return 'never';
        }
        return (Clock::now() - $seen) > $staleAfterS ? 'offline' : 'online';
    }
}
