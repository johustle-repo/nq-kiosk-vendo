<?php

use App\Livewire\SitePanel;
use App\Models\AuditLog;
use App\Models\ControllerCommand;
use App\Models\Device;
use App\Models\Site;
use App\Models\SiteConfig;
use App\Models\User;
use Livewire\Livewire;

it('redirects guests to the login page', function () {
    $this->get('/sites')->assertRedirect('/login');
    $this->get('/')->assertRedirect('/login');
});

it('signs in with a username and records the login', function () {
    admin('owner');
    $this->post('/login', ['username' => 'owner', 'password' => 'wrong-password-1'])->assertSessionHasErrors('username');
    $this->assertGuest();
    $this->post('/login', ['username' => 'owner', 'password' => 'correct-horse-42'])->assertRedirect(route('sites.index'));
    $this->assertAuthenticated();
    expect(AuditLog::pluck('action')->all())->toBe(['auth.login_failed', 'auth.login']);
});

it('rate limits login attempts', function () {
    admin('owner');
    for ($i = 0; $i < 5; $i++) {
        $this->post('/login', ['username' => 'owner', 'password' => 'nope-nope-1']);
    }
    $this->post('/login', ['username' => 'owner', 'password' => 'correct-horse-42'])->assertStatus(429);
});

it('keeps each administrator to their own sites', function () {
    $mine = site(admin('a'), 'Mine');
    $theirs = site(admin('b'), 'Theirs');
    $this->actingAs($mine->owner);

    $this->get('/sites')->assertOk()->assertSee('Mine')->assertDontSee('Theirs');
    $this->get(route('sites.show', $theirs))->assertForbidden();
    $this->post(route('sites.config', $theirs), ['seconds_per_pulse' => 60])->assertForbidden();
    $this->post(route('sites.enroll', $theirs), ['device_type' => 'controller'])->assertForbidden();
    Livewire::test(SitePanel::class, ['site' => $theirs])->assertForbidden();
});

it('creates a site with a default configuration', function () {
    $user = admin();
    $this->actingAs($user)->post('/sites', ['name' => 'Internet cafe'])->assertRedirect();
    $site = Site::firstOrFail();
    expect($site->owner_id)->toBe($user->id)
        ->and($site->currentConfig()->seconds_per_pulse)->toBe(SiteConfig::DEFAULT_SECONDS_PER_PULSE);
});

it('validates and versions the configuration', function () {
    $site = site();
    $this->actingAs($site->owner);
    $this->post(route('sites.config', $site), ['seconds_per_pulse' => 5, 'local_loss_timeout_s' => 30, 'controller_sync_interval_s' => 15])
        ->assertSessionHasErrors();
    $this->post(route('sites.config', $site), [
        'seconds_per_pulse' => 300, 'local_loss_timeout_s' => 30, 'controller_sync_interval_s' => 15,
        'allowed_packages' => "com.android.chrome\ncom.google.android.youtube",
    ])->assertSessionHasNoErrors();
    $cfg = $site->currentConfig();
    expect($cfg->version)->toBe(2)->and($cfg->seconds_per_pulse)->toBe(300)
        ->and($cfg->allowed_packages)->toBe(['com.android.chrome', 'com.google.android.youtube']);
});

it('shows a tablet enrollment code once, bound to its tablet number', function () {
    $site = site();
    $this->actingAs($site->owner);
    $this->post(route('sites.enroll', $site), ['device_type' => 'phone', 'station_no' => 2])
        ->assertSessionHas('new_code', fn ($c) => $c['type'] === 'phone' && $c['station'] === 2 && strlen($c['code']) === 11);
    $this->post(route('sites.enroll', $site), ['device_type' => 'phone', 'station_no' => 9])->assertSessionHasErrors('station_no');
});

it('rejects posts without a CSRF token', function () {
    $site = site();
    $this->actingAs($site->owner);
    // The test kernel skips CSRF by default; turn it back on for this check.
    $this->withMiddleware()->app['env'] = 'production';
    $this->post(route('sites.config', $site), ['seconds_per_pulse' => 300])->assertStatus(419);
});

it('lets the attendant select a tablet, add and end time, and assign held coins', function () {
    $site = site();
    foreach ([1, 2, 3] as $n) {
        enrollDevice($site, 'phone', $n);
    }
    $this->actingAs($site->owner);
    Livewire::test(SitePanel::class, ['site' => $site])
        ->call('select', 3)->assertSet('flash', 'Next coins go to Tablet 3.')
        ->call('addTime', 3, 15)
        ->call('endSession', 2)
        ->call('assignHeld', 1)
        ->call('addTime', 7, 15)->assertSet('flash', 'Tablet number must be 1 to 4.');

    expect($site->fresh()->activeSelection())->toBe(3)
        ->and(ControllerCommand::orderBy('id')->get(['type', 'station_no', 'seconds'])->toArray())->toBe([
            ['type' => 'add_time', 'station_no' => 3, 'seconds' => 900],
            ['type' => 'end_session', 'station_no' => 2, 'seconds' => null],
            ['type' => 'assign_held', 'station_no' => 1, 'seconds' => null],
        ]);
});

it('renders the live panel with tablet time from the coin box', function () {
    $site = site();
    [$ctl] = enrollDevice($site, 'controller');
    enrollDevice($site, 'phone', 2);
    $ctl->update([
        'status_json' => ['stations' => ['2' => ['session' => 'running', 'remaining_s' => 754, 'session_no' => 1, 'paired' => true]]],
        'status_reported_at' => now(), 'last_seen_at' => now(),
    ]);
    $site->update(['held_pulses' => 5, 'reported_station' => 2, 'reported_ttl_s' => 60, 'last_poll_at' => now()]);
    $this->actingAs($site->owner);

    Livewire::test(SitePanel::class, ['site' => $site])
        ->assertSee('Tablet 2')->assertSee('00:12:3') // 754 s ≈ 00:12:34
        ->assertSee('₱5')->assertSee('Next coins → this tablet');
});

it('allows the setup page only with the token and before any admin exists', function () {
    config(['vendo.setup_token' => null]);
    $this->get('/setup')->assertNotFound();

    config(['vendo.setup_token' => str_repeat('s', 32)]);
    $this->get('/setup')->assertOk();
    $this->post('/setup', ['setup_token' => 'wrong', 'name' => 'Jo', 'username' => 'jo', 'password' => 'abcdef12345', 'password_confirmation' => 'abcdef12345'])
        ->assertSessionHasErrors('setup_token');
    $this->post('/setup', ['setup_token' => str_repeat('s', 32), 'name' => 'Jo', 'username' => 'jo', 'password' => 'abcdef12345', 'password_confirmation' => 'abcdef12345'])
        ->assertRedirect(route('sites.index'));
    expect(User::where('username', 'jo')->exists())->toBeTrue();

    auth()->logout();
    $this->get('/setup')->assertNotFound(); // an administrator now exists
});

it('changes the password only with the current one', function () {
    $user = admin();
    $this->actingAs($user);
    $this->post('/account/password', ['current_password' => 'nope', 'password' => 'newpass12345', 'password_confirmation' => 'newpass12345'])
        ->assertSessionHasErrors('current_password');
    $this->post('/account/password', ['current_password' => 'correct-horse-42', 'password' => 'newpass12345', 'password_confirmation' => 'newpass12345'])
        ->assertSessionHasNoErrors();
    expect(auth()->attempt(['username' => $user->username, 'password' => 'newpass12345']))->toBeTrue();
});

it('revokes a device', function () {
    $site = site();
    [$phone] = enrollDevice($site, 'phone', 1);
    $this->actingAs($site->owner)->post(route('devices.revoke', $phone))->assertRedirect();
    expect(Device::find($phone->id)->revoked_at)->not->toBeNull();
});

it('refuses to send coins or time to an empty tablet slot', function () {
    $site = site();
    $this->actingAs($site->owner);
    Livewire::test(SitePanel::class, ['site' => $site])
        ->call('select', 4)->assertSet('flash', 'Tablet 4 has no tablet enrolled or paired yet.')
        ->call('addTime', 4, 5);
    expect($site->fresh()->activeSelection())->toBeNull()->and(ControllerCommand::count())->toBe(0);
});
