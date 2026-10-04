<?php

declare(strict_types=1);

namespace Vendo\Auth;

use Vendo\Request;

/** Synchronizer-token CSRF protection for cookie-authenticated form posts. */
final class Csrf
{
    public static function token(Request $req): string
    {
        $t = $req->session->get('csrf');
        if (!is_string($t) || strlen($t) !== 64) {
            $t = bin2hex(random_bytes(32));
            $req->session->set('csrf', $t);
        }
        return $t;
    }

    public static function valid(Request $req): bool
    {
        $expected = $req->session->get('csrf');
        $given = $req->post['_csrf'] ?? '';
        return is_string($expected) && is_string($given) && $expected !== '' && hash_equals($expected, $given);
    }
}
