#!/usr/bin/env bash
#ddev-generated

# Post-start hook for TYPO3 tryout — runs INSIDE the web container (an `exec`
# hook in config.tryout.yaml), so git, composer and php are the container's own.
# First run: clones core, applies patches, installs composer, sets up TYPO3.
# Subsequent runs: reapplies configured patches, rebuilds.

set -euo pipefail

export TRYOUT_IN_CONTAINER=1
source "${DDEV_APPROOT:-/var/www/html}/.ddev/tryout/functions.sh"

echo ""
echo -e "${BOLD}TYPO3 tryout — Post-Start Setup${NC}"
echo "═══════════════════════════════════════"
echo ""

# --- Step 1: Clone TYPO3 Core if not present ---
# A dangling symlink reads as absent to the tests below, so the clone would fail
# against an occupied path. Catch it with a message that names the fix.
if [ -L "${CORE_DIR}" ] && [ ! -e "${CORE_DIR}" ]; then
    error "typo3-core is a broken symlink -> $(readlink "${CORE_DIR}")"
    error "  → ddev tryout worktree list, then: ddev tryout worktree use <name>"
    exit 1
fi

if [ ! -d "${CORE_DIR}/.git" ] && [ ! -f "${CORE_DIR}/.git" ]; then
    info "[1/5] Cloning TYPO3 Core repository..."
    info "This may take a few minutes on first run."
    if ! git clone --branch "${BRANCH}" "${CORE_REPO}" "${CORE_DIR}"; then
        error "Failed to clone TYPO3 Core"
        error "  → Try manually: ddev tryout download"
        exit 1
    fi
    git -C "${CORE_DIR}" remote add gerrit "${GERRIT_REMOTE}"
    ensure_relative_worktree_paths
    success "TYPO3 Core cloned"
else
    info "[1/5] TYPO3 Core already present"
    # A checkout that predates the container-side git still records absolute
    # host paths in its worktrees; make them readable on both sides.
    ensure_relative_worktree_paths
fi

# --- Step 2: Apply patches from config ---
patches="${TRYOUT_PATCHES:-}"
patches=$(echo "${patches}" | tr -d '[:space:]')

if [ -n "${patches}" ]; then
    info "[2/5] Resetting core to origin/${BRANCH} and applying patches: ${patches}"
    reset_core_to_main
    apply_all_patches || {
        warn "Some patches failed to apply — check output above"
        warn "  → Reset and retry: ddev tryout reset"
    }
else
    info "[2/5] No patches configured"
fi

# --- Step 3: Composer install ---
# The overlay ships with an empty require block, so it must be synced against the
# sysexts actually present in this Core checkout before install can resolve the
# path repository. Doing it every start also keeps it correct after a branch switch.
info "[3/5] Syncing composer.tryout.json with Core sysexts..."
if ! php "$(tryout_script sync-composer.php)"; then
    error "Failed to sync composer.tryout.json"
    error "  → Try: ddev tryout download --reset && ddev restart"
    exit 1
fi

# Core states its PHP requirement per branch (^8.5 on main). Check it before
# Composer does: its resolver trace buries the cause, and the hint below it — a
# re-download — would not fix it.
check_php_for_core || exit 1

info "[3/5] Running composer install..."
if ! run_composer install; then
    error "Composer install failed"
    error "  → Try: ddev tryout download --reset && ddev restart"
    exit 1
fi
success "Composer dependencies installed"

# --- Step 4: TYPO3 setup (first time only) ---
if [ ! -f "${PROJECT_ROOT}/config/system/settings.php" ]; then
    # Derive SQL type from DDEV
    TYPO3_DB_DRIVER="mysqli"
    db_is_postgres && TYPO3_DB_DRIVER="postgres"

    # Derive server type from DDEV webserver config
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        apache*) SERVER_TYPE="apache" ;;
        *)       SERVER_TYPE="other" ;;
    esac

    info "[4/5] Running TYPO3 setup (first time, server-type=${SERVER_TYPE})..."
    # A plain assignment prefix, not `env`: run_typo3 is a shell function.
    if ! TYPO3_DB_DRIVER="${TYPO3_DB_DRIVER}" run_typo3 setup --no-interaction --force --server-type="${SERVER_TYPE}"; then
        error "TYPO3 setup failed"
        error "  → Try: ddev exec env TYPO3_DB_DRIVER=${TYPO3_DB_DRIVER} vendor/bin/typo3 setup --no-interaction --force --server-type=${SERVER_TYPE}"
        exit 1
    fi
    success "TYPO3 setup complete"
else
    info "[4/5] TYPO3 already configured"
fi

# --- Step 5: Extension setup + cache flush ---
info "[5/5] Setting up extensions and flushing caches..."
run_typo3 extension:setup 2>/dev/null || warn "extension:setup had warnings"
run_typo3 cache:flush 2>/dev/null || warn "cache:flush had warnings"
success "Extensions ready, caches flushed"

# --- Done ---
echo ""
echo "═══════════════════════════════════════"
success "TYPO3 is ready!"
echo ""
echo -e "  ${BOLD}Backend:${NC}  ${DDEV_PRIMARY_URL:-}/typo3/"
echo -e "  ${BOLD}Login:${NC}    admin / Password.1"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo "    ddev tryout status     Show project status"
echo "    ddev tryout patch ID   Apply a Gerrit patch"
echo "    ddev tryout reset      Reset to clean state"
echo ""
