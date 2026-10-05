<x-app-layout :title="$site->name">
    <div class="mb-5 flex flex-wrap items-end justify-between gap-2">
        <div>
            <a href="{{ route('sites.index') }}" class="text-sm font-semibold text-brand hover:underline">← Sites</a>
            <h1 class="text-2xl font-black">{{ $site->name }}</h1>
        </div>
        <p class="muted">Rate: ₱1 = {{ intdiv($config->seconds_per_pulse, 60) }} min{{ $config->seconds_per_pulse % 60 ? ' '.($config->seconds_per_pulse % 60).' s' : '' }} · config v{{ $config->version }}</p>
    </div>

    <livewire:site-panel :site="$site" />

    <div class="mt-6 grid gap-5 lg:grid-cols-2">
        {{-- Enroll devices --}}
        <section class="card">
            <h2 class="mb-1 text-lg font-black">Enroll a device</h2>
            <p class="muted mb-3">Creates a one-time code, valid for 30 minutes.</p>
            @if ($newCode)
                <div class="mb-4 rounded-xl border-2 border-dashed border-brand p-4">
                    <p class="text-sm font-semibold">
                        {{ $newCode['type'] === 'phone' ? 'Tablet '.$newCode['station'] : 'Coin box' }} enrollment code — shown once:
                    </p>
                    <p class="my-1 select-all font-mono text-3xl font-black tracking-widest">{{ $newCode['code'] }}</p>
                    <p class="muted">{{ $newCode['type'] === 'phone' ? 'On the tablet: Admin → Cloud → enter this code.' : 'On the coin box: Wi-Fi setup page → cloud enrollment code.' }}</p>
                </div>
            @endif
            <form method="post" action="{{ route('sites.enroll', $site) }}" class="flex flex-wrap items-end gap-2">
                @csrf
                <label class="label">Device
                    <select name="device_type" class="field">
                        <option value="phone">Tablet</option>
                        <option value="controller">Coin box</option>
                    </select>
                </label>
                <label class="label">Tablet number
                    <select name="station_no" class="field">
                        @for ($n = 1; $n <= \App\Models\Site::MAX_STATIONS; $n++)
                            <option value="{{ $n }}">Tablet {{ $n }}</option>
                        @endfor
                    </select>
                </label>
                <button class="btn-primary">Create code</button>
            </form>
            <p class="muted mt-2">The tablet number is ignored for a coin box.</p>
        </section>

        {{-- Configuration --}}
        <section class="card">
            <h2 class="mb-1 text-lg font-black">Configuration</h2>
            <p class="muted mb-3">Applies to the coin box and all tablets of this site. New rates apply to future coins only.</p>
            <form method="post" action="{{ route('sites.config', $site) }}" class="grid gap-3 sm:grid-cols-3">
                @csrf
                <label class="label">Seconds per peso
                    <input name="seconds_per_pulse" type="number" min="10" max="3600" required value="{{ old('seconds_per_pulse', $config->seconds_per_pulse) }}" class="field">
                </label>
                <label class="label">Link-loss timeout (s)
                    <input name="local_loss_timeout_s" type="number" min="5" max="600" required value="{{ old('local_loss_timeout_s', $config->local_loss_timeout_s) }}" class="field">
                </label>
                <label class="label">Coin box sync (s)
                    <input name="controller_sync_interval_s" type="number" min="5" max="300" required value="{{ old('controller_sync_interval_s', $config->controller_sync_interval_s) }}" class="field">
                </label>
                <label class="label sm:col-span-3">Approved apps (Android package names, one per line)
                    <textarea name="allowed_packages" rows="4" class="field font-mono text-sm">{{ old('allowed_packages', implode("\n", $config->allowed_packages ?? [])) }}</textarea>
                </label>
                <div class="sm:col-span-3"><button class="btn-primary">Save new version</button></div>
            </form>
            <p class="muted mt-2">₱1 = {{ intdiv($config->seconds_per_pulse, 60) }} min · ₱5 = {{ intdiv($config->seconds_per_pulse * 5, 60) }} min · ₱10 = {{ intdiv($config->seconds_per_pulse * 10, 60) }} min · ₱20 = {{ intdiv($config->seconds_per_pulse * 20, 60) }} min</p>
        </section>
    </div>

    {{-- Devices --}}
    <section class="card mt-5">
        <h2 class="mb-3 text-lg font-black">Devices</h2>
        <div class="overflow-x-auto">
            <table class="w-full text-left text-sm">
                <thead class="text-xs uppercase tracking-wide text-zinc-500">
                <tr><th class="py-2">Device</th><th>Type</th><th>Status</th><th>Last seen</th><th>Software</th><th>Config</th><th></th></tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                @forelse ($devices as $d)
                    <tr>
                        <td class="py-2 font-semibold">{{ $d->name }} <span class="block font-mono text-xs text-zinc-400">{{ $d->public_id }}</span></td>
                        <td>{{ $d->device_type === 'phone' ? 'Tablet '.($d->station_no ?? '?') : 'Coin box' }}</td>
                        <td>{{ $d->presence() }}</td>
                        <td>{{ $d->last_seen_at?->diffForHumans() ?? 'never' }}</td>
                        <td>{{ $d->sw_version ?? '—' }}</td>
                        <td>{{ $d->config_version_applied ? 'v'.$d->config_version_applied : '—' }}</td>
                        <td class="text-right">
                            @if (! $d->revoked_at)
                                <form method="post" action="{{ route('devices.revoke', $d) }}" data-confirm="Revoke this device? It will stop reporting until enrolled again.">
                                    @csrf
                                    <button class="btn-danger px-2 py-1 text-xs">Revoke</button>
                                </form>
                            @endif
                        </td>
                    </tr>
                @empty
                    <tr><td colspan="7" class="py-3 text-zinc-500">No devices enrolled yet.</td></tr>
                @endforelse
                </tbody>
            </table>
        </div>
    </section>

    {{-- Recent coin box events --}}
    <section class="card mt-5">
        <h2 class="mb-3 text-lg font-black">Recent coins and sessions</h2>
        <div class="overflow-x-auto">
            <table class="w-full text-left text-sm">
                <thead class="text-xs uppercase tracking-wide text-zinc-500">
                <tr><th class="py-2">When</th><th>Event</th><th>Tablet</th><th>Pesos</th><th>Time added</th><th>Remaining after</th></tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                @forelse ($events as $e)
                    <tr>
                        <td class="py-2">{{ $e->occurred_at->timezone(config('app.display_timezone', 'Asia/Manila'))->format('M j, g:i:s A') }}</td>
                        <td>{{ str_replace('_', ' ', $e->event_type) }}</td>
                        <td>{{ $e->station_no ? 'Tablet '.$e->station_no : 'held' }}</td>
                        <td class="font-semibold text-coin">{{ $e->pulses ? '₱'.$e->pulses : '' }}</td>
                        <td>{{ $e->seconds_added ? intdiv($e->seconds_added, 60).' min' : '' }}</td>
                        <td>{{ in_array($e->event_type, ['credit', 'assign', 'admin_credit']) ? gmdate('H:i:s', $e->remaining_after) : '' }}</td>
                    </tr>
                @empty
                    <tr><td colspan="6" class="py-3 text-zinc-500">No coins yet.</td></tr>
                @endforelse
                </tbody>
            </table>
        </div>
    </section>
</x-app-layout>
