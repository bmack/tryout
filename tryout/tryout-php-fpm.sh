#!/usr/bin/env bash
#ddev-generated

# Runs INSIDE the web container, launched by a web_extra_daemons entry that
# .ddev/config.worktrees.yaml declares (DDEV supervises and restarts it).
#
# Starts an additional php-fpm master for one PHP version on its own socket, so
# per-site vhosts can route to a different PHP than the project default.
#
# Usage: tryout-php-fpm.sh <php-version>        e.g. 8.2
#
# Two constraints, both established by experiment:
#   * The version's stock `www` pool must NOT be loaded — it listens on the shared
#     /run/php-fpm.sock and the second master then dies with
#     "Another FPM instance seems to already listen on /run/php-fpm.sock".
#     So we generate a config that includes only our own pool.
#   * `listen` is a pool directive, so it cannot be passed via `php-fpm -d`.
# Everything under /etc and /run is ephemeral across `ddev restart`, hence the
# config is regenerated on every launch.
#
# The socket and pid live under /run/php/, not /run/: this daemon runs as the web
# user, and /run itself is root-owned on some Docker providers (Colima), where the
# bind fails with "Permission denied" and every request answers 502. /run/php/ is
# where the stock php-fpm writes its own pid, so it is writable wherever DDEV runs.
# The vhost generator (write_site_vhost in functions.sh) must use the same path.

set -euo pipefail

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
    echo "tryout-php-fpm: missing PHP version argument" >&2
    exit 64
fi

BIN="/usr/sbin/php-fpm${VERSION}"
if [ ! -x "${BIN}" ]; then
    echo "tryout-php-fpm: ${BIN} not found — PHP ${VERSION} is not installed in this image" >&2
    exit 69
fi

RUN_DIR="/run/php"
SOCKET="${RUN_DIR}/php-fpm-${VERSION}.sock"
CONF_DIR="/tmp/tryout-fpm"
CONF="${CONF_DIR}/php-fpm-${VERSION}.conf"
POOL="tryout${VERSION//./}"

mkdir -p "${CONF_DIR}"

# A self-contained master + single pool. Deliberately does not include
# /etc/php/<v>/fpm/pool.d/, which is where the conflicting stock www pool lives.
cat > "${CONF}" <<CONF_EOF
[global]
pid = ${RUN_DIR}/php-fpm-${VERSION}.pid
error_log = /proc/self/fd/2
daemonize = no

[${POOL}]
listen = ${SOCKET}
listen.mode = 0666
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
clear_env = no
php_admin_value[error_log] = /proc/self/fd/2
php_admin_flag[log_errors] = on
CONF_EOF

if [ ! -w "${RUN_DIR}" ]; then
    echo "tryout-php-fpm: ${RUN_DIR} is not writable by $(id -un) — cannot create ${SOCKET}" >&2
    exit 73
fi

# A socket left behind by a killed master would make bind fail.
rm -f "${SOCKET}"

echo "tryout-php-fpm: starting PHP ${VERSION} on ${SOCKET} (pool ${POOL})"
exec "${BIN}" --nodaemonize --fpm-config "${CONF}"
