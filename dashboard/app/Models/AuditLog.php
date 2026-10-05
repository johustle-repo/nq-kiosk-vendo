<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

#[Fillable(['user_id', 'site_id', 'device_id', 'action', 'details', 'ip', 'created_at'])]
class AuditLog extends Model
{
    public const UPDATED_AT = null;

    protected function casts(): array
    {
        return ['details' => 'array', 'created_at' => 'datetime'];
    }

    public function user(): BelongsTo
    {
        return $this->belongsTo(User::class);
    }

    /** Records an action. Never pass secrets in $details. */
    public static function record(string $action, ?int $userId, ?int $siteId, ?int $deviceId, array $details = [], ?string $ip = null): void
    {
        self::create([
            'user_id' => $userId, 'site_id' => $siteId, 'device_id' => $deviceId, 'action' => $action,
            'details' => $details, 'ip' => $ip, 'created_at' => now(),
        ]);
    }
}
