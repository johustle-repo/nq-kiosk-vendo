<?php

use App\Livewire\SitePanel;
use App\Models\ControllerCommand;
use App\Services\ControllerChannel;
use Livewire\Livewire;

/** A tablet (app 1.2.0+) that says it takes dashboard time itself. */
function newTablet($site, int $station = 1): array
{
    [$phone, $t] = enrollDevice($site, 'phone', $station);
    deviceCall($t, 'phone/heartbeat', ['boot_id' => 'beef0001', 'uptime_ms' => 1, 'features' => ['dashboard_time']])->assertOk();

    return [$phone->fresh(), $t];
}

it('sends added time to a tablet that takes it, over its heartbeat, until acknowledged', function () {
    $site = site();
    [, $box] = enrollDevice($site, 'controller');
    [$phone, $t] = newTablet($site, 2);

    $add = app(ControllerChannel::class)->addTime($site, 2, 900, $site->owner);
    expect($add->device_id)->toBe($phone->id);
    // The coin box does not get it.
    expect(deviceCall($box, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands'))->toBe([]);

    $beat = ['boot_id' => 'beef0001', 'uptime_ms' => 2, 'features' => ['dashboard_time']];
    deviceCall($t, 'phone/heartbeat', $beat)->assertOk()
        ->assertJsonPath('commands', [['id' => $add->id, 'type' => 'add_time', 'seconds' => 900]]);
    // Re-sent until the tablet acknowledges it.
    expect(deviceCall($t, 'phone/heartbeat', ['uptime_ms' => 3] + $beat)->json('commands'))->toHaveCount(1);

    deviceCall($t, 'phone/heartbeat', ['uptime_ms' => 4, 'acks' => [['id' => $add->id, 'result' => 'ok']]] + $beat)
        ->assertOk()->assertJsonPath('commands', []);
    expect($add->fresh()->applied_at)->not->toBeNull()->and($add->fresh()->result)->toBe('ok');
});

it('still sends added time through the coin box for older tablet apps', function () {
    $site = site();
    [$boxDevice] = enrollDevice($site, 'controller');
    [, $t] = enrollDevice($site, 'phone', 1);
    deviceCall($t, 'phone/heartbeat', ['boot_id' => 'beef0001', 'uptime_ms' => 1])->assertOk()->assertJsonPath('commands', []);

    expect(app(ControllerChannel::class)->addTime($site, 1, 600, $site->owner)->device_id)->toBe($boxDevice->id);
});

it('ends the session on both the tablet and its coin box', function () {
    $site = site();
    [$boxDevice] = enrollDevice($site, 'controller', 1);
    [$phone] = newTablet($site, 1);

    app(ControllerChannel::class)->endSession($site, 1, $site->owner);
    expect(ControllerCommand::where('type', 'end_session')->pluck('device_id')->sort()->values()->all())
        ->toBe(collect([$boxDevice->id, $phone->id])->sort()->values()->all());
});

it('does not let a tablet acknowledge another tablet\'s commands', function () {
    $site = site();
    newTablet($site, 1);
    [, $t2] = newTablet($site, 2);
    $add = app(ControllerChannel::class)->addTime($site, 1, 600, $site->owner);
    deviceCall($t2, 'phone/heartbeat', ['boot_id' => 'beef0001', 'uptime_ms' => 9, 'acks' => [['id' => $add->id]]])
        ->assertOk()->assertJsonPath('commands', []);
    expect($add->fresh()->applied_at)->toBeNull();
});

it('adds typed minutes from the site panel and shows the tablet\'s free time', function () {
    $site = site();
    [$phone, $t] = newTablet($site, 3);
    $this->actingAs($site->owner);

    Livewire::test(SitePanel::class, ['site' => $site])
        ->set('customMinutes.3', '45')->call('addCustomTime', 3)
        ->assertSet('flash', 'Adding 45 min to Tablet 3. It arrives within about 30 seconds.')
        ->set('customMinutes.3', '0')->call('addCustomTime', 3)->assertSet('flash', 'Type whole minutes from 1 to 240.')
        ->set('customMinutes.3', '2.5')->call('addCustomTime', 3)->assertSet('flash', 'Type whole minutes from 1 to 240.');
    expect(ControllerCommand::where('device_id', $phone->id)->pluck('seconds')->all())->toBe([2700]);

    deviceCall($t, 'phone/heartbeat', ['boot_id' => 'beef0001', 'uptime_ms' => 5, 'features' => ['dashboard_time'],
        'dashboard_time' => ['remaining_s' => 2700, 'running' => false]])->assertOk();
    Livewire::test(SitePanel::class, ['site' => $site])->assertSee('free from the dashboard')->assertSee('0:45:00');
});
