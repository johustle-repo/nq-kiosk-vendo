<?php

declare(strict_types=1);

namespace Vendo\Service;

use Vendo\Clock;
use Vendo\Db;

/** Applies migrations/NNN_name.sql files in order, once each. */
final class Migrator
{
    public function __construct(private readonly Db $db, private readonly string $dir)
    {
    }

    /** @return list<string> */
    public function available(): array
    {
        $files = glob($this->dir . '/*.sql') ?: [];
        sort($files, SORT_STRING);
        return array_map(static fn ($f) => basename($f, '.sql'), $files);
    }

    /** @return list<string> */
    public function applied(): array
    {
        $this->ensureTable();
        return array_column($this->db->all('SELECT version FROM schema_migrations ORDER BY version'), 'version');
    }

    /** @return list<string> */
    public function pending(): array
    {
        return array_values(array_diff($this->available(), $this->applied()));
    }

    /** @return list<string> the versions applied by this call */
    public function migrate(): array
    {
        $done = [];
        foreach ($this->pending() as $version) {
            $sql = (string) file_get_contents($this->dir . '/' . $version . '.sql');
            if ($this->db->driver === 'sqlite') {
                $sql = self::toSqlite($sql);
            }
            // MySQL DDL auto-commits, so each statement is applied individually.
            foreach (self::statements($sql) as $stmt) {
                $this->db->pdo->exec($stmt);
            }
            $this->db->exec('INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)', [$version, Clock::sql()]);
            $done[] = $version;
        }
        return $done;
    }

    private function ensureTable(): void
    {
        $this->db->pdo->exec('CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(64) NOT NULL PRIMARY KEY, applied_at DATETIME NOT NULL)');
    }

    /** @return list<string> */
    public static function statements(string $sql): array
    {
        $sql = preg_replace('/^\s*--.*$/m', '', $sql) ?? '';
        return array_values(array_filter(array_map('trim', explode(';', $sql)), static fn ($s) => $s !== ''));
    }

    /** Converts the portable MySQL subset used in migrations to SQLite (dev/tests only). */
    public static function toSqlite(string $sql): string
    {
        $sql = str_replace('BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY', 'INTEGER PRIMARY KEY AUTOINCREMENT', $sql);
        $sql = preg_replace('/\)\s*ENGINE=[^;]*;/', ');', $sql) ?? $sql;
        return str_replace(' UNSIGNED', '', $sql);
    }
}
