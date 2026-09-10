#!/usr/bin/env bash
#ddev-generated

# The bodies of the `ddev tryout` verbs, written for the WEB CONTAINER.
#
# commands/host/tryout is the entry point: it owns the terminal (prompts, gum,
# herdr), validates what it can see on the host, then hands the verb to
# tryout-container.sh, which sources this file. In here git, composer, php and
# the database clients are the container's own, and every path is under
# /var/www/html — PROJECT_ROOT, since DDEV_APPROOT is set in the container too.
#
# Arguments arrive resolved: a ctr_* function never prompts, it errors with the
# usage line instead. Sourced after functions.sh; nothing here calls `ddev`.

# ─────────────────────────────────────────────────────────────────────
# status — Show project overview
# ─────────────────────────────────────────────────────────────────────
ctr_status() {
    echo ""
    # The body writes the report and returns early in places; capturing it here
    # keeps that flow and puts the framing in exactly one spot.
    ctr_status_body | ui_box "TYPO3 tryout — Status"
    echo ""
}

ctr_status_body() {
    local OK="${GREEN}✓${TEXT}"
    local WARN="${YELLOW}!${TEXT}"
    local FAIL="${RED}✗${TEXT}"

    # Core repository
    if [ ! -d "${CORE_DIR}/.git" ] && [ ! -f "${CORE_DIR}/.git" ]; then
        echo -e "${TEXT}  Core:      ${FAIL} not cloned${NC}"
        echo -e "${TEXT}             ${DIM}→ ddev tryout download${NC}"
        return
    fi

    local current_branch commit_short commit_date tree_state tree_icon
    current_branch=$(git -C "${CORE_DIR}" branch --show-current 2>/dev/null || echo "detached")
    commit_short=$(git -C "${CORE_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    commit_date=$(git -C "${CORE_DIR}" log -1 --format='%cr' 2>/dev/null || echo "")

    if git -C "${CORE_DIR}" diff --quiet 2>/dev/null && git -C "${CORE_DIR}" diff --cached --quiet 2>/dev/null; then
        tree_state="clean"
        tree_icon="${OK}"
    else
        tree_state="dirty"
        tree_icon="${WARN}"
    fi

    echo -e "${TEXT}  Core:      ${tree_icon} ${current_branch} (${commit_short}) — ${tree_state}${NC}"
    [ -n "${commit_date}" ] && echo -e "${TEXT}             ${DIM}${commit_date}${NC}"

    # Worktrees (only meaningful once migrated to the symlink layout)
    if core_is_symlinked; then
        local active wt_count wt_rows
        active=$(active_worktree_name)
        # ONCE, into a variable: the count and the loop want the same rows, and
        # asking twice doubled the cost. And the _fast form, because this prints
        # the name, the branch and the head — never the dirty flag, which is what
        # the other one spends two `git diff` calls per worktree computing.
        wt_rows="$(list_core_worktrees_fast)"
        wt_count=$(printf '%s\n' "${wt_rows}" | grep -c . | tr -d ' ')
        echo -e "${TEXT}  Worktree:  ${OK} ${active} ${DIM}(${wt_count} total)${NC}"
        printf '%s\n' "${wt_rows}" | while IFS=$'\t' read -r name head branch is_active; do
            [ -n "${name}" ] || continue
            [ -n "${is_active}" ] && continue
            echo -e "${TEXT}             ${DIM}${name} — ${branch} (${head})${NC}"
        done
        # Composer binds vendor/ to the resolved real path, so a switch without a
        # rebuild silently keeps serving the previous Core.
        if vendor_core_mismatch; then
            echo -e "${TEXT}             ${WARN} vendor/ was built from a different Core${NC}"
            echo -e "${TEXT}             ${DIM}→ ddev tryout worktree use ${active}${NC}"
        fi
        # A checkout outside the project is invisible to every other command, so say so.
        local stray_count
        stray_count=$(list_foreign_core_worktrees | grep -c . || true)
        if [ "${stray_count}" -gt 0 ]; then
            echo -e "${TEXT}             ${WARN} ${stray_count} checkout(s) outside the project${NC}"
            echo -e "${TEXT}             ${DIM}→ ddev tryout worktree adopt${NC}"
        fi
    fi

    # Applied patches
    if git -C "${CORE_DIR}" rev-parse "origin/${BRANCH}" >/dev/null 2>&1; then
        local ahead
        ahead=$(git -C "${CORE_DIR}" rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo "0")
        if [ "${ahead}" -gt 0 ]; then
            echo -e "${TEXT}  Patches:   ${OK} ${ahead} applied${NC}"
            git -C "${CORE_DIR}" log --oneline "origin/${BRANCH}..HEAD" 2>/dev/null | head -10 | while IFS= read -r line; do
                echo -e "${TEXT}             ${DIM}${line}${NC}"
            done
        else
            echo -e "${TEXT}  Patches:   ${DIM}none applied${NC}"
        fi
    fi

    # Configured patches
    local patches="${TRYOUT_PATCHES:-}"
    patches=$(echo "${patches}" | tr -d '[:space:]')
    if [ -n "${patches}" ]; then
        echo -e "${TEXT}  Config:    ${CYAN}TRYOUT_PATCHES=${patches}${NC}"
    else
        echo -e "${TEXT}  Config:    ${DIM}no patches configured${NC}"
    fi

    # Custom extensions
    local ext_count
    ext_count=$(find "${PROJECT_ROOT}/packages" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "${ext_count}" -gt 0 ]; then
        echo -e "${TEXT}  Packages:  ${OK} ${ext_count} custom extension(s)${NC}"
        find "${PROJECT_ROOT}/packages" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while IFS= read -r dir; do
            echo -e "${TEXT}             ${DIM}$(basename "${dir}")${NC}"
        done
    else
        echo -e "${TEXT}  Packages:  ${DIM}none in packages/${NC}"
    fi

    # Composer
    if [ -d "${PROJECT_ROOT}/vendor" ]; then
        echo -e "${TEXT}  Composer:  ${OK} installed${NC}"
    else
        echo -e "${TEXT}  Composer:  ${FAIL} not installed${NC}"
        echo -e "${TEXT}             ${DIM}→ ddev composer install${NC}"
    fi

    # TYPO3
    if [ -f "${PROJECT_ROOT}/config/system/settings.php" ]; then
        echo -e "${TEXT}  TYPO3:     ${OK} configured${NC}"
    else
        echo -e "${TEXT}  TYPO3:     ${FAIL} not set up${NC}"
    fi

    # Contribution setup (Gerrit hooks / push URL)
    inspect_contribution_setup
    local cs_parts=()
    [ "${CS_HOOK_COMMIT_MSG}" = "1" ] && cs_parts+=("commit-msg")
    [ "${CS_HOOK_PRE_COMMIT}" = "1" ] && cs_parts+=("pre-commit")
    [ "${CS_TEMPLATE}" = "1" ] && cs_parts+=("template")
    if echo "${CS_PUSH_URL}" | grep -q "^ssh://.*@${GERRIT_SSH_HOST}"; then
        cs_parts+=("push-url")
    fi
    if [ ${#cs_parts[@]} -eq 4 ]; then
        echo -e "${TEXT}  Contrib:   ${OK} ready (${CS_USER:-?})${NC}"
    elif [ ${#cs_parts[@]} -gt 0 ]; then
        echo -e "${TEXT}  Contrib:   ${WARN} partial (${cs_parts[*]})${NC}"
        echo -e "${TEXT}             ${DIM}→ ddev tryout cs doctor${NC}"
    else
        echo -e "${TEXT}  Contrib:   ${DIM}not configured${NC}"
        echo -e "${TEXT}             ${DIM}→ ddev tryout cs${NC}"
    fi

    # Site URL
    echo -e "${TEXT}  Site:      ${BOLD}${DDEV_PRIMARY_URL:-}${NC}"
}

# ─────────────────────────────────────────────────────────────────────
# download — Clone or update TYPO3 Core
# ─────────────────────────────────────────────────────────────────────
ctr_download() {
    local reset=false site="${PRIMARY_SITE}" a
    for a in "$@"; do
        case "${a}" in
            --reset|-r) reset=true ;;
            *)          [ -n "${a}" ] && site="${a}" ;;
        esac
    done

    # Point at the named worktree, the way reset and patch do. Without this the
    # command only ever updated the primary, whichever worktree you meant.
    if ! site_is_primary "${site}"; then
        if ! site_is_served "${site}"; then
            error "No served site '${site}'"
            error "  → ddev tryout worktree list"
            return 1
        fi
        CORE_DIR="$(site_core_dir "${site}")"
        # An attached worktree carries its own branch name; the base it tracks is
        # what to update from. A detached one, or one made before tracking was
        # recorded, has to have its base detected instead.
        #
        # `|| true` is load-bearing: rev-parse EXITS 128 when there is no
        # upstream, and under `set -e` that killed the command before the
        # fallback below could run — the failure a worktree created earlier hits
        # every time.
        BRANCH="$(git -C "${CORE_DIR}" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
        BRANCH="${BRANCH#origin/}"
        [ -n "${BRANCH}" ] || BRANCH="$(detect_detached_base_branch)"
    fi

    # Every "→ ddev tryout download …" hint has to name the same site, or it
    # points the user at the primary's Core instead of the one that failed.
    local site_arg=""
    site_is_primary "${site}" || site_arg=" ${site}"

    # First-time clone
    if [ ! -d "${CORE_DIR}" ]; then
        info "Cloning TYPO3 Core (${BRANCH} branch)..."
        info "This may take a few minutes on first run."
        if ! git clone --branch "${BRANCH}" "${CORE_REPO}" "${CORE_DIR}"; then
            error "Failed to clone TYPO3 Core repository"
            exit 1
        fi
        git -C "${CORE_DIR}" remote add gerrit "${GERRIT_REMOTE}"
        ensure_relative_worktree_paths
        success "TYPO3 Core cloned into typo3-core/"
        return
    fi

    ensure_gerrit_remote

    # Reset mode
    if [ "${reset}" = "true" ]; then
        warn "Resetting $(basename "${CORE_DIR}") to origin/${BRANCH}..."
        warn "All local changes and applied patches will be lost."
        reset_core_to_main "${site}"
        success "Reset to origin/${BRANCH}"
        rebuild_typo3 "${site}"
        return
    fi

    # Update mode
    info "Updating TYPO3 Core..."
    git -C "${CORE_DIR}" fetch origin

    local current_branch
    current_branch=$(git -C "${CORE_DIR}" branch --show-current)
    # A worktree branch is named after the WORKTREE and tracks the base, so its
    # name does not match BRANCH and must not be expected to. What matters is
    # that there is a branch at all: a detached checkout has nothing to rebase.
    if [ -z "${current_branch}" ]; then
        error "Detached checkout — nothing to update from"
        error "  → ddev tryout checkout <branch>${site_arg:+ --site ${site}}"
        error "  → or start over: ddev tryout download${site_arg} --reset"
        exit 1
    fi

    if ! git -C "${CORE_DIR}" diff --quiet || ! git -C "${CORE_DIR}" diff --cached --quiet; then
        error "Working tree has uncommitted changes"
        error "  → Reset: ddev tryout download${site_arg} --reset"
        exit 1
    fi

    # Rebase, never merge: Gerrit wants one commit with a stable Change-Id, and a
    # merge commit in the history is what it cannot take.
    if ! git -C "${CORE_DIR}" pull --rebase origin "${BRANCH}"; then
        error "Pull failed"
        error "  → Reset: ddev tryout download${site_arg} --reset"
        exit 1
    fi

    success "$(basename "${CORE_DIR}") updated to latest origin/${BRANCH}"
    rebuild_typo3 "${site}"
}

# ─────────────────────────────────────────────────────────────────────
# patch — Apply Gerrit patches
# ─────────────────────────────────────────────────────────────────────
# ctr_patch [--site <name>] [<change-id> ...]
#
# Several change numbers are applied in the order given, and the site — which used
# to be the second positional argument — moved to a flag so that stays possible.
# The host still accepts `patch <id> <site>` and translates.
ctr_patch() {
    require_core
    ensure_gerrit_remote

    local site="${PRIMARY_SITE}" ids=() a
    while [ $# -gt 0 ]; do
        case "$1" in
            --site) site="${2:-${PRIMARY_SITE}}"; shift ;;
            --site=*) site="${1#--site=}" ;;
            *)      ids+=("$1") ;;
        esac
        shift
    done

    if ! site_is_primary "${site}"; then
        if ! site_is_served "${site}"; then
            error "No served site '${site}'"
            error "  → ddev tryout worktree list"
            return 1
        fi
        CORE_DIR="$(site_core_dir "${site}")"
        BRANCH="$(detect_detached_base_branch)"
        info "Patching site '${site}' ($(basename "${CORE_DIR}"), base ${BRANCH})"
    fi

    if [ ${#ids[@]} -gt 0 ]; then
        # One rebuild at the end, not one per patch: each is a full composer
        # install, and applying three changes would run it three times.
        local applied=0 id
        for id in "${ids[@]}"; do
            apply_patch "${id}" || break
            [ "${PATCH_RESULT}" = "applied" ] && applied=$((applied + 1))
            [ ${#ids[@]} -gt 1 ] && echo ""
        done
        if [ "${applied}" -gt 0 ]; then
            rebuild_typo3 "${site}"
        fi
    else
        local patches="${TRYOUT_PATCHES:-}"
        patches=$(echo "${patches}" | tr -d '[:space:]')

        if [ -z "${patches}" ]; then
            info "No patches configured."
            echo ""
            echo "Usage:"
            echo "  ddev tryout patch              Browse the open changes and pick"
            echo "  ddev tryout patch <change-id>  Apply a single Gerrit patch"
            echo ""
            echo "Configure in .ddev/config.tryout-patches.yaml:"
            echo "  TRYOUT_PATCHES=56947,12345"
            return
        fi

        apply_all_patches
        if [ "${PATCHES_APPLIED:-0}" -gt 0 ]; then
            rebuild_typo3 "${site}"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────
# reset — Reset Core to latest main and rebuild
# ─────────────────────────────────────────────────────────────────────
ctr_reset() {
    require_core

    local site="${1:-${PRIMARY_SITE}}"
    if ! site_is_primary "${site}"; then
        if ! site_is_served "${site}"; then
            error "No served site '${site}'"
            error "  → ddev tryout worktree list"
            return 1
        fi
        CORE_DIR="$(site_core_dir "${site}")"
        BRANCH="$(detect_detached_base_branch)"
    fi

    echo ""
    info "Resetting $(basename "${CORE_DIR}") to latest origin/${BRANCH}..."
    echo ""

    info "[1/2] Resetting git repository..."
    reset_core_to_main "${site}"
    success "Git reset to origin/${BRANCH}"

    info "[2/2] Rebuilding..."
    rebuild_typo3 "${site}"

    echo ""
    success "Reset complete! Site: $(site_hostname "${site}")"
}

# ─────────────────────────────────────────────────────────────────────
# delete — Wipe database and fileadmin, fresh TYPO3 setup
# ─────────────────────────────────────────────────────────────────────
# The host asks "Are you sure?" and passes --yes; without it this asks itself when
# there is someone to ask, and refuses otherwise.
ctr_delete() {
    local target="" sites=() assume_yes="false" a
    for a in "$@"; do
        case "${a}" in
            --yes|-y) assume_yes="true" ;;
            *)        [ -z "${target}" ] && target="${a}" ;;
        esac
    done

    if [ "${target}" = "--all" ]; then
        sites=("${PRIMARY_SITE}")
        local s
        while IFS= read -r s; do [ -n "${s}" ] && sites+=("${s}"); done < <(served_site_names)
    elif [ -n "${target}" ]; then
        if ! site_is_served "${target}"; then
            error "No served site '${target}'"
            error "  → ddev tryout worktree list"
            return 1
        fi
        sites=("${target}")
    else
        sites=("${PRIMARY_SITE}")
    fi

    if [ "${assume_yes}" != "true" ]; then
        delete_warning "${target}" "${sites[@]}"
        if [ -t 0 ]; then
            read -r -p "Are you sure? [y/N] " confirm
            if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
                info "Aborted."
                return
            fi
        else
            error "Refusing without confirmation — pass --yes"
            return 1
        fi
    fi

    local s label
    for s in "${sites[@]}"; do
        echo ""
        label="${s}"; site_is_primary "${s}" && label="primary"
        info "── ${label} ──"
        delete_site "${s}" || return 1
    done

    echo ""
    success "Fresh setup complete!"
    for s in "${sites[@]}"; do
        echo -e "  ${BOLD}$(site_hostname "${s}")/typo3/${NC}"
    done
    echo -e "  ${BOLD}Login:${TEXT}    admin / Password.1${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────
# checkout — Switch TYPO3 Core branch (version)
# ─────────────────────────────────────────────────────────────────────
ctr_checkout() {
    local target_branch="${1:-}" site="${2:-${PRIMARY_SITE}}"

    if [ -z "${target_branch}" ]; then
        error "Usage: ddev tryout checkout <branch>"
        return 1
    fi

    require_core

    if ! site_is_primary "${site}"; then
        if ! site_is_served "${site}"; then
            error "No served site '${site}'"
            error "  → ddev tryout worktree list"
            return 1
        fi
        CORE_DIR="$(site_core_dir "${site}")"
        info "Switching site '${site}' ($(basename "${CORE_DIR}"))"
    fi

    ui_spin "Fetching latest branches" git -C "${CORE_DIR}" fetch origin

    # Verify the branch exists on the remote
    if ! git -C "${CORE_DIR}" ls-remote --exit-code --heads origin "${target_branch}" >/dev/null 2>&1; then
        error "Branch '${target_branch}' does not exist on origin"
        echo ""
        echo "Available branches:"
        list_remote_core_branches | sed 's/^/  /'
        return 1
    fi

    local current_branch
    current_branch=$(git -C "${CORE_DIR}" branch --show-current 2>/dev/null || echo "detached")

    if [ "${current_branch}" = "${target_branch}" ]; then
        info "Already on ${target_branch}, resetting to latest origin/${target_branch}..."
    else
        info "Switching from ${current_branch} to ${target_branch}..."
    fi

    # git refuses a branch that is checked out in another worktree; point at the
    # non-destructive alternative instead of surfacing the raw git error.
    if core_is_symlinked; then
        local holder
        holder=$(git -C "${CORE_DIR}" worktree list --porcelain 2>/dev/null \
                 | awk -v b="branch refs/heads/${target_branch}" '
                     /^worktree /{w=substr($0,10)} $0==b{print w; exit}')
        if [ -n "${holder}" ] && [ "$(cd "${holder}" && pwd -P)" != "$(cd "${CORE_DIR}" && pwd -P)" ]; then
            error "Branch '${target_branch}' is checked out in $(basename "${holder}")"
            error "  → ddev tryout worktree use ${holder#"${CORE_WORKTREE_PREFIX}"}"
            return 1
        fi
    fi

    # Reset to the target branch
    git -C "${CORE_DIR}" checkout "${target_branch}" 2>/dev/null \
        || git -C "${CORE_DIR}" checkout -b "${target_branch}" "origin/${target_branch}"
    git -C "${CORE_DIR}" reset --hard "origin/${target_branch}"
    git -C "${CORE_DIR}" clean -fd
    rm -rf "${PROJECT_ROOT}/var/cache"/*

    success "Core switched to ${target_branch}"

    # Sync composer.json and rebuild, against this site's own root when serving.
    if site_is_primary "${site}"; then
        ctr_composer
    else
        info "Syncing sites/${site}/composer.tryout.json..."
        env PROJECT_ROOT="$(site_dir "${site}")" TRYOUT_CORE_DIR="$(core_worktree_dir "${site}")" \
            php "$(tryout_script sync-composer.php)"
    fi
    wipe_site_vendor "${site}" || return 1
    rebuild_typo3 "${site}"

    echo ""
    success "Now on TYPO3 branch ${target_branch}"
    echo -e "  ${BOLD}Site:${TEXT} https://$(site_hostname "${site}")${NC}"
}

# ─────────────────────────────────────────────────────────────────────
# composer — Regenerate composer.json from available system extensions
# ─────────────────────────────────────────────────────────────────────
ctr_composer() {
    require_core
    info "Syncing composer.tryout.json with available system extensions..."
    php "$(tryout_script sync-composer.php)"
}

# ─────────────────────────────────────────────────────────────────────
# exec — Run a command in a site's context (its PHP, root and database)
# ─────────────────────────────────────────────────────────────────────
ctr_exec() {
    local site="${1:-}"
    shift || true
    if [ -z "${site}" ] || [ $# -eq 0 ]; then
        error "Usage: ddev tryout exec <site> <command> ..."
        return 1
    fi
    if ! site_is_primary "${site}" && ! site_is_served "${site}"; then
        error "No served site '${site}'"
        error "  → ddev tryout worktree list"
        return 1
    fi
    site_exec "${site}" "$@"
}

# ─────────────────────────────────────────────────────────────────────
# worktree — Manage side-by-side Core checkouts
# ─────────────────────────────────────────────────────────────────────
# `adopt` and `help` stay on the host: adopt moves checkouts from a host-only
# directory, and help is text.
ctr_worktree() {
    local sub="${1:-list}"
    shift || true
    require_core

    case "${sub}" in
        add)
            local name="${1:-}" branch="" attach="true" serve="false" php=""
            shift || true
            while [ $# -gt 0 ]; do
                case "$1" in
                    --detach)  attach="false" ;;
                    --branch)  ;;   # the default now; accepted, does nothing
                    --serve)   serve="true" ;;
                    --php)     php="${2:-}"; shift ;;
                    --php=*)   php="${1#--php=}" ;;
                    *)         branch="$1" ;;
                esac
                shift
            done
            validate_worktree_name "${name}" || return 1
            # A named PHP version only takes effect on a served site.
            [ -n "${php}" ] && serve="true"
            migrate_core_to_worktree_layout || return 1
            add_core_worktree "${name}" "${branch:-${BRANCH}}" "${attach}" || return 1
            if [ "${serve}" = "true" ]; then
                echo ""
                serve_worktree "${name}" "${php}" || return 1
            else
                echo ""
                echo -e "  ${DIM}→ ddev tryout worktree use ${name}      (switch the primary site)${NC}"
                echo -e "  ${DIM}→ ddev tryout worktree serve ${name}    (give it its own URL)${NC}"
            fi
            ;;

        list)
            local plain="false" _wt_rows=""
            if [ "${1:-}" = "--plain" ]; then plain="true"; fi
            echo ""
            echo -e "${BOLD}Core worktrees${NC}"
            if ! core_is_symlinked; then
                echo -e "  ${DIM}single Core checkout (no worktrees yet)${NC}"
                echo -e "  ${DIM}→ ddev tryout worktree add <name> [<branch>]${NC}"
                echo ""
                return 0
            fi
            # --plain is the machine-readable contract: the padded columns other
            # tools already parse (tests/e2e discovers served sites from it). The
            # default is a real table for humans.
            _wt_rows="$(mktemp "${TMPDIR:-/tmp}/tryout-wt.XXXXXX")"
            {
                printf "NAME,HEAD,BRANCH,STATE,PHP,DB,URL\n"
                list_core_worktrees | while IFS=$'\t' read -r name head branch dirty active; do
                    local php="-" db="-" url="" marker=""
                    if site_is_served "${name}"; then
                        php=$(site_php_version "${name}")
                        db=$(site_database "${name}")
                        url="https://$(site_hostname "${name}")"
                    elif [ -n "${active}" ]; then
                        php="${DDEV_PHP_VERSION:-}"
                        db="db"
                        url="${DDEV_PRIMARY_URL:-}"
                    fi
                    if [ -n "${active}" ]; then marker=" ← primary"; fi
                    printf "%s,%s,%s,%s,%s,%s,%s\n" \
                        "${name}" "${head}" "${branch}" "${dirty}" "${php}" "${db}" \
                        "${url}${marker}"
                done
            } > "${_wt_rows}"

            if [ "${plain}" = "true" ]; then
                # Same shape as before: two leading spaces, padded columns.
                awk -F, '{ printf "  %-12s %-12s %-12s %-6s %-5s %-10s %s\n", \
                             $1,$2,$3,$4,$5,$6,$7 }' "${_wt_rows}"
            else
                ui_table < "${_wt_rows}"
            fi
            rm -f "${_wt_rows}"
            echo ""
            echo -e "  ${DIM}served sites have their own URL, PHP and database;${NC}"
            echo -e "  ${DIM}the primary is whichever worktree 'use' points at${NC}"
            echo ""
            ;;

        use)
            local name="${1:-}" force="false"
            shift || true
            [ "${1:-}" = "--force" ] && force="true"
            [ -n "${name}" ] || { error "Usage: ddev tryout worktree use <name> [--force]"; return 1; }
            migrate_core_to_worktree_layout || return 1
            use_core_worktree "${name}" "${force}" || return 1
            echo ""
            success "Now on Core '${name}' — ${DDEV_PRIMARY_URL:-}"
            ;;

        remove|rm)
            local name="${1:-}" force="false"
            shift || true
            [ "${1:-}" = "--force" ] && force="true"
            [ -n "${name}" ] || { error "Usage: ddev tryout worktree remove <name> [--force]"; return 1; }
            # A served site owns a tree and a DB; drop those before the worktree.
            if site_is_served "${name}" 2>/dev/null; then
                warn "'${name}' is currently served — removing its site first"
                unserve_worktree "${name}" "false" || return 1
            fi
            remove_core_worktree "${name}" "${force}"
            ;;

        serve)
            local name="${1:-}" php=""
            shift || true
            while [ $# -gt 0 ]; do
                case "$1" in
                    --php) php="${2:-}"; shift ;;
                    --php=*) php="${1#--php=}" ;;
                esac
                shift
            done
            [ -n "${name}" ] || { error "Usage: ddev tryout worktree serve <name> [--php 8.2]"; return 1; }
            serve_worktree "${name}" "${php}"
            ;;

        unserve)
            local name="${1:-}" keep_db="true"
            shift || true
            [ "${1:-}" = "--drop-db" ] && keep_db="false"
            [ -n "${name}" ] || { error "Usage: ddev tryout worktree unserve <name> [--drop-db]"; return 1; }
            unserve_worktree "${name}" "${keep_db}"
            ;;

        rename)
            local old="${1:-}" new="${2:-}"
            if [ -z "${old}" ] || [ -z "${new}" ]; then
                error "Usage: ddev tryout worktree rename <old> <new>"
                error "  Renames the checkout only — the branch is untouched."
                return 1
            fi
            rename_core_worktree "${old}" "${new}"
            ;;

        *)
            error "Unknown worktree command: ${sub}"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────
# cs — Contribution setup (Gerrit hooks, template, push URL)
# ─────────────────────────────────────────────────────────────────────
ctr_cs() {
    local sub="${1:-setup}"
    shift || true

    case "${sub}" in
        setup)     cmd_cs_setup "$@" ;;
        doctor)    cmd_cs_doctor ;;
        uninstall) cmd_cs_uninstall ;;
        *)
            error "Unknown cs command: ${sub}"
            return 1
            ;;
    esac
}
