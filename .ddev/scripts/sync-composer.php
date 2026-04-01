<?php

/**
 * Regenerates composer.json to match the system extensions available
 * in typo3-core/typo3/sysext/. Run after switching Core branches.
 *
 * - Scans typo3-core/typo3/sysext/<*>/composer.json for package names
 * - Rewrites the "require" section with those packages at "@dev"
 * - Preserves non-typo3/cms-* requires (custom packages)
 * - Preserves all other composer.json fields
 */

$projectRoot = getenv('PROJECT_ROOT') ?: '/var/www/html';
$composerFile = $projectRoot . '/composer.json';
$sysextDir = $projectRoot . '/typo3-core/typo3/sysext';

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

$composerData['require'] = $newRequire;

$json = json_encode($composerData, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
file_put_contents($composerFile, $json);

echo count($sysextNames) . " system extensions written to composer.json\n";
