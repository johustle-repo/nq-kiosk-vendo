<?php

declare(strict_types=1);

namespace Vendo;

/** Session storage abstraction so web handlers can be tested without PHP sessions. */
interface SessionStore
{
    public function get(string $key): mixed;

    public function set(string $key, mixed $value): void;

    public function remove(string $key): void;

    /** Issues a new session id (after login) to prevent session fixation. */
    public function regenerate(): void;

    public function destroy(): void;
}

final class ArraySessionStore implements SessionStore
{
    /** @var array<string,mixed> */
    public array $data = [];
    public int $regenerations = 0;

    public function get(string $key): mixed
    {
        return $this->data[$key] ?? null;
    }

    public function set(string $key, mixed $value): void
    {
        $this->data[$key] = $value;
    }

    public function remove(string $key): void
    {
        unset($this->data[$key]);
    }

    public function regenerate(): void
    {
        $this->regenerations++;
    }

    public function destroy(): void
    {
        $this->data = [];
    }
}

final class PhpSessionStore implements SessionStore
{
    private bool $started = false;

    public function __construct(private readonly bool $secureCookie)
    {
    }

    private function start(): void
    {
        if ($this->started) {
            return;
        }
        session_name('vendo_admin');
        session_set_cookie_params([
            'lifetime' => 0,
            'path' => '/',
            'secure' => $this->secureCookie,
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
        ini_set('session.use_strict_mode', '1');
        ini_set('session.use_only_cookies', '1');
        session_start();
        $this->started = true;
    }

    public function get(string $key): mixed
    {
        $this->start();
        return $_SESSION[$key] ?? null;
    }

    public function set(string $key, mixed $value): void
    {
        $this->start();
        $_SESSION[$key] = $value;
    }

    public function remove(string $key): void
    {
        $this->start();
        unset($_SESSION[$key]);
    }

    public function regenerate(): void
    {
        $this->start();
        session_regenerate_id(true);
    }

    public function destroy(): void
    {
        $this->start();
        $_SESSION = [];
        session_destroy();
        $this->started = false;
    }
}

final class Request
{
    /**
     * @param array<string,string> $query
     * @param array<string,mixed> $post
     * @param array<string,string> $headers lower-case header names
     */
    public function __construct(
        public readonly string $method,
        public readonly string $path,
        public readonly array $query,
        public readonly array $post,
        public readonly array $headers,
        public readonly string $body,
        public readonly string $ip,
        public readonly SessionStore $session,
    ) {
    }

    public static function fromGlobals(Config $config, SessionStore $session): self
    {
        $headers = [];
        foreach ($_SERVER as $k => $v) {
            if (str_starts_with($k, 'HTTP_')) {
                $headers[strtolower(str_replace('_', '-', substr($k, 5)))] = (string) $v;
            }
        }
        if (isset($_SERVER['CONTENT_TYPE'])) {
            $headers['content-type'] = (string) $_SERVER['CONTENT_TYPE'];
        }
        // Some Apache/LiteSpeed setups only expose Authorization via REDIRECT_ variables.
        foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION'] as $k) {
            if (!isset($headers['authorization']) && !empty($_SERVER[$k])) {
                $headers['authorization'] = (string) $_SERVER[$k];
            }
        }
        $path = parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH) ?: '/';
        $path = '/' . trim(rawurldecode($path), '/');

        $ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
        // Only trust a proxy header when explicitly configured (see .env.example).
        $trusted = $config->get('TRUSTED_IP_HEADER');
        if ($trusted !== null && !empty($_SERVER[$trusted])) {
            $candidate = trim(explode(',', (string) $_SERVER[$trusted])[0]);
            if (filter_var($candidate, FILTER_VALIDATE_IP)) {
                $ip = $candidate;
            }
        }

        $body = (string) file_get_contents('php://input', false, null, 0, 262144);
        return new self(
            strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET')),
            $path,
            array_map('strval', array_filter($_GET, 'is_scalar')),
            $_POST,
            $headers,
            $body,
            $ip,
            $session,
        );
    }

    public function header(string $name): ?string
    {
        return $this->headers[strtolower($name)] ?? null;
    }

    /** @return array<string,mixed>|null */
    public function json(): ?array
    {
        if ($this->body === '') {
            return null;
        }
        try {
            $data = json_decode($this->body, true, 16, JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            return null;
        }
        return is_array($data) ? $data : null;
    }

    public function postString(string $key, int $maxLen = 1000): string
    {
        $v = $this->post[$key] ?? '';
        return is_string($v) ? mb_substr(trim($v), 0, $maxLen) : '';
    }

    public function bearerToken(): ?string
    {
        $auth = $this->header('authorization');
        if ($auth !== null && preg_match('/^Bearer\s+(\S+)$/i', $auth, $m)) {
            return $m[1];
        }
        // Fallback for hosts that strip the Authorization header.
        return $this->header('x-device-token');
    }
}

final class Response
{
    /** @param array<string,string> $headers */
    public function __construct(public int $status, public string $body, public array $headers = [])
    {
    }

    public static function json(array $data, int $status = 200): self
    {
        return new self(
            $status,
            json_encode($data, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR),
            ['Content-Type' => 'application/json; charset=utf-8']
        );
    }

    public static function apiError(string $code, string $message, int $status): self
    {
        return self::json(['ok' => false, 'error' => ['code' => $code, 'message' => $message]], $status);
    }

    public static function html(string $html, int $status = 200): self
    {
        return new self($status, $html, ['Content-Type' => 'text/html; charset=utf-8']);
    }

    public static function redirect(string $to): self
    {
        return new self(303, '', ['Location' => $to]);
    }

    public function send(): void
    {
        http_response_code($this->status);
        $defaults = [
            // Responses are per-user/per-device; the Hostinger CDN must never cache them.
            'Cache-Control' => 'no-store, max-age=0',
            'X-Content-Type-Options' => 'nosniff',
            'Referrer-Policy' => 'same-origin',
            'X-Frame-Options' => 'DENY',
            'Content-Security-Policy' => "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'",
            'Strict-Transport-Security' => 'max-age=31536000',
        ];
        foreach ($this->headers + $defaults as $k => $v) {
            header($k . ': ' . $v);
        }
        echo $this->body;
    }
}
