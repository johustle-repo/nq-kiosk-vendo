<?php

namespace App\Providers;

use App\Models\Site;
use App\Models\User;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Illuminate\Validation\Rules\Password;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        // Device API: enrollment per IP; everything else per device credential.
        RateLimiter::for('enroll', fn (Request $r) => Limit::perHour(10)->by('enroll:'.$r->ip()));
        RateLimiter::for('device', fn (Request $r) => Limit::perMinute(150)
            ->by('device:'.optional($r->attributes->get('device'))->id));

        // Dashboard login: per username+IP and per IP.
        RateLimiter::for('login', fn (Request $r) => [
            Limit::perMinute(5)->by('login:'.strtolower((string) $r->input('username')).'|'.$r->ip()),
            Limit::perMinute(20)->by('login-ip:'.$r->ip()),
        ]);

        Password::defaults(fn () => Password::min(10)->letters()->numbers());

        // An administrator can only see and change their own sites.
        Gate::define('manage-site', fn (User $user, Site $site) => $site->owner_id === $user->id);
    }
}
