<?php

use App\Http\ApiError;
use App\Http\Middleware\AuthenticateDevice;
use App\Http\Middleware\SecurityHeaders;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Exceptions\ThrottleRequestsException;
use Illuminate\Http\Request;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Symfony\Component\HttpKernel\Exception\MethodNotAllowedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        apiPrefix: 'api/v1',
        commands: __DIR__.'/../routes/console.php',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        $middleware->alias(['device' => AuthenticateDevice::class]);
        $middleware->append(SecurityHeaders::class);
        $middleware->redirectGuestsTo('/login');
        // Hostinger sits behind a proxy/CDN that terminates TLS.
        $middleware->trustProxies(at: '*');
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        // The device API always answers in its own error format.
        $exceptions->render(function (Throwable $e, Request $request) {
            if (! $request->is('api/*')) {
                return null;
            }
            if ($e instanceof ThrottleRequestsException) {
                return ApiError::response('rate_limited', 'Too many requests. Try again later.', 429);
            }
            if ($e instanceof NotFoundHttpException || $e instanceof MethodNotAllowedHttpException) {
                return ApiError::response('not_found', 'Unknown endpoint.', 404);
            }
            if ($e instanceof HttpExceptionInterface) {
                return ApiError::response('http_error', 'Request rejected.', $e->getStatusCode());
            }
            report($e);

            return ApiError::response('server_error', 'Internal server error.', 500);
        });
    })->create();
