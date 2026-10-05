<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Vite;
use Illuminate\Support\Str;
use Symfony\Component\HttpFoundation\Response;

/**
 * Security headers for every response. Scripts must come from this site or
 * carry the per-request nonce (Vite and Livewire use it); responses are
 * per-user/per-device, so the Hostinger CDN must never cache them.
 */
class SecurityHeaders
{
    public function handle(Request $request, Closure $next): Response
    {
        $nonce = Str::random(32);
        Vite::useCspNonce($nonce);
        $request->attributes->set('csp_nonce', $nonce);

        $script = "'self' 'nonce-{$nonce}'";
        $connect = "'self'";
        if (app()->environment('local')) {
            // Vite dev server during `npm run dev`.
            $script .= ' http://localhost:5173';
            $connect .= ' ws://localhost:5173 http://localhost:5173';
        }
        $policy = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
            ."script-src {$script}; connect-src {$connect}; form-action 'self'; base-uri 'none'";
        // Also emitted as a <meta> tag by the layouts: Hostinger's server replaces
        // this header with its own "upgrade-insecure-requests", and browsers
        // enforce a meta policy in addition to any header.
        $request->attributes->set('csp_policy', $policy);

        $response = $next($request);

        $headers = [
            'Cache-Control' => 'no-store, max-age=0',
            'X-Content-Type-Options' => 'nosniff',
            'Referrer-Policy' => 'same-origin',
            'X-Frame-Options' => 'DENY',
            'Content-Security-Policy' => $policy."; frame-ancestors 'none'",
        ];
        if ($request->isSecure()) {
            $headers['Strict-Transport-Security'] = 'max-age=31536000';
        }
        foreach ($headers as $k => $v) {
            $response->headers->set($k, $v);
        }

        return $response;
    }
}
