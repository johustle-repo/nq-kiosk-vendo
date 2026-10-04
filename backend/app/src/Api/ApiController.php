<?php

declare(strict_types=1);

namespace Vendo\Api;

use Vendo\App;
use Vendo\Auth\DeviceAuth;
use Vendo\Clock;
use Vendo\Request;
use Vendo\Response;

/**
 * Device API (/api/v1). Devices authenticate with a per-device bearer token.
 * No endpoint here can grant paid time: the ESP8266 is authoritative and the
 * cloud only records what devices report.
 */
final class ApiController
{
    public function __construct(private readonly App $app)
    {
    }

    public function handle(Request $req): Response
    {
        $route = $req->method . ' ' . $req->path;
        return match ($route) {
            'GET /api/v1/health' => $this->health(),
            'POST /api/v1/devices/enroll' => $this->enroll($req),
            'POST /api/v1/controller/sync' => $this->controllerSync($req),
            'POST /api/v1/phone/heartbeat' => $this->phoneHeartbeat($req),
            default => Response::apiError('not_found', 'Unknown endpoint.', 404),
        };
    }

    private function health(): Response
    {
        $db = 'ok';
        $pending = null;
        try {
            $this->app->db->one('SELECT 1 AS one');
            $pending = count($this->app->migrator->pending());
        } catch (\Throwable $e) {
            error_log('[vendo] health db: ' . $e->getMessage());
            $db = 'error';
        }
        $ok = $db === 'ok' && $pending === 0;
        return Response::json([
            'ok' => $ok,
            'service' => 'vendo-kiosk',
            'api_version' => VENDO_API_VERSION,
            'backend_version' => VENDO_BACKEND_VERSION,
            'database' => $db,
            'pending_migrations' => $pending,
            'server_time' => Clock::now(),
        ], $ok ? 200 : 503);
    }

    private function enroll(Request $req): Response
    {
        if (!$this->app->limiter->hit('enroll:ip:' . $req->ip, 10, 3600)) {
            return Response::apiError('rate_limited', 'Too many enrollment attempts. Try again later.', 429);
        }
        $in = $req->json();
        $type = $in['device_type'] ?? null;
        $code = $in['enrollment_code'] ?? null;
        $name = is_string($in['name'] ?? null) ? trim(preg_replace('/[^\x20-\x7E]/', '', $in['name']) ?? '') : '';
        $hw = is_string($in['hardware_id'] ?? null) ? substr(preg_replace('/[^A-Za-z0-9:._-]/', '', $in['hardware_id']) ?? '', 0, 64) : null;
        if (!in_array($type, [DeviceAuth::TYPE_PHONE, DeviceAuth::TYPE_CONTROLLER], true) || !is_string($code) || strlen($code) > 32) {
            return Response::apiError('invalid_fields', 'device_type and enrollment_code are required.', 422);
        }
        if ($name === '') {
            $name = $type === DeviceAuth::TYPE_PHONE ? 'Kiosk phone' : 'Coin controller';
        }
        $result = $this->app->kiosks->enroll($code, $type, substr($name, 0, 100), $hw ?: null);
        if (!$result['ok']) {
            $this->app->audit->log('device.enroll_failed', null, null, null, ['reason' => $result['error'], 'type' => $type], $req->ip);
            return Response::apiError($result['error'], 'Enrollment code is invalid, expired, already used, or for another device type.', 403);
        }
        $this->app->audit->log('device.enrolled', null, $result['kiosk_id'], $result['device_id'], ['type' => $type, 'name' => $name], $req->ip);
        return Response::json([
            'ok' => true,
            'device_id' => $result['public_id'],
            'device_token' => $result['token'],
            'api_base' => rtrim((string) $this->app->config->get('APP_URL', ''), '/') . '/api/v1',
        ], 201);
    }

    private function controllerSync(Request $req): Response
    {
        $device = $this->app->deviceAuth->authenticate($req, DeviceAuth::TYPE_CONTROLLER);
        if ($device === null) {
            return Response::apiError('unauthorized', 'Missing, invalid, revoked or wrong-type device token.', 401);
        }
        if (!$this->app->limiter->hit('dev:' . $device['id'], 120, 60)) {
            return Response::apiError('rate_limited', 'Sync too frequent.', 429);
        }
        $r = $this->app->ingest->controllerSync($device, $req->json(), $req->ip);
        return Response::json($r['body'], $r['status']);
    }

    private function phoneHeartbeat(Request $req): Response
    {
        $device = $this->app->deviceAuth->authenticate($req, DeviceAuth::TYPE_PHONE);
        if ($device === null) {
            return Response::apiError('unauthorized', 'Missing, invalid, revoked or wrong-type device token.', 401);
        }
        if (!$this->app->limiter->hit('dev:' . $device['id'], 120, 60)) {
            return Response::apiError('rate_limited', 'Heartbeat too frequent.', 429);
        }
        $r = $this->app->ingest->phoneHeartbeat($device, $req->json(), $req->ip);
        return Response::json($r['body'], $r['status']);
    }
}
