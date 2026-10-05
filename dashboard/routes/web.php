<?php

use App\Http\Controllers\AccountController;
use App\Http\Controllers\AuditController;
use App\Http\Controllers\AuthController;
use App\Http\Controllers\SetupController;
use App\Http\Controllers\SiteController;
use Illuminate\Support\Facades\Route;

Route::middleware('guest')->group(function () {
    Route::get('login', [AuthController::class, 'showLogin'])->name('login');
    Route::post('login', [AuthController::class, 'login'])->middleware('throttle:login');
    Route::get('setup', [SetupController::class, 'show'])->name('setup');
    Route::post('setup', [SetupController::class, 'store'])->middleware('throttle:login');
});

Route::middleware('auth')->group(function () {
    Route::post('logout', [AuthController::class, 'logout'])->name('logout');
    Route::redirect('/', '/sites');

    Route::get('sites', [SiteController::class, 'index'])->name('sites.index');
    Route::post('sites', [SiteController::class, 'store'])->name('sites.store');
    Route::get('sites/{site}', [SiteController::class, 'show'])->name('sites.show');
    Route::post('sites/{site}/config', [SiteController::class, 'saveConfig'])->name('sites.config');
    Route::post('sites/{site}/enroll', [SiteController::class, 'enrollCode'])->name('sites.enroll');
    Route::post('devices/{device}/revoke', [SiteController::class, 'revokeDevice'])->name('devices.revoke');

    Route::get('audit', [AuditController::class, 'index'])->name('audit');
    Route::get('account', [AccountController::class, 'show'])->name('account');
    Route::post('account/password', [AccountController::class, 'updatePassword'])->name('account.password');
});
