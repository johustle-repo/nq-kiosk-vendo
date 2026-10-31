<?php

namespace App\Http\Controllers;

use App\Models\CoinEvent;
use App\Models\Device;
use App\Models\Site;
use Carbon\CarbonImmutable;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\View\View;

/**
 * Pesos per tablet over a period, counted in shop days (display timezone).
 *
 * One pulse is one peso. A tablet earns its "credit" events and the held coins
 * the attendant later gave it ("assign"); coins still held count only in the
 * total, so tablets plus held always add up to what went into the coin boxes.
 */
class EarningsController extends Controller
{
    public const PERIODS = ['today' => 'Today', 'yesterday' => 'Yesterday', '7d' => 'Last 7 days', 'month' => 'This month', 'custom' => 'Custom'];

    /** Longest custom range, in days. */
    public const MAX_DAYS = 92;

    public function show(Request $request, Site $site): View
    {
        Gate::authorize('manage-site', $site);
        $tz = config('app.display_timezone', 'Asia/Manila');
        $period = array_key_exists((string) $request->query('period'), self::PERIODS) ? (string) $request->query('period') : 'today';
        [$from, $to] = self::range($period, $request->query('from'), $request->query('to'), CarbonImmutable::now($tz));

        $events = CoinEvent::where('site_id', $site->id)->whereIn('event_type', ['credit', 'held', 'assign'])
            ->where('occurred_at', '>=', $from->utc())->where('occurred_at', '<', $to->addDay()->utc())
            ->get(['station_no', 'event_type', 'pulses', 'occurred_at']);

        $days = [];
        for ($d = $to; $d >= $from; $d = $d->subDay()) {
            $days[$d->toDateString()] = ['tablets' => [], 'total' => 0];
        }
        $tablets = [];
        $held = 0;
        foreach ($events as $e) {
            $day = $e->occurred_at->timezone($tz)->toDateString();
            if (! isset($days[$day])) {
                continue;
            }
            $pesos = (int) $e->pulses;
            if ($e->event_type === 'held') {
                $held += $pesos;
            } else {
                $n = (int) $e->station_no;
                $tablets[$n] = ($tablets[$n] ?? 0) + $pesos;
                $days[$day]['tablets'][$n] = ($days[$day]['tablets'][$n] ?? 0) + $pesos;
                if ($e->event_type === 'assign') {
                    $held -= $pesos; // the held coins were counted when they went in
                }
            }
            if ($e->event_type !== 'assign') {
                $days[$day]['total'] += $pesos;
            }
        }

        // Tablets enrolled now, plus any that earned in the period.
        $numbers = $site->devices()->whereNull('revoked_at')->whereNotNull('station_no')
            ->whereIn('device_type', [Device::TYPE_PHONE, Device::TYPE_CONTROLLER])->pluck('station_no')
            ->map(fn ($n) => (int) $n)->merge(array_keys($tablets))->filter(fn ($n) => $n >= 1)->unique()->sort()->values()->all();

        return view('sites.earnings', [
            'site' => $site,
            'period' => $period,
            'from' => $from,
            'to' => $to,
            'numbers' => $numbers,
            'tablets' => $tablets,
            // Held coins given out in this period may have gone in before it.
            'held' => max(0, $held),
            'total' => array_sum(array_column($days, 'total')),
            'days' => $days,
        ]);
    }

    /** @return array{0: CarbonImmutable, 1: CarbonImmutable} first and last shop day, inclusive */
    public static function range(string $period, mixed $from, mixed $to, CarbonImmutable $now): array
    {
        $today = $now->startOfDay();

        return match ($period) {
            'yesterday' => [$today->subDay(), $today->subDay()],
            '7d' => [$today->subDays(6), $today],
            'month' => [$today->startOfMonth(), $today],
            'custom' => self::customRange($from, $to, $today),
            default => [$today, $today],
        };
    }

    /** @return array{0: CarbonImmutable, 1: CarbonImmutable} */
    private static function customRange(mixed $from, mixed $to, CarbonImmutable $today): array
    {
        $parse = function (mixed $v) use ($today): ?CarbonImmutable {
            if (! is_string($v) || preg_match('/^\d{4}-\d{2}-\d{2}$/', $v) !== 1) {
                return null;
            }
            $d = CarbonImmutable::createFromFormat('!Y-m-d', $v, $today->timezone);

            return $d && $d->toDateString() === $v ? $d : null;
        };
        $end = min($parse($to) ?? $today, $today);
        $start = $parse($from) ?? $end;
        if ($start > $end) {
            [$start, $end] = [$end, $start];
        }
        if ($start->diffInDays($end) >= self::MAX_DAYS) {
            $start = $end->subDays(self::MAX_DAYS - 1);
        }

        return [$start, $end];
    }
}
