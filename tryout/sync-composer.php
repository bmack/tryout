<?php

// #ddev-generated

/**
 * Regenerates composer.json to match the system extensions available
 * in typo3-core/typo3/sysext/. Run after switching Core branches.
 *
 * - Scans typo3-core/typo3/sysext/<*>/composer.json for package names
 * - Rewrites the "require" section with those packages at "@dev"
 * - Preserves non-typo3/cms-* requires (custom packages)
 * - Preserves all other composer.json fields
 */

// PROJECT_ROOT is the composer root to rewrite (the project itself, or one
// sites/<name> tree). TRYOUT_CORE_DIR names the Core checkout to read sysexts from,
// which for a served site is a sibling worktree outside that root.
$projectRoot = getenv('PROJECT_ROOT') ?: '/var/www/html';

// The overlay, not the project's own composer.json. DDEV points Composer at it via
// COMPOSER=composer.tryout.json, and composer-merge-plugin pulls the user's
// composer.json in as an include — so their dependencies survive untouched and we
// only ever rewrite a file the add-on owns.
$composerName = getenv('TRYOUT_COMPOSER_FILE') ?: 'composer.tryout.json';
$composerFile = $projectRoot . '/' . $composerName;
$composerLockFile = $projectRoot . '/' . preg_replace('/\.json$/', '.lock', $composerName);
$coreDir = getenv('TRYOUT_CORE_DIR') ?: $projectRoot . '/typo3-core';
$sysextDir = $coreDir . '/typo3/sysext';

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

// Add all discovered sysexts — and ONLY those. Nothing is added by branch name:
// typo3/theme-camino used to be appended on main/v14+, but the glob above already
// finds it when typo3/sysext/theme_camino is there, and on 13.4 (where it is not)
// the entry pointed Composer at a path that does not exist:
//
//   Source path "../../typo3-core-main/typo3/sysext/theme_camino" is not found
//
// which fails `composer install` and therefore the whole checkout. The sysexts on
// disk are the only thing that decides what goes in here.
foreach ($sysextNames as $name) {
    $newRequire[$name] = '@dev';
}

ksort($newRequire);

$composerData['require'] = $newRequire;

$json = json_encode($composerData, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
if ($json === false) {
    fwrite(STDERR, "Error: Failed to encode $composerFile: " . json_last_error_msg() . "\n");
    exit(1);
}

// A short write leaves a truncated overlay behind, and the next composer install
// fails somewhere far from the cause. Say so here instead.
if (file_put_contents($composerFile, $json . "\n") === false) {
    fwrite(STDERR, "Error: Failed to write $composerFile (permissions? disk full?)\n");
    exit(1);
}

// The lock file needs to be removed so that the next "composer install" step will use
// current versions. This is e.g. required when Core removes an extension like EXT:setup
@unlink($composerLockFile);
echo count($sysextNames) . " system extensions written to $composerName\n";
