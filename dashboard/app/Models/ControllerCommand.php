<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/** Dashboard → coin box command, re-sent on every poll until acknowledged. */
#[Fillable(['site_id', 'type', 'station_no', 'seconds', 'created_by', 'created_at', 'delivered_at', 'applied_at', 'result'])]
class ControllerCommand extends Model
{
    public const UPDATED_AT = null;

    public const TYPES = ['add_time', 'end_session', 'assign_held'];

    protected function casts(): array
    {
        return ['created_at' => 'datetime', 'delivered_at' => 'datetime', 'applied_at' => 'datetime'];
    }

    public function creator(): BelongsTo
    {
        return $this->belongsTo(User::class, 'created_by');
    }
}
