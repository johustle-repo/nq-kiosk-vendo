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
 * Live view of one site: its tablets (remaining time, status, their own coin
 * box) and, when tablets share one, the shared coin box (selection, held coins)
 * with the attendant's controls. Refreshes every 2 s.
 */
class SitePanel extends Component
{
    #[Locked]
    public int $siteId;

    public ?string $flash = null;

    /** @var array<int, int|string|null> minutes typed per tablet for "Add" */
    public array $customMinutes = [];

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
        if ($this->site()->controllerForStation($station)?->isKioskCoinBox()) {
            $this->flash = "Tablet {$station} has its own coin box: its coins always go to it.";

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
        $direct = $this->site()->phoneForStation($station)?->takesDashboardTime() === true;
        $this->run(fn (Site $s, ControllerChannel $c) => $c->addTime($s, $station, $minutes * 60, auth()->user(), request()->ip()),
            $direct ? "Adding {$minutes} min to Tablet {$station}. It arrives within about 30 seconds."
                : "Adding {$minutes} min to Tablet {$station}…");
    }

    /** "Add" with the minutes typed on the tablet's card. */
    public function addCustomTime(int $station): void
    {
        $raw = $this->customMinutes[$station] ?? null;
        $minutes = is_numeric($raw) ? (int) $raw : 0;
        $max = intdiv((int) config('vendo.max_admin_credit_seconds'), 60);
        if ($minutes < 1 || $minutes > $max || (string) $minutes !== trim((string) $raw)) {
            $this->flash = "Type whole minutes from 1 to {$max}.";

            return;
        }
        $this->addTime($station, $minutes);
        $this->customMinutes[$station] = null;
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
        $paired = (bool) ((($site->controllerForStation($station)?->status('stations', []) ?? [])[$station] ?? [])['paired'] ?? false);
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
        $controllers = $devices->where('device_type', Device::TYPE_CONTROLLER)->sortByDesc('id');
        $controller = $controllers->whereNull('station_no')->first(); // shared coin box
        $age = fn (?Device $d) => $d?->status_reported_at ? (int) $d->status_reported_at->diffInSeconds(now()) : null;
        $ctlAge = $age($controller);

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
            // Its own coin box, else the shared one. Station status is stored under the site tablet number.
            $ownBox = $controllers->where('station_no', $n)->first();
            $box = $ownBox ?? $controller;
            $boxStations = $box?->status('stations', []) ?? [];
            $boxAge = $age($box);
            $st = $boxStations[$n] ?? $boxStations[(string) $n] ?? null;
            $remaining = null;
            if ($st !== null && $boxAge !== null) {
                $remaining = ($st['session'] ?? '') === 'running' ? max(0, (int) $st['remaining_s'] - $boxAge) : 0;
            }
            // Free time the dashboard gave the tablet itself (it runs after the coin time).
            $free = 0;
            if ($phone?->takesDashboardTime() && $phone->presence() === 'online') {
                $free = (int) $phone->status('dashboard_remaining_s', 0);
                if ($phone->status('dashboard_running') === true) {
                    $free = max(0, $free - (int) $age($phone));
                }
                if ($free > 0) {
                    $remaining = ($remaining ?? 0) + $free;
                }
            }
            $tablets[] = [
                'n' => $n,
                'phone' => $phone,
                'ownBox' => $ownBox,
                'boxPresence' => $box?->presence() ?? 'none',
                'boxAge' => $boxAge,
                'held' => (int) ($ownBox?->held_pulses ?? 0),
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
                'freeTime' => $free,
                'pesosToday' => (int) ($perStation[$n] ?? 0),
                'pending' => $pending->get($n, collect())->map(fn (ControllerCommand $c) => $c->type)->all(),
                // Selecting is only for tablets that share a coin box.
                'selectable' => $ownBox === null && $controller !== null,
                'selected' => $ownBox === null && $boxSelected && $boxSelected['station'] === $n,
                'wanted' => $ownBox === null && $wanted === $n,
            ];
        }

        return view('livewire.site-panel', [
            'site' => $site,
            'controller' => $controller,
            'controllerPresence' => $controller?->presence() ?? 'none',
            'controllerAge' => $ctlAge,
            'boxSelected' => $boxSelected,
            'wanted' => $wanted,
            'held' => (int) $site->held_pulses,
            'heldPending' => $pending->flatten()->contains(fn (ControllerCommand $c) => $c->type === 'assign_held'
                && ($c->device_id ?? $controller?->id) === $controller?->id),
            'kioskBoxes' => $controllers->whereNotNull('station_no')->count(),
            'todayTotal' => $todayTotal,
            'tablets' => $tablets,
        ]);
    }
}
