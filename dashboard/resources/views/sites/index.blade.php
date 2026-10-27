<x-app-layout title="Sites">
    <div class="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
            <h1 class="text-2xl font-black">Sites</h1>
            <p class="muted">Each site is one coin box shared by up to {{ \App\Models\Site::MAX_STATIONS }} tablets.</p>
        </div>
        <form method="post" action="{{ route('sites.store') }}" class="flex gap-2">
            @csrf
            <input name="name" required maxlength="100" placeholder="New site name" class="field mt-0 w-56">
            <button class="btn-primary">Add site</button>
        </form>
    </div>

    @if ($sites->isEmpty())
        <div class="card text-center">
            <p class="font-semibold">No sites yet.</p>
            <p class="muted">Add one above, then enroll its coin box and tablets.</p>
        </div>
    @else
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            @foreach ($sites as $site)
                @php
                    $boxes = $site->devices()->where('device_type', 'controller')->whereNull('revoked_at')->get();
                    $tablets = $site->devices()->where('device_type', 'phone')->whereNull('revoked_at')->get();
                    $held = (int) $site->held_pulses + (int) $boxes->whereNotNull('station_no')->sum('held_pulses');
                @endphp
                <a href="{{ route('sites.show', $site) }}" class="card block transition hover:border-brand hover:shadow-md">
                    <div class="flex items-start justify-between">
                        <h2 class="text-lg font-black">{{ $site->name }}</h2>
                        <span class="text-xl font-black text-coin">₱{{ number_format((int) ($today[$site->id] ?? 0)) }}</span>
                    </div>
                    <p class="muted">today</p>
                    <div class="mt-3 flex flex-wrap gap-2 text-xs font-semibold">
                        @php $boxesOnline = $boxes->filter(fn ($b) => $b->presence() === 'online')->count(); @endphp
                        <span class="pill {{ $boxes->isNotEmpty() && $boxesOnline === $boxes->count() ? 'bg-brand-soft text-brand-deep' : 'bg-zinc-100 text-zinc-500' }}">{{ $boxes->isEmpty() ? 'Coin box: not enrolled' : $boxesOnline.' / '.$boxes->count().' coin boxes online' }}</span>
                        <span class="pill bg-zinc-100 text-charcoal">{{ $tablets->filter(fn ($t) => $t->presence() === 'online')->count() }} / {{ $tablets->count() }} tablets online</span>
                        @if ($held > 0)
                            <span class="pill bg-coin-soft text-coin">₱{{ $held }} held</span>
                        @endif
                    </div>
                </a>
            @endforeach
        </div>
    @endif
</x-app-layout>
