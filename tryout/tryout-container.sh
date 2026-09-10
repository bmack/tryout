#!/usr/bin/env bash
#ddev-generated

# Runs INSIDE the web container: the far end of `ddev tryout`.
#
# commands/host/tryout resolves prompts on the host, then runs
#   ddev exec bash /var/www/html/.ddev/tryout/tryout-container.sh <verb> [args]
# once per command. Everything from here on uses the container's git, composer,
# php, curl and database clients; nothing calls `ddev`, which is only a stub
# in here. DDEV_APPROOT is /var/www/html, so functions.sh resolves every path
# to the container side by itself.

set -euo pipefail

export TRYOUT_IN_CONTAINER=1

source "${DDEV_APPROOT:-/var/www/html}/.ddev/tryout/functions.sh"
source "${PROJECT_ROOT}/.ddev/tryout/commands.sh"

ACTION="${1:-}"
shift || true

case "${ACTION}" in
    status)   ctr_status "$@" ;;
    download) ctr_download "$@" ;;
    checkout) ctr_checkout "$@" ;;
    composer) ctr_composer "$@" ;;
    patch)    ctr_patch "$@" ;;
    worktree) ctr_worktree "$@" ;;
    cs)       ctr_cs "$@" ;;
    exec)     ctr_exec "$@" ;;
    reset)    ctr_reset "$@" ;;
    delete)   ctr_delete "$@" ;;
    *)
        error "tryout-container: unknown verb '${ACTION}'"
        exit 64
        ;;
esac
