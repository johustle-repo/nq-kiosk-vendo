<?php

namespace App\Http;

use Illuminate\Http\JsonResponse;

/** Error body the devices understand: {"ok":false,"error":{"code","message"}}. */
final class ApiError
{
    public static function response(string $code, string $message, int $status): JsonResponse
    {
        return response()->json(['ok' => false, 'error' => ['code' => $code, 'message' => $message]], $status);
    }
}
