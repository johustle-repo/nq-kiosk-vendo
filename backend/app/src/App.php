<?php

declare(strict_types=1);

namespace Vendo;

use Vendo\Api\ApiController;
use Vendo\Auth\AdminAuth;
use Vendo\Auth\DeviceAuth;
use Vendo\Auth\RateLimiter;
use Vendo\Service\Audit;
use Vendo\Service\IngestService;
use Vendo\Service\KioskService;
use Vendo\Service\Migrator;
use Vendo\Web\WebController;

/** Front controller: routes /api/v1/* to the device API and everything else to the dashboard. */
final class App
{
    public readonly RateLimiter $limiter;
    public readonly AdminAuth $adminAuth;
    public readonly DeviceAuth $deviceAuth;
    public readonly KioskService $kiosks;
    public readonly IngestService $ingest;
    public readonly Audit $audit;
    public readonly Migrator $migrator;

    public function __construct(public readonly Config $config, public readonly Db $db)
    {
        $this->limiter = new RateLimiter($db);
        $this->adminAuth = new AdminAuth($db, $this->limiter);
        $this->deviceAuth = new DeviceAuth($db);
        $this->kiosks = new KioskService($db);
        $this->ingest = new IngestService($db, $this->kiosks);
        $this->audit = new Audit($db);
        $this->migrator = new Migrator($db, VENDO_APP_DIR . '/migrations');
    }

    public function handle(Request $req): Response
    {
        try {
            if ($req->path === '/api/v1' || str_starts_with($req->path, '/api/')) {
                return (new ApiController($this))->handle($req);
            }
            return (new WebController($this))->handle($req);
        } catch (\Throwable $e) {
            error_log('[vendo] ' . get_class($e) . ': ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine());
            if (str_starts_with($req->path, '/api/')) {
                return Response::apiError('server_error', 'Internal server error.', 500);
            }
            return Response::html('<h1>Server error</h1><p>The error was logged.</p>', 500);
        }
    }

    public function staleAfter(string $deviceType): int
    {
        return $deviceType === DeviceAuth::TYPE_PHONE
            ? $this->config->int('PHONE_STALE_SECONDS', 120)
            : $this->config->int('CONTROLLER_STALE_SECONDS', 90);
    }
}
