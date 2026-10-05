<?php

use App\Http\Controllers\Api\DeviceApiController;
use Illuminate\Support\Facades\Route;

// Device API, mounted at /api/v1 (see bootstrap/app.php).
Route::get('health', [DeviceApiController::class, 'health']);

Route::post('devices/enroll', [DeviceApiController::class, 'enroll'])->middleware('throttle:enroll');

Route::middleware(['device:controller', 'throttle:device'])->group(function () {
    Route::post('controller/sync', [DeviceApiController::class, 'controllerSync']);
    Route::post('controller/poll', [DeviceApiController::class, 'controllerPoll']);
});

Route::post('phone/heartbeat', [DeviceApiController::class, 'phoneHeartbeat'])
    ->middleware(['device:phone', 'throttle:device']);
