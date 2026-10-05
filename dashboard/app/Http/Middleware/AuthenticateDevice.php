<?php

namespace App\Http\Middleware;

use App\Http\ApiError;
use App\Models\Device;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Device bearer token: vkd_<public_id>_<secret>. Only SHA-256(secret) is
 * stored. The token must belong to a non-revoked device of the expected type,
 * so a coin box credential can never act as a tablet or vice versa.
 *
 * Usage: ->middleware('device:controller') or ->middleware('device:phone').
 */
class AuthenticateDevice
{
    public function handle(Request $request, Closure $next, string $type): Response
    {
        $token = $request->bearerToken();
        $device = null;
        if ($token !== null && preg_match('/^vkd_([0-9a-f]{16})_([A-Za-z0-9_-]{43})$/', $token, $m)) {
            $candidate = Device::where('public_id', $m[1])->first();
            if ($candidate !== null
                && $candidate->revoked_at === null
                && hash_equals((string) $candidate->token_hash, hash('sha256', $m[2]))
                && $candidate->device_type === $type) {
                $device = $candidate;
            }
        }
        if ($device === null) {
            return ApiError::response('unauthorized', 'Missing, invalid, revoked or wrong-type device token.', 401);
        }
        $request->attributes->set('device', $device);

        return $next($request);
    }
}
