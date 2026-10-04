<?php

declare(strict_types=1);

namespace Vendo;

use PDO;
use PDOException;

/** Thin PDO wrapper. Every query uses bound parameters. */
final class Db
{
    public function __construct(public readonly PDO $pdo, public readonly string $driver)
    {
    }

    public static function fromConfig(Config $config): self
    {
        $options = [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ];
        $driver = $config->get('DB_DRIVER', 'mysql');
        if ($driver === 'sqlite') {
            // Local development and tests only.
            $pdo = new PDO('sqlite:' . $config->get('DB_PATH', ':memory:'), null, null, $options);
            $pdo->exec('PRAGMA foreign_keys = ON');
            return new self($pdo, 'sqlite');
        }
        $dsn = sprintf(
            'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
            $config->get('DB_HOST', 'localhost'),
            $config->int('DB_PORT', 3306),
            $config->get('DB_NAME', '')
        );
        $pdo = new PDO($dsn, $config->get('DB_USER', ''), $config->get('DB_PASS', ''), $options);
        $pdo->exec("SET time_zone = '+00:00'");
        return new self($pdo, 'mysql');
    }

    /** @return array<string,mixed>|null */
    public function one(string $sql, array $params = []): ?array
    {
        $st = $this->pdo->prepare($sql);
        $st->execute($params);
        $row = $st->fetch();
        return $row === false ? null : $row;
    }

    /** @return list<array<string,mixed>> */
    public function all(string $sql, array $params = []): array
    {
        $st = $this->pdo->prepare($sql);
        $st->execute($params);
        return $st->fetchAll();
    }

    /** Executes a statement and returns the number of affected rows. */
    public function exec(string $sql, array $params = []): int
    {
        $st = $this->pdo->prepare($sql);
        $st->execute($params);
        return $st->rowCount();
    }

    public function insert(string $sql, array $params = []): int
    {
        $this->exec($sql, $params);
        return (int) $this->pdo->lastInsertId();
    }

    /**
     * @template T
     * @param callable():T $fn
     * @return T
     */
    public function tx(callable $fn): mixed
    {
        $this->pdo->beginTransaction();
        try {
            $result = $fn();
            $this->pdo->commit();
            return $result;
        } catch (\Throwable $e) {
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            throw $e;
        }
    }

    public static function isUniqueViolation(PDOException $e): bool
    {
        return $e->getCode() === '23000' || (isset($e->errorInfo[1]) && in_array((int) $e->errorInfo[1], [1062, 19, 2067], true));
    }
}
