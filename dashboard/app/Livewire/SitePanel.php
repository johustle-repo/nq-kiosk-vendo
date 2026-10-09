<?php

namespace App\Livewire;

use App\Models\AuditLog;
use App\Models\CoinEvent;
use App\Models\ControllerCommand;
use App\Models\Device;
use App\Models\Site;
use App\Services\ControllerChannel;
use Illuminate\Support\Facades\Gate;
use Illuminate\View\View;
use InvalidArgumentException;
use Livewire\Attributes\Locked;
use Livewire\Component;

/**
 * Live view of one site: the coin box (selection, held coins) and its tablets
 * (remaining time, status) with the attendant's controls. Refreshes every 2 s.
 */
class SitePanel extends Component
{
    #[Locked]
    public int $siteId;

    public ?string $flash = null;

    public function mount(Site $site): void
    {
        Gate::authorize('manage-site', $site);
        $this->siteId = $site->id;
    }

    private function site(): Site
    {
        $site = Site::findOrFail($this->siteId);
        Gate::authorize('manage-site', $site);

        return $site;
    }

    // ------------------------------------------------------------ actions

    public function select(int $station): void
    {
        if (! $this->usable($station)) {
            return;
        }
        $this->run(fn (Site $s, ControllerChannel $c) => $c->select($s, $station, auth()->user(), request()->ip()),
            "Next coins go to Tablet {$station}.");
    }

    public function clearSelection(): void
    {
        $this->run(fn (Site $s, ControllerChannel $c) => $c->select($s, null, auth()->user(), request()->ip()),
            'Selection cleared. New coins will be held.');
    }

    public function addTime(int $station, int $minutes): void
    {
        if (! $this->usable($station)) {
            return;
        }
        $this->run(fn (Site $s, ControllerChannel $c) => $c->addTime($s, $station, $minutes * 60, auth()->user(), request()->ip()),
            "Adding {$minutes} min to Tablet {$station}…");
    }

    public function endSession(int $station): void
    {
        $this->run(fn (Site $s, ControllerChannel $c) => $c->endSession($s, $station, auth()->user(), request()->ip()),
            "Ending Tablet {$station}'s session…");
    }

    /**
     * Opens the admin screen on a tablet without its PIN (the dashboard login
     * is the proof). The tablet picks it up on its next heartbeat (~30 s).
     */
    public function openAdmin(int $station): void
    {
        $site = $this->site();
        $phone = $station >= 1 && $station <= Site::MAX_STATIONS ? $site->phoneForStation($station) : null;
        if ($phone === null) {
            $this->flash = "Tablet {$station} is not connected to the dashboard.";

            return;
        }
        $phone->update([
            'admin_unlock_id' => bin2hex(random_bytes(8)),
            'admin_unlock_expires_at' => now()->addSeconds(Device::ADMIN_UNLOCK_TTL_S),
        ]);
        AuditLog::record('site.tablet.open_admin', auth()->id(), $site->id, $phone->id, ['station' => $station], request()->ip());
        $this->flash = "Opening admin on Tablet {$station}. It appears on the tablet within about 30 seconds.";
    }

    /**
     * Turns the hidden 10-tap admin gesture back on for a tablet enrolled here
     * (the PIN is still asked). It goes off again when the tablet's
     * administrator locks the admin screen.
     */
    public function enableTaps(int $station): void
    {
        $site = $this->site();
        $phone = $station >= 1 && $station <= Site::MAX_STATIONS ? $site->phoneForStation($station) : null;
        if ($phone === null) {
            $this->flash = "Tablet {$station} is not connected to the dashboard.";

            return;
        }
        $phone->update(['tap_admin_expires_at' => now()->addSeconds(Device::TAP_ADMIN_TTL_S)]);
        AuditLog::record('site.tablet.enable_taps', auth()->id(), $site->id, $phone->id, ['station' => $station], request()->ip());
        $this->flash = "Turning on the 10-tap admin on Tablet {$station} (within about 30 seconds). It turns off again when admin is locked on the tablet.";
    }

    public function assignHeld(int $station): void
    {
        $this->run(fn (Site $s, ControllerChannel $c) => $c->assignHeld($s, $station, auth()->user(), request()->ip()),
            "Giving the held coins to Tablet {$station}…");
    }

    /**
     * A tablet slot can receive coins or time only when a tablet is enrolled for
     * it or paired with the coin box; otherwise the time would go to nobody.
     */
    private function usable(int $station): bool
    {
        if ($station < 1 || $station > Site::MAX_STATIONS) {
            $this->flash = 'Tablet number must be 1 to '.Site::MAX_STATIONS.'.';

            return false;
        }
        $site = $this->site();
        $paired = (bool) ((($site->controller()?->status('stations', []) ?? [])[$station] ?? [])['paired'] ?? false);
        if ($site->phoneForStation($station) === null && ! $paired) {
            $this->flash = "Tablet {$station} has no tablet enrolled or paired yet.";

            return false;
        }

        return true;
    }

    private function run(callable $action, string $message): void
    {
        try {
            $action($this->site(), app(ControllerChannel::class));
            $this->flash = $message;
        } catch (InvalidArgumentException $e) {
            $this->flash = $e->getMessage();
        }
    }

    // ------------------------------------------------------------ view model

    public function render(): View
    {
        $site = $this->site();
        $devices = $site->devices()->whereNull('revoked_at')->get();
        $controller = $devices->where('device_type', Device::TYPE_CONTROLLER)->sortByDesc('id')->first();
        $ctlStations = $controller?->status('stations', []) ?? [];
        $ctlAge = $controller?->status_reported_at ? (int) $controller->status_reported_at->diffInSeconds(now()) : null;

        $todayStart = now()->startOfDay();
        $perStation = CoinEvent::where('site_id', $site->id)->whereIn('event_type', ['credit', 'assign'])
            ->where('occurred_at', '>=', $todayStart)->selectRaw('station_no, SUM(pulses) as pesos')
            ->groupBy('station_no')->pluck('pesos', 'station_no');
        $todayTotal = (int) CoinEvent::where('site_id', $site->id)->whereIn('event_type', CoinEvent::MONEY_TYPES)
            ->where('occurred_at', '>=', $todayStart)->sum('pulses');
        $pending = ControllerCommand::where('site_id', $site->id)->whereNull('applied_at')->get()->groupBy('station_no');

        // What the coin box itself last reported (the truth on the floor).
        $pollAge = $site->last_poll_at ? (int) $site->last_poll_at->diffInSeconds(now()) : null;
        $boxSelected = $site->reported_station && $pollAge !== null && $pollAge < 15
            ? ['station' => (int) $site->reported_station, 'ttl' => max(0, (int) $site->reported_ttl_s - $pollAge)]
            : null;
        $wanted = $site->activeSelection();

        $tablets = [];
        for ($n = 1; $n <= Site::MAX_STATIONS; $n++) {
            $phone = $devices->where('device_type', Device::TYPE_PHONE)->where('station_no', $n)->sortByDesc('id')->first();
            $st = $ctlStations[$n] ?? $ctlStations[(string) $n] ?? null;
            $remaining = null;
            if ($st !== null && $ctlAge !== null) {
                $remaining = ($st['session'] ?? '') === 'running' ? max(0, (int) $st['remaining_s'] - $ctlAge) : 0;
            }
            $tablets[] = [
                'n' => $n,
                'phone' => $phone,
                'presence' => $phone?->presence() ?? 'none',
                'mode' => $phone?->status('mode'),
                'locked' => $phone?->status('lock_task') === 'locked',
                'link' => $phone?->status('controller_link'),
                'battery' => $phone?->status('battery_pct'),
                'charging' => $phone?->status('charging') === true,
                'adminPending' => $phone?->adminUnlockPending() === true,
                'tapsPending' => $phone?->tapAdminPending() === true,
                'tapsOn' => $phone?->status('tap_admin') === true,
                'paired' => (bool) ($st['paired'] ?? false),
                'usable' => $phone !== null || (bool) ($st['paired'] ?? false),
                'remaining' => $remaining,
                'pesosToday' => (int) ($perStation[$n] ?? 0),
                'pending' => $pending->get($n, collect())->map(fn (ControllerCommand $c) => $c->type)->all(),
                'selected' => $boxSelected && $boxSelected['station'] === $n,
                'wanted' => $wanted === $n,
            ];
        }

        return view('livewire.site-panel', [
            'site' => $site,
            'controller' => $controller,
            'controllerPresence' => $controller?->presence() ?? 'none',
            'boxSelected' => $boxSelected,
            'wanted' => $wanted,
            'held' => (int) $site->held_pulses,
            'heldPending' => $pending->flatten()->contains(fn (ControllerCommand $c) => $c->type === 'assign_held'),
            'todayTotal' => $todayTotal,
            'tablets' => $tablets,
        ]);
    }
}
