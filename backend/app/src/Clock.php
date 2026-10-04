<?php

declare(strict_types=1);

namespace Vendo;

/** Server clock (UTC). Tests can freeze it. */
final class Clock
{
    private static ?int $frozen = null;

    public static function now(): int
    {
        return self::$frozen ?? time();
    }

    public static function freeze(?int $ts): void
    {
        self::$frozen = $ts;
    }

    public static function sql(?int $ts = null): string
    {
        return gmdate('Y-m-d H:i:s', $ts ?? self::now());
    }

    public static function parse(?string $sql): ?int
    {
        if ($sql === null || $sql === '') {
            return null;
        }
        $dt = \DateTimeImmutable::createFromFormat('Y-m-d H:i:s', $sql, new \DateTimeZone('UTC'));
        return $dt === false ? null : $dt->getTimestamp();
    }
}
