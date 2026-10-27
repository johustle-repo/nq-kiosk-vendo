<?php

namespace App\Services;

use App\Models\AuditLog;
use App\Models\ControllerCommand;
use App\Models\Device;
use App\Models\Site;
use App\Models\User;
use Illuminate\Database\Eloquent\Builder;
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
 *
 * Each command is queued for the coin box that serves its tablet: the tablet's
 * own kiosk coin box (which knows it as station 1), else the shared one. Kiosk
 * coin boxes have a single tablet, so they get no selection.
 *
 * "Add time" goes to the tablet itself when its app supports it: the tablet
 * keeps that free time and uses it after any paid coin time, so it works with
 * no coin box paired. The tablet collects its commands on its heartbeat
 * (~30 s) and acknowledges them the same way.
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
                self::commandsFor($device)->whereKey($id)->whereNull('applied_at')
                    ->update(['applied_at' => $now, 'result' => $result]);
            }
            if ($device->isKioskCoinBox()) {
                $device->update(['held_pulses' => $held, 'last_poll_at' => $now, 'last_seen_at' => $now, 'last_ip' => $ip]);
            } else {
                $site->update([
                    'reported_station' => $selected ?: null,
                    'reported_ttl_s' => $selected ? $ttl : null,
                    'held_pulses' => $held,
                    'last_poll_at' => $now,
                ]);
                $device->update(['last_poll_at' => $now, 'last_seen_at' => $now, 'last_ip' => $ip]);
            }

            $pending = self::commandsFor($device)->whereNull('applied_at')
                ->orderBy('id')->limit(self::MAX_COMMANDS_PER_POLL)->get();
            ControllerCommand::whereIn('id', $pending->pluck('id'))->whereNull('delivered_at')->update(['delivered_at' => $now]);

            return $pending;
        });

        $active = $device->isKioskCoinBox() ? null : $site->activeSelection();

        return ['status' => 200, 'body' => [
            'ok' => true,
            'server_time' => $now->timestamp,
            // Apply only when version is newer than the one the box last applied.
            'selection' => [
                'version' => $device->isKioskCoinBox() ? 0 : (int) $site->selection_version,
                'station' => $active ?? 0,
                'ttl_s' => $active ? max(1, (int) now()->diffInSeconds($site->selection_expires_at)) : 0,
            ],
            'commands' => $commands->map(fn (ControllerCommand $c) => [
                'id' => $c->id, 'type' => $c->type, 'station' => $device->localStation((int) $c->station_no), 'seconds' => (int) ($c->seconds ?? 0),
            ])->values()->all(),
        ]];
    }

    /**
     * Tablet side: applies the acknowledgements in a heartbeat and returns the
     * commands for this tablet not yet acknowledged.
     *
     * @return list<array{id: int, type: string, seconds: int}>
     */
    public function tabletCommands(Device $phone, mixed $acks): array
    {
        $now = now();

        return DB::transaction(function () use ($phone, $acks, $now) {
            foreach (is_array($acks) ? array_slice($acks, 0, 32) : [] as $ack) {
                $id = is_array($ack) ? IngestService::intIn($ack['id'] ?? null, 1, PHP_INT_MAX) : null;
                if ($id !== null) {
                    ControllerCommand::where('device_id', $phone->id)->whereKey($id)->whereNull('applied_at')
                        ->update(['applied_at' => $now, 'result' => IngestService::str($ack['result'] ?? 'ok', 32) ?? 'ok']);
                }
            }
            $pending = ControllerCommand::where('device_id', $phone->id)->whereNull('applied_at')
                ->orderBy('id')->limit(self::MAX_COMMANDS_PER_POLL)->get();
            ControllerCommand::whereIn('id', $pending->pluck('id'))->whereNull('delivered_at')->update(['delivered_at' => $now]);

            return $pending->map(fn (ControllerCommand $c) => [
                'id' => $c->id, 'type' => $c->type, 'seconds' => (int) ($c->seconds ?? 0),
            ])->values()->all();
        });
    }

    /** Commands this coin box carries out (the shared box also takes ones queued before kiosk coin boxes). */
    private static function commandsFor(Device $device): Builder
    {
        $q = ControllerCommand::where('site_id', $device->site_id);

        return $device->isKioskCoinBox()
            ? $q->where('device_id', $device->id)
            : $q->where(fn (Builder $w) => $w->where('device_id', $device->id)->orWhereNull('device_id'));
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

        $phone = $site->phoneForStation($station);

        return $this->queue($site, 'add_time', $station, $seconds, $by, $ip,
            $phone?->takesDashboardTime() ? $phone : $site->controllerForStation($station));
    }

    /** Ends the paid time on the coin box and the free time on the tablet. */
    public function endSession(Site $site, int $station, User $by, ?string $ip = null): ControllerCommand
    {
        self::assertStation($station);
        $phone = $site->phoneForStation($station);
        $box = $site->controllerForStation($station);
        if ($phone?->takesDashboardTime()) {
            $cmd = $this->queue($site, 'end_session', $station, null, $by, $ip, $phone);
            if ($box === null) {
                return $cmd;
            }
        }

        return $this->queue($site, 'end_session', $station, null, $by, $ip, $box);
    }

    /** Gives the coins inserted while no tablet was selected to tablet N. */
    public function assignHeld(Site $site, int $station, User $by, ?string $ip = null): ControllerCommand
    {
        self::assertStation($station);

        return $this->queue($site, 'assign_held', $station, null, $by, $ip, $site->controllerForStation($station));
    }

    /** @param  Device|null  $to  coin box or tablet that carries it out */
    private function queue(Site $site, string $type, int $station, ?int $seconds, User $by, ?string $ip, ?Device $to): ControllerCommand
    {
        $cmd = ControllerCommand::create([
            'site_id' => $site->id, 'device_id' => $to?->id, 'type' => $type, 'station_no' => $station, 'seconds' => $seconds,
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
