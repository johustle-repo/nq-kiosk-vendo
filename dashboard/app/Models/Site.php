<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * A shop with up to [Site::MAX_STATIONS] tablets. Each tablet has its own kiosk
 * coin box, or all share one coin box (the original design).
 */
#[Fillable(['owner_id', 'name', 'selected_station', 'selection_expires_at', 'selection_version',
    'reported_station', 'reported_ttl_s', 'held_pulses', 'last_poll_at'])]
class Site extends Model
{
    public const MAX_STATIONS = 4;

    protected function casts(): array
    {
        return [
            'selection_expires_at' => 'datetime',
            'last_poll_at' => 'datetime',
        ];
    }

    public function owner(): BelongsTo
    {
        return $this->belongsTo(User::class, 'owner_id');
    }

    public function configs(): HasMany
    {
        return $this->hasMany(SiteConfig::class);
    }

    public function devices(): HasMany
    {
        return $this->hasMany(Device::class);
    }

    public function commands(): HasMany
    {
        return $this->hasMany(ControllerCommand::class);
    }

    public function currentConfig(): SiteConfig
    {
        return $this->configs()->orderByDesc('version')->firstOrFail();
    }

    /** The active (non-revoked) shared coin box, if enrolled. */
    public function controller(): ?Device
    {
        return $this->devices()->where('device_type', Device::TYPE_CONTROLLER)->whereNull('station_no')
            ->whereNull('revoked_at')->latest('id')->first();
    }

    /** The coin box that takes tablet N's coins: its own kiosk coin box, else the shared one. */
    public function controllerForStation(int $station): ?Device
    {
        return $this->devices()->where('device_type', Device::TYPE_CONTROLLER)->where('station_no', $station)
            ->whereNull('revoked_at')->latest('id')->first() ?? $this->controller();
    }

    /** Active tablet for a station number, if enrolled. */
    public function phoneForStation(int $station): ?Device
    {
        return $this->devices()->where('device_type', Device::TYPE_PHONE)->where('station_no', $station)
            ->whereNull('revoked_at')->latest('id')->first();
    }

    /** Dashboard selection still in force (not expired). */
    public function activeSelection(): ?int
    {
        return $this->selected_station !== null && $this->selection_expires_at?->isFuture()
            ? (int) $this->selected_station : null;
    }
}
