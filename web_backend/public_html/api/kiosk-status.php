<?php

declare(strict_types=1);

// GET /api/kiosk-status.php — authenticated, read-only timer status for the
// browser kiosk. All logic and the config (DB credentials) live in the private
// folder next to public_html:  domains/<domain>/vendo_web/
// See docs/WEB_KIOSK.md.

$private = dirname(__DIR__, 2) . '/vendo_web';
require $private . '/kiosk_status_lib.php';

VendoWeb\run_from_globals($private . '/config.php');
