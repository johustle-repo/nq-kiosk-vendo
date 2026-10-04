<?php

declare(strict_types=1);

// Usage (SSH):  php vendo_app/bin/create-admin.php <username>
// Prompts for the password without echoing it where the terminal allows.

if (PHP_SAPI !== 'cli') {
    exit(1);
}
require __DIR__ . '/../bootstrap.php';

$username = $argv[1] ?? '';
if (!preg_match('/^[A-Za-z0-9_.-]{3,64}$/', $username)) {
    fwrite(STDERR, "Usage: php create-admin.php <username>\n");
    exit(2);
}
if (DIRECTORY_SEPARATOR === '/') {
    shell_exec('stty -echo');
}
echo 'Password (12+ chars): ';
$password = rtrim((string) fgets(STDIN), "\r\n");
if (DIRECTORY_SEPARATOR === '/') {
    shell_exec('stty echo');
}
echo PHP_EOL;
if (($problem = Vendo\Auth\AdminAuth::passwordProblem($password)) !== null) {
    fwrite(STDERR, $problem . PHP_EOL);
    exit(2);
}
$db = Vendo\Db::fromConfig(Vendo\Config::load(VENDO_APP_DIR . '/.env'));
try {
    $id = $db->insert(
        'INSERT INTO admins (username, password_hash, created_at, password_changed_at) VALUES (?, ?, ?, ?)',
        [$username, Vendo\Auth\AdminAuth::hashPassword($password), Vendo\Clock::sql(), Vendo\Clock::sql()]
    );
} catch (PDOException $e) {
    fwrite(STDERR, Vendo\Db::isUniqueViolation($e) ? "Username already exists.\n" : "Database error.\n");
    exit(1);
}
(new Vendo\Service\Audit($db))->log('admin.created_cli', $id, null, null, ['username' => $username], null);
echo "Created administrator #$id ($username).\n";
