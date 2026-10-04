<?php

declare(strict_types=1);

namespace Vendo\Web;

use Vendo\App;
use Vendo\Auth\AdminAuth;
use Vendo\Auth\Csrf;
use Vendo\Auth\DeviceAuth;
use Vendo\Clock;
use Vendo\Request;
use Vendo\Response;
use Vendo\Service\KioskService;

/** Administrator dashboard (server-rendered, cookie session + CSRF tokens). */
final class WebController
{
    private ?array $admin = null;

    public function __construct(private readonly App $app)
    {
    }

    public function handle(Request $req): Response
    {
        $m = $req->method;
        $p = $req->path;

        if ($m === 'POST' && !Csrf::valid($req)) {
            return Response::html('<h1>Form expired</h1><p>Reload the page and try again.</p>', 419);
        }

        // Routes that do not require a login.
        if ($p === '/setup') {
            return $m === 'POST' ? $this->setupPost($req) : $this->setupGet($req);
        }
        if ($p === '/login') {
            if ($this->needsSetup()) {
                return Response::redirect('/setup');
            }
            return $m === 'POST' ? $this->loginPost($req) : $this->view($req, 'login', ['title' => 'Sign in']);
        }

        $this->admin = $this->app->adminAuth->current($req);
        if ($this->admin === null) {
            if ($m === 'GET' && str_ends_with($p, '.json')) {
                return Response::json(['ok' => false, 'error' => 'login_required'], 401);
            }
            return Response::redirect($this->needsSetup() ? '/setup' : '/login');
        }
        $adminId = (int) $this->admin['id'];

        if ($p === '/logout' && $m === 'POST') {
            $this->app->adminAuth->logout($req);
            return Response::redirect('/login');
        }
        if ($p === '/' && $m === 'GET') {
            return $this->dashboard($req, $adminId);
        }
        if ($p === '/kiosks' && $m === 'POST') {
            return $this->createKiosk($req, $adminId);
        }
        if (preg_match('#^/kiosks/(\d+)(/[a-z.-]+)?$#', $p, $mm)) {
            $kiosk = $this->app->kiosks->kioskForAdmin((int) $mm[1], $adminId);
            if ($kiosk === null) {
                return $this->notFound($req); // Not yours or does not exist: same answer.
            }
            $sub = $mm[2] ?? '';
            return match ("$m $sub") {
                'GET ' => $this->kioskPage($req, $kiosk),
                'GET /status.json' => $this->kioskStatusJson($kiosk),
                'POST /config' => $this->saveConfig($req, $kiosk, $adminId),
                'POST /enroll-code' => $this->enrollCode($req, $kiosk, $adminId),
                default => $this->notFound($req),
            };
        }
        if (preg_match('#^/devices/(\d+)/revoke$#', $p, $mm) && $m === 'POST') {
            return $this->revokeDevice($req, (int) $mm[1], $adminId);
        }
        if ($p === '/audit' && $m === 'GET') {
            return $this->auditPage($req, $adminId);
        }
        if ($p === '/account') {
            return $m === 'POST' ? $this->changePassword($req, $adminId) : $this->view($req, 'account', ['title' => 'Account']);
        }
        if ($p === '/diagnostics') {
            return $m === 'POST' ? $this->runMigrations($req, $adminId) : $this->diagnostics($req);
        }
        return $this->notFound($req);
    }

    // ---------------------------------------------------------------- setup

    private function needsSetup(): bool
    {
        try {
            if ($this->app->migrator->pending() !== []) {
                return true;
            }
            return $this->app->db->one('SELECT id FROM admins LIMIT 1') === null;
        } catch (\Throwable) {
            return true;
        }
    }

    private function setupAllowed(): ?string
    {
        $token = (string) $this->app->config->get('SETUP_TOKEN', '');
        if (strlen($token) < 24) {
            return 'Setup is disabled. Set SETUP_TOKEN (24+ random characters) in the private .env file.';
        }
        if (!$this->needsSetup()) {
            return 'Setup is already complete. Remove SETUP_TOKEN from .env.';
        }
        return null;
    }

    private function setupGet(Request $req, array $errors = []): Response
    {
        $blocked = $this->setupAllowed();
        $pending = [];
        try {
            $pending = $this->app->migrator->pending();
        } catch (\Throwable $e) {
            $errors[] = 'Database connection failed. Check DB_* values in .env.';
        }
        return $this->view($req, 'setup', ['title' => 'First-time setup', 'blocked' => $blocked, 'pending' => $pending, 'errors' => $errors]);
    }

    private function setupPost(Request $req): Response
    {
        if (($blocked = $this->setupAllowed()) !== null) {
            return $this->setupGet($req);
        }
        // Before the first migration the rate_limits table does not exist yet; the
        // 24+ character random setup token is the protection in that window.
        $tablesExist = !in_array('001_init', $this->app->migrator->pending(), true);
        if ($tablesExist && !$this->app->limiter->hit('setup:ip:' . $req->ip, 10, 900)) {
            return $this->setupGet($req, ['Too many attempts. Wait 15 minutes.']);
        }
        if (!hash_equals((string) $this->app->config->get('SETUP_TOKEN'), $req->postString('setup_token', 200))) {
            return $this->setupGet($req, ['Setup token is incorrect.']);
        }
        $username = $req->postString('username', 64);
        $password = (string) ($req->post['password'] ?? '');
        $errors = [];
        if (!preg_match('/^[A-Za-z0-9_.-]{3,64}$/', $username)) {
            $errors[] = 'Username: 3-64 letters, digits, dot, dash or underscore.';
        }
        if (($problem = AdminAuth::passwordProblem($password)) !== null) {
            $errors[] = $problem;
        }
        if ($password !== (string) ($req->post['password_confirm'] ?? '')) {
            $errors[] = 'Passwords do not match.';
        }
        if ($errors !== []) {
            return $this->setupGet($req, $errors);
        }
        $applied = $this->app->migrator->migrate();
        if ($this->app->db->one('SELECT id FROM admins LIMIT 1') !== null) {
            return Response::redirect('/login');
        }
        $id = $this->app->db->insert(
            'INSERT INTO admins (username, password_hash, created_at, password_changed_at) VALUES (?, ?, ?, ?)',
            [$username, AdminAuth::hashPassword($password), Clock::sql(), Clock::sql()]
        );
        $this->app->audit->log('setup.completed', $id, null, null, ['migrations' => $applied, 'username' => $username], $req->ip);
        $this->flash($req, 'Setup complete. Sign in, then remove SETUP_TOKEN from .env.');
        return Response::redirect('/login');
    }

    // ---------------------------------------------------------------- auth

    private function loginPost(Request $req): Response
    {
        $username = $req->postString('username', 64);
        $result = $this->app->adminAuth->attemptLogin($req, $username, (string) ($req->post['password'] ?? ''));
        if (!$result['ok']) {
            $this->app->audit->log('admin.login_failed', null, null, null, ['username' => $username], $req->ip);
            return $this->view($req, 'login', ['title' => 'Sign in', 'errors' => [$result['error']], 'username' => $username], 401);
        }
        $this->app->audit->log('admin.login', (int) $result['admin']['id'], null, null, [], $req->ip);
        return Response::redirect('/');
    }

    private function changePassword(Request $req, int $adminId): Response
    {
        $row = $this->app->db->one('SELECT password_hash FROM admins WHERE id = ?', [$adminId]);
        $new = (string) ($req->post['new_password'] ?? '');
        $errors = [];
        if (!$this->app->limiter->hit('pwchange:' . $adminId, 10, 900)
            || !password_verify((string) ($req->post['current_password'] ?? ''), (string) $row['password_hash'])) {
            $errors[] = 'Current password is incorrect.';
        }
        if (($problem = AdminAuth::passwordProblem($new)) !== null) {
            $errors[] = $problem;
        }
        if ($new !== (string) ($req->post['new_password_confirm'] ?? '')) {
            $errors[] = 'New passwords do not match.';
        }
        if ($errors !== []) {
            return $this->view($req, 'account', ['title' => 'Account', 'errors' => $errors], 422);
        }
        $this->app->db->exec(
            'UPDATE admins SET password_hash = ?, password_changed_at = ?, session_epoch = session_epoch + 1 WHERE id = ?',
            [AdminAuth::hashPassword($new), Clock::sql(), $adminId]
        );
        $this->app->audit->log('admin.password_changed', $adminId, null, null, [], $req->ip);
        $this->app->adminAuth->logout($req);
        return Response::redirect('/login');
    }

    // ---------------------------------------------------------------- kiosks

    private function dashboard(Request $req, int $adminId): Response
    {
        $kiosks = [];
        foreach ($this->app->kiosks->kiosksForAdmin($adminId) as $k) {
            $k['devices'] = $this->decorateDevices($this->app->kiosks->devicesForKiosk((int) $k['id']));
            $kiosks[] = $k;
        }
        return $this->view($req, 'dashboard', ['title' => 'Kiosks', 'kiosks' => $kiosks]);
    }

    private function createKiosk(Request $req, int $adminId): Response
    {
        $name = $req->postString('name', 100);
        if ($name === '') {
            $this->flash($req, 'Kiosk name is required.', 'error');
            return Response::redirect('/');
        }
        $id = $this->app->kiosks->createKiosk($adminId, $name);
        $this->app->audit->log('kiosk.created', $adminId, $id, null, ['name' => $name], $req->ip);
        return Response::redirect('/kiosks/' . $id);
    }

    private function kioskPage(Request $req, array $kiosk, array $errors = [], int $status = 200): Response
    {
        $kid = (int) $kiosk['id'];
        $db = $this->app->db;
        // A freshly generated enrollment code is displayed exactly once.
        $newCode = $req->session->get('new_code_' . $kid);
        $req->session->remove('new_code_' . $kid);
        return $this->view($req, 'kiosk', [
            'title' => $kiosk['name'],
            'kiosk' => $kiosk,
            'devices' => $this->decorateDevices($this->app->kiosks->devicesForKiosk($kid)),
            'config' => $this->app->kiosks->currentConfig($kid),
            'history' => $this->app->kiosks->configHistory($kid),
            'events' => $db->all('SELECT e.*, d.name AS device_name FROM coin_events e JOIN devices d ON d.id = e.device_id WHERE e.kiosk_id = ? ORDER BY e.occurred_at DESC, e.id DESC LIMIT 50', [$kid]),
            'sessions' => $db->all('SELECT * FROM sessions WHERE kiosk_id = ? ORDER BY started_at DESC, id DESC LIMIT 25', [$kid]),
            'totals' => $db->one("SELECT COUNT(*) AS credits, COALESCE(SUM(pulses),0) AS pulses, COALESCE(SUM(seconds_added),0) AS seconds FROM coin_events WHERE kiosk_id = ? AND event_type = 'credit'", [$kid]),
            'new_code' => $newCode,
            'errors' => $errors,
        ], $status);
    }

    /** JSON for the dashboard's auto-refresh. Session-authenticated GET, owner-scoped. */
    private function kioskStatusJson(array $kiosk): Response
    {
        $out = [];
        foreach ($this->decorateDevices($this->app->kiosks->devicesForKiosk((int) $kiosk['id'])) as $d) {
            $out[] = [
                'id' => (int) $d['id'],
                'presence' => $d['presence'],
                'last_seen_at' => $d['last_seen_at'],
                'status_reported_at' => $d['status_reported_at'],
                'status' => $d['status'],
                'config_version_applied' => $d['config_version_applied'] === null ? null : (int) $d['config_version_applied'],
            ];
        }
        return Response::json(['ok' => true, 'server_time' => Clock::now(), 'devices' => $out]);
    }

    private function saveConfig(Request $req, array $kiosk, int $adminId): Response
    {
        $v = KioskService::validateConfig([
            'seconds_per_pulse' => $req->postString('seconds_per_pulse', 10),
            'local_loss_timeout_s' => $req->postString('local_loss_timeout_s', 10),
            'controller_sync_interval_s' => $req->postString('controller_sync_interval_s', 10),
            'allowed_packages' => $req->postString('allowed_packages', 8000),
        ]);
        if ($v['errors'] !== []) {
            return $this->kioskPage($req, $kiosk, $v['errors'], 422);
        }
        $before = $this->app->kiosks->currentConfig((int) $kiosk['id']);
        $version = $this->app->kiosks->saveConfig((int) $kiosk['id'], $adminId, $v['config']);
        $this->app->audit->log('config.updated', $adminId, (int) $kiosk['id'], null, [
            'version' => $version,
            'from' => array_intersect_key($before, $v['config']),
            'to' => $v['config'],
        ], $req->ip);
        $this->flash($req, "Saved configuration version $version. Devices apply it on their next sync; new rates affect future coins only.");
        return Response::redirect('/kiosks/' . $kiosk['id']);
    }

    private function enrollCode(Request $req, array $kiosk, int $adminId): Response
    {
        $type = $req->postString('device_type', 16);
        if (!in_array($type, [DeviceAuth::TYPE_PHONE, DeviceAuth::TYPE_CONTROLLER], true)) {
            return $this->notFound($req);
        }
        if (!$this->app->limiter->hit('enrollcode:' . $adminId, 30, 3600)) {
            $this->flash($req, 'Too many enrollment codes generated. Wait and try again.', 'error');
            return Response::redirect('/kiosks/' . $kiosk['id']);
        }
        $code = $this->app->kiosks->createEnrollmentCode((int) $kiosk['id'], $adminId, $type);
        $this->app->audit->log('enrollment_code.created', $adminId, (int) $kiosk['id'], null, ['device_type' => $type], $req->ip);
        // Shown once on the next page view, then forgotten.
        $req->session->set('new_code_' . $kiosk['id'], ['code' => $code, 'type' => $type, 'expires' => Clock::now() + KioskService::ENROLL_CODE_TTL_S]);
        return Response::redirect('/kiosks/' . $kiosk['id']);
    }

    private function revokeDevice(Request $req, int $deviceId, int $adminId): Response
    {
        $device = $this->app->kiosks->deviceForAdmin($deviceId, $adminId);
        if ($device === null) {
            return $this->notFound($req);
        }
        if ($device['revoked_at'] === null) {
            $this->app->db->exec('UPDATE devices SET revoked_at = ? WHERE id = ?', [Clock::sql(), $deviceId]);
            $this->app->audit->log('device.revoked', $adminId, (int) $device['kiosk_id'], $deviceId, ['name' => $device['name'], 'type' => $device['device_type']], $req->ip);
            $this->flash($req, 'Device credential revoked. Enroll the device again with a new code to restore cloud reporting.');
        }
        return Response::redirect('/kiosks/' . $device['kiosk_id']);
    }

    private function auditPage(Request $req, int $adminId): Response
    {
        // Entries for this admin's kiosks plus the admin's own account actions.
        $rows = $this->app->db->all(
            'SELECT l.*, a.username, k.name AS kiosk_name FROM audit_log l
             LEFT JOIN admins a ON a.id = l.admin_id
             LEFT JOIN kiosks k ON k.id = l.kiosk_id
             WHERE (k.owner_admin_id = ?) OR (l.kiosk_id IS NULL AND l.admin_id = ?)
             ORDER BY l.id DESC LIMIT 200',
            [$adminId, $adminId]
        );
        return $this->view($req, 'audit', ['title' => 'Audit log', 'rows' => $rows]);
    }

    private function diagnostics(Request $req, array $notes = []): Response
    {
        return $this->view($req, 'diagnostics', [
            'title' => 'Diagnostics',
            'php' => PHP_VERSION,
            'driver' => $this->app->db->driver,
            'applied' => $this->app->migrator->applied(),
            'pending' => $this->app->migrator->pending(),
            'remote_addr' => (string) ($_SERVER['REMOTE_ADDR'] ?? $req->ip),
            'xff' => (string) ($_SERVER['HTTP_X_FORWARDED_FOR'] ?? ''),
            'client_ip' => $req->ip,
            'setup_token_set' => $this->app->config->get('SETUP_TOKEN') !== null,
            'notes' => $notes,
        ]);
    }

    private function runMigrations(Request $req, int $adminId): Response
    {
        $applied = $this->app->migrator->migrate();
        $this->app->audit->log('migrations.applied', $adminId, null, null, ['versions' => $applied], $req->ip);
        return $this->diagnostics($req, [$applied === [] ? 'No pending migrations.' : 'Applied: ' . implode(', ', $applied)]);
    }

    // ---------------------------------------------------------------- helpers

    /** @return list<array<string,mixed>> */
    private function decorateDevices(array $devices): array
    {
        foreach ($devices as &$d) {
            $d['presence'] = KioskService::presence($d, $this->app->staleAfter((string) $d['device_type']));
            $d['status'] = $d['status_json'] ? json_decode((string) $d['status_json'], true) : null;
        }
        return $devices;
    }

    private function flash(Request $req, string $message, string $kind = 'ok'): void
    {
        $req->session->set('flash', ['kind' => $kind, 'message' => $message]);
    }

    private function notFound(Request $req): Response
    {
        return $this->view($req, 'notfound', ['title' => 'Not found'], 404);
    }

    private function view(Request $req, string $template, array $vars, int $status = 200): Response
    {
        $flash = $req->session->get('flash');
        $req->session->remove('flash');
        $vars += [
            'admin' => $this->admin,
            'csrf' => Csrf::token($req),
            'flash' => $flash,
            'errors' => [],
        ];
        return Response::html(View::render($template, $vars), $status);
    }
}
