<?php

use App\Http\Controllers\EarningsController;
use App\Models\CoinEvent;
use App\Models\Device;
use App\Models\Site;
use Carbon\CarbonImmutable;

/** A coin box event at a Philippine local time ("Y-m-d H:i"). */
function coin(Site $site, Device $box, string $type, int $station, int $pesos, string $manila): void
{
    static $seq = 0;
    CoinEvent::create([
        'device_id' => $box->id, 'site_id' => $site->id, 'station_no' => $station, 'boot_id' => 'b00710ad', 'seq' => ++$seq,
        'event_type' => $type, 'session_no' => 1, 'pulses' => $pesos, 'device_uptime_ms' => 1,
        'occurred_at' => CarbonImmutable::parse($manila, 'Asia/Manila')->utc(), 'received_at' => now(),
    ]);
}

beforeEach(function () {
    $this->travelTo(CarbonImmutable::parse('2026-10-31 15:00', 'Asia/Manila'));
});

it('shows each tablet its own pesos for today, in Philippine days', function () {
    $site = site();
    [$box1] = enrollDevice($site, 'controller', 1);
    [$box2] = enrollDevice($site, 'controller', 2);
    coin($site, $box1, 'credit', 1, 5, '2026-10-31 00:30'); // after shop midnight (16:30 UTC the day before)
    coin($site, $box1, 'credit', 1, 10, '2026-10-31 14:00');
    coin($site, $box2, 'credit', 2, 20, '2026-10-31 09:00');
    coin($site, $box2, 'credit', 2, 1, '2026-10-30 23:59'); // yesterday
    coin($site, $box1, 'admin_credit', 1, 0, '2026-10-31 10:00');

    $this->actingAs($site->owner)->get(route('sites.earnings', $site))->assertOk()
        ->assertViewHas('tablets', [1 => 15, 2 => 20])
        ->assertViewHas('total', 35)
        ->assertSeeInOrder(['Tablet 1', '₱15', 'Tablet 2', '₱20', 'Total', '₱35']);
});

it('counts held coins in the total and moves assigned ones to the tablet', function () {
    $site = site();
    [$box] = enrollDevice($site, 'controller');
    coin($site, $box, 'held', 0, 10, '2026-10-31 08:00');
    coin($site, $box, 'assign', 2, 6, '2026-10-31 08:05');

    $this->actingAs($site->owner)->get(route('sites.earnings', $site))->assertOk()
        ->assertViewHas('tablets', [2 => 6])
        ->assertViewHas('held', 4)
        ->assertViewHas('total', 10);
});

it('breaks a period down by day, newest first', function () {
    $site = site();
    [$box] = enrollDevice($site, 'controller', 1);
    coin($site, $box, 'credit', 1, 3, '2026-10-29 12:00');
    coin($site, $box, 'credit', 1, 4, '2026-10-31 12:00');
    coin($site, $box, 'credit', 1, 9, '2026-10-20 12:00'); // before the 7 days

    $res = $this->actingAs($site->owner)->get(route('sites.earnings', [$site, 'period' => '7d']))->assertOk()
        ->assertViewHas('total', 7)->assertSee('By day');
    $days = $res->viewData('days');
    expect(array_keys($days))->toHaveCount(7)
        ->and(array_key_first($days))->toBe('2026-10-31')
        ->and($days['2026-10-29']['total'])->toBe(3);
});

it('keeps custom ranges sane', function () {
    $now = CarbonImmutable::now('Asia/Manila');
    $r = fn (mixed $from, mixed $to) => array_map(fn ($d) => $d->toDateString(), EarningsController::range('custom', $from, $to, $now));

    expect($r('2026-10-01', '2026-10-10'))->toBe(['2026-10-01', '2026-10-10'])
        ->and($r('2026-10-10', '2026-10-01'))->toBe(['2026-10-01', '2026-10-10'])
        ->and($r('2026-10-01', '2027-01-01'))->toBe(['2026-10-01', '2026-10-31'])
        ->and($r('garbage', '2026-02-30'))->toBe(['2026-10-31', '2026-10-31'])
        ->and($r('2025-01-01', '2026-10-31'))->toBe(['2026-08-01', '2026-10-31']);
});

it('only shows a site to its owner', function () {
    $site = site();
    $this->actingAs(admin('someone-else'))->get(route('sites.earnings', $site))->assertForbidden();
});

it('links to the earnings page and counts today from shop midnight on the site panel', function () {
    $site = site();
    [$box] = enrollDevice($site, 'controller', 1);
    coin($site, $box, 'credit', 1, 5, '2026-10-31 07:00'); // before 08:00, which was UTC midnight
    $this->actingAs($site->owner)->get(route('sites.show', $site))->assertOk()
        ->assertSee(route('sites.earnings', $site))->assertSee('₱5');
});
