<?php

declare(strict_types=1);

// Usage (SSH, optional):  php vendo_app/bin/migrate.php [--status]
// Without SSH, use the /setup page (first install) or Diagnostics → Apply pending migrations.

if (PHP_SAPI !== 'cli') {
    exit(1);
}
require __DIR__ . '/../bootstrap.php';

$config = Vendo\Config::load(VENDO_APP_DIR . '/.env');
$db = Vendo\Db::fromConfig($config);
$m = new Vendo\Service\Migrator($db, VENDO_APP_DIR . '/migrations');

if (in_array('--status', $argv, true)) {
    echo 'Applied: ' . implode(', ', $m->applied()) . PHP_EOL;
    echo 'Pending: ' . implode(', ', $m->pending()) . PHP_EOL;
    exit(0);
}
$done = $m->migrate();
echo $done === [] ? "Nothing to migrate.\n" : 'Applied: ' . implode(', ', $done) . PHP_EOL;
