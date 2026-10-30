<?php

use App\Livewire\SitePanel;
use App\Models\AuditLog;
use App\Models\ControllerCommand;
use App\Services\ControllerChannel;
use Livewire\Livewire;

/** Kiosk coin box for tablet $station reporting firmware $fw and $dash seconds of "Charge now" left. */
function chargeBox($site, int $station = 1, string $fw = '2.5.0', int $dash = 0, ?bool $relay = null): array
{
    [$box, $t] = enrollDevice($site, 'controller', $station);
    deviceCall($t, 'controller/sync', ['fw_version' => $fw] + syncBody(status: [
        'charge_relay' => $relay ?? $dash > 0,
        'stations' => [['station' => 1, 'session' => 'idle', 'remaining_s' => 0, 'session_no' => 0, 'paired' => true, 'dash_charge_s' => $dash]],
    ]))->assertOk();

    return [$box->fresh(), $t];
}

it('sends Charge now to the tablet\'s own coin box as station 1, audited', function () {
    $site = site();
    [$box, $t] = chargeBox($site, 2);

    $cmd = app(ControllerChannel::class)->chargeNow($site, 2, $site->owner);
    expect($cmd->device_id)->toBe($box->id)->and($cmd->seconds)->toBe(4 * 3600);
    deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->assertOk()
        ->assertJsonPath('commands', [['id' => $cmd->id, 'type' => 'charge_on', 'station' => 1, 'seconds' => 4 * 3600]]);
    expect(AuditLog::where('action', 'site.command.charge_on')->exists())->toBeTrue();

    $off = app(ControllerChannel::class)->stopCharge($site, 2, $site->owner);
    expect($off->type)->toBe('charge_off')->and($off->device_id)->toBe($box->id);
});

it('refuses Charge now without a coin box or with older firmware', function () {
    $site = site();
    expect(fn () => app(ControllerChannel::class)->chargeNow($site, 1, $site->owner))
        ->toThrow(InvalidArgumentException::class, 'has no coin box');

    chargeBox($site, 1, '2.4.0');
    expect(fn () => app(ControllerChannel::class)->chargeNow($site, 1, $site->owner))
        ->toThrow(InvalidArgumentException::class, 'firmware 2.5.0');
});

it('stores the charger state the coin box reports', function () {
    $site = site();
    [$box] = chargeBox($site, 3, dash: 600);
    expect($box->status('charge_relay'))->toBeTrue()
        ->and(ControllerChannel::dashChargeSeconds($box, 3))->toBeGreaterThan(590);
});

it('stops Charge now once the tablet reports a full battery, only once', function () {
    $site = site();
    [$box] = chargeBox($site, 1, dash: 3000);
    [, $t] = enrollDevice($site, 'phone', 1);
    $beat = ['boot_id' => 'beef0001', 'uptime_ms' => 1, 'battery' => ['pct' => 99, 'charging' => true]];

    deviceCall($t, 'phone/heartbeat', $beat)->assertOk();
    expect(ControllerCommand::where('type', 'charge_off')->count())->toBe(0);

    deviceCall($t, 'phone/heartbeat', ['uptime_ms' => 2, 'battery' => ['pct' => 100, 'charging' => true]] + $beat)->assertOk();
    deviceCall($t, 'phone/heartbeat', ['uptime_ms' => 3, 'battery' => ['pct' => 100, 'charging' => true]] + $beat)->assertOk();
    $off = ControllerCommand::where('type', 'charge_off')->get();
    expect($off)->toHaveCount(1)->and($off[0]->device_id)->toBe($box->id)->and($off[0]->created_by)->toBeNull();
});

it('also cancels a Charge now still waiting for the coin box when the battery is full', function () {
    $site = site();
    chargeBox($site, 1);
    [, $t] = enrollDevice($site, 'phone', 1);
    app(ControllerChannel::class)->chargeNow($site, 1, $site->owner);

    deviceCall($t, 'phone/heartbeat', ['boot_id' => 'beef0001', 'uptime_ms' => 1, 'battery' => ['pct' => 100]])->assertOk();
    expect(ControllerCommand::where('type', 'charge_off')->count())->toBe(1);
});

it('shows the charger and the Charge now / Stop charging buttons on the tablet card', function () {
    $site = site();
    chargeBox($site, 1);
    enrollDevice($site, 'phone', 1);
    $this->actingAs($site->owner);

    Livewire::test(SitePanel::class, ['site' => $site])
        ->assertSee('Charger')->assertSee('Charge now')
        ->call('chargeNow', 1)->assertSee('Charging Tablet 1')->assertSee('Stop charging')
        ->call('stopCharge', 1)->assertSee('Stopping charging');
    expect(ControllerCommand::pluck('type')->all())->toBe(['charge_on', 'charge_off']);
});

it('disables Charge now for coin box firmware before 2.5.0', function () {
    $site = site();
    chargeBox($site, 1, '2.4.0');
    enrollDevice($site, 'phone', 1);
    $this->actingAs($site->owner);

    Livewire::test(SitePanel::class, ['site' => $site])->assertSee('Charge now needs coin box firmware 2.5.0');
});
