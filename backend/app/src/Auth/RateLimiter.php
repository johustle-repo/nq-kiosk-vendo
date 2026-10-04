<?php

declare(strict_types=1);

namespace Vendo\Auth;

use Vendo\Clock;
use Vendo\Db;

/** Fixed-window rate limiter stored in the database (works on shared hosting). */
final class RateLimiter
{
    public function __construct(private readonly Db $db)
    {
    }

    /** Records a hit and returns false when the bucket is over its limit. */
    public function hit(string $bucket, int $limit, int $windowSeconds): bool
    {
        $now = Clock::now();
        $bucket = substr($bucket, 0, 160);
        return $this->db->tx(function () use ($bucket, $limit, $windowSeconds, $now): bool {
            $row = $this->db->one('SELECT window_start, hits FROM rate_limits WHERE bucket = ?', [$bucket]);
            if ($row === null) {
                try {
                    $this->db->exec('INSERT INTO rate_limits (bucket, window_start, hits) VALUES (?, ?, 1)', [$bucket, $now]);
                } catch (\PDOException $e) {
                    if (!Db::isUniqueViolation($e)) {
                        throw $e;
                    }
                    $this->db->exec('UPDATE rate_limits SET hits = hits + 1 WHERE bucket = ?', [$bucket]);
                }
                return 1 <= $limit;
            }
            if ((int) $row['window_start'] + $windowSeconds <= $now) {
                $this->db->exec('UPDATE rate_limits SET window_start = ?, hits = 1 WHERE bucket = ?', [$now, $bucket]);
                return 1 <= $limit;
            }
            $hits = (int) $row['hits'] + 1;
            $this->db->exec('UPDATE rate_limits SET hits = ? WHERE bucket = ?', [$hits, $bucket]);
            return $hits <= $limit;
        });
    }

    public function isBlocked(string $bucket, int $limit, int $windowSeconds): bool
    {
        $row = $this->db->one('SELECT window_start, hits FROM rate_limits WHERE bucket = ?', [substr($bucket, 0, 160)]);
        return $row !== null
            && (int) $row['window_start'] + $windowSeconds > Clock::now()
            && (int) $row['hits'] >= $limit;
    }

    public function clear(string $bucket): void
    {
        $this->db->exec('DELETE FROM rate_limits WHERE bucket = ?', [substr($bucket, 0, 160)]);
    }

    public function prune(int $olderThanSeconds = 86400): int
    {
        return $this->db->exec('DELETE FROM rate_limits WHERE window_start < ?', [Clock::now() - $olderThanSeconds]);
    }
}
