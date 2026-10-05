<?php

namespace App\Http\Controllers;

use App\Models\AuditLog;
use App\Models\User;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Schema;
use Illuminate\Validation\Rules\Password;
use Illuminate\View\View;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

/**
 * First-time setup without SSH: applies migrations and creates the first
 * administrator. Only works while SETUP_TOKEN is set in .env and no
 * administrator exists; remove SETUP_TOKEN afterwards.
 */
class SetupController extends Controller
{
    public function show(): View
    {
        $this->ensureAllowed();

        return view('auth.setup');
    }

    public function store(Request $request): RedirectResponse
    {
        $this->ensureAllowed();
        $data = $request->validate([
            'setup_token' => ['required', 'string'],
            'name' => ['required', 'string', 'max:100'],
            'username' => ['required', 'string', 'max:64', 'regex:/^[A-Za-z0-9_.-]+$/'],
            'password' => ['required', 'confirmed', Password::defaults()],
        ]);
        if (! hash_equals((string) config('vendo.setup_token'), $data['setup_token'])) {
            return back()->withErrors(['setup_token' => 'Wrong setup token.'])->withInput($request->except('password', 'password_confirmation', 'setup_token'));
        }
        Artisan::call('migrate', ['--force' => true]);
        if (User::exists()) {
            throw new NotFoundHttpException;
        }
        $user = User::create([
            'name' => $data['name'], 'username' => $data['username'], 'password' => $data['password'], 'password_changed_at' => now(),
        ]);
        AuditLog::record('setup.first_admin', $user->id, null, null, [], $request->ip());
        Auth::login($user);
        $request->session()->regenerate();

        return redirect()->route('sites.index')->with('status', 'Setup complete. Now remove SETUP_TOKEN from .env.');
    }

    private function ensureAllowed(): void
    {
        $token = (string) config('vendo.setup_token');
        $hasUsers = Schema::hasTable('users') && User::exists();
        if (strlen($token) < 24 || $hasUsers) {
            throw new NotFoundHttpException;
        }
    }
}
