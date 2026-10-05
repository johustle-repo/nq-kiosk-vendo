<?php

namespace App\Http\Controllers\Api;

use App\Http\ApiError;
use App\Http\Controllers\Controller;
use App\Models\AuditLog;
use App\Models\Device;
use App\Services\ControllerChannel;
use App\Services\IngestService;
use App\Services\SiteService;
use Illuminate\Database\Migrations\Migrator;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Throwable;

/** Device API (/api/v1) used by the coin box firmware and the kiosk tablets. */
class DeviceApiController extends Controller
{
    public function __construct(
        private readonly SiteService $sites,
        private readonly IngestService $ingest,
        private readonly ControllerChannel $channel,
    ) {}

    public function health(Migrator $migrator): JsonResponse
    {
        $db = 'ok';
        $pending = null;
        try {
            DB::select('SELECT 1');
            $ran = $migrator->getRepository()->getRan();
            $files = array_keys($migrator->getMigrationFiles(database_path('migrations')));
            $pending = count(array_diff($files, $ran));
        } catch (Throwable) {
            $db = 'unavailable';
        }
        $ok = $db === 'ok' && $pending === 0;

        return response()->json([
            'ok' => $ok,
            'service' => 'vendo-kiosk',
            'api_version' => config('vendo.api_version'),
            'backend_version' => config('vendo.backend_version'),
            'database' => $db,
            'pending_migrations' => $pending,
            'server_time' => time(),
        ], $ok ? 200 : 503);
    }

    public function enroll(Request $request): JsonResponse
    {
        $in = self::json($request) ?? [];
        $type = $in['device_type'] ?? null;
        $code = $in['enrollment_code'] ?? null;
        $name = is_string($in['name'] ?? null) ? trim(preg_replace('/[^\x20-\x7E]/', '', $in['name']) ?? '') : '';
        $hw = is_string($in['hardware_id'] ?? null) ? substr(preg_replace('/[^A-Za-z0-9:._-]/', '', $in['hardware_id']) ?? '', 0, 64) : null;
        if (! in_array($type, [Device::TYPE_PHONE, Device::TYPE_CONTROLLER], true) || ! is_string($code) || strlen($code) > 32) {
            return ApiError::response('invalid_fields', 'device_type and enrollment_code are required.', 422);
        }
        if ($name === '') {
            $name = $type === Device::TYPE_PHONE ? 'Kiosk tablet' : 'Coin box';
        }
        $result = $this->sites->enroll($code, $type, substr($name, 0, 100), $hw ?: null);
        if (! $result['ok']) {
            AuditLog::record('device.enroll_failed', null, null, null, ['reason' => $result['error'], 'type' => $type], $request->ip());

            return ApiError::response($result['error'], 'Enrollment code is invalid, expired, already used, or for another device type.', 403);
        }
        $device = $result['device'];
        AuditLog::record('device.enrolled', null, $device->site_id, $device->id,
            ['type' => $type, 'name' => $name, 'station' => $device->station_no], $request->ip());

        return response()->json([
            'ok' => true,
            'device_id' => $device->public_id,
            'device_token' => $result['token'],
            'station' => $device->station_no,
            'api_base' => rtrim((string) config('app.url'), '/').'/api/v1',
        ], 201);
    }

    public function controllerSync(Request $request): JsonResponse
    {
        return self::reply($this->ingest->controllerSync(self::device($request), self::json($request), (string) $request->ip()));
    }

    public function controllerPoll(Request $request): JsonResponse
    {
        return self::reply($this->channel->poll(self::device($request), self::json($request), (string) $request->ip()));
    }

    public function phoneHeartbeat(Request $request): JsonResponse
    {
        return self::reply($this->ingest->phoneHeartbeat(self::device($request), self::json($request), (string) $request->ip()));
    }

    private static function device(Request $request): Device
    {
        return $request->attributes->get('device');
    }

    /** Strict JSON object body, or null (ints stay ints for exact validation). */
    private static function json(Request $request): ?array
    {
        $data = json_decode($request->getContent(), true);

        return is_array($data) && ($data === [] || ! array_is_list($data)) ? $data : null;
    }

    /** @param array{status: int, body: array<string, mixed>} $r */
    private static function reply(array $r): JsonResponse
    {
        return response()->json($r['body'], $r['status']);
    }
}
