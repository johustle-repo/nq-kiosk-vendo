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

    {{-- Coin box --}}
    <section class="card">
        <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="flex items-center gap-3">
                <img src="{{ asset('images/vendo-coin.png') }}" alt="" class="h-11 w-11">
                <div>
                    <h2 class="text-lg font-black">Coin box</h2>
                    <p class="muted">{{ $controller?->name ?? 'Not enrolled yet' }}
                        <span class="pill ml-1 {{ $presenceClass($controllerPresence) }}">{{ strtoupper($controllerPresence === 'none' ? 'not enrolled' : $controllerPresence) }}</span>
                    </p>
                </div>
            </div>
            <div class="text-right">
                <p class="muted">Today</p>
                <p class="text-2xl font-black text-coin">₱{{ number_format($todayTotal) }}</p>
            </div>
        </div>

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
                            @for ($n = 1; $n <= \App\Models\Site::MAX_STATIONS; $n++)
                                <button wire:click="assignHeld({{ $n }})" wire:confirm="Give ₱{{ $held }} of held coins to Tablet {{ $n }}?" class="btn-outline py-1">Give to Tablet {{ $n }}</button>
                            @endfor
                        </div>
                    @endif
                @else
                    <p class="text-xl font-black text-charcoal">None</p>
                @endif
            </div>
        </div>
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
                </div>

                <dl class="grid grid-cols-2 gap-x-2 gap-y-1 text-sm">
                    <dt class="text-zinc-500">Kiosk</dt>
                    <dd class="text-right font-semibold">{{ $t['mode'] ? ucfirst($t['mode']) : '—' }}@if ($t['locked']) · locked @endif</dd>
                    <dt class="text-zinc-500">Coin box link</dt>
                    <dd class="text-right font-semibold">{{ $t['paired'] ? ($t['link'] ?? 'paired') : 'not paired' }}</dd>
                    <dt class="text-zinc-500">Today</dt>
                    <dd class="text-right font-bold text-coin">₱{{ number_format($t['pesosToday']) }}</dd>
                </dl>

                @if ($t['pending'])
                    <p class="rounded-lg bg-zinc-100 px-2 py-1 text-xs font-semibold text-zinc-600">Sending to coin box: {{ implode(', ', array_map(fn ($c) => str_replace('_', ' ', $c), $t['pending'])) }}</p>
                @endif

                <div class="mt-auto space-y-2">
                    @unless ($t['usable'])
                        <p class="text-xs text-zinc-500">Enroll a tablet as Tablet {{ $t['n'] }} or pair one with the coin box first.</p>
                    @endunless
                    @if ($t['selected'])
                        <p class="btn w-full bg-brand text-white">Next coins → this tablet</p>
                    @else
                        <button wire:click="select({{ $t['n'] }})" class="btn-primary w-full" @disabled(! $t['usable'])>Select for next coins</button>
                    @endif
                    <div class="grid grid-cols-3 gap-1.5">
                        @foreach ([5, 15, 30] as $m)
                            <button wire:click="addTime({{ $t['n'] }}, {{ $m }})" wire:confirm="Give Tablet {{ $t['n'] }} {{ $m }} free minutes?" class="btn-outline px-1 py-1.5" @disabled(! $t['usable'])>+{{ $m }} min</button>
                        @endforeach
                    </div>
                    <button wire:click="endSession({{ $t['n'] }})" wire:confirm="End Tablet {{ $t['n'] }}'s session now? The customer loses the remaining time." class="btn-danger w-full py-1.5" @disabled(! $t['remaining'])>End session</button>
                </div>
            </article>
        @endforeach
    </section>
</div>
