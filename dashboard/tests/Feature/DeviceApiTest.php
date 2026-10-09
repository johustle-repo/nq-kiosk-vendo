<?php

use App\Models\CoinEvent;
use App\Models\Device;
use App\Models\EnrollmentCode;
use App\Models\KioskSession;
use App\Services\SiteService;

// Ported from the original backend's tests/run.php, plus protocol 2 (tablets).

it('reports health', function () {
    $this->getJson('/api/v1/health')->assertOk()
        ->assertJson(['ok' => true, 'database' => 'ok', 'pending_migrations' => 0, 'api_version' => 'v1']);
});

it('answers unknown API routes with a 404 JSON error', function () {
    $this->getJson('/api/v1/nope')->assertNotFound()->assertJsonPath('error.code', 'not_found');
});

it('makes enrollment codes single-use, typed and expiring', function () {
    $site = site();
    $sites = app(SiteService::class);

    $code = $sites->createEnrollmentCode($site, $site->owner, 'controller', null);
    $this->postJson('/api/v1/devices/enroll', ['device_type' => 'phone', 'enrollment_code' => $code])
        ->assertForbidden()->assertJsonPath('error.code', 'wrong_device_type');
    $this->postJson('/api/v1/devices/enroll', ['device_type' => 'controller', 'enrollment_code' => strtolower($code)])
        ->assertCreated()->assertJsonStructure(['device_id', 'device_token']);
    $this->postJson('/api/v1/devices/enroll', ['device_type' => 'controller', 'enrollment_code' => $code])
        ->assertForbidden()->assertJsonPath('error.code', 'invalid_code');

    $expired = $sites->createEnrollmentCode($site, $site->owner, 'controller', null);
    EnrollmentCode::query()->update(['expires_at' => now()->subMinute()]);
    $this->postJson('/api/v1/devices/enroll', ['device_type' => 'controller', 'enrollment_code' => $expired])
        ->assertForbidden();
});

it('stores the tablet number from a phone enrollment code', function () {
    [$phone] = enrollDevice(site(), 'phone', 3);
    expect($phone->station_no)->toBe(3);
});

it('rate limits enrollment per IP', function () {
    for ($i = 0; $i < 10; $i++) {
        $this->postJson('/api/v1/devices/enroll', ['device_type' => 'phone', 'enrollment_code' => 'AAAAA-BBBBB']);
    }
    $this->postJson('/api/v1/devices/enroll', ['device_type' => 'phone', 'enrollment_code' => 'AAAAA-BBBBB'])
        ->assertStatus(429)->assertJsonPath('error.code', 'rate_limited');
});

it('checks device authentication and credential type', function () {
    $site = site();
    [, $ctl] = enrollDevice($site, 'controller');
    [$phone, $phoneToken] = enrollDevice($site, 'phone', 1);

    $this->postJson('/api/v1/controller/sync', syncBody())->assertUnauthorized();
    deviceCall('vkd_0000000000000000_'.str_repeat('a', 43), 'controller/sync', syncBody())->assertUnauthorized();
    deviceCall($phoneToken, 'controller/sync', syncBody())->assertUnauthorized(); // phone token as controller
    deviceCall($phoneToken, 'controller/poll', ['boot_id' => 'a1b2c3d4'])->assertUnauthorized();
    deviceCall($ctl, 'phone/heartbeat', ['boot_id' => 'a1b2c3d4', 'uptime_ms' => 1])->assertUnauthorized();
    deviceCall($ctl, 'controller/sync', syncBody())->assertOk();

    $phone->update(['revoked_at' => now()]);
    deviceCall($phoneToken, 'phone/heartbeat', ['boot_id' => 'a1b2c3d4', 'uptime_ms' => 1])->assertUnauthorized();
});

it('stores events to the owning site only and never duplicates retried syncs', function () {
    $a = site(admin('a'), 'A');
    $b = site(admin('b'), 'B');
    [, $tokenA] = enrollDevice($a, 'controller');
    enrollDevice($b, 'controller');

    $body = syncBody([coinEvent(1, station: 2), coinEvent(2, station: 2, pulses: 1)]);
    deviceCall($tokenA, 'controller/sync', $body)->assertOk()->assertJsonPath('ack.acked_seqs', [1, 2])->assertJsonPath('ack.inserted', 2);
    deviceCall($tokenA, 'controller/sync', $body)->assertOk()->assertJsonPath('ack.inserted', 0);

    expect(CoinEvent::where('site_id', $a->id)->count())->toBe(2)
        ->and(CoinEvent::where('site_id', $b->id)->count())->toBe(0)
        ->and(CoinEvent::first()->station_no)->toBe(2);
    $session = KioskSession::first();
    expect($session->station_no)->toBe(2)->and($session->total_pulses)->toBe(6)->and($session->credit_count)->toBe(2);
});

it('treats the same seq after a controller restart (new boot id) as a new event', function () {
    [, $t] = enrollDevice(site(), 'controller');
    deviceCall($t, 'controller/sync', syncBody([coinEvent(1)], boot: 'aaaaaaaa'))->assertOk();
    deviceCall($t, 'controller/sync', syncBody([coinEvent(1)], boot: 'bbbbbbbb'))->assertOk();
    expect(CoinEvent::count())->toBe(2);
});

it('does not overwrite a newer status with a stale one', function () {
    [$ctl, $t] = enrollDevice(site(), 'controller');
    deviceCall($t, 'controller/sync', ['uptime_ms' => 200000] + syncBody(status: ['remaining_s' => 50]))->assertOk();
    deviceCall($t, 'controller/sync', ['uptime_ms' => 100000] + syncBody(status: ['remaining_s' => 99]))->assertOk();
    expect($ctl->fresh()->status('remaining_s'))->toBe(50);
});

it('rejects invalid events individually and malformed bodies with 422', function () {
    [, $t] = enrollDevice(site(), 'controller');
    $bad = coinEvent(2, pulses: 0);           // credit without pulses
    $wrongStation = coinEvent(3, station: 0); // only held coins may be station 0
    deviceCall($t, 'controller/sync', syncBody([coinEvent(1), $bad, $wrongStation]))
        ->assertOk()->assertJsonPath('ack.acked_seqs', [1])->assertJsonPath('ack.rejected_seqs', [2, 3]);

    $this->call('POST', '/api/v1/controller/sync', [], [], [],
        ['CONTENT_TYPE' => 'application/json', 'HTTP_AUTHORIZATION' => 'Bearer '.$t], '{not json')
        ->assertStatus(422)->assertJsonPath('error.code', 'invalid_json');
    deviceCall($t, 'controller/sync', ['protocol' => 9] + syncBody())->assertStatus(422)->assertJsonPath('error.code', 'unsupported_protocol');
});

it('never puts paid time in the sync response', function () {
    [, $t] = enrollDevice(site(), 'controller');
    $json = deviceCall($t, 'controller/sync', syncBody([coinEvent(1)]))->assertOk()->json();
    expect(array_keys($json))->toEqualCanonicalizing(['ok', 'server_time', 'ack', 'config'])
        ->and(array_keys($json['config']))->toEqualCanonicalizing(['version', 'seconds_per_pulse', 'sync_interval_s']);
});

it('accepts protocol 1 controllers as tablet 1', function () {
    [, $t] = enrollDevice(site(), 'controller');
    $ev = coinEvent(1);
    unset($ev['station']);
    deviceCall($t, 'controller/sync', syncBody([$ev], protocol: 1))->assertOk()->assertJsonPath('ack.acked_seqs', [1]);
    expect(CoinEvent::first()->station_no)->toBe(1);
});

it('closes the session on expiry and on an admin end', function () {
    [, $t] = enrollDevice(site(), 'controller');
    deviceCall($t, 'controller/sync', syncBody([
        coinEvent(1, station: 1), coinEvent(2, station: 2),
        ['type' => 'expire'] + coinEvent(3, station: 1, pulses: 0, type: 'expire'),
        ['type' => 'admin_end'] + coinEvent(4, station: 2, pulses: 0, type: 'admin_end'),
    ]))->assertOk()->assertJsonPath('ack.acked_seqs', [1, 2, 3, 4]);
    expect(KioskSession::where('station_no', 1)->first()->end_reason)->toBe('expired')
        ->and(KioskSession::where('station_no', 2)->first()->end_reason)->toBe('ended_by_admin');
});

it('records held coins and their later assignment without counting money twice', function () {
    $site = site();
    [, $t] = enrollDevice($site, 'controller');
    deviceCall($t, 'controller/sync', syncBody([
        coinEvent(1, station: 0, pulses: 5, session: 0, type: 'held'),
        coinEvent(2, station: 3, pulses: 5, type: 'assign'),
    ], status: ['held_pulses' => 0]))->assertOk()->assertJsonPath('ack.acked_seqs', [1, 2]);

    $pesos = CoinEvent::whereIn('event_type', CoinEvent::MONEY_TYPES)->sum('pulses');
    expect((int) $pesos)->toBe(5)
        ->and(KioskSession::where('station_no', 3)->first()->total_pulses)->toBe(5);
});

it('records the heartbeat and lets an unnumbered tablet adopt its paired number', function () {
    $site = site();
    [$phone, $t] = enrollDevice($site, 'phone');
    deviceCall($t, 'phone/heartbeat', [
        'boot_id' => 'cafe0001', 'uptime_ms' => 5, 'mode' => 'production', 'device_owner' => true,
        'controller' => ['paired' => true, 'link' => 'ok', 'station' => 2], 'allowed_packages' => ['com.android.chrome', 'bad name'],
        'battery' => ['pct' => 87, 'charging' => true],
    ])->assertOk()->assertJsonStructure(['config' => ['version', 'allowed_packages', 'local_loss_timeout_s', 'seconds_per_pulse']]);
    $phone->refresh();
    expect($phone->station_no)->toBe(2)
        ->and($phone->status('allowed_packages'))->toBe(['com.android.chrome'])
        ->and($phone->presence())->toBe('online')
        ->and($phone->status('battery_pct'))->toBe(87)
        ->and($phone->status('charging'))->toBeTrue();
});

it('ignores an out-of-range battery level', function () {
    [$phone, $t] = enrollDevice(site(), 'phone');
    deviceCall($t, 'phone/heartbeat', ['boot_id' => 'cafe0002', 'uptime_ms' => 5, 'battery' => ['pct' => -1, 'charging' => 'yes']])->assertOk();
    $phone->refresh();
    expect($phone->status('battery_pct'))->toBeNull()
        ->and($phone->status('charging'))->toBeFalse();
});

it('marks devices offline when they stop reporting', function () {
    [$ctl] = enrollDevice(site(), 'controller');
    expect($ctl->presence())->toBe('never');
    $ctl->update(['last_seen_at' => now()->subMinutes(10)]);
    expect($ctl->fresh()->presence())->toBe('offline');
    $ctl->update(['revoked_at' => now()]);
    expect($ctl->fresh()->presence())->toBe('revoked');
});

it('returns the device type mismatch as unauthorized, not as data', function () {
    [, $t] = enrollDevice(site(), 'phone', 1);
    deviceCall($t, 'controller/sync', syncBody())->assertUnauthorized()->assertJsonPath('ok', false);
    expect(Device::count())->toBe(1);
});

it('accepts the X-Device-Token header when Authorization is stripped', function () {
    [, $t] = enrollDevice(site(), 'controller');
    $this->withHeader('X-Device-Token', $t)->postJson('/api/v1/controller/poll', ['boot_id' => 'a1b2c3d4'])->assertOk();
});
