<div wire:poll.2s class="space-y-5">
    @php
        $hms = fn (?int $s) => $s === null ? '--:--:--' : sprintf('%02d:%02d:%02d', intdiv($s, 3600), intdiv($s % 3600, 60), $s % 60);
        $presenceClass = fn (string $p) => match ($p) {
            'online' => 'bg-brand-soft text-brand-deep',
            'offline' => 'bg-red-100 text-red-700',
            'revoked' => 'bg-zinc-200 text-zinc-500 line-through',
            default => 'bg-zinc-100 text-zinc-500',
        };
    @endphp

    @if ($flash)
        <div class="rounded-xl border border-brand/30 bg-brand-soft px-4 py-2.5 text-sm font-semibold text-brand-deep" wire:key="flash">{{ $flash }}</div>
    @endif

    {{-- Coin box: the shared one when tablets share it; with a coin box per tablet, each card shows its own. --}}
    <section class="card">
        <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="flex items-center gap-3">
                <img src="{{ asset('images/vendo-coin.png') }}" alt="" class="h-11 w-11">
                <div>
                    @if ($controller || ! $kioskBoxes)
                        <h2 class="text-lg font-black">{{ $kioskBoxes ? 'Shared coin box' : 'Coin box' }}</h2>
                        <p class="muted">{{ $controller?->name ?? 'Not enrolled yet' }}
                            <span class="pill ml-1 {{ $presenceClass($controllerPresence) }}">{{ strtoupper($controllerPresence === 'none' ? 'not enrolled' : $controllerPresence) }}</span>
                        </p>
                    @else
                        <h2 class="text-lg font-black">Coin boxes</h2>
                        <p class="muted">One per tablet · {{ $kioskBoxes }} enrolled</p>
                    @endif
                </div>
            </div>
            <div class="text-right">
                <p class="muted">Today</p>
                <p class="text-2xl font-black text-coin">₱{{ number_format($todayTotal) }}</p>
            </div>
        </div>

        @if ($controller || ! $kioskBoxes)
        <div class="mt-4 grid gap-3 md:grid-cols-2">
            {{-- Where the next coins go --}}
            <div @class(['rounded-xl border px-4 py-3', 'border-brand bg-brand-soft' => $boxSelected, 'border-zinc-200 bg-canvas' => ! $boxSelected])>
                <p class="text-xs font-bold uppercase tracking-wide text-zinc-500">Next coins go to</p>
                @if ($boxSelected)
                    <p class="text-xl font-black text-brand-deep">Tablet {{ $boxSelected['station'] }}
                        <span class="text-sm font-semibold text-brand">· {{ $boxSelected['ttl'] }} s left</span></p>
                @elseif ($wanted)
                    <p class="text-xl font-black text-charcoal">Tablet {{ $wanted }} <span class="text-sm font-semibold text-zinc-500">· sending to coin box…</span></p>
                @else
                    <p class="text-xl font-black text-charcoal">Nobody <span class="text-sm font-semibold text-zinc-500">· coins will be held</span></p>
                @endif
                @if ($boxSelected || $wanted)
                    <button wire:click="clearSelection" class="mt-2 text-sm font-semibold text-zinc-600 underline hover:text-ink">Clear selection</button>
                @endif
            </div>

            {{-- Held coins --}}
            <div @class(['rounded-xl border px-4 py-3', 'border-coin bg-coin-soft' => $held > 0, 'border-zinc-200 bg-canvas' => $held === 0])>
                <p class="text-xs font-bold uppercase tracking-wide text-zinc-500">Held coins (no tablet selected)</p>
                @if ($held > 0)
                    <p class="text-xl font-black text-coin">₱{{ $held }} <span class="text-sm font-semibold">waiting</span></p>
                    @if ($heldPending)
                        <p class="text-sm font-semibold text-zinc-600">Assigning…</p>
                    @else
                        <div class="mt-2 flex flex-wrap gap-2">
                            {{-- Only tablets that share this coin box; one with its own box gets its own held coins. --}}
                            @foreach ($tablets as $t)
                                @continue(! $t['selectable'])
                                <button wire:click="assignHeld({{ $t['n'] }})" wire:confirm="Give ₱{{ $held }} of held coins to Tablet {{ $t['n'] }}?" class="btn-outline py-1">Give to Tablet {{ $t['n'] }}</button>
                            @endforeach
                        </div>
                    @endif
                @else
                    <p class="text-xl font-black text-charcoal">None</p>
                @endif
            </div>
        </div>
        @endif

        @if ($controller)
            @php
                $rssi = $controller->status('wifi_rssi');
                $signal = $rssi === null ? null : ($rssi >= -60 ? 'good' : ($rssi >= -72 ? 'fair' : 'weak'));
                $heap = $controller->status('free_heap');
            @endphp
            <dl class="mt-4 grid grid-cols-2 gap-x-4 gap-y-1 rounded-xl border border-zinc-200 bg-canvas px-4 py-3 text-sm md:grid-cols-4">
                <div><dt class="text-zinc-500">Wi-Fi</dt>
                    <dd class="truncate font-semibold">{{ $controller->status('wifi_ssid') ?? '—' }}
                        @if ($signal)<span @class(['text-xs', 'text-brand' => $signal === 'good', 'text-amber-700' => $signal === 'fair', 'text-red-600' => $signal === 'weak'])>· {{ $signal }} ({{ $rssi }} dBm)</span>@endif</dd></div>
                <div><dt class="text-zinc-500">Coin box IP (for pairing)</dt>
                    <dd class="font-mono font-semibold">{{ $controller->status('local_ip') ?? '—' }}</dd></div>
                <div><dt class="text-zinc-500">Firmware · uptime</dt>
                    <dd class="font-semibold">{{ $controller->sw_version ?? '—' }}@if ($controller->status_uptime_ms) · {{ \Carbon\CarbonInterval::seconds(intdiv((int) $controller->status_uptime_ms, 1000))->cascade()->forHumans(['short' => true, 'parts' => 2]) }}@endif</dd></div>
                <div><dt class="text-zinc-500">Last report · memory</dt>
                    <dd @class(['font-semibold', 'text-red-600' => $heap !== null && $heap < 10240])>{{ $controllerAge === null ? 'never' : $controllerAge.' s ago' }}@if ($heap !== null) · {{ number_format($heap / 1024, 1) }} KB free @endif</dd></div>
            </dl>
        @endif
    </section>

    {{-- Tablets --}}
    <section class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        @foreach ($tablets as $t)
            <article wire:key="tablet-{{ $t['n'] }}" @class([
                'card flex flex-col gap-3',
                'ring-2 ring-brand' => $t['selected'],
            ])>
                <header class="flex items-start justify-between gap-2">
                    <div>
                        <h3 class="text-lg font-black">Tablet {{ $t['n'] }}</h3>
                        <p class="muted truncate">{{ $t['phone']?->name ?? 'Not enrolled' }}</p>
                    </div>
                    <span class="pill {{ $presenceClass($t['presence']) }}">{{ strtoupper($t['presence'] === 'none' ? 'empty' : $t['presence']) }}</span>
                </header>

                <div @class(['rounded-xl px-3 py-2 text-center', 'bg-brand-soft' => ($t['remaining'] ?? 0) > 300, 'bg-amber-50' => ($t['remaining'] ?? 0) > 0 && $t['remaining'] <= 300, 'bg-canvas' => ! $t['remaining']])>
                    <p class="text-xs font-bold uppercase tracking-wide text-zinc-500">Time left</p>
                    <p @class(['font-mono text-3xl font-black tabular-nums', 'text-brand-deep' => ($t['remaining'] ?? 0) > 300, 'text-amber-700' => ($t['remaining'] ?? 0) > 0 && $t['remaining'] <= 300, 'text-zinc-400' => ! $t['remaining']])>{{ $hms($t['remaining']) }}</p>
                    @if ($t['freeTime'] > 0)
                        <p class="text-xs font-semibold text-zinc-500">incl. {{ $hms($t['freeTime']) }} free from the dashboard</p>
                    @endif
                </div>

                <dl class="grid grid-cols-2 gap-x-2 gap-y-1 text-sm">
                    <dt class="text-zinc-500">Kiosk</dt>
                    <dd class="text-right font-semibold">{{ $t['mode'] ? ucfirst($t['mode']) : '—' }}@if ($t['locked']) · locked @endif</dd>
                    <dt class="text-zinc-500">Coin box link</dt>
                    <dd class="text-right font-semibold">{{ $t['paired'] ? ($t['link'] ?? 'paired') : 'not paired' }}</dd>
                    <dt class="text-zinc-500">Battery</dt>
                    <dd @class(['text-right font-semibold', 'text-red-600' => $t['battery'] !== null && $t['battery'] <= 20 && ! $t['charging']])>{{ $t['battery'] === null ? '—' : $t['battery'].'%'.($t['charging'] ? ' · charging' : ($t['battery'] <= 20 ? ' · low' : '')) }}</dd>
                    <dt class="text-zinc-500">Today</dt>
                    <dd class="text-right font-bold text-coin">₱{{ number_format($t['pesosToday']) }}</dd>
                </dl>

                {{-- This tablet's own coin box --}}
                @if ($b = $t['ownBox'])
                    <div class="rounded-xl border border-zinc-200 bg-canvas px-3 py-2 text-sm">
                        <div class="flex items-center justify-between gap-2">
                            <p class="font-bold">Coin box <span class="font-normal text-zinc-500">· {{ $b->name }}</span></p>
                            <span class="pill {{ $presenceClass($t['boxPresence']) }}">{{ strtoupper($t['boxPresence']) }}</span>
                        </div>
                        <dl class="mt-1 grid grid-cols-2 gap-x-2 gap-y-0.5">
                            <dt class="text-zinc-500">Wi-Fi</dt>
                            <dd class="truncate text-right font-semibold">{{ $b->status('wifi_ssid') ?? '—' }}@if ($b->status('wifi_rssi') !== null) · {{ $b->status('wifi_rssi') }} dBm @endif</dd>
                            <dt class="text-zinc-500">IP</dt>
                            <dd class="text-right font-mono font-semibold">{{ $b->status('local_ip') ?? '—' }}</dd>
                            <dt class="text-zinc-500">Firmware</dt>
                            <dd class="text-right font-semibold">{{ $b->sw_version ?? '—' }} · {{ $t['boxAge'] === null ? 'never' : $t['boxAge'].' s ago' }}</dd>
                        </dl>
                        @if ($t['held'] > 0)
                            <div class="mt-2 flex items-center justify-between gap-2 rounded-lg bg-coin-soft px-2 py-1">
                                <span class="font-bold text-coin">₱{{ $t['held'] }} held</span>
                                @if (in_array('assign_held', $t['pending'], true))
                                    <span class="text-xs font-semibold text-zinc-600">Assigning…</span>
                                @else
                                    <button wire:click="assignHeld({{ $t['n'] }})" wire:confirm="Give ₱{{ $t['held'] }} of held coins to Tablet {{ $t['n'] }}?" class="btn-outline px-2 py-0.5 text-xs" @disabled(! $t['usable'])>Give to tablet</button>
                                @endif
                            </div>
                        @endif
                    </div>
                @endif

                @if ($t['pending'])
                    <p class="rounded-lg bg-zinc-100 px-2 py-1 text-xs font-semibold text-zinc-600">Sending to coin box: {{ implode(', ', array_map(fn ($c) => str_replace('_', ' ', $c), $t['pending'])) }}</p>
                @endif

                <div class="mt-auto space-y-2">
                    @unless ($t['usable'])
                        <p class="text-xs text-zinc-500">Enroll a tablet as Tablet {{ $t['n'] }} or pair one with the coin box first.</p>
                    @endunless
                    @if ($t['selected'])
                        <p class="btn w-full bg-brand text-white">Next coins → this tablet</p>
                    @elseif ($t['selectable'])
                        <button wire:click="select({{ $t['n'] }})" class="btn-primary w-full" @disabled(! $t['usable'])>Select for next coins</button>
                    @elseif (! $t['ownBox'])
                        <p class="text-xs text-zinc-500">Enroll a coin box as Tablet {{ $t['n'] }} to take coins here.</p>
                    @endif
                    <div class="grid grid-cols-3 gap-1.5">
                        @foreach ([5, 15, 30] as $m)
                            <button wire:click="addTime({{ $t['n'] }}, {{ $m }})" wire:confirm="Give Tablet {{ $t['n'] }} {{ $m }} free minutes?" class="btn-outline px-1 py-1.5" @disabled(! $t['usable'])>+{{ $m }} min</button>
                        @endforeach
                    </div>
                    <form wire:submit="addCustomTime({{ $t['n'] }})" wire:confirm="Give Tablet {{ $t['n'] }} these free minutes?" class="flex gap-1.5">
                        <label class="sr-only" for="minutes-{{ $t['n'] }}">Minutes for Tablet {{ $t['n'] }}</label>
                        <input id="minutes-{{ $t['n'] }}" type="number" min="1" max="{{ intdiv((int) config('vendo.max_admin_credit_seconds'), 60) }}" step="1" inputmode="numeric" placeholder="Minutes"
                            wire:model="customMinutes.{{ $t['n'] }}" class="field min-w-0 flex-1 py-1.5" @disabled(! $t['usable'])>
                        <button type="submit" class="btn-outline px-3 py-1.5" @disabled(! $t['usable'])>Add</button>
                    </form>
                    <button wire:click="endSession({{ $t['n'] }})" wire:confirm="End Tablet {{ $t['n'] }}'s session now? The customer loses the remaining time." class="btn-danger w-full py-1.5" @disabled(! $t['remaining'])>End session</button>
                    @if ($t['phone'])
                        <button wire:click="openAdmin({{ $t['n'] }})" wire:confirm="Open the admin screen on Tablet {{ $t['n'] }} without its PIN? Anyone at the tablet gets admin for 5 minutes." class="btn-outline w-full py-1.5" @disabled($t['adminPending'])>{{ $t['adminPending'] ? 'Opening admin…' : 'Open admin' }}</button>
                        @if ($t['tapsOn'])
                            <p class="text-center text-xs text-slate-500">10-tap admin is on (off when admin is locked on the tablet)</p>
                        @else
                            <button wire:click="enableTaps({{ $t['n'] }})" wire:confirm="Turn on the 10-tap admin gesture on Tablet {{ $t['n'] }}? The PIN is still required. It turns off when admin is locked on the tablet." class="btn-outline w-full py-1.5" @disabled($t['tapsPending'])>{{ $t['tapsPending'] ? 'Enabling 10 taps…' : 'Enable 10 taps' }}</button>
                        @endif
                    @endif
                </div>
            </article>
        @endforeach
    </section>
</div>
