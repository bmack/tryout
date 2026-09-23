<?php

/**
 * Regenerates composer.json to match the system extensions available
 * in typo3-core/typo3/sysext/. Run after switching Core branches.
 *
 * - Scans typo3-core/typo3/sysext/<*>/composer.json for package names
 * - Rewrites the "require" section with those packages at "@dev"
 * - Preserves non-typo3/cms-* requires (custom packages)
 * - Preserves all other composer.json fields
 *
 * With --release=14.3 the Core clone is not used: the path repository for
 * typo3-core/ is removed and all typo3/cms-* / typo3/theme-* requirements
 * become "^14.3" (Packagist). Running without it restores the dev-main setup.
 */

$projectRoot = getenv('PROJECT_ROOT') ?: '/var/www/html';
$composerFile = $projectRoot . '/composer.json';
$composerLockFile = $projectRoot . '/composer.lock';
$sysextDir = $projectRoot . '/typo3-core/typo3/sysext';

$release = null;
foreach ($argv as $arg) {
    if (str_starts_with($arg, '--release=')) {
        $release = substr($arg, strlen('--release='));
    }
}

if ($release !== null) {
    if (!preg_match('/^\d+(\.\d+){0,2}$/', $release)) {
        fwrite(STDERR, "Error: invalid version '$release' (expected e.g. 14, 14.3 or 14.3.1)\n");
        exit(1);
    }
    $composerData = json_decode(file_get_contents($composerFile), true);
    if ($composerData === null) {
        fwrite(STDERR, "Error: Failed to parse $composerFile\n");
        exit(1);
    }
    $before = json_encode($composerData);
    $major = (int)explode('.', $release)[0];
    $composerData['repositories'] = array_values(array_filter(
        $composerData['repositories'] ?? [],
        static fn(array $repo): bool => !str_starts_with($repo['url'] ?? '', 'typo3-core/')
    ));
    foreach ($composerData['require'] ?? [] as $package => $version) {
        if (!str_starts_with($package, 'typo3/cms-') && !str_starts_with($package, 'typo3/theme-')) {
            continue;
        }
        if ($package === 'typo3/theme-camino' && $major < 14) {
            unset($composerData['require'][$package]);
            continue;
        }
        $composerData['require'][$package] = '^' . $release;
    }
    if (json_encode($composerData) !== $before) {
        file_put_contents($composerFile, json_encode($composerData, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
        @unlink($composerLockFile);
    }
    echo "composer.json requires TYPO3 ^$release from Packagist\n";
    exit(0);
}

if (!is_dir($sysextDir)) {
    fwrite(STDERR, "Error: $sysextDir not found. Clone TYPO3 Core first.\n");
    exit(1);
}

if (!file_exists($composerFile)) {
    fwrite(STDERR, "Error: $composerFile not found.\n");
    exit(1);
}

$composerData = json_decode(file_get_contents($composerFile), true);
if ($composerData === null) {
    fwrite(STDERR, "Error: Failed to parse $composerFile\n");
    exit(1);
}

// Collect package names from all sysext composer.json files
$sysextNames = [];
foreach (glob($sysextDir . '/*/composer.json') as $path) {
    $extData = json_decode(file_get_contents($path), true);
    $name = $extData['name'] ?? '';
    if ($name !== '') {
        $sysextNames[] = $name;
    }
}
sort($sysextNames);

if (empty($sysextNames)) {
    fwrite(STDERR, "Error: No system extensions found in $sysextDir\n");
    exit(1);
}

// Detect active branch to determine version-specific packages
$coreDir = $projectRoot . '/typo3-core';
$branch = trim(shell_exec("git -C " . escapeshellarg($coreDir) . " branch --show-current 2>/dev/null") ?: 'main');

// Keep non-sysext requires (custom packages from packages/*),
// but drop managed typo3/* packages so they can be re-evaluated
$managedPrefixes = ['typo3/cms-', 'typo3/theme-'];
$oldRequire = $composerData['require'] ?? [];
$newRequire = [];
foreach ($oldRequire as $package => $version) {
    $isManaged = false;
    foreach ($managedPrefixes as $prefix) {
        if (str_starts_with($package, $prefix)) {
            $isManaged = true;
            break;
        }
    }
    if (!$isManaged) {
        $newRequire[$package] = $version;
    }
}

// Add all discovered sysexts
foreach ($sysextNames as $name) {
    $newRequire[$name] = '@dev';
}

// Packages only included on main / v14+
if ($branch === 'main' || version_compare($branch, '14', '>=')) {
    $newRequire['typo3/theme-camino'] = '@dev';
}

ksort($newRequire);

// Restore the Core path repository (removed by --release mode)
$hasCoreRepo = false;
foreach ($composerData['repositories'] ?? [] as $repo) {
    $hasCoreRepo = $hasCoreRepo || ($repo['url'] ?? '') === 'typo3-core/typo3/sysext/*';
}
if (!$hasCoreRepo) {
    $composerData['repositories'][] = [
        'type' => 'path',
        'url' => 'typo3-core/typo3/sysext/*',
        'options' => ['symlink' => true],
    ];
}

$composerData['require'] = $newRequire;

$json = json_encode($composerData, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
file_put_contents($composerFile, $json);

// The lock file needs to be removed so that the next "composer install" step will use
// current versions. This is e.g. required when Core removes an extension like EXT:setup
@unlink($composerLockFile);
echo count($sysextNames) . " system extensions written to composer.json\n";
