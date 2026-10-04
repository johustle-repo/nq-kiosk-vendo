<?php

declare(strict_types=1);

namespace Vendo\Service;

use Vendo\Clock;
use Vendo\Db;

/** Append-only log of configuration changes and privileged actions. */
final class Audit
{
    public function __construct(private readonly Db $db)
    {
    }

    public function log(string $action, ?int $adminId, ?int $kioskId, ?int $deviceId, array $details, ?string $ip): void
    {
        $this->db->exec(
            'INSERT INTO audit_log (admin_id, kiosk_id, device_id, action, details, ip, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
            [$adminId, $kioskId, $deviceId, $action, json_encode($details, JSON_UNESCAPED_SLASHES), $ip, Clock::sql()]
        );
    }
}
