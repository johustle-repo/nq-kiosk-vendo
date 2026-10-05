<?php

use App\Models\Device;
use App\Models\Site;
use App\Models\User;
use App\Services\SiteService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Testing\TestResponse;
use Tests\TestCase;

pest()->extend(TestCase::class)->use(RefreshDatabase::class)->in('Feature');

// ---------------------------------------------------------------- helpers

function admin(string $username = 'owner'): User
{
    return User::factory()->create(['username' => $username, 'password' => 'correct-horse-42']);
}

function site(?User $owner = null, string $name = 'Shop'): Site
{
    return app(SiteService::class)->createSite($owner ?? admin(), $name);
}

/**
 * Enrolls a device through the real API and returns [Device, token].
 *
 * @return array{0: Device, 1: string}
 */
function enrollDevice(Site $site, string $type, ?int $station = null): array
{
    $code = app(SiteService::class)->createEnrollmentCode($site, $site->owner, $type, $station);
    $res = test()->postJson('/api/v1/devices/enroll', ['device_type' => $type, 'enrollment_code' => $code, 'name' => ucfirst($type)]);
    $res->assertStatus(201);

    return [Device::where('public_id', $res->json('device_id'))->firstOrFail(), $res->json('device_token')];
}

function deviceCall(string $token, string $path, array $body): TestResponse
{
    return test()->withHeader('Authorization', 'Bearer '.$token)->postJson('/api/v1/'.$path, $body);
}

/** A coin box sync body (protocol 2 unless given). */
function syncBody(array $events = [], array $status = [], int $protocol = 2, string $boot = 'a1b2c3d4'): array
{
    return [
        'protocol' => $protocol,
        'boot_id' => $boot,
        'uptime_ms' => 100000,
        'fw_version' => '2.0.0',
        'config_version_applied' => 1,
        'status' => $status + ['session' => 'idle', 'remaining_s' => 0, 'seq' => count($events), 'session_no' => 0],
        'events' => $events,
    ];
}

function coinEvent(int $seq, int $station = 1, int $pulses = 5, int $session = 1, string $type = 'credit'): array
{
    return [
        'seq' => $seq, 'type' => $type, 'station' => $station, 'session_no' => $session, 'pulses' => $pulses,
        'seconds' => $type === 'held' ? 0 : $pulses * 240, 'rate_version' => 1, 'remaining_after' => $pulses * 240,
        'uptime_ms' => 90000 + $seq, 'unix_time' => 0,
    ];
}
