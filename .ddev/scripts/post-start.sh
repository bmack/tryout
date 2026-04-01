#!/usr/bin/env bash

# Post-start hook for TYPO3 tryout.
# First run: clones core, applies patches, installs composer, sets up TYPO3.
# Subsequent runs: reapplies configured patches, rebuilds.

set -euo pipefail

source /var/www/html/.ddev/scripts/functions.sh

echo ""
echo -e "${BOLD}TYPO3 tryout — Post-Start Setup${NC}"
echo "═══════════════════════════════════════"
echo ""

# --- Step 1: Clone TYPO3 Core if not present ---
if [ ! -d "${CORE_DIR}/.git" ]; then
    info "[1/5] Cloning TYPO3 Core repository..."
    info "This may take a few minutes on first run."
    if ! git clone --branch "${BRANCH}" "${CORE_REPO}" "${CORE_DIR}"; then
        error "Failed to clone TYPO3 Core"
        error "  → Try manually: ddev tryout download"
        exit 1
    fi
    git -C "${CORE_DIR}" remote add gerrit "${GERRIT_REMOTE}"
    success "TYPO3 Core cloned"
else
    info "[1/5] TYPO3 Core already present"
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
info "[3/5] Running composer install..."
if ! composer install --working-dir="${PROJECT_ROOT}"; then
    error "Composer install failed"
    error "  → Try: ddev tryout download --reset && ddev restart"
    exit 1
fi
success "Composer dependencies installed"

# --- Step 4: TYPO3 setup (first time only) ---
if [ ! -f "${PROJECT_ROOT}/config/system/settings.php" ]; then
    # Derive SQL type from DDEV
    ddev_db="${DDEV_DATABASE:-mariadb}"
    export TYPO3_DB_DRIVER="mysqli"
    if [[ "${ddev_db}" == postgres* ]]; then
      export TYPO3_DB_DRIVER="postgres"
    fi

    # Derive server type from DDEV webserver config
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        apache*) SERVER_TYPE="apache" ;;
        *)       SERVER_TYPE="other" ;;
    esac

    info "[4/5] Running TYPO3 setup (first time, server-type=${SERVER_TYPE})..."
    if ! vendor/bin/typo3 setup --no-interaction --force --server-type="${SERVER_TYPE}"; then
        error "TYPO3 setup failed"
        error "  → Try: ddev exec vendor/bin/typo3 setup --no-interaction --force --server-type=${SERVER_TYPE}"
        exit 1
    fi
    success "TYPO3 setup complete"
else
    info "[4/5] TYPO3 already configured"
fi

# --- Step 5: Extension setup + cache flush ---
info "[5/5] Setting up extensions and flushing caches..."
vendor/bin/typo3 extension:setup 2>/dev/null || warn "extension:setup had warnings"
vendor/bin/typo3 cache:flush 2>/dev/null || warn "cache:flush had warnings"
success "Extensions ready, caches flushed"

# --- Done ---
echo ""
echo "═══════════════════════════════════════"
success "TYPO3 is ready!"
echo ""
echo -e "  ${BOLD}Backend:${NC}  ${DDEV_PRIMARY_URL}/typo3/"
echo -e "  ${BOLD}Login:${NC}    admin / Password.1"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo "    ddev tryout status     Show project status"
echo "    ddev tryout patch ID   Apply a Gerrit patch"
echo "    ddev tryout reset      Reset to clean state"
echo ""
