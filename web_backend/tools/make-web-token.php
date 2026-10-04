<?php

declare(strict_types=1);

// Creates a browser/kiosk access token ON YOUR PC (no SSH needed on the server).
//
//   php web_backend/tools/make-web-token.php vendo-001 "Front browser" [days-valid]
//
// Prints:
//   1. the token — give it to the browser kiosk; it is shown ONCE and is not stored;
//   2. an INSERT statement containing only the token's SHA-256 hash — run it in
//      hPanel → phpMyAdmin → SQL on the database that holds device_status.
// To revoke: UPDATE web_kiosk_tokens SET revoked_at = UTC_TIMESTAMP() WHERE public_id = '<id>';

if (PHP_SAPI !== 'cli') {
    exit(1);
}
$device = $argv[1] ?? '';
$label = $argv[2] ?? 'Browser kiosk';
$days = isset($argv[3]) ? (int) $argv[3] : 90;
if (!preg_match('/^[A-Za-z0-9_.:-]{1,64}$/', $device) || $days < 0 || $days > 3650) {
    fwrite(STDERR, "Usage: php make-web-token.php <device-code> [label] [days-valid, 0 = never expires]\n");
    exit(2);
}
$label = substr(preg_replace('/[^\x20-\x7E]/', '', $label) ?? '', 0, 100);

$publicId = bin2hex(random_bytes(8));
$secret = rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
$token = "vkw_{$publicId}_{$secret}";
$now = gmdate('Y-m-d H:i:s');
$expires = $days === 0 ? 'NULL' : "'" . gmdate('Y-m-d H:i:s', time() + $days * 86400) . "'";
$q = static fn (string $s): string => "'" . str_replace(["\\", "'"], ["\\\\", "''"], $s) . "'";

echo "Token (store it only in the browser kiosk; shown once):\n\n  $token\n\n";
echo "SQL for phpMyAdmin:\n\n";
printf(
    "INSERT INTO web_kiosk_tokens (public_id, token_hash, device_code, label, created_at, expires_at) VALUES (%s, %s, %s, %s, %s, %s);\n\n",
    $q($publicId), $q(hash('sha256', $secret)), $q($device), $q($label), $q($now), $expires
);
echo "Revoke later with:\n\n  UPDATE web_kiosk_tokens SET revoked_at = UTC_TIMESTAMP() WHERE public_id = '$publicId';\n";
