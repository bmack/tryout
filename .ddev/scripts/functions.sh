#!/usr/bin/env bash

# Shared functions for TYPO3 tryout DDEV commands.
# Source this file: source /var/www/html/.ddev/scripts/functions.sh

PROJECT_ROOT="/var/www/html"
CORE_DIR="${PROJECT_ROOT}/typo3-core"
CORE_REPO="https://github.com/typo3/typo3.git"
GERRIT_REMOTE="https://review.typo3.org/Packages/TYPO3.CMS"
GERRIT_API="https://review.typo3.org"
GERRIT_URL="https://review.typo3.org/c/Packages/TYPO3.CMS/+/"

# Resolve the active branch: use TRYOUT_BRANCH env if set, otherwise detect
# from the Core clone, falling back to "main".
if [ -n "${TRYOUT_BRANCH:-}" ]; then
    BRANCH="${TRYOUT_BRANCH}"
elif [ -d "${CORE_DIR}/.git" ]; then
    BRANCH=$(git -C "${CORE_DIR}" branch --show-current 2>/dev/null || echo "main")
else
    BRANCH="main"
fi

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Output helpers ---
info()    { echo -e "${CYAN}==>${NC} $*"; }
success() { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}==>${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

# --- Git helpers ---

ensure_gerrit_remote() {
    if ! git -C "${CORE_DIR}" remote get-url gerrit >/dev/null 2>&1; then
        info "Adding Gerrit remote..."
        git -C "${CORE_DIR}" remote add gerrit "${GERRIT_REMOTE}"
    fi
}

require_core() {
    if [ ! -d "${CORE_DIR}/.git" ]; then
        error "TYPO3 Core not found at typo3-core/"
        error "  → Run: ddev tryout download"
        exit 1
    fi
}

rebuild_typo3() {
    info "Running composer install..."
    composer install --working-dir="${PROJECT_ROOT}" || { error "Composer install failed"; return 1; }
    info "Running extension:setup..."
    vendor/bin/typo3 extension:setup 2>/dev/null || true
    info "Flushing caches..."
    rm -rf var/cache/* 2>/dev/null || true
    vendor/bin/typo3 cache:flush 2>/dev/null || true
    success "Rebuild complete"
}

reset_core_to_main() {
    git -C "${CORE_DIR}" fetch origin
    git -C "${CORE_DIR}" checkout "${BRANCH}" 2>/dev/null || git -C "${CORE_DIR}" checkout -b "${BRANCH}" "origin/${BRANCH}"
    git -C "${CORE_DIR}" reset --hard "origin/${BRANCH}"
    git -C "${CORE_DIR}" clean -fd
    rm -rf var/cache/*
}

# --- Gerrit patch functions ---

# Resolve a Gerrit change number to its latest patchset ref.
# Sets: PATCH_SUBJECT, PATCH_REF, PATCH_NUMBER, PATCH_STATUS
resolve_patch_ref() {
    local change_id="$1"
    local api_url="${GERRIT_API}/changes/${change_id}?o=CURRENT_REVISION"

    local response
    response=$(curl -sf "${api_url}") || {
        error "Failed to fetch change ${change_id} from Gerrit (HTTP error)"
        error "  → Verify: ${GERRIT_URL}${change_id}"
        return 1
    }

    # Strip the Gerrit XSSI prefix )]}'
    local json
    json=$(echo "${response}" | tail -n +2)

    local result
    result=$(echo "${json}" | jq -r '
        .current_revision as $rev |
        .revisions[$rev] as $r |
        (.subject // "No subject" | gsub("\n"; " ") | ltrimstr(" ") | rtrimstr(" ")),
        $r.ref,
        ($r._number | tostring),
        (.status // "UNKNOWN")
    ' 2>/dev/null) || {
        error "Failed to parse Gerrit response for change ${change_id}"
        error "  → Verify: ${GERRIT_URL}${change_id}"
        return 1
    }

    PATCH_SUBJECT=$(echo "${result}" | sed -n '1p')
    PATCH_REF=$(echo "${result}" | sed -n '2p')
    PATCH_NUMBER=$(echo "${result}" | sed -n '3p')
    PATCH_STATUS=$(echo "${result}" | sed -n '4p')
}

# Apply a single patch by change ID.
# Sets PATCH_RESULT to: "applied", "already_applied", "merged", "abandoned", "conflict", or "error"
apply_patch() {
    local change_id="$1"
    PATCH_RESULT="error"

    ensure_gerrit_remote

    info "Resolving change ${change_id}..."
    if ! resolve_patch_ref "${change_id}"; then
        PATCH_RESULT="error"
        return 1
    fi

    echo -e "  ${BOLD}Subject:${NC}  ${PATCH_SUBJECT}"
    echo -e "  ${BOLD}Patchset:${NC} ${PATCH_NUMBER}"
    echo -e "  ${BOLD}Status:${NC}   ${PATCH_STATUS}"

    if [ "${PATCH_STATUS}" = "MERGED" ]; then
        info "Change ${change_id} is already merged — skipping"
        PATCH_RESULT="merged"
        return 0
    fi
    if [ "${PATCH_STATUS}" = "ABANDONED" ]; then
        warn "Change ${change_id} is abandoned — skipping"
        PATCH_RESULT="abandoned"
        return 0
    fi

    info "Fetching from Gerrit..."
    if ! git -C "${CORE_DIR}" fetch gerrit "${PATCH_REF}"; then
        error "Failed to fetch ref ${PATCH_REF} from Gerrit"
        error "  → Verify: ${GERRIT_URL}${change_id}"
        PATCH_RESULT="error"
        return 1
    fi

    # Check if already applied via Change-Id
    local gerrit_change_id
    gerrit_change_id=$(git -C "${CORE_DIR}" log -1 --format=%b FETCH_HEAD | grep '^Change-Id:' | head -1 | awk '{print $2}')
    if [ -n "${gerrit_change_id}" ]; then
        if git -C "${CORE_DIR}" log --format=%b "origin/${BRANCH}..HEAD" | grep -q "^Change-Id: ${gerrit_change_id}$"; then
            info "Change ${change_id} is already applied — skipping"
            PATCH_RESULT="already_applied"
            return 0
        fi
    fi

    info "Cherry-picking change ${change_id}..."
    if git -C "${CORE_DIR}" cherry-pick FETCH_HEAD 2>/dev/null; then
        success "Applied change ${change_id}: ${PATCH_SUBJECT}"
        PATCH_RESULT="applied"
    else
        git -C "${CORE_DIR}" cherry-pick --abort 2>/dev/null || true
        error "Cherry-pick failed for change ${change_id} (merge conflict)"
        error "  Cherry-pick has been aborted automatically."
        error "  → Verify: ${GERRIT_URL}${change_id}"
        PATCH_RESULT="conflict"
        return 1
    fi
}

# Print a summary table of patch results.
# Uses parallel arrays: SUMMARY_IDS, SUMMARY_SUBJECTS, SUMMARY_RESULTS
print_patch_summary() {
    local count=${#SUMMARY_IDS[@]}
    [ "${count}" -eq 0 ] && return

    echo ""
    echo -e "${BOLD}Patch Summary${NC}"
    printf "%-10s %-37s %s\n" "Change" "Subject" "Result"
    printf "%-10s %-37s %s\n" "──────────" "─────────────────────────────────────" "──────────"

    for i in $(seq 0 $((count - 1))); do
        local id="${SUMMARY_IDS[$i]}"
        local subj="${SUMMARY_SUBJECTS[$i]}"
        local result="${SUMMARY_RESULTS[$i]}"

        if [ ${#subj} -gt 35 ]; then
            subj="${subj:0:32}..."
        fi

        local colored_result
        case "${result}" in
            applied)         colored_result="${GREEN}${result}${NC}" ;;
            merged)          colored_result="${CYAN}${result}${NC}" ;;
            already_applied) colored_result="${CYAN}${result}${NC}" ;;
            abandoned)       colored_result="${YELLOW}${result}${NC}" ;;
            conflict)        colored_result="${RED}${result}${NC}" ;;
            *)               colored_result="${RED}${result}${NC}" ;;
        esac

        printf "%-10s %-37s " "${id}" "${subj}"
        echo -e "${colored_result}"
    done
    echo ""
}

# Apply all patches from TRYOUT_PATCHES environment variable.
# Sets PATCHES_APPLIED to the number of patches actually cherry-picked.
apply_all_patches() {
    PATCHES_APPLIED=0
    local patches="${TRYOUT_PATCHES:-}"
    patches=$(echo "${patches}" | tr -d '[:space:]')

    if [ -z "${patches}" ]; then
        info "No patches configured."
        return 0
    fi

    info "Applying patches: ${patches}"
    echo ""

    IFS=',' read -ra PATCH_LIST <<< "${patches}"
    local applied=0
    local skipped=0
    local failed=0

    SUMMARY_IDS=()
    SUMMARY_SUBJECTS=()
    SUMMARY_RESULTS=()

    for patch_id in "${PATCH_LIST[@]}"; do
        patch_id=$(echo "${patch_id}" | tr -d '[:space:]')
        [ -z "${patch_id}" ] && continue

        if apply_patch "${patch_id}"; then
            SUMMARY_IDS+=("${patch_id}")
            SUMMARY_SUBJECTS+=("${PATCH_SUBJECT:-unknown}")
            SUMMARY_RESULTS+=("${PATCH_RESULT}")
            case "${PATCH_RESULT}" in
                applied) applied=$((applied + 1)) ;;
                *)       skipped=$((skipped + 1)) ;;
            esac
        else
            SUMMARY_IDS+=("${patch_id}")
            SUMMARY_SUBJECTS+=("${PATCH_SUBJECT:-unknown}")
            SUMMARY_RESULTS+=("${PATCH_RESULT}")
            failed=$((failed + 1))
            warn "Stopping — remaining patches skipped due to failure."
            break
        fi
        echo ""
    done

    print_patch_summary
    PATCHES_APPLIED=${applied}

    if [ "${failed}" -gt 0 ]; then
        error "${failed} patch(es) failed. ${applied} applied, ${skipped} skipped."
        error "  → Reset and retry: ddev tryout reset"
        return 1
    elif [ "${applied}" -eq 0 ]; then
        info "All ${skipped} patch(es) already applied, merged or abandoned."
    else
        success "${applied} patch(es) applied, ${skipped} skipped."
    fi
}
