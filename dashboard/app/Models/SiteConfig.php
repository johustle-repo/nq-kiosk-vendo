<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** Immutable, versioned site configuration (rates, approved apps, timeouts). */
#[Fillable(['site_id', 'version', 'seconds_per_pulse', 'allowed_packages', 'local_loss_timeout_s',
    'controller_sync_interval_s', 'created_by', 'created_at'])]
class SiteConfig extends Model
{
    public const UPDATED_AT = null;

    public const DEFAULT_SECONDS_PER_PULSE = 240;

    public const DEFAULT_LOCAL_LOSS_TIMEOUT_S = 30;

    public const DEFAULT_CONTROLLER_SYNC_S = 15;

    protected function casts(): array
    {
        return ['allowed_packages' => 'array', 'created_at' => 'datetime'];
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
