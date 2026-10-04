<?php

// Configuration for /api/kiosk-status.php — TEMPLATE.
// Copy to config.php in the PRIVATE folder (domains/<domain>/vendo_web/config.php,
// next to public_html, NOT inside it). Never commit config.php.

return [
    // Same MySQL database the existing api/ uses (hPanel → Databases).
    'db' => [
        'host' => 'localhost',
        'port' => 3306,
        'name' => '',
        'user' => '',
        'pass' => '',
    ],

    // Existing table written by the ESP8266 upload endpoint (api/status.php).
    // Adjust the column names to match `SHOW COLUMNS FROM device_status;`.
    // The endpoint verifies these columns exist and fails closed otherwise.
    'status_source' => [
        'table' => 'device_status',
        'device_column' => 'device_id',            // holds 'vendo-001'
        'remaining_column' => 'remaining_seconds',
        'boot_column' => 'boot_id',
        'sequence_column' => 'sequence_number',
        'pulses_column' => 'last_pulses',
        'updated_column' => 'updated_at',          // when the ESP8266 last reported
        // 'datetime' = DATETIME/TIMESTAMP written with NOW() by the database,
        // 'unix'     = integer seconds since 1970.
        'updated_type' => 'datetime',
    ],

    // Status older than this is flagged "stale" (the ESP8266 stopped reporting).
    'stale_after_seconds' => 60,

    // Long-polling: the browser asks "anything newer than what I have?" and the
    // server answers as soon as a new upload is in the database (checked every
    // long_poll_check_ms), or after at most long_poll_max_seconds. Each open
    // kiosk tab keeps one PHP worker busy while waiting — on small shared plans
    // with many tabs, lower this or set 0 to fall back to plain 3 s polling.
    'long_poll_max_seconds' => 20,
    'long_poll_check_ms' => 300,

    // Per-token request limit (the web app polls every 3 s = 20/min).
    'rate_limit_per_minute' => 60,

    // Exact origins allowed to call the endpoint cross-origin (local development
    // only). Production uses same-origin requests and needs no entry here.
    // Example: ['http://localhost:5173']. Never use '*'.
    'cors_allowed_origins' => [],
];
