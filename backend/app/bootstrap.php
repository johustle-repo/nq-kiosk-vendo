<?php

declare(strict_types=1);

// Shared bootstrap for the web front controller, CLI scripts and tests.
// This directory must live OUTSIDE the public document root.

if (PHP_VERSION_ID < 80100) {
    http_response_code(500);
    exit("Vendo Kiosk requires PHP 8.1 or newer.\n");
}

spl_autoload_register(static function (string $class): void {
    if (!str_starts_with($class, 'Vendo\\')) {
        return;
    }
    $path = __DIR__ . '/src/' . str_replace('\\', '/', substr($class, 6)) . '.php';
    if (is_file($path)) {
        require $path;
    }
});

// Request, Response and the session stores share one file.
require_once __DIR__ . '/src/Http.php';

define('VENDO_APP_DIR', __DIR__);
define('VENDO_API_VERSION', 'v1');
define('VENDO_BACKEND_VERSION', '1.0.0');
