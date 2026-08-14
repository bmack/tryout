#!/usr/bin/env bash

# Post-start hook for TYPO3 tryout.
# First run: clones core, applies patches, installs composer, sets up TYPO3.
# Subsequent runs: reapplies configured patches, rebuilds.

set -euo pipefail

source "${DDEV_APPROOT}/.ddev/scripts/functions.sh"

echo ""
echo -e "${BOLD}TYPO3 tryout — Post-Start Setup${NC}"
echo "═══════════════════════════════════════"
echo ""

# --- Step 1: Clone TYPO3 Core if not present ---
if [ ! -d "${CORE_DIR}/.git" ] && [ ! -f "${CORE_DIR}/.git" ]; then
    info "[1/6] Cloning TYPO3 Core repository..."
    info "This may take a few minutes on first run."
    if ! git clone --branch "${BRANCH}" "${CORE_REPO}" "${CORE_DIR}"; then
        error "Failed to clone TYPO3 Core"
        error "  → Try manually: ddev tryout download"
        exit 1
    fi
    git -C "${CORE_DIR}" remote add gerrit "${GERRIT_REMOTE}"
    success "TYPO3 Core cloned"
else
    info "[1/6] TYPO3 Core already present"
fi

# --- Step 2: Apply patches from config ---
patches="${TRYOUT_PATCHES:-}"
patches=$(echo "${patches}" | tr -d '[:space:]')

if [ -n "${patches}" ]; then
    info "[2/6] Resetting core to origin/${BRANCH} and applying patches: ${patches}"
    reset_core_to_main
    apply_all_patches || {
        warn "Some patches failed to apply — check output above"
        warn "  → Reset and retry: ddev tryout reset"
    }
else
    info "[2/6] No patches configured"
fi

# --- Step 3: Composer install ---
info "[3/6] Running composer install..."
if ! ddev composer install; then
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

    info "[4/6] Running TYPO3 setup (first time, server-type=${SERVER_TYPE})..."
    if ! ddev exec env TYPO3_DB_DRIVER="${TYPO3_DB_DRIVER}" vendor/bin/typo3 setup --no-interaction --force --server-type="${SERVER_TYPE}"; then
        error "TYPO3 setup failed"
        error "  → Try: ddev exec env TYPO3_DB_DRIVER=${TYPO3_DB_DRIVER} vendor/bin/typo3 setup --no-interaction --force --server-type=${SERVER_TYPE}"
        exit 1
    fi
    success "TYPO3 setup complete"
else
    info "[4/6] TYPO3 already configured"
fi

# --- Step 5: Extension setup + cache flush ---
info "[5/6] Setting up extensions and flushing caches..."
ddev typo3 extension:setup 2>/dev/null || warn "extension:setup had warnings"
ddev typo3 cache:flush 2>/dev/null || warn "cache:flush had warnings"
success "Extensions ready, caches flushed"

# --- Step 6: Render the documentation ---
# Never fatal: a broken link in the manual must not be the reason an instance
# does not come up. On the first start this also installs the renderer, which
# is the one slow part — set TRYOUT_DOCS=0 to skip the step entirely.
DOCS_RENDERED=0
docs_enabled="${TRYOUT_DOCS:-1}"
if [ "${docs_enabled}" = "0" ] || [ "${docs_enabled}" = "false" ]; then
    info "[6/6] Documentation skipped (TRYOUT_DOCS=${docs_enabled})"
elif [ ! -f "${PROJECT_ROOT}/docs/guides.xml" ]; then
    info "[6/6] No documentation in docs/ — skipping"
else
    info "[6/6] Rendering documentation..."
    if ddev docs; then
        DOCS_RENDERED=1
    else
        warn "Documentation rendering failed"
        warn "  → See the reason: ddev docs"
    fi
fi

# --- Done ---
echo ""
echo "═══════════════════════════════════════"
success "TYPO3 is ready!"
echo ""
echo -e "  ${BOLD}Backend:${NC}  ${DDEV_PRIMARY_URL}/typo3/"
echo -e "  ${BOLD}Login:${NC}    admin / Password.1"
if [ "${DOCS_RENDERED}" = "1" ]; then
    echo -e "  ${BOLD}Docs:${NC}     ${DDEV_PRIMARY_URL}/_docs/"
fi
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo "    ddev tryout status     Show project status"
echo "    ddev tryout patch ID   Apply a Gerrit patch"
echo "    ddev tryout reset      Reset to clean state"
echo "    ddev docs              Re-render the documentation"
echo ""
