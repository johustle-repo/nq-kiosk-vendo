<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;

/** One-time, typed, expiring code that enrolls a device into a site. */
#[Fillable(['site_id', 'device_type', 'station_no', 'code_hash', 'created_by', 'created_at', 'expires_at',
    'used_at', 'used_by_device_id'])]
class EnrollmentCode extends Model
{
    public const UPDATED_AT = null;

    public const TTL_SECONDS = 1800;

    private const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

    protected function casts(): array
    {
        return ['created_at' => 'datetime', 'expires_at' => 'datetime', 'used_at' => 'datetime'];
    }

    /** A new plaintext code such as "K7M2Q-9XRTB" (shown to the admin once). */
    public static function generate(): string
    {
        $c = '';
        for ($i = 0; $i < 10; $i++) {
            $c .= self::ALPHABET[random_int(0, strlen(self::ALPHABET) - 1)];
        }

        return substr($c, 0, 5).'-'.substr($c, 5);
    }

    public static function normalise(string $code): string
    {
        $c = strtoupper(preg_replace('/[^A-Za-z0-9]/', '', $code) ?? '');

        return strlen($c) === 10 ? substr($c, 0, 5).'-'.substr($c, 5) : $c;
    }

    public static function hash(string $code): string
    {
        return hash('sha256', 'vendo-enroll:'.self::normalise($code));
    }
}
