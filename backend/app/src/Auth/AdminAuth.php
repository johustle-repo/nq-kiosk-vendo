<?php

declare(strict_types=1);

namespace Vendo\Auth;

use Vendo\Clock;
use Vendo\Db;
use Vendo\Request;

final class AdminAuth
{
    public const IDLE_TIMEOUT_S = 1800;
    public const ABSOLUTE_TIMEOUT_S = 43200;
    public const MIN_PASSWORD_LEN = 12;

    public function __construct(private readonly Db $db, private readonly RateLimiter $limiter)
    {
    }

    public static function hashPassword(string $password): string
    {
        $algo = defined('PASSWORD_ARGON2ID') ? PASSWORD_ARGON2ID : PASSWORD_DEFAULT;
        return password_hash($password, $algo);
    }

    public static function passwordProblem(string $password): ?string
    {
        if (strlen($password) < self::MIN_PASSWORD_LEN) {
            return 'Password must be at least ' . self::MIN_PASSWORD_LEN . ' characters.';
        }
        if (strlen($password) > 200) {
            return 'Password is too long.';
        }
        return null;
    }

    /**
     * @return array{ok:bool, error?:string, admin?:array<string,mixed>}
     */
    public function attemptLogin(Request $req, string $username, string $password): array
    {
        $userBucket = 'login:user:' . strtolower($username);
        $ipBucket = 'login:ip:' . $req->ip;
        // Count every attempt; blocks both password spraying from one IP and
        // guessing against one account from many IPs.
        $ipOk = $this->limiter->hit($ipBucket, 20, 900);
        $userOk = $this->limiter->hit($userBucket, 8, 900);
        if (!$ipOk || !$userOk) {
            return ['ok' => false, 'error' => 'Too many login attempts. Wait 15 minutes and try again.'];
        }
        $admin = $this->db->one('SELECT * FROM admins WHERE username = ?', [$username]);
        // Verify against a dummy hash when the user does not exist to keep timing similar.
        // (The dummy is a hash of discarded random bytes; nothing can match it.)
        $hash = $admin['password_hash'] ?? '$2y$12$3F.5H/IdnDZl4EbAnjuF5euctABNaFEe5zIbPtxbb7iYkOyM2mRRm';
        if (!password_verify($password, $hash) || $admin === null) {
            return ['ok' => false, 'error' => 'Invalid username or password.'];
        }
        if (password_needs_rehash($hash, defined('PASSWORD_ARGON2ID') ? PASSWORD_ARGON2ID : PASSWORD_DEFAULT)) {
            $this->db->exec('UPDATE admins SET password_hash = ? WHERE id = ?', [self::hashPassword($password), $admin['id']]);
        }
        $this->limiter->clear($userBucket);
        $req->session->regenerate();
        $req->session->set('admin_id', (int) $admin['id']);
        $req->session->set('admin_epoch', (int) $admin['session_epoch']);
        $req->session->set('login_at', Clock::now());
        $req->session->set('last_active', Clock::now());
        $req->session->remove('csrf');
        $this->db->exec('UPDATE admins SET last_login_at = ? WHERE id = ?', [Clock::sql(), $admin['id']]);
        return ['ok' => true, 'admin' => $admin];
    }

    /** @return array<string,mixed>|null the logged-in admin, or null. */
    public function current(Request $req): ?array
    {
        $id = $req->session->get('admin_id');
        if (!is_int($id)) {
            return null;
        }
        $now = Clock::now();
        $loginAt = (int) $req->session->get('login_at');
        $last = (int) $req->session->get('last_active');
        if ($now - $last > self::IDLE_TIMEOUT_S || $now - $loginAt > self::ABSOLUTE_TIMEOUT_S) {
            $req->session->destroy();
            return null;
        }
        $admin = $this->db->one('SELECT id, username, session_epoch, last_login_at FROM admins WHERE id = ?', [$id]);
        // A password change bumps session_epoch, which logs out other sessions.
        if ($admin === null || (int) $admin['session_epoch'] !== (int) $req->session->get('admin_epoch')) {
            $req->session->destroy();
            return null;
        }
        $req->session->set('last_active', $now);
        return $admin;
    }

    public function logout(Request $req): void
    {
        $req->session->destroy();
    }
}
