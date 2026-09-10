<?php

// #ddev-generated

/**
 * Creates sites/<name>/composer.json for a served worktree.
 *
 * Runs inside the web container. Copies the root tryout overlay and repoints its
 * path repositories: Core comes from that worktree, packages/ stays shared so one
 * extension can be developed against several TYPO3 versions at once.
 *
 * Usage: site-composer.php <site-name>
 */

$name = $argv[1] ?? '';
if ($name === '' || !preg_match('/^[A-Za-z0-9._-]+$/', $name)) {
    fwrite(STDERR, "site-composer: invalid or missing site name\n");
    exit(64);
}

// The PHP version this site's vhost will serve. Composer must resolve against it,
// not against the container's default CLI PHP — otherwise dependencies are picked
// for the wrong version and vendor/composer/platform_check.php aborts every
// request and CLI call with "your dependencies require PHP >= x".
$sitePhp = $argv[2] ?? '';
if ($sitePhp !== '' && !preg_match('/^\d+\.\d+$/', $sitePhp)) {
    fwrite(STDERR, "site-composer: invalid PHP version '$sitePhp'\n");
    exit(64);
}

$root = getenv('DDEV_APPROOT') ?: '/var/www/html';

// The tryout overlay, not the project's own composer.json — see sync-composer.php.
$composerName = getenv('TRYOUT_COMPOSER_FILE') ?: 'composer.tryout.json';
$rootComposer = $root . '/' . $composerName;

if (!file_exists($rootComposer)) {
    fwrite(STDERR, "site-composer: $rootComposer not found\n");
    exit(1);
}

$data = json_decode(file_get_contents($rootComposer), true);
if ($data === null) {
    fwrite(STDERR, "site-composer: cannot parse $rootComposer\n");
    exit(1);
}

foreach (($data['repositories'] ?? []) as $i => $repo) {
    if (($repo['type'] ?? '') !== 'path') {
        continue;
    }
    $url = $repo['url'] ?? '';
    if (str_contains($url, 'typo3-core')) {
        $data['repositories'][$i]['url'] = '../../typo3-core-' . $name . '/typo3/sysext/*';
    } elseif (str_starts_with($url, 'packages')) {
        $data['repositories'][$i]['url'] = '../../packages/*';
    }
}

// The merge-plugin include is relative to this overlay, which now sits two levels
// down in sites/<name>/. Repoint it at the project root's composer.json so a served
// site still picks up the user's own dependencies.
if (isset($data['extra']['merge-plugin']['include'])) {
    $data['extra']['merge-plugin']['include'] = array_map(
        static fn (string $path): string => str_starts_with($path, '..') ? $path : '../../' . $path,
        $data['extra']['merge-plugin']['include']
    );
}

// A site's vendor/bin must exist for `ddev tryout exec <site>` to work.
$data['config']['vendor-dir'] = 'vendor';

// Pin the platform so resolution targets the PHP this site actually serves.
if ($sitePhp !== '') {
    $data['config']['platform']['php'] = $sitePhp;
}

$dir = $root . '/sites/' . $name;
if (!is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
    fwrite(STDERR, "site-composer: cannot create $dir\n");
    exit(1);
}

$json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
if ($json === false) {
    fwrite(STDERR, "site-composer: failed to encode: " . json_last_error_msg() . "\n");
    exit(1);
}

// A short write leaves a truncated overlay, and composer install then fails far
// from the cause.
if (file_put_contents($dir . '/' . $composerName, $json . "\n") === false) {
    fwrite(STDERR, "site-composer: cannot write $dir/$composerName\n");
    exit(1);
}

echo "sites/$name/$composerName written\n";
