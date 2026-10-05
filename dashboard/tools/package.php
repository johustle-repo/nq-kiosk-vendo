<?php

/*
 * Builds the Hostinger upload: dist/vendo-dashboard-<version>-<timestamp>.zip
 *
 *   php tools/package.php            (run `npm run build` first)
 *
 * Layout inside the zip:
 *   public_html/       → the subdomain's document root (index.php, .htaccess, build/, images/)
 *   vendo_dashboard/   → the Laravel app, OUTSIDE the web root (code, vendor, storage)
 *
 * The zip contains no secrets: no .env, no database, no logs, no sessions.
 * Production dependencies only (composer install --no-dev).
 */

$root = dirname(__DIR__);
$repo = dirname($root);
chdir($root);

if (! is_file($root.'/public/build/manifest.json')) {
    fwrite(STDERR, "Run `npm run build` first (public/build/manifest.json is missing).\n");
    exit(1);
}

preg_match("/'backend_version' => '([^']+)'/", (string) file_get_contents($root.'/config/vendo.php'), $m);
$version = $m[1] ?? 'dev';
$stamp = gmdate('Ymd-His');
$stage = sys_get_temp_dir().DIRECTORY_SEPARATOR.'vendo-dashboard-'.$stamp;
$app = $stage.'/vendo_dashboard';

// Everything except development-only and secret files.
$skip = [
    '#^\.env($|\.(?!example$))#', '#^node_modules(/|$)#', '#^vendor(/|$)#', '#^tests(/|$)#', '#^tools(/|$)#',
    '#^\.git#', '#^\.phpunit#', '#^storage/(logs|framework/(sessions|cache/data|views|testing))/.+#',
    '#^database/.*\.sqlite#', '#^public/hot$#', '#^CLAUDE\.md$#', '#^\.idea|^\.vscode#',
];
$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST);
foreach ($it as $file) {
    $rel = str_replace('\\', '/', substr($file->getPathname(), strlen($root) + 1));
    foreach ($skip as $re) {
        if (preg_match($re, $rel)) {
            continue 2;
        }
    }
    $dest = $app.'/'.$rel;
    if ($file->isDir()) {
        @mkdir($dest, 0775, true);
    } else {
        @mkdir(dirname($dest), 0775, true);
        copy($file->getPathname(), $dest);
    }
}
// Empty runtime folders Laravel expects.
foreach (['storage/logs', 'storage/framework/sessions', 'storage/framework/views', 'storage/framework/cache/data', 'bootstrap/cache'] as $d) {
    @mkdir($app.'/'.$d, 0775, true);
}

echo "Installing production dependencies…\n";
passthru('composer install --no-dev --classmap-authoritative --no-interaction --quiet --working-dir='.escapeshellarg($app), $code);
if ($code !== 0) {
    fwrite(STDERR, "composer install failed\n");
    exit(1);
}

// Move the web root out of the app and point its index.php back at the app.
rename($app.'/public', $stage.'/public_html');
file_put_contents($stage.'/public_html/index.php', <<<'PHP'
<?php

use Illuminate\Http\Request;

define('LARAVEL_START', microtime(true));

// The application lives next to the web root, never inside it.
$base = __DIR__.'/../vendo_dashboard';

if (file_exists($maintenance = $base.'/storage/framework/maintenance.php')) {
    require $maintenance;
}

require $base.'/vendor/autoload.php';

/** @var Illuminate\Foundation\Application $app */
$app = require_once $base.'/bootstrap/app.php';
$app->usePublicPath(__DIR__);
$app->handleRequest(Request::capture());
PHP);

@mkdir($repo.'/dist', 0775, true);
$zipPath = $repo.'/dist/vendo-dashboard-'.$version.'-'.$stamp.'.zip';
$zip = new ZipArchive;
$zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE);
$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($stage, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST);
$count = 0;
foreach ($files as $file) {
    $rel = str_replace('\\', '/', substr($file->getPathname(), strlen($stage) + 1));
    if ($file->isDir()) {
        $zip->addEmptyDir($rel);
    } else {
        $zip->addFile($file->getPathname(), $rel);
        $count++;
    }
}
$zip->close();

// Clean up the staging copy.
$rm = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($stage, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
foreach ($rm as $f) {
    $f->isDir() ? @rmdir($f->getPathname()) : @unlink($f->getPathname());
}
@rmdir($stage);

printf("Packaged %d files into %s (%.1f MB)\n", $count, $zipPath, filesize($zipPath) / 1048576);
