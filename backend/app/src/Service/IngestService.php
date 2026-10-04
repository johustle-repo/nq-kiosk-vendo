<?php

declare(strict_types=1);

namespace Vendo\Service;

use Vendo\Clock;
use Vendo\Db;

/**
 * Stores what devices report. The cloud is a record keeper only:
 *  - coin events are idempotent on (device, boot_id, seq);
 *  - status reports never move backwards within one boot;
 *  - nothing here ever sends paid time back to a device.
 */
final class IngestService
{
    public const MAX_EVENTS_PER_SYNC = 32;
    public const PROTOCOL = 1;

    public function __construct(private readonly Db $db, private readonly KioskService $kiosks)
    {
    }

    public static function isBootId(mixed $v): bool
    {
        return is_string($v) && preg_match('/^[0-9a-f]{8,16}$/', $v) === 1;
    }

    private static function intIn(mixed $v, int $min, int $max): ?int
    {
        if (!is_int($v) || $v < $min || $v > $max) {
            return null;
        }
        return $v;
    }

    /**
     * @return array{status:int, body:array<string,mixed>}
     */
    public function controllerSync(array $device, ?array $in, string $ip): array
    {
        if ($in === null) {
            return self::error('invalid_json', 'Body must be a JSON object.');
        }
        if (($in['protocol'] ?? null) !== self::PROTOCOL) {
            return self::error('unsupported_protocol', 'Expected protocol ' . self::PROTOCOL . '.');
        }
        $bootId = $in['boot_id'] ?? null;
        $uptime = self::intIn($in['uptime_ms'] ?? null, 0, PHP_INT_MAX);
        $status = $in['status'] ?? null;
        if (!self::isBootId($bootId) || $uptime === null || !is_array($status)) {
            return self::error('invalid_fields', 'boot_id, uptime_ms and status are required.');
        }
        $cleanStatus = [
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
        ];
        $events = $in['events'] ?? [];
        if (!is_array($events) || count($events) > self::MAX_EVENTS_PER_SYNC) {
            return self::error('too_many_events', 'At most ' . self::MAX_EVENTS_PER_SYNC . ' events per sync.');
        }

        $now = Clock::now();
        $acked = [];
        $rejected = [];
        $inserted = 0;
        foreach ($events as $ev) {
            $seq = is_array($ev) ? self::intIn($ev['seq'] ?? null, 1, PHP_INT_MAX) : null;
            $clean = $seq === null ? null : self::validateEvent($ev);
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

        $cfg = $this->kiosks->currentConfig((int) $device['kiosk_id']);
        return ['status' => 200, 'body' => [
            'ok' => true,
            'server_time' => $now,
            'ack' => ['boot_id' => $bootId, 'acked_seqs' => $acked, 'rejected_seqs' => $rejected, 'inserted' => $inserted],
            'config' => [
                'version' => (int) $cfg['version'],
                'seconds_per_pulse' => (int) $cfg['seconds_per_pulse'],
                'sync_interval_s' => (int) $cfg['controller_sync_interval_s'],
            ],
        ]];
    }

    /** @return array<string,int|string>|null */
    private static function validateEvent(array $ev): ?array
    {
        $type = $ev['type'] ?? null;
        if (!in_array($type, ['credit', 'expire'], true)) {
            return null;
        }
        $clean = [
            'type' => $type,
            'session_no' => self::intIn($ev['session_no'] ?? null, 0, PHP_INT_MAX),
            'pulses' => self::intIn($ev['pulses'] ?? 0, 0, 1000),
            'seconds' => self::intIn($ev['seconds'] ?? 0, 0, 7 * 86400),
            'rate_version' => self::intIn($ev['rate_version'] ?? 0, 0, PHP_INT_MAX),
            'remaining_after' => self::intIn($ev['remaining_after'] ?? 0, 0, 30 * 86400),
            'uptime_ms' => self::intIn($ev['uptime_ms'] ?? null, 0, PHP_INT_MAX),
            'unix_time' => self::intIn($ev['unix_time'] ?? 0, 0, PHP_INT_MAX),
        ];
        foreach ($clean as $v) {
            if ($v === null) {
                return null;
            }
        }
        if ($type === 'credit' && ($clean['pulses'] < 1 || $clean['seconds'] < 1)) {
            return null;
        }
        return $clean;
    }

    /** Device NTP time when plausible, otherwise derived from device uptime. */
    private static function occurredAt(array $ev, int $deviceUptimeNow, int $now): int
    {
        $unix = (int) $ev['unix_time'];
        if ($unix > 1700000000 && abs($unix - $now) < 86400) {
            return $unix;
        }
        $ageS = intdiv(max(0, $deviceUptimeNow - (int) $ev['uptime_ms']), 1000);
        return $now - $ageS;
    }

    /** Returns true when the event was new; false for a retried duplicate. */
    private function storeEvent(array $device, string $bootId, int $seq, array $ev, int $occurred): bool
    {
        return $this->db->tx(function () use ($device, $bootId, $seq, $ev, $occurred): bool {
            try {
                $this->db->exec(
                    'INSERT INTO coin_events (device_id, kiosk_id, boot_id, seq, event_type, session_no, pulses, seconds_added, rate_version, remaining_after, device_uptime_ms, occurred_at, received_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                    [$device['id'], $device['kiosk_id'], $bootId, $seq, $ev['type'], $ev['session_no'], $ev['pulses'], $ev['seconds'],
                        $ev['rate_version'], $ev['remaining_after'], $ev['uptime_ms'], Clock::sql($occurred), Clock::sql()]
                );
            } catch (\PDOException $e) {
                if (Db::isUniqueViolation($e)) {
                    return false; // Already stored by an earlier attempt.
                }
                throw $e;
            }
            $key = [$device['id'], $bootId, $ev['session_no']];
            $session = $this->db->one('SELECT id FROM sessions WHERE device_id = ? AND boot_id = ? AND session_no = ?', $key);
            if ($ev['type'] === 'credit') {
                if ($session === null) {
                    $this->db->exec(
                        'INSERT INTO sessions (device_id, kiosk_id, boot_id, session_no, started_at, last_credit_at, total_pulses, total_seconds, credit_count)
                         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)',
                        [$device['id'], $device['kiosk_id'], $bootId, $ev['session_no'], Clock::sql($occurred), Clock::sql($occurred), $ev['pulses'], $ev['seconds']]
                    );
                } else {
                    $this->db->exec(
                        'UPDATE sessions SET total_pulses = total_pulses + ?, total_seconds = total_seconds + ?, credit_count = credit_count + 1, last_credit_at = ? WHERE id = ?',
                        [$ev['pulses'], $ev['seconds'], Clock::sql($occurred), $session['id']]
                    );
                }
            } elseif ($session !== null) {
                $this->db->exec("UPDATE sessions SET ended_at = ?, end_reason = 'expired' WHERE id = ?", [Clock::sql($occurred), $session['id']]);
            }
            return true;
        });
    }

    /**
     * Stores the latest status report. Within one boot, a report with a lower
     * uptime than the stored one is older (delayed/retried) and is discarded.
     */
    public function updateStatus(array $device, string $bootId, int $uptimeMs, array $status, string $ip, ?string $swVersion, ?int $configApplied): bool
    {
        $current = $this->db->one('SELECT status_boot_id, status_uptime_ms FROM devices WHERE id = ?', [$device['id']]);
        $fresh = $current === null
            || $current['status_boot_id'] === null
            || $current['status_boot_id'] !== $bootId
            || $uptimeMs > (int) $current['status_uptime_ms'];
        $now = Clock::sql();
        // Presence is updated for every authenticated contact, even a stale report.
        $this->db->exec('UPDATE devices SET last_seen_at = ?, last_ip = ? WHERE id = ?', [$now, $ip, $device['id']]);
        if (!$fresh) {
            return false;
        }
        $this->db->exec(
            'UPDATE devices SET status_json = ?, status_boot_id = ?, status_uptime_ms = ?, status_reported_at = ?,
                sw_version = COALESCE(?, sw_version), config_version_applied = COALESCE(?, config_version_applied) WHERE id = ?',
            [json_encode($status, JSON_UNESCAPED_SLASHES), $bootId, $uptimeMs, $now, $swVersion, $configApplied, $device['id']]
        );
        return true;
    }

    /**
     * @return array{status:int, body:array<string,mixed>}
     */
    public function phoneHeartbeat(array $device, ?array $in, string $ip): array
    {
        if ($in === null) {
            return self::error('invalid_json', 'Body must be a JSON object.');
        }
        $bootId = $in['boot_id'] ?? null;
        $uptime = self::intIn($in['uptime_ms'] ?? null, 0, PHP_INT_MAX);
        if (!self::isBootId($bootId) || $uptime === null) {
            return self::error('invalid_fields', 'boot_id and uptime_ms are required.');
        }
        $ctl = is_array($in['controller'] ?? null) ? $in['controller'] : [];
        $pk = is_array($in['allowed_packages'] ?? null) ? $in['allowed_packages'] : [];
        $status = [
            'mode' => in_array($in['mode'] ?? null, ['demo', 'production', 'unconfigured'], true) ? $in['mode'] : 'unknown',
            'device_owner' => ($in['device_owner'] ?? null) === true,
            'lock_task' => self::str($in['lock_task'] ?? null, 16),
            'access' => self::str($in['access'] ?? null, 32),
            'controller_paired' => ($ctl['paired'] ?? null) === true,
            'controller_link' => self::str($ctl['link'] ?? null, 16),
            'controller_last_ok_age_s' => self::intIn($ctl['last_ok_age_s'] ?? null, -1, PHP_INT_MAX),
            'controller_remaining_s' => self::intIn($ctl['remaining_s'] ?? null, 0, 30 * 86400),
            'allowed_packages' => array_values(array_filter(array_slice($pk, 0, 50), static fn ($p) => is_string($p) && KioskService::isPackageName($p))),
            'model' => self::str($in['model'] ?? null, 64),
            'android_sdk' => self::intIn($in['android_sdk'] ?? null, 1, 1000),
        ];
        $applied = self::intIn($in['config_version_applied'] ?? null, 0, PHP_INT_MAX);
        $this->updateStatus($device, (string) $bootId, $uptime, $status, $ip, self::str($in['app_version'] ?? null, 32), $applied);
        $cfg = $this->kiosks->currentConfig((int) $device['kiosk_id']);
        return ['status' => 200, 'body' => [
            'ok' => true,
            'server_time' => Clock::now(),
            'config' => [
                'version' => (int) $cfg['version'],
                'allowed_packages' => $cfg['allowed_packages'],
                'local_loss_timeout_s' => (int) $cfg['local_loss_timeout_s'],
                'seconds_per_pulse' => (int) $cfg['seconds_per_pulse'],
            ],
        ]];
    }

    private static function str(mixed $v, int $max): ?string
    {
        if (!is_string($v)) {
            return null;
        }
        $v = preg_replace('/[^\x20-\x7E]/', '', $v) ?? '';
        return $v === '' ? null : substr($v, 0, $max);
    }

    /** @return array{status:int, body:array<string,mixed>} */
    private static function error(string $code, string $message): array
    {
        return ['status' => 422, 'body' => ['ok' => false, 'error' => ['code' => $code, 'message' => $message]]];
    }
}
