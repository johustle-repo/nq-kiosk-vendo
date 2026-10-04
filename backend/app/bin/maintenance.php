<?php

declare(strict_types=1);

// OPTIONAL daily cron job (hPanel → Advanced → Cron Jobs):
//   /usr/bin/php /home/<user>/domains/vendo-kiosk.ebnleadgen.online/vendo_app/bin/maintenance.php
// Prunes expired rate-limit rows and old unused enrollment codes.
// Not required for correctness: offline status is computed at read time.

if (PHP_SAPI !== 'cli') {
    exit(1);
}
require __DIR__ . '/../bootstrap.php';

$db = Vendo\Db::fromConfig(Vendo\Config::load(VENDO_APP_DIR . '/.env'));
$rl = (new Vendo\Auth\RateLimiter($db))->prune(86400);
$codes = $db->exec('DELETE FROM enrollment_codes WHERE used_at IS NULL AND expires_at < ?', [Vendo\Clock::sql(Vendo\Clock::now() - 7 * 86400)]);
echo "Pruned $rl rate-limit rows, $codes expired enrollment codes.\n";
