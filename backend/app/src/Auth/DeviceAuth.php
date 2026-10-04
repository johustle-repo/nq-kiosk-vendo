<?php

declare(strict_types=1);

namespace Vendo\Auth;

use Vendo\Db;
use Vendo\Request;

/**
 * Device credentials have the form  vkd_<public_id>_<secret>.
 * Only SHA-256(secret) is stored, so a database leak does not reveal tokens.
 */
final class DeviceAuth
{
    public const TYPE_PHONE = 'phone';
    public const TYPE_CONTROLLER = 'controller';

    public function __construct(private readonly Db $db)
    {
    }

    /** @return array{public_id:string, token:string, hash:string} */
    public static function newCredential(): array
    {
        $publicId = bin2hex(random_bytes(8));
        $secret = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
        return [
            'public_id' => $publicId,
            'token' => 'vkd_' . $publicId . '_' . $secret,
            'hash' => hash('sha256', $secret),
        ];
    }

    /**
     * Authenticates the request and checks the device type.
     * Returns the device row (with owning kiosk) or null.
     *
     * @return array<string,mixed>|null
     */
    public function authenticate(Request $req, string $expectedType): ?array
    {
        $token = $req->bearerToken();
        if ($token === null || !preg_match('/^vkd_([0-9a-f]{16})_([A-Za-z0-9_-]{43})$/', $token, $m)) {
            return null;
        }
        $device = $this->db->one(
            'SELECT d.*, k.owner_admin_id FROM devices d JOIN kiosks k ON k.id = d.kiosk_id WHERE d.public_id = ?',
            [$m[1]]
        );
        if ($device === null || $device['revoked_at'] !== null) {
            return null;
        }
        if (!hash_equals((string) $device['token_hash'], hash('sha256', $m[2]))) {
            return null;
        }
        // Ownership check: a controller credential can never act as a phone or vice versa.
        if ($device['device_type'] !== $expectedType) {
            return null;
        }
        return $device;
    }
}
