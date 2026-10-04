<?php

declare(strict_types=1);

namespace Vendo\Web;

use Vendo\Clock;

final class View
{
    public static function render(string $template, array $vars): string
    {
        $file = VENDO_APP_DIR . '/views/' . $template . '.php';
        $content = self::capture($file, $vars);
        return self::capture(VENDO_APP_DIR . '/views/layout.php', $vars + ['content' => $content]);
    }

    private static function capture(string $file, array $vars): string
    {
        extract($vars, EXTR_SKIP);
        ob_start();
        require $file;
        return (string) ob_get_clean();
    }
}

/** HTML-escape. */
function h(mixed $v): string
{
    return htmlspecialchars((string) ($v ?? ''), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function hms(int $seconds): string
{
    $seconds = max(0, $seconds);
    return sprintf('%02d:%02d:%02d', intdiv($seconds, 3600), intdiv($seconds % 3600, 60), $seconds % 60);
}

/** "12 s ago" style age for a UTC SQL timestamp. */
function ago(?string $sql): string
{
    $ts = Clock::parse($sql);
    if ($ts === null) {
        return 'never';
    }
    $d = max(0, Clock::now() - $ts);
    return match (true) {
        $d < 60 => $d . ' s ago',
        $d < 3600 => intdiv($d, 60) . ' min ago',
        $d < 86400 => intdiv($d, 3600) . ' h ago',
        default => intdiv($d, 86400) . ' d ago',
    };
}

/** <time> element; app.js converts it to the viewer's local time. */
function ts(?string $sql): string
{
    $t = Clock::parse($sql);
    if ($t === null) {
        return '<span class="muted">—</span>';
    }
    return '<time datetime="' . gmdate('c', $t) . '">' . h($sql) . ' UTC</time>';
}

function csrf_field(string $token): string
{
    return '<input type="hidden" name="_csrf" value="' . h($token) . '">';
}
