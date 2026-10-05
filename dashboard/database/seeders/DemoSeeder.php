<?php

namespace Database\Seeders;

use App\Models\Device;
use App\Models\User;
use App\Services\SiteService;
use Illuminate\Database\Seeder;

/**
 * Local preview data: `php artisan migrate:fresh --seed --seeder=DemoSeeder`.
 * Never run against production. Sign in as demo / demo-pass-123.
 */
class DemoSeeder extends Seeder
{
    public function run(): void
    {
        if (app()->environment('production')) {
            $this->command?->error('DemoSeeder refuses to run in production.');

            return;
        }
        $user = User::create(['name' => 'Demo Admin', 'username' => 'demo', 'password' => 'demo-pass-123']);
        $site = app(SiteService::class)->createSite($user, 'Jo-hustle Internet Cafe');
        $mk = fn (array $a) => Device::create($a + ['site_id' => $site->id, 'public_id' => bin2hex(random_bytes(8)), 'token_hash' => str_repeat('0', 64)]);

        $mk([
            'device_type' => 'controller', 'name' => 'Coin box vk-f6e705', 'last_seen_at' => now(), 'sw_version' => '2.0.0',
            'config_version_applied' => 1, 'status_reported_at' => now(),
            'status_json' => ['held_pulses' => 5, 'stations' => [
                '1' => ['session' => 'running', 'remaining_s' => 2712, 'session_no' => 4, 'paired' => true],
                '2' => ['session' => 'running', 'remaining_s' => 214, 'session_no' => 2, 'paired' => true],
                '3' => ['session' => 'idle', 'remaining_s' => 0, 'session_no' => 7, 'paired' => true],
                '4' => ['session' => 'idle', 'remaining_s' => 0, 'session_no' => 0, 'paired' => false],
            ]],
        ]);
        foreach ([1 => 'Pixel Tablet', 2 => 'TECNO Spark 30C', 3 => 'Galaxy Tab A9'] as $n => $name) {
            $mk([
                'device_type' => 'phone', 'name' => $name, 'station_no' => $n, 'last_seen_at' => $n === 3 ? now()->subMinutes(9) : now(),
                'sw_version' => '1.0.0', 'config_version_applied' => 1, 'status_reported_at' => now(),
                'status_json' => ['mode' => 'production', 'lock_task' => 'locked', 'controller_link' => 'ok', 'controller_station' => $n],
            ]);
        }
        $site->update(['held_pulses' => 5, 'reported_station' => 2, 'reported_ttl_s' => 74, 'last_poll_at' => now(),
            'selected_station' => 2, 'selection_expires_at' => now()->addSeconds(74), 'selection_version' => 1]);
    }
}
