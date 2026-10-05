<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;

/** A customer session on one tablet, built from coin box events. */
#[Fillable(['device_id', 'site_id', 'station_no', 'boot_id', 'session_no', 'started_at', 'last_credit_at',
    'ended_at', 'end_reason', 'total_pulses', 'total_seconds', 'credit_count'])]
class KioskSession extends Model
{
    public $timestamps = false;

    protected function casts(): array
    {
        return ['started_at' => 'datetime', 'last_credit_at' => 'datetime', 'ended_at' => 'datetime'];
    }
}
