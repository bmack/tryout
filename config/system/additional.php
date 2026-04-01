<?php

if (getenv('IS_DDEV_PROJECT') == 'true') {
    // Derive DB driver from DDEV_DATABASE (e.g. "mariadb:10.11", "postgres:16")
    $ddevDatabase = getenv('DDEV_DATABASE') ?: 'mariadb:10.11';
    $isPostgres = str_starts_with($ddevDatabase, 'postgres');
    $dbDriver = $isPostgres ? 'pdo_pgsql' : 'mysqli';
    $dbPort = $isPostgres ? 5432 : 3306;

    $GLOBALS['TYPO3_CONF_VARS'] = array_replace_recursive(
        $GLOBALS['TYPO3_CONF_VARS'],
        [
            'DB' => [
                'Connections' => [
                    'Default' => [
                        'dbname' => 'db',
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
