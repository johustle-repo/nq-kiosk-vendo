<?php

namespace App\Http\Controllers;

use App\Models\AuditLog;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Validation\Rules\Password;
use Illuminate\View\View;

class AccountController extends Controller
{
    public function show(): View
    {
        return view('account');
    }

    public function updatePassword(Request $request): RedirectResponse
    {
        $request->validate([
            'current_password' => ['required', 'current_password'],
            'password' => ['required', 'confirmed', Password::defaults()],
        ]);
        $user = $request->user();
        $user->forceFill(['password' => $request->input('password'), 'password_changed_at' => now()])->save();
        // Signs out every other browser that was logged in as this administrator.
        Auth::logoutOtherDevices($request->input('password'));
        $request->session()->regenerate();
        AuditLog::record('auth.password_changed', $user->id, null, null, [], $request->ip());

        return back()->with('status', 'Password changed. Other sessions were signed out.');
    }
}
