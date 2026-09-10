<?php

// #ddev-generated — provided by the tryout DDEV add-on.
// Remove the line above if you want to own and edit this file yourself.

if (getenv('IS_DDEV_PROJECT') == 'true') {
    // Derive DB driver from DDEV_DATABASE (e.g. "mariadb:10.11", "postgres:16")
    $ddevDatabase = getenv('DDEV_DATABASE') ?: 'mariadb:10.11';
    $isPostgres = str_starts_with($ddevDatabase, 'postgres');
    $dbDriver = $isPostgres ? 'pdo_pgsql' : 'mysqli';
    $dbPort = $isPostgres ? 5432 : 3306;

    // A served worktree site gets its own database, injected by its vhost
    // (Apache SetEnv / nginx fastcgi_param). The primary site has no such
    // variable and keeps plain 'db'.
    $dbName = getenv('TYPO3_DB_DBNAME') ?: 'db';

    $GLOBALS['TYPO3_CONF_VARS'] = array_replace_recursive(
        $GLOBALS['TYPO3_CONF_VARS'],
        [
            'DB' => [
                'Connections' => [
                    'Default' => [
                        'dbname' => $dbName,
                        'driver' => $dbDriver,
                        'host' => 'db',
                        'password' => 'db',
                        'port' => $dbPort,
                        'user' => 'db',
                    ],
                ],
            ],
            'GFX' => [
                'processor' => 'ImageMagick',
                'processor_path' => '/usr/bin/',
                'processor_path_lzw' => '/usr/bin/',
            ],
            'MAIL' => [
                'transport' => 'smtp',
                'transport_smtp_encrypt' => false,
                'transport_smtp_server' => 'localhost:1025',
            ],
            'SYS' => [
                'trustedHostsPattern' => '.*.*',
                'devIPmask' => '*',
                'displayErrors' => 1,
            ],
        ]
    );
}
