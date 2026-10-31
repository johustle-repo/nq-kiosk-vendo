<x-app-layout :title="'Earnings · '.$site->name">
    <div class="mb-5">
        <a href="{{ route('sites.show', $site) }}" class="text-sm font-semibold text-brand hover:underline">← {{ $site->name }}</a>
        <h1 class="text-2xl font-black">Earnings per tablet</h1>
        <p class="muted">{{ $from->equalTo($to) ? $from->format('l, M j, Y') : $from->format('M j, Y').' – '.$to->format('M j, Y') }}</p>
    </div>

    <section class="card mb-5">
        <div class="mb-3 flex flex-wrap gap-2">
            @foreach (\App\Http\Controllers\EarningsController::PERIODS as $key => $label)
                @continue($key === 'custom')
                <a href="{{ route('sites.earnings', [$site, 'period' => $key]) }}"
                   @class(['py-1.5 px-3', 'btn-primary' => $period === $key, 'btn-outline' => $period !== $key])>{{ $label }}</a>
            @endforeach
        </div>
        <form method="get" action="{{ route('sites.earnings', $site) }}" class="flex flex-wrap items-end gap-2">
            <input type="hidden" name="period" value="custom">
            <label class="label">From
                <input type="date" name="from" value="{{ $from->toDateString() }}" max="{{ now(config('app.display_timezone', 'Asia/Manila'))->toDateString() }}" class="field">
            </label>
            <label class="label">To
                <input type="date" name="to" value="{{ $to->toDateString() }}" max="{{ now(config('app.display_timezone', 'Asia/Manila'))->toDateString() }}" class="field">
            </label>
            <button class="btn-outline py-2">Show</button>
        </form>
        <p class="muted mt-2">Up to {{ \App\Http\Controllers\EarningsController::MAX_DAYS }} days. Days run midnight to midnight, Philippine time.</p>
    </section>

    <div class="mb-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        @foreach ($numbers as $n)
            <section class="card">
                <p class="muted">Tablet {{ $n }}</p>
                <p class="text-2xl font-black text-coin">₱{{ number_format($tablets[$n] ?? 0) }}</p>
            </section>
        @endforeach
        @if ($held > 0)
            <section class="card">
                <p class="muted">Held (not given to a tablet)</p>
                <p class="text-2xl font-black text-coin">₱{{ number_format($held) }}</p>
            </section>
        @endif
        <section class="card border-2 border-brand">
            <p class="muted">Total</p>
            <p class="text-2xl font-black text-coin">₱{{ number_format($total) }}</p>
        </section>
    </div>

    @if (count($days) > 1)
        <section class="card overflow-x-auto">
            <h2 class="mb-2 text-lg font-black">By day</h2>
            <table class="w-full text-left text-sm">
                <thead class="text-xs uppercase tracking-wide text-zinc-500">
                <tr>
                    <th class="py-2">Day</th>
                    @foreach ($numbers as $n)<th class="text-right">Tablet {{ $n }}</th>@endforeach
                    <th class="text-right">Total</th>
                </tr>
                </thead>
                <tbody class="divide-y divide-zinc-100">
                @foreach ($days as $date => $day)
                    <tr>
                        <td class="py-2 whitespace-nowrap">{{ \Carbon\CarbonImmutable::parse($date)->format('D, M j') }}</td>
                        @foreach ($numbers as $n)<td class="text-right">₱{{ number_format($day['tablets'][$n] ?? 0) }}</td>@endforeach
                        <td class="text-right font-bold">₱{{ number_format($day['total']) }}</td>
                    </tr>
                @endforeach
                </tbody>
            </table>
        </section>
    @endif
</x-app-layout>
