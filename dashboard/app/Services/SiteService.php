<?php

namespace App\Services;

use App\Models\Device;
use App\Models\EnrollmentCode;
use App\Models\Site;
use App\Models\SiteConfig;
use App\Models\User;
use Illuminate\Support\Facades\DB;

/** Sites, versioned configuration and device enrollment. */
class SiteService
{
    public function createSite(User $owner, string $name): Site
    {
        return DB::transaction(function () use ($owner, $name): Site {
            $site = Site::create(['owner_id' => $owner->id, 'name' => $name]);
            SiteConfig::create([
                'site_id' => $site->id,
                'version' => 1,
                'seconds_per_pulse' => SiteConfig::DEFAULT_SECONDS_PER_PULSE,
                'allowed_packages' => [],
                'local_loss_timeout_s' => SiteConfig::DEFAULT_LOCAL_LOSS_TIMEOUT_S,
                'controller_sync_interval_s' => SiteConfig::DEFAULT_CONTROLLER_SYNC_S,
                'created_by' => $owner->id,
                'created_at' => now(),
            ]);

            return $site;
        });
    }

    public static function isPackageName(string $p): bool
    {
        return strlen($p) <= 150 && preg_match('/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/', $p) === 1;
    }

    /**
     * Validates dashboard input. Returns ['errors' => [...]] or ['errors' => [], 'config' => [...]].
     *
     * @return array{errors: list<string>, config?: array<string, mixed>}
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
            if (! self::isPackageName($p)) {
                $errors[] = 'Invalid Android package name: '.mb_substr($p, 0, 80);

                continue;
            }
            $packages[$p] = true;
        }
        if (count($packages) > 50) {
            $errors[] = 'At most 50 allowed apps per site.';
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

    /** Stores a new configuration version and returns its number. */
    public function saveConfig(Site $site, User $by, array $config): int
    {
        return DB::transaction(function () use ($site, $by, $config): int {
            $version = (int) $site->configs()->lockForUpdate()->max('version') + 1;
            SiteConfig::create([
                'site_id' => $site->id,
                'version' => $version,
                'seconds_per_pulse' => $config['seconds_per_pulse'],
                'allowed_packages' => array_values($config['allowed_packages']),
                'local_loss_timeout_s' => $config['local_loss_timeout_s'],
                'controller_sync_interval_s' => $config['controller_sync_interval_s'],
                'created_by' => $by->id,
                'created_at' => now(),
            ]);

            return $version;
        });
    }

    /** Creates a one-time enrollment code and returns the plaintext (shown once). */
    public function createEnrollmentCode(Site $site, User $by, string $deviceType, ?int $station): string
    {
        $code = EnrollmentCode::generate();
        EnrollmentCode::create([
            'site_id' => $site->id,
            'device_type' => $deviceType,
            'station_no' => $deviceType === Device::TYPE_PHONE ? $station : null,
            'code_hash' => EnrollmentCode::hash($code),
            'created_by' => $by->id,
            'created_at' => now(),
            'expires_at' => now()->addSeconds(EnrollmentCode::TTL_SECONDS),
        ]);

        return $code;
    }

    /**
     * Redeems an enrollment code and creates the device.
     *
     * @return array{ok: bool, error?: string, device?: Device, token?: string}
     */
    public function enroll(string $code, string $deviceType, string $name, ?string $hardwareId): array
    {
        return DB::transaction(function () use ($code, $deviceType, $name, $hardwareId): array {
            $row = EnrollmentCode::where('code_hash', EnrollmentCode::hash($code))->first();
            if ($row === null || $row->used_at !== null || $row->expires_at->isPast()) {
                return ['ok' => false, 'error' => 'invalid_code'];
            }
            if ($row->device_type !== $deviceType) {
                return ['ok' => false, 'error' => 'wrong_device_type'];
            }
            // Single use: only one redemption can win this conditional update.
            $claimed = EnrollmentCode::whereKey($row->id)->whereNull('used_at')->update(['used_at' => now()]);
            if ($claimed !== 1) {
                return ['ok' => false, 'error' => 'invalid_code'];
            }
            $cred = Device::newCredential();
            $device = Device::create([
                'site_id' => $row->site_id,
                'device_type' => $deviceType,
                'public_id' => $cred['public_id'],
                'token_hash' => $cred['hash'],
                'name' => $name,
                'hardware_id' => $hardwareId,
                'station_no' => $row->station_no,
            ]);
            $row->update(['used_by_device_id' => $device->id]);

            return ['ok' => true, 'device' => $device, 'token' => $cred['token']];
        });
    }
}
