<?php

namespace App\Http\Controllers;

use App\Models\AuditLog;
use App\Models\CoinEvent;
use App\Models\Device;
use App\Models\Site;
use App\Services\SiteService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\Rule;
use Illuminate\View\View;

class SiteController extends Controller
{
    public function __construct(private readonly SiteService $sites) {}

    public function index(Request $request): View
    {
        $sites = $request->user()->sites()->orderBy('name')->get();
        $today = CoinEvent::whereIn('site_id', $sites->pluck('id'))->whereIn('event_type', CoinEvent::MONEY_TYPES)
            ->where('occurred_at', '>=', now()->startOfDay())->selectRaw('site_id, SUM(pulses) as pesos')
            ->groupBy('site_id')->pluck('pesos', 'site_id');

        return view('sites.index', ['sites' => $sites, 'today' => $today]);
    }

    public function store(Request $request): RedirectResponse
    {
        $data = $request->validate(['name' => ['required', 'string', 'max:100']]);
        $site = $this->sites->createSite($request->user(), $data['name']);
        AuditLog::record('site.created', $request->user()->id, $site->id, null, ['name' => $site->name], $request->ip());

        return redirect()->route('sites.show', $site)->with('status', 'Site created. Enroll its coin box and tablets below.');
    }

    public function show(Request $request, Site $site): View
    {
        Gate::authorize('manage-site', $site);

        return view('sites.show', [
            'site' => $site,
            'config' => $site->currentConfig(),
            'history' => $site->configs()->with('creator')->orderByDesc('version')->limit(5)->get(),
            'devices' => $site->devices()->orderBy('device_type')->orderBy('station_no')->get(),
            'events' => CoinEvent::where('site_id', $site->id)->orderByDesc('occurred_at')->orderByDesc('id')->limit(25)->get(),
            'newCode' => session('new_code'),
        ]);
    }

    public function saveConfig(Request $request, Site $site): RedirectResponse
    {
        Gate::authorize('manage-site', $site);
        $result = SiteService::validateConfig($request->only(['seconds_per_pulse', 'local_loss_timeout_s', 'controller_sync_interval_s', 'allowed_packages']));
        if ($result['errors'] !== []) {
            return back()->withErrors($result['errors'])->withInput();
        }
        $version = $this->sites->saveConfig($site, $request->user(), $result['config']);
        AuditLog::record('site.config_saved', $request->user()->id, $site->id, null, ['version' => $version] + $result['config'], $request->ip());

        return back()->with('status', "Configuration v{$version} saved. Devices pick it up on their next sync; new rates apply to future coins only.");
    }

    public function enrollCode(Request $request, Site $site): RedirectResponse
    {
        Gate::authorize('manage-site', $site);
        $data = $request->validate([
            'device_type' => ['required', Rule::in([Device::TYPE_CONTROLLER, Device::TYPE_PHONE])],
            'station_no' => ['nullable', 'required_if:device_type,phone', 'integer', 'between:1,'.Site::MAX_STATIONS],
        ]);
        $station = $data['device_type'] === Device::TYPE_PHONE ? (int) $data['station_no'] : null;
        $code = $this->sites->createEnrollmentCode($site, $request->user(), $data['device_type'], $station);
        AuditLog::record('site.enroll_code', $request->user()->id, $site->id, null, ['type' => $data['device_type'], 'station' => $station], $request->ip());

        return back()->with('new_code', ['code' => $code, 'type' => $data['device_type'], 'station' => $station]);
    }

    public function revokeDevice(Request $request, Device $device): RedirectResponse
    {
        Gate::authorize('manage-site', $device->site);
        if ($device->revoked_at === null) {
            $device->update(['revoked_at' => now()]);
            AuditLog::record('device.revoked', $request->user()->id, $device->site_id, $device->id, ['name' => $device->name], $request->ip());
        }

        return back()->with('status', "Device “{$device->name}” revoked. It can no longer report to the dashboard.");
    }
}
