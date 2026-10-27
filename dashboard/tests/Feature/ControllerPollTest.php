<?php

use App\Models\AuditLog;
use App\Models\ControllerCommand;
use App\Services\ControllerChannel;

it('delivers the attendant selection with a version and expiry', function () {
    $site = site();
    [, $t] = enrollDevice($site, 'controller');
    deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->assertOk()
        ->assertJsonPath('selection.station', 0)->assertJsonPath('commands', []);

    app(ControllerChannel::class)->select($site, 2, $site->owner);
    $sel = deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->assertOk()->json('selection');
    expect($sel['station'])->toBe(2)->and($sel['version'])->toBe(1)->and($sel['ttl_s'])->toBeGreaterThan(80);

    // Expired selections are not delivered.
    $site->update(['selection_expires_at' => now()->subSecond()]);
    deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->assertJsonPath('selection.station', 0);
});

it('stores what the coin box reports', function () {
    $site = site();
    [, $t] = enrollDevice($site, 'controller');
    deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4', 'selected' => 3, 'selected_ttl_s' => 42, 'held_pulses' => 10])->assertOk();
    $site->refresh();
    expect($site->reported_station)->toBe(3)->and($site->reported_ttl_s)->toBe(42)
        ->and($site->held_pulses)->toBe(10)->and($site->last_poll_at)->not->toBeNull();
});

it('re-sends commands until acknowledged and records the result', function () {
    $site = site();
    [, $t] = enrollDevice($site, 'controller');
    $channel = app(ControllerChannel::class);
    $add = $channel->addTime($site, 2, 900, $site->owner);
    $end = $channel->endSession($site, 4, $site->owner);

    $cmds = deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands');
    expect($cmds)->toBe([
        ['id' => $add->id, 'type' => 'add_time', 'station' => 2, 'seconds' => 900],
        ['id' => $end->id, 'type' => 'end_session', 'station' => 4, 'seconds' => 0],
    ]);
    // Not acknowledged yet → sent again.
    expect(deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands'))->toHaveCount(2);

    deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4', 'acks' => [['id' => $add->id, 'result' => 'ok']]])->assertOk();
    expect(deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands.*.id'))->toBe([$end->id])
        ->and($add->fresh()->applied_at)->not->toBeNull()
        ->and($add->fresh()->result)->toBe('ok');
});

it('only lets a coin box acknowledge commands of its own site', function () {
    $mine = site(admin('a'), 'A');
    $other = site(admin('b'), 'B');
    [, $t] = enrollDevice($mine, 'controller');
    $foreign = app(ControllerChannel::class)->addTime($other, 1, 600, $other->owner);
    deviceCall($t, 'controller/poll', ['boot_id' => 'a1b2c3d4', 'acks' => [['id' => $foreign->id]]])->assertOk();
    expect($foreign->fresh()->applied_at)->toBeNull();
});

it('validates and audits dashboard commands', function () {
    $site = site();
    $channel = app(ControllerChannel::class);
    expect(fn () => $channel->addTime($site, 5, 600, $site->owner))->toThrow(InvalidArgumentException::class)
        ->and(fn () => $channel->addTime($site, 1, 10, $site->owner))->toThrow(InvalidArgumentException::class)
        ->and(fn () => $channel->addTime($site, 1, 999999, $site->owner))->toThrow(InvalidArgumentException::class);

    $channel->assignHeld($site, 1, $site->owner);
    $channel->select($site, 1, $site->owner);
    expect(ControllerCommand::count())->toBe(1)
        ->and(AuditLog::pluck('action')->all())->toBe(['site.command.assign_held', 'site.select_station']);
});

it('routes each tablet\'s commands to its own kiosk coin box as station 1', function () {
    $site = site();
    [$box2, $t2] = enrollDevice($site, 'controller', 2);
    [, $t3] = enrollDevice($site, 'controller', 3);
    $channel = app(ControllerChannel::class);
    $add = $channel->addTime($site, 2, 900, $site->owner);
    $end = $channel->endSession($site, 3, $site->owner);
    $channel->select($site, 2, $site->owner); // ignored by kiosk coin boxes

    expect($add->device_id)->toBe($box2->id);
    $res = deviceCall($t2, 'controller/poll', ['boot_id' => 'a1b2c3d4', 'held_pulses' => 7])->assertOk();
    expect($res->json('commands'))->toBe([['id' => $add->id, 'type' => 'add_time', 'station' => 1, 'seconds' => 900]])
        ->and($res->json('selection'))->toBe(['version' => 0, 'station' => 0, 'ttl_s' => 0])
        ->and($box2->fresh()->held_pulses)->toBe(7)
        ->and($site->fresh()->held_pulses)->toBe(0);
    expect(deviceCall($t3, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands'))
        ->toBe([['id' => $end->id, 'type' => 'end_session', 'station' => 1, 'seconds' => 0]]);

    // A kiosk coin box cannot acknowledge another box's command.
    deviceCall($t3, 'controller/poll', ['boot_id' => 'a1b2c3d4', 'acks' => [['id' => $add->id]]])->assertOk();
    expect($add->fresh()->applied_at)->toBeNull();
});

it('sends tablets without their own coin box to the shared one', function () {
    $site = site();
    [, $shared] = enrollDevice($site, 'controller');
    [, $own] = enrollDevice($site, 'controller', 1);
    $channel = app(ControllerChannel::class);
    $one = $channel->addTime($site, 1, 600, $site->owner);
    $four = $channel->addTime($site, 4, 600, $site->owner);
    expect(deviceCall($shared, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands.*.id'))->toBe([$four->id])
        ->and(deviceCall($own, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->json('commands.*.id'))->toBe([$one->id]);
});
