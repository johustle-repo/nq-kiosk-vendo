<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;

/**
 * Event reported by the coin box, idempotent on (device, boot_id, seq).
 * Types: credit, expire, held (coin with no tablet selected, station 0),
 * assign (held coins given to a tablet), admin_credit, admin_end.
 */
#[Fillable(['device_id', 'site_id', 'station_no', 'boot_id', 'seq', 'event_type', 'session_no', 'pulses',
    'seconds_added', 'rate_version', 'remaining_after', 'device_uptime_ms', 'command_id', 'occurred_at', 'received_at'])]
class CoinEvent extends Model
{
    public $timestamps = false;

    public const TYPES = ['credit', 'expire', 'held', 'assign', 'admin_credit', 'admin_end'];

    /** Event types that represent money put into the coin box (one pulse = one peso). */
    public const MONEY_TYPES = ['credit', 'held'];

    protected function casts(): array
    {
        return ['occurred_at' => 'datetime', 'received_at' => 'datetime'];
    }
}
