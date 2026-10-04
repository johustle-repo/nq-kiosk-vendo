<?php

declare(strict_types=1);

// Builds the Hostinger upload package:  php backend/tools/package.php
// Output: dist/vendo-backend-<version>-<timestamp>.zip containing
//   public_html/   -> the subdomain document root
//   vendo_app/     -> private application folder (sibling of public_html)
// The package never contains a .env file or any secret.

require __DIR__ . '/../app/bootstrap.php';

$root = realpath(__DIR__ . '/..');
$dist = dirname($root) . '/dist';
if (!is_dir($dist) && !mkdir($dist, 0775, true)) {
    fwrite(STDERR, "Cannot create $dist\n");
    exit(1);
}
$name = sprintf('%s/vendo-backend-%s-%s.zip', $dist, VENDO_BACKEND_VERSION, gmdate('Ymd-His'));
$zip = new ZipArchive();
if ($zip->open($name, ZipArchive::CREATE | ZipArchive::EXCL) !== true) {
    fwrite(STDERR, "Cannot create $name\n");
    exit(1);
}

$map = ['public' => 'public_html', 'app' => 'vendo_app'];
$excluded = static function (string $rel): bool {
    $base = basename($rel);
    return $base === '.env' || str_ends_with($base, '.sqlite') || str_ends_with($base, '.log');
};
$count = 0;
foreach ($map as $src => $dest) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator("$root/$src", FilesystemIterator::SKIP_DOTS));
    foreach ($it as $file) {
        $rel = str_replace('\\', '/', substr($file->getPathname(), strlen("$root/$src") + 1));
        if ($excluded($rel)) {
            continue; // never ship secrets or local data
        }
        $zip->addFile($file->getPathname(), "$dest/$rel");
        $count++;
    }
}
$zip->close();
echo "Packaged $count files into $name\n";
