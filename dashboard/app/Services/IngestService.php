<?php

namespace App\Services;

use App\Models\CoinEvent;
use App\Models\Device;
use App\Models\KioskSession;
use App\Models\Site;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;

/**
 * Stores what devices report:
 *  - coin events are idempotent on (device, boot_id, seq);
 *  - status reports never move backwards within one boot;
 *  - sync and heartbeat responses never contain paid time. Time can only reach
 *    the coin box as an audited dashboard command on /controller/poll.
 *
 * Protocol 1 (one tablet) and protocol 2 (up to 4 tablets, held coins) are both
 * accepted; protocol 1 events belong to station 1.
 */
class IngestService
{
    public const MAX_EVENTS_PER_SYNC = 32;

    public const PROTOCOLS = [1, 2];

    public static function isBootId(mixed $v): bool
    {
        return is_string($v) && preg_match('/^[0-9a-f]{8,16}$/', $v) === 1;
    }

    public static function intIn(mixed $v, int $min, int $max): ?int
    {
        return is_int($v) && $v >= $min && $v <= $max ? $v : null;
    }

    public static function str(mixed $v, int $max): ?string
    {
        if (! is_string($v)) {
            return null;
        }
        $v = preg_replace('/[^\x20-\x7E]/', '', $v) ?? '';

        return $v === '' ? null : substr($v, 0, $max);
    }

    /** @return array{status: int, body: array<string, mixed>} */
    public static function error(string $code, string $message, int $status = 422): array
    {
        return ['status' => $status, 'body' => ['ok' => false, 'error' => ['code' => $code, 'message' => $message]]];
    }

    /** @return array{status: int, body: array<string, mixed>} */
    public function controllerSync(Device $device, ?array $in, string $ip): array
    {
        if ($in === null) {
            return self::error('invalid_json', 'Body must be a JSON object.');
        }
        $protocol = $in['protocol'] ?? null;
        if (! in_array($protocol, self::PROTOCOLS, true)) {
            return self::error('unsupported_protocol', 'Expected protocol 1 or 2.');
        }
        $bootId = $in['boot_id'] ?? null;
        $uptime = self::intIn($in['uptime_ms'] ?? null, 0, PHP_INT_MAX);
        $status = $in['status'] ?? null;
        if (! self::isBootId($bootId) || $uptime === null || ! is_array($status)) {
            return self::error('invalid_fields', 'boot_id, uptime_ms and status are required.');
        }
        $cleanStatus = self::cleanControllerStatus($status);
        $events = $in['events'] ?? [];
        if (! is_array($events) || count($events) > self::MAX_EVENTS_PER_SYNC) {
            return self::error('too_many_events', 'At most '.self::MAX_EVENTS_PER_SYNC.' events per sync.');
        }

        $now = time();
        $acked = [];
        $rejected = [];
        $inserted = 0;
        foreach ($events as $ev) {
            $seq = is_array($ev) ? self::intIn($ev['seq'] ?? null, 1, PHP_INT_MAX) : null;
            $clean = $seq === null ? null : self::validateEvent($ev, $protocol);
            if ($clean === null) {
                if ($seq !== null) {
                    $rejected[] = $seq;
                }

                continue;
            }
            $occurred = self::occurredAt($clean, $uptime, $now);
            if ($this->storeEvent($device, (string) $bootId, $seq, $clean, $occurred)) {
                $inserted++;
            }
            $acked[] = $seq;
        }

        $applied = self::intIn($in['config_version_applied'] ?? null, 0, PHP_INT_MAX);
        $this->updateStatus($device, (string) $bootId, $uptime, $cleanStatus, $ip, self::str($in['fw_version'] ?? null, 32), $applied);
        if ($protocol === 2) {
            Site::whereKey($device->site_id)->update(['held_pulses' => $cleanStatus['held_pulses']]);
        }

        $cfg = $device->site->currentConfig();

        return ['status' => 200, 'body' => [
            'ok' => true,
            'server_time' => $now,
            'ack' => ['boot_id' => $bootId, 'acked_seqs' => $acked, 'rejected_seqs' => $rejected, 'inserted' => $inserted],
            'config' => [
                'version' => (int) $cfg->version,
                'seconds_per_pulse' => (int) $cfg->seconds_per_pulse,
                'sync_interval_s' => (int) $cfg->controller_sync_interval_s,
            ],
        ]];
    }

    /** @return array<string, mixed> */
    private static function cleanControllerStatus(array $status): array
    {
        $clean = [
            'session' => in_array($status['session'] ?? null, ['idle', 'running'], true) ? $status['session'] : 'unknown',
            'remaining_s' => self::intIn($status['remaining_s'] ?? null, 0, 30 * 86400) ?? 0,
            'seq' => self::intIn($status['seq'] ?? null, 0, PHP_INT_MAX) ?? 0,
            'session_no' => self::intIn($status['session_no'] ?? null, 0, PHP_INT_MAX) ?? 0,
            'seconds_per_pulse' => self::intIn($status['seconds_per_pulse'] ?? null, 0, 86400) ?? 0,
            'rate_version' => self::intIn($status['rate_version'] ?? null, 0, PHP_INT_MAX) ?? 0,
            'wifi_rssi' => self::intIn($status['wifi_rssi'] ?? null, -150, 0),
            'free_heap' => self::intIn($status['free_heap'] ?? null, 0, 1 << 20),
            'buffered_events' => self::intIn($status['buffered_events'] ?? null, 0, 1000) ?? 0,
            'dropped_events' => self::intIn($status['dropped_events'] ?? null, 0, PHP_INT_MAX) ?? 0,
            'phone_last_poll_age_s' => self::intIn($status['phone_last_poll_age_s'] ?? null, -1, PHP_INT_MAX),
            'held_pulses' => self::intIn($status['held_pulses'] ?? null, 0, 100000) ?? 0,
            'stations' => [],
        ];
        // Protocol 2: one entry per tablet.
        foreach (array_slice(is_array($status['stations'] ?? null) ? $status['stations'] : [], 0, Site::MAX_STATIONS) as $s) {
            $n = is_array($s) ? self::intIn($s['station'] ?? null, 1, Site::MAX_STATIONS) : null;
            if ($n === null) {
                continue;
            }
            $clean['stations'][$n] = [
                'session' => in_array($s['session'] ?? null, ['idle', 'running'], true) ? $s['session'] : 'unknown',
                'remaining_s' => self::intIn($s['remaining_s'] ?? null, 0, 30 * 86400) ?? 0,
                'session_no' => self::intIn($s['session_no'] ?? null, 0, PHP_INT_MAX) ?? 0,
                'paired' => ($s['paired'] ?? null) === true,
                'phone_last_poll_age_s' => self::intIn($s['phone_last_poll_age_s'] ?? null, -1, PHP_INT_MAX),
            ];
        }
        // Protocol 1: the single session is station 1.
        if ($clean['stations'] === []) {
            $clean['stations'][1] = [
                'session' => $clean['session'], 'remaining_s' => $clean['remaining_s'], 'session_no' => $clean['session_no'],
                'paired' => true, 'phone_last_poll_age_s' => $clean['phone_last_poll_age_s'],
            ];
        }

        return $clean;
    }

    /** @return array<string, int|string>|null */
    private static function validateEvent(array $ev, int $protocol): ?array
    {
        $type = $ev['type'] ?? null;
        $types = $protocol === 1 ? ['credit', 'expire'] : CoinEvent::TYPES;
        if (! in_array($type, $types, true)) {
            return null;
        }
        $station = $protocol === 1 ? 1 : self::intIn($ev['station'] ?? null, 0, Site::MAX_STATIONS);
        $clean = [
            'type' => $type,
            'station' => $station,
            'session_no' => self::intIn($ev['session_no'] ?? 0, 0, PHP_INT_MAX),
            'pulses' => self::intIn($ev['pulses'] ?? 0, 0, 1000),
            'seconds' => self::intIn($ev['seconds'] ?? 0, 0, 7 * 86400),
            'rate_version' => self::intIn($ev['rate_version'] ?? 0, 0, PHP_INT_MAX),
            'remaining_after' => self::intIn($ev['remaining_after'] ?? 0, 0, 30 * 86400),
            'uptime_ms' => self::intIn($ev['uptime_ms'] ?? null, 0, PHP_INT_MAX),
            'unix_time' => self::intIn($ev['unix_time'] ?? 0, 0, PHP_INT_MAX),
            'command_id' => self::intIn($ev['command_id'] ?? 0, 0, PHP_INT_MAX),
        ];
        foreach ($clean as $v) {
            if ($v === null) {
                return null;
            }
        }
        // Only held coins live on station 0; everything else names a tablet.
        if (($type === 'held') !== ($clean['station'] === 0)) {
            return null;
        }
        $ok = match ($type) {
            'credit', 'assign' => $clean['pulses'] >= 1 && $clean['seconds'] >= 1,
            'held' => $clean['pulses'] >= 1,
            'admin_credit' => $clean['seconds'] >= 1 && $clean['pulses'] === 0,
            default => true, // expire, admin_end
        };

        return $ok ? $clean : null;
    }

    /** Device NTP time when plausible, otherwise derived from device uptime. */
    private static function occurredAt(array $ev, int $deviceUptimeNow, int $now): int
    {
        $unix = (int) $ev['unix_time'];
        if ($unix > 1700000000 && abs($unix - $now) < 86400) {
            return $unix;
        }

        return $now - intdiv(max(0, $deviceUptimeNow - (int) $ev['uptime_ms']), 1000);
    }

    /** Returns true when the event was new; false for a retried duplicate. */
    private function storeEvent(Device $device, string $bootId, int $seq, array $ev, int $occurred): bool
    {
        return DB::transaction(function () use ($device, $bootId, $seq, $ev, $occurred): bool {
            $at = Carbon::createFromTimestamp($occurred);
            try {
                CoinEvent::create([
                    'device_id' => $device->id, 'site_id' => $device->site_id, 'station_no' => $ev['station'],
                    'boot_id' => $bootId, 'seq' => $seq, 'event_type' => $ev['type'], 'session_no' => $ev['session_no'],
                    'pulses' => $ev['pulses'], 'seconds_added' => $ev['seconds'], 'rate_version' => $ev['rate_version'],
                    'remaining_after' => $ev['remaining_after'], 'device_uptime_ms' => $ev['uptime_ms'],
                    'command_id' => $ev['command_id'] ?: null, 'occurred_at' => $at, 'received_at' => now(),
                ]);
            } catch (UniqueConstraintViolationException) {
                return false; // Already stored by an earlier attempt.
            }
            if ($ev['station'] === 0) {
                return true; // Held coins belong to no session until assigned.
            }
            $session = KioskSession::where([
                'device_id' => $device->id, 'boot_id' => $bootId, 'station_no' => $ev['station'], 'session_no' => $ev['session_no'],
            ])->first();
            if (in_array($ev['type'], ['credit', 'assign', 'admin_credit'], true)) {
                $pulses = $ev['type'] === 'admin_credit' ? 0 : $ev['pulses'];
                if ($session === null) {
                    KioskSession::create([
                        'device_id' => $device->id, 'site_id' => $device->site_id, 'station_no' => $ev['station'],
                        'boot_id' => $bootId, 'session_no' => $ev['session_no'], 'started_at' => $at, 'last_credit_at' => $at,
                        'total_pulses' => $pulses, 'total_seconds' => $ev['seconds'], 'credit_count' => 1,
                    ]);
                } else {
                    $session->increment('total_pulses', $pulses, ['last_credit_at' => $at]);
                    $session->increment('total_seconds', $ev['seconds']);
                    $session->increment('credit_count');
                }
            } elseif ($session !== null) {
                $session->update(['ended_at' => $at, 'end_reason' => $ev['type'] === 'admin_end' ? 'ended_by_admin' : 'expired']);
            }

            return true;
        });
    }

    /**
     * Stores the latest status report. Within one boot, a report with a lower
     * uptime than the stored one is older (delayed/retried) and is discarded.
     */
    public function updateStatus(Device $device, string $bootId, int $uptimeMs, array $status, string $ip, ?string $swVersion, ?int $configApplied): bool
    {
        $fresh = $device->status_boot_id === null
            || $device->status_boot_id !== $bootId
            || $uptimeMs > (int) $device->status_uptime_ms;
        // Presence is updated for every authenticated contact, even a stale report.
        $update = ['last_seen_at' => now(), 'last_ip' => $ip];
        if ($fresh) {
            $update += [
                'status_json' => $status, 'status_boot_id' => $bootId, 'status_uptime_ms' => $uptimeMs,
                'status_reported_at' => now(),
            ];
            if ($swVersion !== null) {
                $update['sw_version'] = $swVersion;
            }
            if ($configApplied !== null) {
                $update['config_version_applied'] = $configApplied;
            }
        }
        $device->update($update);

        return $fresh;
    }

    /** @return array{status: int, body: array<string, mixed>} */
    public function phoneHeartbeat(Device $device, ?array $in, string $ip): array
    {
        if ($in === null) {
            return self::error('invalid_json', 'Body must be a JSON object.');
        }
        $bootId = $in['boot_id'] ?? null;
        $uptime = self::intIn($in['uptime_ms'] ?? null, 0, PHP_INT_MAX);
        if (! self::isBootId($bootId) || $uptime === null) {
            return self::error('invalid_fields', 'boot_id and uptime_ms are required.');
        }
        $ctl = is_array($in['controller'] ?? null) ? $in['controller'] : [];
        $pk = is_array($in['allowed_packages'] ?? null) ? $in['allowed_packages'] : [];
        $battery = is_array($in['battery'] ?? null) ? $in['battery'] : [];
        $station = self::intIn($ctl['station'] ?? null, 1, Site::MAX_STATIONS);
        $status = [
            'mode' => in_array($in['mode'] ?? null, ['demo', 'production', 'unconfigured'], true) ? $in['mode'] : 'unknown',
            'device_owner' => ($in['device_owner'] ?? null) === true,
            'lock_task' => self::str($in['lock_task'] ?? null, 16),
            'access' => self::str($in['access'] ?? null, 32),
            'controller_paired' => ($ctl['paired'] ?? null) === true,
            'controller_link' => self::str($ctl['link'] ?? null, 16),
            'controller_last_ok_age_s' => self::intIn($ctl['last_ok_age_s'] ?? null, -1, PHP_INT_MAX),
            'controller_remaining_s' => self::intIn($ctl['remaining_s'] ?? null, 0, 30 * 86400),
            'controller_station' => $station,
            'allowed_packages' => array_values(array_filter(array_slice($pk, 0, 50),
                static fn ($p) => is_string($p) && SiteService::isPackageName($p))),
            'model' => self::str($in['model'] ?? null, 64),
            'android_sdk' => self::intIn($in['android_sdk'] ?? null, 1, 1000),
            'battery_pct' => self::intIn($battery['pct'] ?? null, 0, 100),
            'charging' => ($battery['charging'] ?? null) === true,
            'tap_admin' => ($in['tap_admin'] ?? null) === true,
        ];
        $applied = self::intIn($in['config_version_applied'] ?? null, 0, PHP_INT_MAX);
        $this->updateStatus($device, (string) $bootId, $uptime, $status, $ip, self::str($in['app_version'] ?? null, 32), $applied);
        // A tablet enrolled without a number adopts the one it paired with.
        if ($device->station_no === null && $station !== null) {
            $device->update(['station_no' => $station]);
        }
        $cfg = $device->site->currentConfig();
        $body = [
            'ok' => true,
            'server_time' => time(),
            'config' => [
                'version' => (int) $cfg->version,
                'allowed_packages' => $cfg->allowed_packages,
                'local_loss_timeout_s' => (int) $cfg->local_loss_timeout_s,
                'seconds_per_pulse' => (int) $cfg->seconds_per_pulse,
            ],
        ];
        // "Open admin" from the dashboard: handed over once (claimed atomically), then cleared.
        $unlockId = $device->admin_unlock_id;
        if ($unlockId !== null) {
            $claimed = Device::whereKey($device->id)->where('admin_unlock_id', $unlockId)
                ->update(['admin_unlock_id' => null, 'admin_unlock_expires_at' => null]);
            if ($claimed === 1 && $device->admin_unlock_expires_at?->isFuture()) {
                $body['admin_unlock'] = ['id' => $unlockId];
            }
        }

        // "Enable 10 taps" from the dashboard: handed over once, then cleared.
        if ($device->tap_admin_expires_at !== null) {
            $claimed = Device::whereKey($device->id)->whereNotNull('tap_admin_expires_at')
                ->update(['tap_admin_expires_at' => null]);
            if ($claimed === 1 && $device->tap_admin_expires_at->isFuture()) {
                $body['tap_admin'] = true;
            }
        }

        return ['status' => 200, 'body' => $body];
    }
}
