<?php

namespace App\Http\Controllers;

use App\Models\AuditLog;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Validation\ValidationException;
use Illuminate\View\View;

class AuthController extends Controller
{
    public function showLogin(): View
    {
        return view('auth.login');
    }

    public function login(Request $request): RedirectResponse
    {
        $credentials = $request->validate([
            'username' => ['required', 'string', 'max:64'],
            'password' => ['required', 'string', 'max:200'],
        ]);
        if (! Auth::attempt($credentials)) {
            AuditLog::record('auth.login_failed', null, null, null, ['username' => mb_substr($credentials['username'], 0, 64)], $request->ip());
            throw ValidationException::withMessages(['username' => 'Wrong username or password.']);
        }
        $request->session()->regenerate();
        $user = $request->user();
        $user->forceFill(['last_login_at' => now()])->save();
        AuditLog::record('auth.login', $user->id, null, null, [], $request->ip());

        return redirect()->intended(route('sites.index'));
    }

    public function logout(Request $request): RedirectResponse
    {
        $id = $request->user()?->id;
        Auth::logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();
        AuditLog::record('auth.logout', $id, null, null, [], $request->ip());

        return redirect()->route('login');
    }
}
