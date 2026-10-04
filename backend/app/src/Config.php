<?php

declare(strict_types=1);

namespace Vendo;

/** Reads KEY=VALUE pairs from the private .env file (never from the web root). */
final class Config
{
    /** @param array<string,string> $values */
    public function __construct(private array $values)
    {
    }

    public static function load(string $envFile): self
    {
        if (!is_file($envFile) || !is_readable($envFile)) {
            throw new \RuntimeException('Configuration file not found. Copy .env.example to .env outside the web root.');
        }
        $values = [];
        foreach (file($envFile, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            $line = trim($line);
            if ($line === '' || $line[0] === '#') {
                continue;
            }
            $eq = strpos($line, '=');
            if ($eq === false) {
                continue;
            }
            $key = trim(substr($line, 0, $eq));
            $val = trim(substr($line, $eq + 1));
            if (strlen($val) >= 2 && ($val[0] === '"' || $val[0] === "'") && $val[strlen($val) - 1] === $val[0]) {
                $val = substr($val, 1, -1);
            }
            $values[$key] = $val;
        }
        return new self($values);
    }

    public function get(string $key, ?string $default = null): ?string
    {
        $v = $this->values[$key] ?? null;
        return ($v === null || $v === '') ? $default : $v;
    }

    public function int(string $key, int $default): int
    {
        $v = $this->get($key);
        return ($v !== null && preg_match('/^-?\d+$/', $v)) ? (int) $v : $default;
    }

    public function bool(string $key, bool $default): bool
    {
        $v = $this->get($key);
        if ($v === null) {
            return $default;
        }
        return in_array(strtolower($v), ['1', 'true', 'yes', 'on'], true);
    }
}
