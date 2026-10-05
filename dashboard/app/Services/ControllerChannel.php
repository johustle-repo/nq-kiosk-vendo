<?php

namespace App\Services;

use App\Models\AuditLog;
use App\Models\ControllerCommand;
use App\Models\Device;
use App\Models\Site;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use InvalidArgumentException;

/**
 * Dashboard ⇄ coin box channel.
 *
 * The coin box polls /controller/poll every ~2 s. Each poll reports what the box
 * is doing (selected tablet, held coins) and acknowledges commands it applied;
 * the response carries the attendant's current selection and any commands not
 * yet acknowledged. Commands are re-sent until acknowledged, so the box applies
 * them idempotently by id.
 */
class ControllerChannel
{
    public const MAX_COMMANDS_PER_POLL = 8;

    // ------------------------------------------------------------ device side

    /** @return array{status: int, body: array<string, mixed>} */
    public function poll(Device $device, ?array $in, string $ip): array
    {
        if ($in === null) {
            return IngestService::error('invalid_json', 'Body must be a JSON object.');
        }
        $bootId = $in['boot_id'] ?? null;
        if (! IngestService::isBootId($bootId)) {
            return IngestService::error('invalid_fields', 'boot_id is required.');
        }
        $selected = IngestService::intIn($in['selected'] ?? 0, 0, Site::MAX_STATIONS) ?? 0;
        $ttl = IngestService::intIn($in['selected_ttl_s'] ?? 0, 0, 3600) ?? 0;
        $held = IngestService::intIn($in['held_pulses'] ?? 0, 0, 100000) ?? 0;
        $acks = is_array($in['acks'] ?? null) ? array_slice($in['acks'], 0, 32) : [];

        $site = $device->site;
        $now = now();
        $commands = DB::transaction(function () use ($site, $device, $acks, $selected, $ttl, $held, $ip, $now) {
            foreach ($acks as $ack) {
                $id = is_array($ack) ? IngestService::intIn($ack['id'] ?? null, 1, PHP_INT_MAX) : null;
                if ($id === null) {
                    continue;
                }
                $result = IngestService::str($ack['result'] ?? 'ok', 32) ?? 'ok';
                ControllerCommand::where('site_id', $site->id)->whereKey($id)->whereNull('applied_at')
                    ->update(['applied_at' => $now, 'result' => $result]);
            }
            $site->update([
                'reported_station' => $selected ?: null,
                'reported_ttl_s' => $selected ? $ttl : null,
                'held_pulses' => $held,
                'last_poll_at' => $now,
            ]);
            $device->update(['last_seen_at' => $now, 'last_ip' => $ip]);

            $pending = ControllerCommand::where('site_id', $site->id)->whereNull('applied_at')
                ->orderBy('id')->limit(self::MAX_COMMANDS_PER_POLL)->get();
            ControllerCommand::whereIn('id', $pending->pluck('id'))->whereNull('delivered_at')->update(['delivered_at' => $now]);

            return $pending;
        });

        $active = $site->activeSelection();

        return ['status' => 200, 'body' => [
            'ok' => true,
            'server_time' => $now->timestamp,
            // Apply only when version is newer than the one the box last applied.
            'selection' => [
                'version' => (int) $site->selection_version,
                'station' => $active ?? 0,
                'ttl_s' => $active ? max(1, (int) now()->diffInSeconds($site->selection_expires_at)) : 0,
            ],
            'commands' => $commands->map(fn (ControllerCommand $c) => [
                'id' => $c->id, 'type' => $c->type, 'station' => (int) $c->station_no, 'seconds' => (int) ($c->seconds ?? 0),
            ])->values()->all(),
        ]];
    }

    // ------------------------------------------------------------ dashboard side

    /** "Next coins go to tablet N" (null clears the selection). */
    public function select(Site $site, ?int $station, User $by, ?string $ip = null): void
    {
        if ($station !== null) {
            self::assertStation($station);
        }
        DB::transaction(function () use ($site, $station) {
            $site->refresh();
            $site->update([
                'selected_station' => $station,
                'selection_expires_at' => $station === null ? null : now()->addSeconds((int) config('vendo.selection_ttl_seconds')),
                'selection_version' => $site->selection_version + 1,
            ]);
        });
        AuditLog::record('site.select_station', $by->id, $site->id, null, ['station' => $station], $ip);
    }

    public function addTime(Site $site, int $station, int $seconds, User $by, ?string $ip = null): ControllerCommand
    {
        self::assertStation($station);
        $max = (int) config('vendo.max_admin_credit_seconds');
        if ($seconds < 60 || $seconds > $max) {
            throw new InvalidArgumentException("Time must be between 1 minute and {$max} seconds.");
        }

        return $this->queue($site, 'add_time', $station, $seconds, $by, $ip);
    }

    public function endSession(Site $site, int $station, User $by, ?string $ip = null): ControllerCommand
    {
        self::assertStation($station);

        return $this->queue($site, 'end_session', $station, null, $by, $ip);
    }

    /** Gives the coins inserted while no tablet was selected to tablet N. */
    public function assignHeld(Site $site, int $station, User $by, ?string $ip = null): ControllerCommand
    {
        self::assertStation($station);

        return $this->queue($site, 'assign_held', $station, null, $by, $ip);
    }

    private function queue(Site $site, string $type, int $station, ?int $seconds, User $by, ?string $ip): ControllerCommand
    {
        $cmd = ControllerCommand::create([
            'site_id' => $site->id, 'type' => $type, 'station_no' => $station, 'seconds' => $seconds,
            'created_by' => $by->id, 'created_at' => now(),
        ]);
        AuditLog::record('site.command.'.$type, $by->id, $site->id, null,
            ['command_id' => $cmd->id, 'station' => $station, 'seconds' => $seconds], $ip);

        return $cmd;
    }

    private static function assertStation(int $station): void
    {
        if ($station < 1 || $station > Site::MAX_STATIONS) {
            throw new InvalidArgumentException('Tablet number must be 1 to '.Site::MAX_STATIONS.'.');
        }
    }
}
