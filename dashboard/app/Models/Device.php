<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Attributes\Hidden;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * An enrolled coin box (controller) or tablet (phone). Credentials have the form
 * vkd_<public_id>_<secret>; only SHA-256(secret) is stored.
 */
#[Fillable(['site_id', 'device_type', 'public_id', 'token_hash', 'name', 'hardware_id', 'station_no', 'held_pulses', 'last_poll_at',
    'revoked_at', 'last_seen_at', 'last_ip', 'sw_version', 'config_version_applied', 'status_json',
    'status_boot_id', 'status_uptime_ms', 'status_reported_at', 'admin_unlock_id', 'admin_unlock_expires_at', 'tap_admin_expires_at'])]
#[Hidden(['token_hash'])]
class Device extends Model
{
    public const TYPE_PHONE = 'phone';

    public const TYPE_CONTROLLER = 'controller';

    protected function casts(): array
    {
        return [
            'revoked_at' => 'datetime',
            'last_seen_at' => 'datetime',
            'status_reported_at' => 'datetime',
            'status_json' => 'array',
            'admin_unlock_expires_at' => 'datetime',
            'tap_admin_expires_at' => 'datetime',
            'last_poll_at' => 'datetime',
        ];
    }

    /** Seconds an "open admin" request waits for the tablet's next heartbeat. */
    public const ADMIN_UNLOCK_TTL_S = 120;

    public function adminUnlockPending(): bool
    {
        return $this->admin_unlock_id !== null && $this->admin_unlock_expires_at?->isFuture() === true;
    }

    /** Seconds an "enable 10 taps" request waits for the tablet's next heartbeat. */
    public const TAP_ADMIN_TTL_S = 120;

    public function tapAdminPending(): bool
    {
        return $this->tap_admin_expires_at?->isFuture() === true;
    }

    /**
     * A kiosk coin box: enrolled with a tablet number and serving only that
     * tablet, which it knows as its station 1. A coin box without a number is
     * the shared box whose stations are the site's tablet numbers.
     */
    public function isKioskCoinBox(): bool
    {
        return $this->device_type === self::TYPE_CONTROLLER && $this->station_no !== null;
    }

    /** Site tablet number for a station number the coin box reported (null: not one of ours). */
    public function siteStation(int $local): ?int
    {
        if (! $this->isKioskCoinBox()) {
            return $local;
        }

        return match ($local) {
            0 => 0,
            1 => (int) $this->station_no,
            default => null,
        };
    }

    /** Station number the coin box knows a site tablet by. */
    public function localStation(int $station): int
    {
        return $this->isKioskCoinBox() ? 1 : $station;
    }

    /** A tablet that takes "add time" and "end session" itself, over its heartbeat (app 1.2.0+). */
    public function takesDashboardTime(): bool
    {
        return $this->device_type === self::TYPE_PHONE && in_array('dashboard_time', (array) $this->status('features', []), true);
    }

    public function site(): BelongsTo
    {
        return $this->belongsTo(Site::class);
    }

    /** @return array{public_id:string, token:string, hash:string} */
    public static function newCredential(): array
    {
        $publicId = bin2hex(random_bytes(8));
        $secret = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');

        return ['public_id' => $publicId, 'token' => 'vkd_'.$publicId.'_'.$secret, 'hash' => hash('sha256', $secret)];
    }

    /**
     * Cloud presence: online / offline / never / revoked. Display only — it is
     * never used to authorise paid access.
     */
    public function presence(): string
    {
        if ($this->revoked_at !== null) {
            return 'revoked';
        }
        if ($this->last_seen_at === null) {
            return 'never';
        }
        $stale = $this->device_type === self::TYPE_PHONE
            ? (int) config('vendo.phone_stale_seconds')
            : (int) config('vendo.controller_stale_seconds');

        return $this->last_seen_at->diffInSeconds(now()) > $stale ? 'offline' : 'online';
    }

    /** A value from the device's last status report. */
    public function status(string $key, mixed $default = null): mixed
    {
        return ($this->status_json ?? [])[$key] ?? $default;
    }
}
