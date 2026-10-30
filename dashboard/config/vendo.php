<?php

return [
    // Device API version reported by /api/v1/health.
    'api_version' => 'v1',
    'backend_version' => '2.0.0',

    // Presence: a device is "offline" when not seen for this long.
    'phone_stale_seconds' => (int) env('PHONE_STALE_SECONDS', 120),
    'controller_stale_seconds' => (int) env('CONTROLLER_STALE_SECONDS', 90),

    // How long an attendant's "next coins -> tablet N" selection lasts.
    'selection_ttl_seconds' => (int) env('SELECTION_TTL_SECONDS', 90),

    // Largest single "add time" from the dashboard (seconds).
    'max_admin_credit_seconds' => 4 * 3600,

    // How long a dashboard "Charge now" keeps the coin box charger relay on at
    // most (it stops earlier when the tablet reports a full battery).
    'dashboard_charge_seconds' => 4 * 3600,

    // First coin box firmware that takes "Charge now" from the dashboard.
    'charge_firmware' => '2.5.0',

    // One-time token for the first-admin setup page (empty = page disabled).
    'setup_token' => env('SETUP_TOKEN'),
];
