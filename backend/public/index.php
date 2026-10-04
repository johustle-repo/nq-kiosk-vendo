<?php

declare(strict_types=1);

// Public front controller. The application code and the .env secrets live in a
// sibling directory OUTSIDE the document root (see docs/DEPLOYMENT_HOSTINGER.md).

// Local development (php -S ... public/index.php): let the built-in server
// serve existing static files such as /assets/app.css.
if (PHP_SAPI === 'cli-server') {
    $file = realpath(__DIR__ . parse_url((string) $_SERVER['REQUEST_URI'], PHP_URL_PATH));
    if ($file !== false && str_starts_with($file, realpath(__DIR__ . '/assets') ?: "\0") && is_file($file)) {
        return false;
    }
}

$candidates = [
    __DIR__ . '/../vendo_app',  // Hostinger layout: <domain>/public_html + <domain>/vendo_app
    __DIR__ . '/../app',        // repository layout: backend/public + backend/app
];
$appDir = null;
foreach ($candidates as $c) {
    if (is_file($c . '/bootstrap.php')) {
        $appDir = $c;
        break;
    }
}
if ($appDir === null) {
    http_response_code(500);
    header('Content-Type: text/plain');
    exit("Application directory not found. Upload vendo_app next to public_html.\n");
}

require $appDir . '/bootstrap.php';

try {
    $config = Vendo\Config::load($appDir . '/.env');
    $db = Vendo\Db::fromConfig($config);
} catch (Throwable $e) {
    error_log('[vendo] startup: ' . $e->getMessage());
    http_response_code(503);
    $isApi = str_starts_with((string) ($_SERVER['REQUEST_URI'] ?? ''), '/api/');
    header('Cache-Control: no-store');
    if ($isApi) {
        header('Content-Type: application/json');
        echo json_encode(['ok' => false, 'error' => ['code' => 'unavailable', 'message' => 'Service configuration or database unavailable.']]);
    } else {
        header('Content-Type: text/plain');
        echo "Service unavailable: configuration or database error (details are in the PHP error log).\n";
    }
    exit;
}

$app = new Vendo\App($config, $db);
$session = new Vendo\PhpSessionStore($config->bool('SESSION_SECURE', true));
$app->handle(Vendo\Request::fromGlobals($config, $session))->send();
