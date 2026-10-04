<?php

declare(strict_types=1);

// Builds (flutter build web --release, no dart-defines) and packages the browser kiosk for Hostinger:
//   php web_backend/tools/package-web.php
// Output: dist/vendo-web-<timestamp>.zip
//   public_html/            ← Flutter build/web contents + api/kiosk-status.php + .htaccess.root-example
//   vendo_web/              ← private endpoint code, config template, migration (NO config.php)
// The zip contains no secrets and none of the existing api/ files, so extracting
// it cannot overwrite api/status.php, api/db.php, api/health.php or api/.htaccess.

$root = dirname(__DIR__, 2);
$web = "$root/build/web";

// Always package a fresh production build: same-origin API, no --dart-define,
// so a development API address can never be shipped by accident.
echo "Running: flutter build web --release\n";
passthru('cd ' . escapeshellarg($root) . ' && flutter build web --release', $code);
if ($code !== 0 || !is_file("$web/index.html") || !is_file("$web/main.dart.js")) {
    fwrite(STDERR, "flutter build web failed.\n");
    exit(1);
}
@mkdir("$root/dist", 0775, true);
$name = "$root/dist/vendo-web-" . gmdate('Ymd-His') . '.zip';
$zip = new ZipArchive();
if ($zip->open($name, ZipArchive::CREATE | ZipArchive::EXCL) !== true) {
    fwrite(STDERR, "Cannot create $name\n");
    exit(1);
}

$add = static function (string $dir, string $prefix, callable $skip) use ($zip): int {
    $n = 0;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        $rel = str_replace('\\', '/', substr($f->getPathname(), strlen($dir) + 1));
        if ($skip($rel)) {
            continue;
        }
        $zip->addFile($f->getPathname(), $prefix . $rel);
        $n++;
    }
    return $n;
};

$count = $add($web, 'public_html/', static fn (string $r) => str_starts_with($r, 'api/') || $r === 'seed.html');
$zip->addFile("$root/web_backend/public_html/api/kiosk-status.php", 'public_html/api/kiosk-status.php');
$zip->addFile("$root/web_backend/public_html/api/.htaccess.snippet", 'public_html/api/.htaccess.snippet');
$zip->addFile("$root/web_backend/public_html/.htaccess.root-example", 'public_html/.htaccess.root-example');
$count += 3;
$count += $add("$root/web_backend/vendo_web", 'vendo_web/', static fn (string $r) => $r === 'config.php' || str_ends_with($r, '.sqlite'));
$zip->close();
echo "Packaged $count files into $name\n";
