#!/usr/bin/env bash
#ddev-generated

# Shared functions for TYPO3 tryout DDEV commands.
# Source this file: source "${DDEV_APPROOT}/.ddev/tryout/functions.sh"

PROJECT_ROOT="${DDEV_APPROOT}"
CORE_DIR="${PROJECT_ROOT}/typo3-core"
CORE_GIT_DIR="${CORE_DIR}/.git"
# shellcheck disable=SC2034 # used by post-start.sh and commands/host/tryout
CORE_REPO="https://github.com/typo3/typo3.git"
GERRIT_REMOTE="https://review.typo3.org/Packages/TYPO3.CMS"
GERRIT_API="https://review.typo3.org"
GERRIT_URL="https://review.typo3.org/c/Packages/TYPO3.CMS/+/"
GERRIT_SSH_HOST="review.typo3.org"
GERRIT_SSH_PORT="29418"
GERRIT_PROJECT="Packages/TYPO3.CMS"
COMMIT_TEMPLATE_SRC="${PROJECT_ROOT}/.ddev/tryout/gitmessage.txt"

# Payload version. `ddev add-on get` copies these files once and never refreshes
# them, so a project installed before a change keeps the old command and the old
# completion script — which still work, but offer the previous feature set. That
# is indistinguishable from a broken install, so the number is stamped into
# .ddev/tryout/.version at install time and cmd_status compares the two.
#
# BUMP THIS whenever a change alters what a user sees: a new verb, a new flag, a
# new completion candidate. It is a plain integer because nothing at install time
# can read git — a local `ddev add-on get <dir>` records no version of its own.
TRYOUT_VERSION=28

# Core worktrees live next to the main clone as typo3-core-<name>; CORE_DIR is a
# symlink to whichever one is active. See `ddev tryout worktree`.
CORE_WORKTREE_PREFIX="${PROJECT_ROOT}/typo3-core-"
DEFAULT_CORE_WORKTREE="main"

# Served sites. The PRIMARY site is the project root (public/, vendor/, config/)
# serving whichever worktree typo3-core points at; every other served worktree gets
# its own tree under sites/<name>/. See `ddev tryout worktree serve`.
SITES_DIR="${PROJECT_ROOT}/sites"
PRIMARY_SITE="@primary"
WORKTREE_CONFIG="${PROJECT_ROOT}/.ddev/config.worktrees.yaml"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
# Ordinary text, stated rather than inherited. Output that carries no colour of
# its own takes the terminal's default foreground, and a herdr popup does not
# inherit the pane's — labels and values came out unreadable there. 37 is the
# basic ANSI white every theme maps to something legible on its own background.
TEXT='\033[37m'
NC='\033[0m'

# --- Output helpers ---
info()    { echo -e "${CYAN}==>${NC} $*"; }
success() { echo -e "${GREEN}==>${NC} $*"; }
warn()    { echo -e "${YELLOW}==>${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

# --- host / container split ---------------------------------------------------
# The work of every container-safe verb runs INSIDE the web container: the host
# command resolves prompts, then hands the verb to tryout-container.sh, which
# exports this flag and sources commands.sh. The helpers below that build, query
# the database or talk to Gerrit are written for the container and call the
# tools directly — never `ddev …`, which is a stub in there. Path helpers, git
# reads and the herdr/ui code run on either side.
in_container() { [ "${TRYOUT_IN_CONTAINER:-}" = "1" ]; }

# A shipped script by name, wherever the payload was installed.
tryout_script() { echo "${PROJECT_ROOT}/.ddev/tryout/$1"; }

# Composer reads COMPOSER=composer.tryout.json from the container environment
# (config.tryout.yaml), exactly as `ddev composer` did.
run_composer() { (cd "${PROJECT_ROOT}" && composer "$@"); }
run_typo3()    { (cd "${PROJECT_ROOT}" && vendor/bin/typo3 "$@"); }

db_is_postgres() { [[ "${DDEV_DATABASE:-mariadb}" == postgres* ]]; }

# One SQL statement as the database superuser, against the db service. DDEV's
# root/root (MariaDB, MySQL) and db/db (Postgres, a superuser there) are reachable
# from the web container by the service name.
db_root_sql() {
    if db_is_postgres; then
        PGPASSWORD=db psql -h db -U db -d postgres -tAc "$1"
    else
        mysql -h db -uroot -proot -e "$1"
    fi
}

# --- gum-backed presentation ------------------------------------------------
# gum (https://github.com/charmbracelet/gum) is OPTIONAL and host-only: the
# container never has it. Everything goes through these wrappers rather than
# calling gum directly, because two of its behaviours have to be handled in ONE
# place:
#
#   1. `gum choose` and friends need a controlling terminal. Without one they
#      print "could not open TTY" AND EXIT 0 — so the exit code lies, and the
#      output is the only reliable signal.
#   2. `gum spin` writes escape sequences when its stdout is not a terminal, so
#      it must never wrap a command whose output is captured.

have_gum() { command -v gum >/dev/null 2>&1; }

# An interactive prompt is always read as `x="$(ui_choose ...)"`, so stdout is a
# pipe by definition — testing it would disable the chooser everywhere. gum draws
# its UI on stderr, so stdin and stderr are what must be terminals.
have_tty() { [ -t 0 ] && [ -t 2 ]; }

# A bordered block. Content on stdin.
ui_box() {
    local title="${1:-}"
    if have_gum; then
        if [ -n "${title}" ]; then
            gum style --border rounded --padding "0 1" --border-foreground 244                 "$(gum style --bold "${title}")" "$(cat)"
        else
            gum style --border rounded --padding "0 1" --border-foreground 244 "$(cat)"
        fi
    else
        [ -n "${title}" ] && echo -e "${BOLD}${title}${NC}"
        cat
    fi
}

# A table. CSV on stdin, first line the header.
ui_table() {
    if have_gum; then
        gum table --print --separator "," 2>/dev/null && return 0
    fi
    # Fallback: readable columns without the borders.
    sed 's/,/	/g' | column -t -s $'	' 2>/dev/null || cat
}

# Pick one of the arguments. Echoes the choice; empty means cancelled.
# NEVER trust gum's exit code here — see the note above.
ui_choose() {
    local prompt="$1"; shift
    [ $# -gt 0 ] || return 1

    if have_gum && have_tty; then
        local picked
        # Never redirect stderr: that is where gum draws the list.
        # `choose`, never `filter` — filter cannot be cancelled with ESC.
        picked="$(printf '%s\n' "$@" | gum choose --header "${prompt}" --height 15)"
        # An empty answer means no TTY or a cancel; either way, nothing was chosen.
        [ -n "${picked}" ] && { printf '%s' "${picked}"; return 0; }
        return 1
    fi

    # A piped answer still works; the prompt is only drawn where it can be seen,
    # or it lands in whatever is capturing this.
    if [ -t 2 ]; then
        printf '  %s\n' "$*" >&2
        printf '  %s: ' "${prompt}" >&2
    fi
    local answer=""
    read -r answer || return 1
    # An arrow key arrives as a full escape sequence (ESC [ B). Dropping the ESC
    # alone would leave a printable "[B" that reads like a typed name.
    answer="$(printf '%s' "${answer}" \
        | sed $'s/\033\[[0-9;]*[A-Za-z]//g; s/\033[NOP]*[A-Za-z]//g' \
        | tr -d '\000-\037')"
    [ -n "${answer}" ] || return 1
    printf '%s' "${answer}"
}

# Pick SEVERAL of the arguments, one per line. Echoes the choices; a cancel or an
# empty pick returns 1. Same two gum rules as ui_choose: its screen is stderr and
# never redirected, and its exit code is not to be trusted — the output is.
ui_choose_multi() {
    local prompt="$1"; shift
    [ $# -gt 0 ] || return 1

    if have_gum && have_tty; then
        local picked
        # Do NOT spell the toggle key out in a prompt: gum draws its own footer
        # ("x toggle • enter submit" in gum 2.0), and a hint of ours would be one
        # more thing to get wrong when gum rebinds it.
        picked="$(printf '%s\n' "$@" \
            | gum choose --no-limit --header "${prompt}" --height 15)"
        [ -n "${picked}" ] && { printf '%s\n' "${picked}"; return 0; }
        return 1
    fi

    # No gum, or no terminal for it: read a line per pick until EOF or a blank.
    if [ -t 2 ]; then
        printf '  %s\n' "$@" >&2
        printf '  %s (one per line, blank to finish): ' "${prompt}" >&2
    fi
    local answer="" got=""
    while IFS= read -r answer; do
        answer="$(printf '%s' "${answer}" | tr -d '\000-\037')"
        [ -n "${answer}" ] || break
        got="${got}${answer}"$'\n'
    done
    [ -n "${got}" ] || return 1
    printf '%s' "${got}"
}

# Free text. Echoes the answer; empty means cancelled.
ui_input() {
    local prompt="$1" placeholder="${2:-}"
    if have_gum && have_tty; then
        local v
        # stderr is gum's screen — see ui_choose.
        v="$(gum input --header "${prompt}" --placeholder "${placeholder}")"
        [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
        return 1
    fi

    if [ -t 2 ]; then printf '  %s: ' "${prompt}" >&2; fi
    local answer=""
    read -r answer || return 1
    [ -n "${answer}" ] || return 1
    printf '%s' "${answer}"
}

# Confirm a destructive action.
#   0 confirmed   1 declined (no, ESC, Ctrl-C)   2 no terminal to ask on
# 1 and 2 must stay apart: callers say "Aborted." for one, "pass --yes" for the
# other. gum conflates them — it exits 1 either way — hence the have_tty gate.
ui_confirm() {
    local prompt="$1"
    have_tty || return 2

    if have_gum; then
        # rc, not `if`: a bare `gum confirm` under `set -e` kills the script.
        local rc=0
        # --default=false, or gum preselects Yes and a bare Enter confirms.
        gum confirm --default=false --affirmative "Yes" --negative "No" "${prompt}" || rc=$?
        [ "${rc}" -eq 0 ] && return 0
        return 1
    fi

    # stderr, not stdout: DDEV pipes a host command's stdout, always.
    printf '  %s [y/N] ' "${prompt}" >&2
    local answer=""
    read -r answer || return 1
    # Strip escape sequences — see ui_choose; a stray "y" in one would confirm.
    answer="$(printf '%s' "${answer}" \
        | sed $'s/\033\[[0-9;]*[A-Za-z]//g; s/\033[NOP]*[A-Za-z]//g' \
        | tr -d '\000-\037')"
    case "${answer}" in [Yy]|[Yy][Ee][Ss]) return 0 ;; esac
    return 1
}

# Run a command behind a spinner, preserving its exit code — the error handling
# throughout this file depends on those codes surviving. Only spins on a terminal:
# piped, gum would emit escape sequences into whatever is reading.
ui_spin() {
    local title="$1"; shift
    # gum draws the spinner on stderr, so that is the stream that must be a
    # terminal. Not stdout: DDEV pipes a host command's stdout, always.
    if have_gum && [ -t 2 ]; then
        gum spin --spinner dot --title "${title}" --show-error -- "$@"
        return $?
    fi
    if [ -t 2 ]; then info "${title}" >&2; fi
    "$@"
}

# --- Guided arguments -------------------------------------------------------
# A command run without its argument asks for it instead of failing — when
# someone is there to answer. Each ask_* helper prints the answer; on a cancel
# or with no terminal it prints nothing and returns 1, so the caller falls
# through to explain_missing, which shows the usage line only where nobody
# could have answered a prompt.

explain_missing() {
    local usage="$1"
    if have_tty; then
        warn "Cancelled"
    else
        error "Usage: ${usage}"
    fi
}

# core_worktree_names [all|nonprimary|served|unserved]
# From the directory glob, not list_core_worktrees: no git status per tree. This is
# the helper for anything that must be instant — completion. The
# picker wants detail instead and uses worktree_labels below.
core_worktree_names() {
    local mode="${1:-all}" d name primary
    primary="$(active_worktree_name 2>/dev/null)"
    for d in "${CORE_WORKTREE_PREFIX}"*; do
        [ -d "${d}" ] || continue
        name="${d#"${CORE_WORKTREE_PREFIX}"}"
        case "${mode}" in
            nonprimary) [ "${name}" = "${primary}" ] && continue ;;
            served)     [ -f "$(site_dir "${name}")/.tryout-site" ] || continue ;;
            unserved)   [ -f "$(site_dir "${name}")/.tryout-site" ] && continue ;;
        esac
        echo "${name}"
    done
}

# One rendered row per worktree, filtered by <mode> exactly as core_worktree_names
# filters: "<name>  <branch>  <head>  <state>  <what it serves>".
#
# This runs a `git status` per worktree, which core_worktree_names deliberately
# avoids — but a picker is opened by hand, once, and a list of bare names does not
# say which branch is which. Never call it from completion.
worktree_labels() {
    local mode="${1:-all}" name head branch dirty active site
    while IFS=$'\t' read -r name head branch dirty active; do
        [ -n "${name}" ] || continue
        case "${mode}" in
            nonprimary) [ -n "${active}" ] && continue ;;
            served)     site_is_served "${name}" || continue ;;
            unserved)   site_is_served "${name}" && continue ;;
        esac
        site=""
        if [ -n "${active}" ]; then
            site="← primary"
        elif site_is_served "${name}"; then
            site="PHP $(site_php_version "${name}")"
        fi
        printf '%s  %s  %s  %s  %s\n' \
            "$(pad_display "${name}" 14)" "$(pad_display "${branch}" 20)" \
            "${head}" "$(pad_display "${dirty}" 5)" "${site}"
    done < <(list_core_worktrees)
}

# Pick a worktree. Shows what each one is; answers with its bare name.
ask_worktree() {
    local prompt="$1" mode="${2:-all}" labels=() l picked
    while IFS= read -r l; do [ -n "${l}" ] && labels+=("${l}"); done < <(worktree_labels "${mode}")
    if [ ${#labels[@]} -eq 0 ]; then
        error "No worktree to choose from"
        error "  → ddev tryout worktree add <name> [<branch>]"
        return 1
    fi
    picked="$(ui_choose "${prompt}" "${labels[@]}")" || return 1
    # Column one is the name, whether the answer is a picked row or a typed name.
    printf '%s' "${picked%% *}"
}

# Pick a site. Echoes the site NAME — the "@primary" sentinel for the primary, so
# callers keep passing what site_is_primary understands — while the list shows a
# readable label: what each site is, on which PHP, at which URL.
#
# extra… are further entries offered verbatim below the sites (delete uses this
# for "--all"); picking one echoes it unchanged.
ask_site() {
    local prompt="$1"; shift
    local names=("${PRIMARY_SITE}") labels=() n i=0
    while IFS= read -r n; do [ -n "${n}" ] && names+=("${n}"); done < <(served_site_names)

    for n in "${names[@]}"; do
        if site_is_primary "${n}"; then
            labels+=("$(printf '%s  %s' "$(pad_display "primary" 12)" "${DDEV_PRIMARY_URL:-}")")
        else
            labels+=("$(printf '%s  https://%s  %s' "$(pad_display "${n}" 12)" \
                "$(site_hostname "${n}")" "PHP $(site_php_version "${n}")")")
        fi
    done
    for n in "$@"; do labels+=("${n}"); done

    local picked
    picked="$(ui_choose "${prompt}" "${labels[@]}")" || return 1

    # Map the label back to the name it stands for; anything extra is itself.
    for i in "${!labels[@]}"; do
        if [ "${labels[${i}]}" = "${picked}" ]; then
            [ "${i}" -lt "${#names[@]}" ] && { printf '%s' "${names[${i}]}"; return 0; }
            printf '%s' "${picked}"; return 0
        fi
    done

    # Not an exact label: either a name typed at the no-gum prompt, or a label
    # whose spacing does not match byte for byte. The first word decides — it is
    # the site name in every label this function builds.
    picked="${picked%% *}"
    [ "${picked}" = "primary" ] && { printf '%s' "${PRIMARY_SITE}"; return 0; }
    printf '%s' "${picked}"
}

# Local refs, ordered by usefulness: main, releases newest first, the pre-9
# TYPO3_x-y refs last. checkout fetches afterwards anyway.
# "<number> - <subject>" for each of the space-separated change numbers in $1,
# looked up in the TSV rows that follow. A number with no row — a hand-typed one —
# still gets a line, just without a subject.
describe_patches() {
    local wanted="$1"; shift
    local id row n s rest
    for id in ${wanted}; do
        s=""
        for row in "$@"; do
            # All the way to `rest`: a two-variable read would put every
            # remaining column into the subject, owner and scores included.
            IFS=$'\t' read -r n s rest <<<"${row}"
            [ "${n}" = "${id}" ] && break
            s=""
        done
        if [ -n "${s}" ]; then
            printf '%s - %s\n' "${id}" "${s}"
        else
            printf '%s\n' "${id}"
        fi
    done
}

# Pad a string to <width> COLUMNS. printf's %-Ns counts bytes, so a name like
# "Frédéric" or a "…" would leave the column short and shift everything after it.
pad_display() {
    local str="$1" width="$2" len
    len=${#str}                       # bash counts characters here, not bytes
    if [ "${len}" -ge "${width}" ]; then
        printf '%s' "${str}"
        return
    fi
    printf '%s%*s' "${str}" "$((width - len))" ""
}

# The open Gerrit changes for a branch, one TSV row each, under a spinner.
# Fails when Gerrit cannot be reached or answers nothing.
#
# The listing is fetched in the container (curl and jq live there); picking from
# it happens on the host, where gum and the terminal are — the host/container
# split in two functions rather than one, because a spinner and an interactive
# chooser cannot share a pipeline.
fetch_open_patches() {
    local branch="${1:-${BRANCH}}" limit="${2:-50}" out=""
    local label="${branch}"
    [ "${label}" = "-" ] && label="every branch"
    out="$(ui_spin "Fetching open changes for ${label}" \
        bash "$(tryout_script list-patches.sh)" "${GERRIT_API}" "${branch}" "${limit}")" || return 1
    [ -n "${out}" ] || return 1
    printf '%s\n' "${out}"
}

# Pick one or several changes. The rows come as arguments, NOT on stdin: without
# gum the chooser reads the answer from stdin, and a function that had consumed
# stdin to build its list would leave nothing for it to read.
#
# Echoes the chosen change numbers, one per line; nothing on a cancel.
pick_patches() {
    local prompt="${1:-Apply which changes?}"; shift
    local row n s o sc labels=()

    # What the user picks from is a rendered line; the number is column one, so
    # it survives the round trip without a second lookup.
    for row in "$@"; do
        [ -n "${row}" ] || continue
        IFS=$'\t' read -r n s o sc <<<"${row}"
        # pad_display, not printf %-Ns: printf counts BYTES, so one accented
        # letter in an owner's name would shift that row's last column.
        labels+=("$(printf '%-7s %s %s %s' "${n}" \
            "$(pad_display "${s}" 68)" "$(pad_display "${o}" 18)" "${sc}")")
    done
    [ ${#labels[@]} -gt 0 ] || return 1

    ui_choose_multi "${prompt}" "${labels[@]}" | awk 'NF {print $1}'
}

# Append change numbers to TRYOUT_PATCHES in the user's patch list, keeping the
# rest of the file — comments included — exactly as it was. Numbers already
# there are not added twice.
persist_patches() {
    local file="${PROJECT_ROOT}/.ddev/config.tryout-patches.yaml"
    [ -f "${file}" ] || {
        error "No patch list at .ddev/config.tryout-patches.yaml"
        return 1
    }
    [ $# -gt 0 ] || return 0

    local current new_list="" n
    current=$(sed -n 's/^ *- *TRYOUT_PATCHES=//p' "${file}" | head -1 | tr -d '[:space:]')
    new_list="${current}"
    for n in "$@"; do
        case ",${new_list}," in
            *",${n},"*) continue ;;     # already listed
        esac
        [ -n "${new_list}" ] && new_list="${new_list},${n}" || new_list="${n}"
    done
    [ "${new_list}" = "${current}" ] && return 0

    # sed -i needs a suffix to work on both BSD and GNU; the backup goes away
    # again immediately.
    sed -i.tryout-bak "s|^\( *- *\)TRYOUT_PATCHES=.*|\1TRYOUT_PATCHES=${new_list}|" "${file}"
    rm -f "${file}.tryout-bak"
    success "Patch list is now: ${new_list}"
}

ask_branch() {
    local prompt="$1" branches=(main) b
    while IFS= read -r b; do
        [ -n "${b}" ] && [ "${b}" != "main" ] && branches+=("${b}")
    done < <(list_local_core_branches | sort -rV | awk '/^[0-9]/{print; next}{l=l $0 "\n"} END{printf "%s", l}')
    ui_choose "${prompt}" "${branches[@]}"
}

ask_text() { ui_input "$1" "${2:-}"; }

# The branch a NEW worktree is based on, resolved into ASKED_BRANCH.
#
# Every creation route asks this, whether or not the name arrived as an argument:
# naming a worktree says nothing about which branch it should sit on, and quietly
# taking ${BRANCH} bases it on whatever Core happens to be checked out.
#
# Three outcomes, and the difference matters:
#   already set  → keep it (an explicit `worktree add x 13.4` is not a question)
#   no terminal  → ${BRANCH}, silently. `ddev start` and scripts must not block.
#   cancelled    → non-zero, so the caller stops. explain_missing says "Cancelled".
#
# The answer lands in a variable rather than on stdout so a caller can tell a cancel
# apart from an empty pick without inspecting $? through a command substitution.
ASKED_BRANCH=""
ask_new_worktree_branch() {
    local usage="${1:-ddev tryout worktree add <name> [<branch>]}"

    [ -n "${ASKED_BRANCH}" ] && return 0
    if ! have_tty; then
        ASKED_BRANCH="${BRANCH}"
        return 0
    fi

    ASKED_BRANCH="$(ask_branch "Based on which branch?")" || {
        ASKED_BRANCH=""
        explain_missing "${usage}"
        return 1
    }
    [ -n "${ASKED_BRANCH}" ] || { explain_missing "${usage}"; return 1; }
}

# In a linked worktree .git is a file pointing at the shared object store, so
# resolve it to the common dir — hooks and config live there, not per worktree.
# Must run before branch detection, which needs a usable git dir.
if [ -f "${CORE_GIT_DIR}" ]; then
    CORE_GIT_DIR="$(git -C "${CORE_DIR}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
        || git -C "${CORE_DIR}" rev-parse --git-common-dir)"

    if [ ! -d "$CORE_GIT_DIR" ]; then
        error "Could not detect valid TYPO3 Git directory, git rev-parse --git-common-dir returned '$CORE_GIT_DIR'"
        exit 1
    fi
fi

# For a detached HEAD, derive the base branch from the remote branches containing
# it. A release branch wins over main: when a commit sits on both, it is the more
# specific answer, and the newest release branch is the likeliest base. Only when
# nothing but main contains it do we say main.
detect_detached_base_branch() {
    local refs found
    # Drop origin/HEAD, which for-each-ref reports as a bare "origin".
    refs=$(git -C "${CORE_DIR}" for-each-ref --format='%(refname:short)' \
               --contains HEAD refs/remotes/origin 2>/dev/null \
           | sed 's|^origin/||' \
           | grep -Ex 'main|[0-9]+\.[0-9]+')

    found=$(echo "${refs}" | grep -Ex '[0-9]+\.[0-9]+' | sort -V | tail -1)
    [ -z "${found}" ] && found=$(echo "${refs}" | grep -Fx main)
    echo "${found:-main}"
}

# Resolve the active branch: use TRYOUT_BRANCH env if set, otherwise detect from
# the Core clone, falling back to "main".
# Note -e, not -d: in a worktree .git is a file. And `branch --show-current`
# exits 0 with empty output on a detached HEAD, so test the value, not $?.
if [ -n "${TRYOUT_BRANCH:-}" ]; then
    BRANCH="${TRYOUT_BRANCH}"
elif [ -e "${CORE_GIT_DIR}" ]; then
    BRANCH=$(git -C "${CORE_DIR}" branch --show-current 2>/dev/null || true)
    [ -z "${BRANCH}" ] && BRANCH="$(detect_detached_base_branch)"
else
    BRANCH="main"
fi

# --- Git helpers ---

ensure_gerrit_remote() {
    if ! git -C "${CORE_DIR}" remote get-url gerrit >/dev/null 2>&1; then
        info "Adding Gerrit remote..."
        git -C "${CORE_DIR}" remote add gerrit "${GERRIT_REMOTE}"
    fi
}

require_core() {
    if [ ! -d "${CORE_GIT_DIR}" ] && [ ! -f "${CORE_GIT_DIR}" ]; then
        error "TYPO3 Core not found at typo3-core/"
        error "  → Run: ddev tryout download"
        exit 1
    fi
}

# Drop a site's vendor/ before Composer installs against a different Core.
#
# Composer loads the plugins already in vendor/ before resolving. Switching Core
# majors changes typo3/class-alias-loader (v2 on main, v1 on 13.4), and the loaded
# v2 plugin then runs its pre-autoload-dump hook against the v1 code it just
# installed: "Class TYPO3\ClassAliasLoader\IncludeFile\SuffixToken not found",
# exit 1, and the site answers 500 until vendor/ is wiped by hand. The lock is
# sync-composer.php's job.
wipe_site_vendor() {
    local name="${1:-${PRIMARY_SITE}}" rel=""
    site_is_primary "${name}" || rel="sites/${name}/"
    info "Removing ${rel}vendor/ — Core changed, a stale install cannot be updated in place"
    rm -rf "$(site_vendor "${name}")" \
        || { error "Could not remove ${rel}vendor/"; return 1; }
}

# Rebuild a site. Called with no argument it targets the primary, exactly as before,
# so the existing call sites keep their behaviour; pass a served site name to rebuild
# that one under its own PHP, composer root and database.
rebuild_typo3() {
    local name="${1:-${PRIMARY_SITE}}"

    if site_is_primary "${name}"; then
        check_php_for_core || return 1
        info "Running composer install..."
        run_composer install || { error "Composer install failed"; return 1; }
        info "Running extension:setup..."
        run_typo3 extension:setup 2>/dev/null || true
        info "Flushing caches..."
        rm -rf "${PROJECT_ROOT}/var/cache"/* 2>/dev/null || true
        run_typo3 cache:flush 2>/dev/null || true
        success "Rebuild complete"
        return
    fi

    local php
    php=$(site_php_version "${name}")
    check_php_for_core "$(site_core_dir "${name}")" "${php}" "${name}" || return 1
    info "Running composer install for '${name}' on PHP ${php}..."
    "php${php}" /usr/local/bin/composer install \
        --working-dir="$(site_dir "${name}")" --no-interaction \
        || { error "Composer install failed for ${name}"; return 1; }
    info "Running extension:setup for '${name}'..."
    site_exec "${name}" vendor/bin/typo3 extension:setup >/dev/null 2>&1 || true
    info "Flushing caches for '${name}'..."
    rm -rf "$(site_dir "${name}")/var/cache"/* 2>/dev/null || true
    site_exec "${name}" vendor/bin/typo3 cache:flush >/dev/null 2>&1 || true
    success "Rebuild complete for '${name}'"
}

reset_core_to_main() {
    git -C "${CORE_DIR}" fetch origin
    # Whatever branch this worktree is on, stay on it and move it to the base's
    # tip. It must NOT try to check out ${BRANCH}: that is the BASE a worktree
    # tracks, and a worktree carries a branch of its own name — so checking out
    # `main` here either collides with the worktree that holds it, or fails
    # outright because the branch already exists. Only a detached checkout, which
    # has no branch to move, resets in place.
    git -C "${CORE_DIR}" reset --hard "origin/${BRANCH}"
    git -C "${CORE_DIR}" clean -fd
    # ${1} names the site whose cache to drop; defaults to the primary's.
    rm -rf "$(site_dir "${1:-${PRIMARY_SITE}}")/var/cache"/* 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────
# Core worktrees
#
# typo3-core is a symlink to the active typo3-core-<name>. Keeping the path
# stable means composer.json's path repository, sync-composer.php and CORE_DIR
# all keep working untouched. Composer resolves the symlink when it writes
# vendor/ links, so a switch MUST be followed by a rebuild — see use_core_worktree.
# ─────────────────────────────────────────────────────────────────────

core_worktree_dir() { echo "${CORE_WORKTREE_PREFIX}$1"; }

# git >= 2.48 can record worktree metadata with RELATIVE paths. That is what lets
# the container (which does the git work) and the host (editors, herdr, the
# completion) share one worktree: an absolute path is right on one side only.
git_supports_relative_worktrees() {
    local v major minor
    v=$(git --version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    [ -n "${v}" ] || return 1
    major="${v%%.*}"; minor="${v#*.}"
    [ "${major}" -gt 2 ] || { [ "${major}" -eq 2 ] && [ "${minor}" -ge 48 ]; }
}

# Configure the Core repo to write relative worktree paths, and rewrite whatever
# is there already. `git worktree repair <path>` re-derives both pointers from the
# worktree's directory name, so it also mends a worktree the other side created
# with absolute paths that do not exist here. Idempotent and cheap; every place
# that clones, migrates or adds a worktree calls it.
ensure_relative_worktree_paths() {
    local main_dir dir
    git_supports_relative_worktrees || return 0
    main_dir=$(main_core_worktree_dir)
    [ -n "${main_dir}" ] || main_dir="${CORE_DIR}"
    [ -e "${main_dir}/.git" ] || return 0
    git -C "${main_dir}" config worktree.useRelativePaths true 2>/dev/null || return 0
    for dir in "${CORE_WORKTREE_PREFIX}"*; do
        [ -d "${dir}" ] || continue
        [ "$(cd "${dir}" && pwd -P)" = "$(cd "${main_dir}" && pwd -P)" ] && continue
        git -C "${main_dir}" worktree repair "${dir}" >/dev/null 2>&1 || true
    done
}

# A name becomes a directory, so keep it strictly harmless (no slashes, no ..).
validate_worktree_name() {
    local name="${1:-}"
    if [ -z "${name}" ]; then
        error "Missing worktree name"
        error "  → ddev tryout worktree add <name> [<branch>]"
        return 1
    fi
    # A leading hyphen is what a mis-parsed flag looks like — `worktree add
    # --herdr` once reached here as a NAME and passed. It is also unusable as a
    # directory, a git branch and a herdr label, so it is never a real name.
    case "${name}" in
        -*) error "Invalid worktree name '${name}' (cannot start with '-')"
            error "  → ddev tryout worktree add <name> [<branch>]"
            return 1 ;;
    esac
    if ! echo "${name}" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        error "Invalid worktree name '${name}' (allowed: letters, digits, . _ -)"
        return 1
    fi
    if [ "${name}" = "." ] || [ "${name}" = ".." ]; then
        error "Invalid worktree name '${name}'"
        return 1
    fi
}

core_is_symlinked() { [ -L "${CORE_DIR}" ]; }

# Name of the active worktree, empty on the legacy plain-clone layout.
# Hand a URL to the desktop's browser. Host-only: the container has no browser,
# and DDEV runs host commands with a real environment, so `open`/`xdg-open` are
# there to be found.
#
# Output goes nowhere: xdg-open is chatty on some desktops and prints straight
# over the line we just wrote. The URL is echoed regardless, so a headless box
# (or a container shell) still leaves the user something to click.
open_url() {
    local url="${1:-}" opener=""
    [ -n "${url}" ] || return 1

    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        darwin*|Darwin) opener="open" ;;
        *)              opener="xdg-open" ;;
    esac

    if [ "${TRYOUT_IN_CONTAINER:-}" != "1" ] && command -v "${opener}" >/dev/null 2>&1; then
        if "${opener}" "${url}" >/dev/null 2>&1; then
            success "Opened ${url}"
            return 0
        fi
    fi

    # No opener, or it refused. Not an error: the URL is the useful part.
    info "Open: ${url}"
}

# The Core worktree a path belongs to, or nothing if it is not in one.
#
# `top` matches only a worktree's own directory — what herdr wants, since a
# workspace sitting in a subdirectory is not that worktree's workspace. The
# default also matches anything INSIDE one, which is what a cwd needs: you run
# `ddev tryout launch` from wherever you happen to be in the checkout.
#
# The path is resolved first: on macOS the project is reached through /var while
# other tools report /private/var, and a plain prefix test would match neither.
worktree_name_for_path() {
    local path="${1:-}" mode="${2:-any}" root real name=""
    [ -n "${path}" ] || return 1
    root="$(cd "${PROJECT_ROOT}" 2>/dev/null && pwd -P)" || return 1
    real="$(cd "${path}" 2>/dev/null && pwd -P)" || return 1

    local rest=""
    case "${real}" in
        "${root}/typo3-core-"*) name="${real#"${root}/typo3-core-"}"
                                rest="${name#*/}"
                                [ "${rest}" = "${name}" ] && rest=""
                                name="${name%%/*}" ;;
        "${root}/typo3-core")   name="$(plain_core_name)" ;;
        "${root}/typo3-core/"*) name="$(plain_core_name)"
                                rest="${real#"${root}/typo3-core/"}" ;;
        *) return 1 ;;
    esac

    # typo3-core-<name>/Build/... is still <name>; only `top` insists on the root.
    [ "${mode}" = "top" ] && [ -n "${rest}" ] && return 1

    [ -n "${name}" ] || return 1
    printf '%s' "${name}"
}

active_worktree_name() {
    core_is_symlinked || return 0
    basename "$(readlink "${CORE_DIR}")" | sed "s|^$(basename "${CORE_WORKTREE_PREFIX}")||"
}

# The worktree that owns the object store; git lists it first. worktree add must
# run against a real worktree, and it can never be removed.
main_core_worktree_dir() {
    git -C "${CORE_DIR}" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print substr($0,10); exit}'
}

core_worktree_is_dirty() {
    local dir="$1"
    ! git -C "${dir}" diff --quiet 2>/dev/null \
        || ! git -C "${dir}" diff --cached --quiet 2>/dev/null
}

# One-time move to the symlink layout: the real clone becomes typo3-core-<branch>
# and typo3-core becomes a symlink to it. Idempotent; never runs unless a
# worktree command asks for it, so existing installs stay untouched.
# The name a plain typo3-core/ clone goes by before there are worktrees: its
# branch, falling back to the default. It is what migrate_core_to_worktree_layout
# renames it to, so anything keyed on it — a herdr workspace label — survives the
# move to the worktree layout. Empty on the symlink layout.
plain_core_name() {
    core_is_symlinked && return 0
    local name
    name=$(git -C "${CORE_DIR}" branch --show-current 2>/dev/null || true)
    [ -z "${name}" ] && name="${DEFAULT_CORE_WORKTREE}"
    validate_worktree_name "${name}" >/dev/null 2>&1 || name="${DEFAULT_CORE_WORKTREE}"
    echo "${name}"
}

migrate_core_to_worktree_layout() {
    core_is_symlinked && return 0

    local name target
    name=$(plain_core_name)
    target=$(core_worktree_dir "${name}")

    if [ -e "${target}" ]; then
        error "Cannot migrate: ${target} already exists"
        error "  → Move it aside, then retry"
        return 1
    fi
    if core_worktree_is_dirty "${CORE_DIR}"; then
        error "TYPO3 Core has uncommitted changes — refusing to migrate"
        error "  → Commit or stash them in typo3-core/, then retry"
        return 1
    fi

    info "Migrating typo3-core/ to the worktree layout..."
    mv "${CORE_DIR}" "${target}"
    ln -sfn "$(basename "${target}")" "${CORE_DIR}"
    ensure_relative_worktree_paths
    success "typo3-core -> $(basename "${target}")"
}

# Create a sibling worktree on a branch of its own, named after the worktree.
#
# Not named after the base: git allows one worktree per branch, so a second
# checkout off main would fail with "'main' is already used by worktree at …".
# The worktree's own name is unique by construction.
#
# --track records the base as the branch's upstream, which is the only place it
# survives: BRANCH is read from `branch --show-current`, and that returns the
# WORKTREE's name here, not the base — so `origin/<name>` does not exist and
# anything that pulls or resets would fail without it. With the upstream set, a
# bare `git rebase` finds the base on its own.
#
# --detach is still available for a throwaway checkout. Gerrit does not care
# either way: pushes go to refs/for/<branch> from HEAD, never from a local
# branch. A branch is for not losing work that has not been pushed yet.
add_core_worktree() {
    local name="$1" branch="${2:-${BRANCH}}" attach="${3:-true}" dir
    validate_worktree_name "${name}" || return 1
    dir=$(core_worktree_dir "${name}")

    if [ -e "${dir}" ]; then
        error "Worktree '${name}' already exists at $(basename "${dir}")"
        error "  → ddev tryout worktree use ${name}"
        return 1
    fi

    # An absolute-path worktree would be unreadable on the other side of the
    # container boundary; refuse rather than create one.
    if ! git_supports_relative_worktrees; then
        error "git $(git --version 2>/dev/null | awk '{print $3}') cannot write relative worktree paths (needs 2.48+)"
        error "  → ddev restart   (rebuilds the web image with the add-on's git)"
        return 1
    fi

    local main_dir
    main_dir=$(main_core_worktree_dir)
    [ -z "${main_dir}" ] && main_dir="${CORE_DIR}"
    ensure_relative_worktree_paths

    info "Fetching origin..."
    git -C "${main_dir}" fetch origin || { error "Fetch failed"; return 1; }

    if ! git -C "${main_dir}" rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
        error "Branch '${branch}' does not exist on origin"
        error "  → ddev tryout checkout   (lists available branches)"
        return 1
    fi

    info "Creating worktree '${name}' at origin/${branch}..."
    if [ "${attach}" = "true" ]; then
        # A name already taken would be silently reset by -B, losing whatever it
        # pointed at.
        if git -C "${main_dir}" show-ref -q --verify "refs/heads/${name}"; then
            error "A branch '${name}' already exists"
            # Say WHICH case this is, but change nothing: a command that failed
            # must not quietly delete a ref on the way out. A branch left over
            # from a removed worktree looks like nothing at all — the folder is
            # gone — so the bare message sends people hunting for a directory that
            # is not there. Name the one command that clears it.
            if [ ! -d "${dir}" ]; then
                error "  (its worktree is gone; the branch outlived it)"
                if git -C "${main_dir}" merge-base --is-ancestor \
                     "refs/heads/${name}" "origin/${branch}" 2>/dev/null; then
                    error "  → nothing unmerged on it: git -C ${main_dir} branch -d ${name}"
                else
                    error "  → it has unmerged commits: git -C ${main_dir} branch -D ${name}"
                fi
            fi
            error "  → ddev tryout worktree add ${name}-2 ${branch}"
            error "  → or: ddev tryout worktree use ${name}   (if it is already a worktree)"
            return 1
        fi
        git -C "${main_dir}" worktree add -B "${name}" --track \
            "${dir}" "origin/${branch}" || return 1
    else
        git -C "${main_dir}" worktree add --detach "${dir}" "origin/${branch}" || return 1
    fi
    success "Worktree '${name}' created"
}

set_active_core() {
    ln -sfn "$(basename "$(core_worktree_dir "$1")")" "${CORE_DIR}"
}

# Switch the active Core. The rebuild is mandatory, never optional: Composer
# binds vendor/ to the resolved real path, so without it the site silently keeps
# serving the previous Core.
use_core_worktree() {
    local name="$1" force="${2:-false}" dir
    validate_worktree_name "${name}" || return 1
    dir=$(core_worktree_dir "${name}")

    if [ ! -d "${dir}" ]; then
        error "No worktree '${name}'"
        error "  → ddev tryout worktree list"
        return 1
    fi

    local active
    active=$(active_worktree_name)
    if [ "${active}" = "${name}" ]; then
        info "'${name}' is already active — rebuilding anyway"
    elif [ -n "${active}" ] && [ "${force}" != "true" ] \
         && core_worktree_is_dirty "$(core_worktree_dir "${active}")"; then
        error "Active worktree '${active}' has uncommitted changes"
        error "  Switching would hide them from typo3-core/."
        error "  → Commit or stash them, or: ddev tryout worktree use ${name} --force"
        return 1
    fi

    set_active_core "${name}"
    success "Active Core: ${name}"

    # Sysext sets differ between versions, so regenerate before installing.
    info "Syncing composer.tryout.json..."
    php "$(tryout_script sync-composer.php)" || warn "composer sync had warnings"
    wipe_site_vendor || return 1
    rebuild_typo3
}

remove_core_worktree() {
    local name="$1" force="${2:-false}" dir
    validate_worktree_name "${name}" || return 1
    dir=$(core_worktree_dir "${name}")

    if [ ! -d "${dir}" ]; then
        error "No worktree '${name}'"
        return 1
    fi
    if [ "$(active_worktree_name)" = "${name}" ]; then
        error "Cannot remove the active worktree '${name}'"
        error "  → ddev tryout worktree use <other>   first"
        return 1
    fi

    local main_dir
    main_dir=$(main_core_worktree_dir)
    if [ "${dir}" = "${main_dir}" ]; then
        error "Cannot remove '${name}': it owns the shared git object store"
        return 1
    fi

    # --force twice, deliberately. A Core checkout always carries untracked and
    # ignored files — vendor/, var/, Build/ — and plain `git worktree remove`
    # refuses outright on any of them ("contains modified or untracked files"),
    # leaving the directory behind after saying it removed the worktree. The user
    # has already been asked on the host, and the question named the directory, so
    # the answer must actually take it. A second --force also drops a worktree
    # whose branch is not merged.
    local args=("worktree" "remove" "--force")
    [ "${force}" = "true" ] && args+=("--force")
    if ! git -C "${CORE_DIR}" "${args[@]}" "${dir}"; then
        error "Failed to remove worktree '${name}'"
        error "  → git -C ${CORE_DIR} worktree remove --force ${dir}"
        return 1
    fi
    git -C "${CORE_DIR}" worktree prune 2>/dev/null || true

    # git leaves the directory when anything in it was not its own to delete — a
    # root-owned file a container wrote, say. The worktree is deregistered by now,
    # so what is left is a plain directory nothing refers to: take it, or the next
    # `worktree add <same name>` fails on a path that already exists.
    if [ -d "${dir}" ]; then
        rm -rf "${dir}" 2>/dev/null || true
        [ -d "${dir}" ] && warn "Could not delete ${dir} — remove it by hand"
    fi

    # The branch outlives the worktree, and add_core_worktree refuses a name whose
    # branch already exists — so leaving it behind blocks re-creating a worktree of
    # the same name, with an error about a branch the user never thinks about
    # ("A branch 'jochen' already exists" after the folder is plainly gone).
    #
    # `git branch -d`, never -D unless asked: git itself refuses to delete a branch
    # holding work that is not merged, which is precisely the check that keeps an
    # unpushed commit from disappearing with the checkout. So a spent branch goes
    # quietly, and one with work on it stays and says why.
    local main_dir_b
    main_dir_b=$(main_core_worktree_dir)
    [ -z "${main_dir_b}" ] && main_dir_b="${CORE_DIR}"
    if git -C "${main_dir_b}" show-ref -q --verify "refs/heads/${name}"; then
        local del="-d"
        [ "${force}" = "true" ] && del="-D"
        if git -C "${main_dir_b}" branch "${del}" "${name}" >/dev/null 2>&1; then
            success "Removed worktree '${name}', its directory and its branch"
            return 0
        fi
        warn "Branch '${name}' kept — it has commits that are not merged"
        echo -e "  ${DIM}→ ddev tryout worktree remove ${name} --force   (delete it too)${NC}"
        echo -e "  ${DIM}→ or: git -C ${main_dir_b} branch -D ${name}${NC}"
    fi
    success "Removed worktree '${name}' and its directory"
}

# Give a worktree a different directory name. The BRANCH is never touched: a name
# derived from a branch — which is all herdr's own New-worktree action can give us —
# is a starting point, not a commitment.
#
# The name reaches further than the checkout, so all of it moves together: the
# typo3-core symlink when this is the active worktree, and a served site's tree,
# vhost and database name.
rename_core_worktree() {
    local old="$1" new="$2" old_dir new_dir was_active="false" was_served="false" php=""
    validate_worktree_name "${old}" || return 1
    validate_worktree_name "${new}" || return 1
    [ "${old}" = "${new}" ] && { info "'${old}' is already called that"; return 0; }

    old_dir="$(core_worktree_dir "${old}")"
    new_dir="$(core_worktree_dir "${new}")"

    [ -d "${old_dir}" ] || { error "No worktree '${old}'"; return 1; }
    [ -e "${new_dir}" ] && { error "'${new}' already exists"; return 1; }

    [ "$(active_worktree_name)" = "${old}" ] && was_active="true"
    if site_is_served "${old}" 2>/dev/null; then
        was_served="true"
        php="$(site_php_version "${old}")"
    fi

    # A served site owns a database and a vhost keyed on the old name. Drop the site
    # first — keeping its database — then rebuild it under the new one.
    if [ "${was_served}" = "true" ]; then
        info "Unserving '${old}' so it can be re-served as '${new}'..."
        unserve_worktree "${old}" "true" >/dev/null 2>&1 || true
    fi

    # git worktree move, never mv: it rewrites the metadata on both sides.
    if ! git -C "${old_dir}" worktree move "${old_dir}" "${new_dir}" 2>/dev/null; then
        error "Could not move ${old_dir} (uncommitted changes, or it is locked?)"
        return 1
    fi

    [ "${was_active}" = "true" ] && set_active_core "${new}"
    success "Renamed worktree '${old}' to '${new}'"

    if [ "${was_served}" = "true" ]; then
        info "Re-serving as '${new}' on PHP ${php}..."
        # The hostname changes with the name, so DDEV has to register the new one —
        # and drop the old, which it only does on a restart.
        serve_worktree "${new}" "${php}" || {
            error "The worktree was renamed, but re-serving failed"
            error "  → ddev tryout worktree serve ${new}"
            return 1
        }
    fi
}

# Emit "name<TAB>head<TAB>branch<TAB>dirty<TAB>active" per worktree.
# Same rows as list_core_worktrees, minus the dirty column — and minus the two
# `git diff` calls per worktree that produce it. A TYPO3 Core checkout is ~20k
# tracked files, so on a Mutagen project that check costs seconds per worktree
# cold; anything that does not PRINT the answer must not pay for it.
#
# Deliberately a separate function rather than a flag: the caller's choice is
# visible at the call site, and the field list differs, so a positional reader
# cannot silently shift a column.
list_core_worktrees_fast() {
    local active dir name head branch
    active=$(active_worktree_name)
    for dir in "${CORE_WORKTREE_PREFIX}"*; do
        [ -d "${dir}" ] || continue
        name="${dir#"${CORE_WORKTREE_PREFIX}"}"
        head=$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        branch=$(git -C "${dir}" branch --show-current 2>/dev/null || true)
        [ -z "${branch}" ] && branch="(detached)"
        printf '%s\t%s\t%s\t%s\n' "${name}" "${head}" "${branch}" \
            "$([ "${name}" = "${active}" ] && echo active || echo "")"
    done
}

# With the dirty column, and the per-worktree cost that comes with it. For
# `worktree list`, which prints it — see list_core_worktrees_fast for the rest.
list_core_worktrees() {
    local active dir name head branch dirty
    active=$(active_worktree_name)
    for dir in "${CORE_WORKTREE_PREFIX}"*; do
        [ -d "${dir}" ] || continue
        name="${dir#"${CORE_WORKTREE_PREFIX}"}"
        head=$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        branch=$(git -C "${dir}" branch --show-current 2>/dev/null || true)
        [ -z "${branch}" ] && branch="(detached)"
        dirty="clean"
        core_worktree_is_dirty "${dir}" && dirty="dirty"
        printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${head}" "${branch}" "${dirty}" \
            "$([ "${name}" = "${active}" ] && echo active || echo "")"
    done
}

# Branch names on origin, one per line, version-sorted. The remote form asks
# origin and so needs the network; the local form reads refs already fetched,
# which is what tab-completion uses so a TAB never blocks.
list_remote_core_branches() {
    git -C "${CORE_DIR}" ls-remote --heads origin 2>/dev/null \
        | awk -F/ '{print $NF}' \
        | sort -V
}

list_local_core_branches() {
    git -C "${CORE_DIR}" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin 2>/dev/null \
        | grep -vx 'HEAD' \
        | sort -V
}

# --- herdr integration -----------------------------------------------------
# herdr (https://herdr.dev) is a terminal multiplexer built around coding agents.
# It is an OPTIONAL host tool: the add-on never installs it, and nothing else here
# depends on it. `ddev tryout herdr` opens one workspace per Core worktree.

# This project's own herdr session, so Core worktrees never land among the user's
# everyday workspaces. Session names accept dots and uppercase, so the DDEV project
# name goes in verbatim.
herdr_session_name() {
    # DDEV only exports DDEV_SITENAME to commands it runs itself. The herdr popups
    # are launched by herdr, not ddev, so fall back to the project config — without
    # this they resolve to the session "tryout" and talk to a server that is not
    # there.
    local name="${DDEV_SITENAME:-}"
    if [ -z "${name}" ] && [ -f "${PROJECT_ROOT}/.ddev/config.yaml" ]; then
        name="$(sed -n 's/^name: *//p' "${PROJECT_ROOT}/.ddev/config.yaml" 2>/dev/null \
                | head -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
    fi
    [ -n "${name}" ] && { echo "tryout-${name}"; return; }
    echo "tryout"
}

# Every herdr call goes through here. `--session` MUST precede the subcommand: put it
# after and herdr SILENTLY IGNORES it and talks to the default session instead.
# (HERDR_SESSION is no good either — it reports the right name but resolves the
# default socket.)
herdr_cli() { herdr --session "$(herdr_session_name)" "$@"; }

# The binary and the JSON parser we need. Not a check for a running server: we start
# one ourselves. Deliberately NOT gated on HERDR_ENV either — the herdr CLI talks to
# a socket, not to the calling pane, and a DDEV host command never runs inside one.
# Install hints worth reading: name the tool, why it is needed, and the command for
# the platform actually in use rather than a list to pick from.
missing_tool() {
    local tool="$1" why="$2" brew="$3" apt="$4" docs="$5"
    error "${tool} is not installed on the host"
    error "  ${why}"
    # uname may be missing from a stripped PATH; fall back to bash's own OSTYPE.
    local os="${OSTYPE:-}"
    command -v uname >/dev/null 2>&1 && os="$(uname -s)"
    case "${os}" in
        Darwin|darwin*)
            error "  → brew install ${brew}"
            ;;
        Linux|linux*)
            if command -v apt-get >/dev/null 2>&1; then
                error "  → sudo apt-get install ${apt}"
            elif command -v dnf >/dev/null 2>&1; then
                error "  → sudo dnf install ${apt}"
            elif command -v pacman >/dev/null 2>&1; then
                error "  → sudo pacman -S ${apt}"
            else
                error "  → install '${apt}' with your package manager"
            fi
            ;;
    esac
    [ -n "${docs}" ] && error "  ${DIM}${docs}${NC}"
    return 1
}

herdr_available() {
    if ! command -v herdr >/dev/null 2>&1; then
        error "herdr is not installed on the host"
        error "  'ddev tryout herdr' opens your Core worktrees in it."
        # Homebrew carries it; no Linux distro packages it, so the installer is the
        # honest answer there rather than an apt-get line that would fail.
        case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
            darwin*|Darwin) error "  → brew install herdr" ;;
        esac
        error "  → curl -fsSL https://herdr.dev/install.sh | sh"
        error "  ${DIM}https://herdr.dev/docs/install/${NC}"
        return 1
    fi
    # Control commands answer in JSON; we parse IDs out rather than predict them.
    if ! command -v jq >/dev/null 2>&1; then
        missing_tool "jq" \
            "herdr answers in JSON and its replies have to be parsed." \
            "jq" "jq" "https://jqlang.github.io/jq/download/"
        return 1
    fi
}

# Drop the user into their session. A DDEV host command has no stdin/stdout tty of
# its own, but /dev/tty still reaches the real terminal, so herdr can take it over —
# this is what makes `ddev tryout herdr` land you in the session rather than printing
# a command to copy. Two cases cannot attach:
#   - no controlling terminal (a script, CI, an editor task runner)
#   - already inside herdr, which refuses to nest
# Both fall back to printing the command, so nothing is lost.
attach_herdr_session() {
    local session
    session="$(herdr_session_name)"

    if [ "${HERDR_ENV:-}" = "1" ]; then
        info "  ${DIM}→ already in herdr; switch to '${session}' or: herdr session attach ${session}${NC}"
        return 0
    fi

    if [ ! -e /dev/tty ] || ! { : < /dev/tty; } 2>/dev/null; then
        info "  ${DIM}→ herdr session attach ${session}${NC}"
        return 0
    fi

    info "Attaching to '${session}'..."
    # Deliberately NOT herdr_cli: `session attach` takes the session as its argument,
    # and this call must own the real terminal. Every other call goes through the
    # wrapper; a unit test allows this one line by name.
    herdr session attach "${session}" < /dev/tty > /dev/tty 2>&1
}

# Start this project's session unless it is already up. A server spawned here
# outlives the command, which is what makes `ddev tryout herdr` usable at all: a DDEV
# host command has no TTY, so it can never host the session itself.
ensure_herdr_session() {
    herdr_cli status server --json 2>/dev/null | grep -q '"running":true' && return 0

    info "Starting herdr session '$(herdr_session_name)'..."
    nohup herdr --session "$(herdr_session_name)" server >/dev/null 2>&1 &
    disown 2>/dev/null || true

    # Poll rather than sleep blindly: the server answers in ~30ms, and a successful
    # status check is a reliable gate for real work.
    local i
    for i in $(seq 1 50); do
        herdr_cli status server --json 2>/dev/null | grep -q '"running":true' && return 0
        sleep 0.1
    done

    error "herdr session '$(herdr_session_name)' did not start"
    return 1
}

# Worktree names allow uppercase and dots (see validate_worktree_name); herdr
# agent names must match [a-z][a-z0-9_-]{0,31}. Map one onto the other.
herdr_agent_name() {
    printf '%s' "${1:-}" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9_-]/-/g' -e 's/^[^a-z]/x&/' \
        | cut -c1-32
}

# Where a checkout name lives: typo3-core-<name> on the worktree layout, and the
# plain typo3-core/ clone itself when that is all a fresh project has yet.
herdr_checkout_dir() {
    local name="$1"
    if ! core_is_symlinked && [ "${name}" = "$(plain_core_name)" ]; then
        echo "${CORE_DIR}"
    else
        core_worktree_dir "${name}"
    fi
}

# True when any pane anywhere is already sitting in that worktree, which is what
# makes `ddev tryout herdr` safe to re-run. Deliberately NOT scoped to the current
# workspace: each worktree gets its own, so a scoped query would never find them.
# Keyed on the pane cwd rather than the label, which a user can rename by hand.
herdr_worktree_is_open() {
    local dir="$1"
    herdr_cli pane list 2>/dev/null \
        | jq -e --arg d "${dir}" \
            '[.result.panes[]? | select(.cwd == $d)] | length > 0' >/dev/null 2>&1
}

# Workspace labels live in one global sidebar alongside every other project, so a
# bare worktree name would be ambiguous there.
herdr_workspace_label() { echo "core-${1}"; }

# Show a worktree's branch under its space in the herdr sidebar.
#
# herdr's OWN `branch` row is computed server-side from the workspace's repo_root,
# which for a linked worktree points at the origin clone — so it renders only for
# the one checkout that owns the repo, and the value is not on the API's worktree
# struct to correct. A custom token is the way in: it is addressed as $wt_branch
# and renders wherever the sidebar config names it. See the README for the row.
#
# "detached" rather than nothing when there is no branch: an empty token makes the
# row vanish, and half the worktrees in a typical project are detached.
set_workspace_branch_token() {
    local ws="${1:-}" name="${2:-}" dir b
    [ -n "${ws}" ] && [ -n "${name}" ] || return 0
    dir="$(core_worktree_dir "${name}")"
    [ -d "${dir}" ] || return 0

    b="$(git -C "${dir}" symbolic-ref --short -q HEAD 2>/dev/null)" || b=""
    [ -n "${b}" ] || b="detached"

    herdr_cli workspace report-metadata "${ws}" --source tryout \
        --token "wt_branch=${b}" >/dev/null 2>&1 || true
    return 0
}

# Workspace id for a worktree's workspace, empty when it is not open.
# Does this workspace already run an agent anywhere in it?
herdr_workspace_has_agent() {
    herdr_cli pane list 2>/dev/null \
        | jq -e --arg w "$1" \
            '[.result.panes[]? | select(.workspace_id == $w and .agent != null)] | length > 0' \
            >/dev/null 2>&1
}

# The pane an agent belongs in: the one sitting in the worktree, not the panel
# docked beside it — which is in the project root and would run claude in the
# wrong directory.
herdr_workspace_agent_pane() {
    local ws="$1" dir="$2"
    herdr_cli pane list 2>/dev/null \
        | jq -r --arg w "${ws}" --arg d "${dir}" --arg l "${PANEL_PANE_LABEL}" \
            'first(.result.panes[]? | select(.workspace_id == $w and .cwd == $d
                                             and (.label // "") != $l) | .pane_id) // empty' \
            2>/dev/null
}

# A workspace's current label.
herdr_workspace_label_of() {
    herdr_cli workspace list 2>/dev/null \
        | jq -r --arg w "$1" \
            'first(.result.workspaces[]? | select(.workspace_id == $w) | .label) // empty' 2>/dev/null
}

# Workspace id for whichever workspace holds a pane in this directory, empty when
# none does. Unlike herdr_workspace_id this does NOT go through the label — which
# matters precisely when the label is the thing that is wrong, as on a workspace
# opened before the core-<name> scheme existed.
herdr_workspace_id_for_dir() {
    local dir="$1"
    herdr_cli pane list 2>/dev/null \
        | jq -r --arg d "${dir}" \
            'first(.result.panes[]? | select(.cwd == $d) | .workspace_id) // empty' 2>/dev/null
}

herdr_workspace_id() {
    herdr_cli workspace list 2>/dev/null \
        | jq -r --arg l "$(herdr_workspace_label "${1}")" \
            '.result.workspaces[]? | select(.label == $l) | .workspace_id' 2>/dev/null \
        | head -1
}

# The tab holding a plain shell, beside the agent's own. herdr labels the first
# tab "1", which says nothing about what is in it.
TERMINAL_TAB_LABEL="Terminal"

# Give a workspace its Terminal tab unless it already has one. Idempotent, because
# both routes call it: a freshly opened workspace, and the reconcile pass over
# workspaces opened before this existed.
# Name a workspace's first tab for what it holds. herdr calls it "1", which says
# nothing; an agent pane in it earns "Claude", anything else is a plain "Shell".
# Only ever renames the default "1", so a name the user chose is left alone.
ensure_first_tab_label() {
    local ws="$1" first agent
    [ -n "${ws}" ] || return 0

    # "1" is herdr's own name for an unnamed tab, but "Shell" is OURS — set when
    # the workspace had no agent — and an agent starting later must be allowed to
    # correct it. Any other label is the user's and is left alone.
    first=$(herdr_cli tab list --workspace "${ws}" 2>/dev/null \
        | jq -r '.result.tabs[0]? | select(.label == "1" or .label == "Shell" or .label == "Claude")
                 | .tab_id // empty' 2>/dev/null)
    [ -n "${first}" ] || return 0

    # An agent anywhere in the workspace means the first tab is the one running it:
    # the Terminal tab is created without one.
    agent=$(herdr_cli pane list 2>/dev/null \
        | jq -r --arg w "${ws}" \
            '[.result.panes[]? | select(.workspace_id == $w and .agent != null)] | length' 2>/dev/null)
    if [ "${agent:-0}" = "0" ]; then
        herdr_cli tab rename "${first}" "Shell" >/dev/null 2>&1 || return 1
    else
        herdr_cli tab rename "${first}" "Claude" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# The pane running the command panel, beside the Terminal tab's shell.
PANEL_PANE_LABEL="tryout"
# How much of the split the SHELL keeps; the panel gets the rest. herdr clamps to
# 0.1-0.9. Both routes that dock a panel must use it, or they look different.
PANEL_DOCK_RATIO="0.78"

# What a worktree is, which decides what can be done to it:
#   primary        it IS the project's site
#   served         it has a site, URL and database of its own
#   checkout-only  a checkout and nothing more — most worktrees, most of the time
# Site-scoped verbs (checkout, reset, patch) need one of the first two; offering
# them on the third would mean a command that fails, or silently hits the primary.
core_worktree_state() {
    local name="$1"
    [ -n "${name}" ] || { echo "checkout-only"; return 0; }
    if [ "${name}" = "$(active_worktree_name)" ]; then
        echo "primary"
    elif site_is_served "${name}"; then
        echo "served"
    else
        echo "checkout-only"
    fi
}

# Dock the panel in a workspace's Terminal tab, unless it is already there.
# Deliberately that tab and not the agent's: the panel would take width from
# claude in every workspace, which is the clutter it exists to avoid.
# Is this pane actually running the panel, or is it a shell wearing its label?
#
# `pane process-info` answers for ANY live pane, a bare shell included, so it can
# only spot a pane whose process is GONE — never one running the wrong thing. A
# panel closed with q or esc drops back to its shell and keeps the label, and that
# read as healthy: seven of eight panels sat like that with every re-run of
# `ddev tryout herdr` reporting success.
#
# The terminal title is what tells them apart. herdr reports the running command
# there, so a live panel's title names the script and a shell's is a prompt.
panel_pane_is_running() {
    local id="${1:-}"
    [ -n "${id}" ] || return 1
    herdr_cli pane list 2>/dev/null \
        | jq -e --arg p "${id}" \
            '[.result.panes[]? | select(.pane_id == $p)
              | (.terminal_title // "") | test("herdr-panel")] | any' \
            >/dev/null 2>&1
}

ensure_panel_pane() {
    local ws="$1" dir="$2" name="$3" has tab_pane
    [ -n "${ws}" ] || return 0

    # The agent's tab is what gets split: the panel drives the worktree the agent
    # is working in, so it belongs where you are already looking.
    local tab; tab="$(herdr_agent_tab_id "${ws}")"
    [ -n "${tab}" ] || return 1

    # The pane to split is the agent's own, never a panel already sitting there:
    # splitting the panel would nest one inside the other. Its label is the only
    # thing that tells them apart.
    tab_pane=$(herdr_cli pane list 2>/dev/null \
        | jq -r --arg w "${ws}" --arg t "${tab}" --arg l "${PANEL_PANE_LABEL}" \
            '[.result.panes[]? | select(.workspace_id == $w and .tab_id == $t
                                        and (.label // "") != $l)][0].pane_id // empty' 2>/dev/null)
    [ -n "${tab_pane}" ] || return 1

    local existing existing_tab
    existing=$(herdr_cli pane list 2>/dev/null \
        | jq -r --arg w "${ws}" --arg l "${PANEL_PANE_LABEL}" \
            '.result.panes[]? | select(.workspace_id == $w and .label == $l) | .pane_id' \
            2>/dev/null | head -1)
    if [ -n "${existing}" ]; then
        if panel_pane_is_running "${existing}"; then
            # Alive. A panel docked before this one sits in the Terminal tab, so
            # move it rather than close and redock: closing would kill a running
            # panel and flash the pane for nothing.
            existing_tab=$(herdr_cli pane list 2>/dev/null \
                | jq -r --arg p "${existing}" \
                    '.result.panes[]? | select(.pane_id == $p) | .tab_id' 2>/dev/null | head -1)
            if [ -n "${existing_tab}" ] && [ "${existing_tab}" != "${tab}" ]; then
                # --no-focus, as the split below: a reconcile pass must not yank
                # focus off the agent onto a panel the user did not ask for.
                herdr_cli pane move "${existing}" --tab "${tab}" --split right \
                    --target-pane "${tab_pane}" --ratio "${PANEL_DOCK_RATIO}" \
                    --no-focus >/dev/null 2>&1 || true
            fi
            return 0
        fi
        # Not running the panel: a corpse from a herdr server restart, or a shell
        # left behind by q/esc. Either way the label lies, so close it and let the
        # code below dock a real one. A panel closed on purpose therefore comes
        # back on the next run — to be rid of it, close the pane, not the panel.
        herdr_cli pane close "${existing}" >/dev/null 2>&1 || true
    fi

    # An install predating the panel has no script to run.
    local script; script="$(tryout_script herdr-panel.sh)"
    [ -f "${script}" ] || return 0

    # The panel runs outside DDEV, so it cannot source this file: it is handed the
    # three things it would otherwise have to guess. The session especially —
    # without it a bare `herdr` in the panel means the DEFAULT session, not the
    # tryout-<project> one these workspaces live in.
    local new
    # Same geometry and same working directory as `ddev tryout panel`, or the two
    # routes hand you visibly different panels. 0.78 leaves the panel the narrow
    # right-hand strip; the agent beside it keeps the room. The project root, not
    # the worktree, because the popup's manifest command is a relative path that
    # herdr resolves against this cwd — see run_selected.
    new=$(herdr_cli pane split "${tab_pane}" --direction right --ratio "${PANEL_DOCK_RATIO}" \
            --no-focus --cwd "${PROJECT_ROOT}" \
            --env "TRYOUT_PANEL_WORKTREE=${name}" \
            --env "TRYOUT_PANEL_APPROOT=${PROJECT_ROOT}" \
            --env "TRYOUT_PANEL_SESSION=$(herdr_session_name)" 2>/dev/null \
          | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
    [ -n "${new}" ] || return 1

    herdr_cli pane rename "${new}" "${PANEL_PANE_LABEL}" >/dev/null 2>&1 || true

    # `pane run` types the command into the pane's shell, and `pane split` answers
    # before that shell has reached its prompt — so a first attempt can be typed
    # into nothing and lost, leaving a pane that is labelled but bare. Same race
    # start_agent_in_pane retries for. herdr answering ok proves only that it
    # delivered the keystrokes, so confirm the panel is really up before believing
    # it, and say so if it never comes.
    #
    # WAIT before concluding it did not start. `pane run` answers in ~17ms, but the
    # pane's terminal title — all panel_pane_is_running has to go on — takes ~700ms
    # to appear. Checking straight after the call therefore failed every single
    # time, however well the panel had started, and the "retry" then typed the
    # command AT A LIVE PANEL. Those keystrokes end in a newline, the panel's
    # `read -rsn1` returns that as empty, and its loop reads empty as Enter — so it
    # ran whatever row was selected, which on a fresh panel is row 0: `status`.
    # That is the bug this loop caused; re-running at a running panel is never
    # harmless, so the poll below has to lose before another `pane run` may fire.
    local attempt=0 waited
    while :; do
        herdr_cli pane run "${new}" bash "${script}" >/dev/null 2>&1 || true
        # ~700ms is the measured norm; six whole seconds is slack for a loaded
        # machine. Whole-second sleeps only: a fractional one is not portable and
        # this runs on the host.
        waited=0
        while [ "${waited}" -lt 6 ]; do
            sleep 1
            waited=$((waited + 1))
            panel_pane_is_running "${new}" && return 0
        done
        attempt=$((attempt + 1))
        [ "${attempt}" -ge 3 ] && break
    done
    return 1
}

# The Terminal tab of a workspace, empty when it has none yet.
herdr_terminal_tab_id() {
    herdr_cli tab list --workspace "${1}" 2>/dev/null \
        | jq -r --arg l "${TERMINAL_TAB_LABEL}" \
            '.result.tabs[]? | select(.label == $l) | .tab_id' 2>/dev/null | head -1
}

# The agent's tab: the workspace's FIRST, whatever it is called. ensure_first_tab_label
# names it "Claude" or "Shell" depending on what is in it, and a user may rename it
# again — so the position is the reliable key, not the label.
herdr_agent_tab_id() {
    herdr_cli tab list --workspace "${1}" 2>/dev/null \
        | jq -r '.result.tabs[0]?.tab_id // empty' 2>/dev/null
}

ensure_terminal_tab() {
    local ws="$1" dir="$2" has
    [ -n "${ws}" ] || return 0

    has=$(herdr_cli tab list --workspace "${ws}" 2>/dev/null \
        | jq -r --arg l "${TERMINAL_TAB_LABEL}" \
            '[.result.tabs[]? | select(.label == $l)] | length' 2>/dev/null)
    [ "${has:-0}" = "0" ] || return 0

    # --no-focus: the agent is what the user came for, so opening a workspace must
    # not land them in the shell.
    herdr_cli tab create --workspace "${ws}" --cwd "${dir}" \
        --label "${TERMINAL_TAB_LABEL}" --no-focus >/dev/null 2>&1 \
        || return 1
    return 0
}

# Workspaces this command manages whose worktree is no longer on disk, one per
# line as "<workspace_id>\t<label>\t<name>".
#
# Only the core-<name> label marks a workspace as ours: the session is per
# project, but a user may have opened anything else in it, and those must never
# be touched. One `workspace list` call, then a filesystem test each — this runs
# on every bare `ddev tryout herdr`, so it must not cost a round trip per
# workspace.
herdr_orphan_workspaces() {
    local id label name
    while IFS=$'\t' read -r id label; do
        [ -n "${id}" ] || continue
        case "${label}" in
            core-*) name="${label#core-}" ;;
            *)      continue ;;
        esac
        [ -n "${name}" ] || continue
        # herdr_checkout_dir knows both layouts: typo3-core-<name>, and the plain
        # typo3-core/ clone a project has before its first worktree.
        [ -d "$(herdr_checkout_dir "${name}")" ] && continue
        printf '%s\t%s\t%s\n' "${id}" "${label}" "${name}"
    done < <(herdr_cli workspace list 2>/dev/null \
        | jq -r '.result.workspaces[]? | [.workspace_id, .label] | @tsv' 2>/dev/null)
}

# The directory a workspace is sitting in, from its first pane's cwd.
#
# NOT worktree.checkout_path: that field only exists for workspaces opened with
# `worktree open`, and the `workspace create` fallback records none — so it is
# absent exactly when we still need an answer. Every workspace has a pane.
herdr_workspace_dir() {
    local id="$1"
    herdr_cli pane list 2>/dev/null \
        | jq -r --arg w "${id}" \
            'first(.result.panes[]? | select(.workspace_id == $w) | .cwd) // empty' 2>/dev/null
}

# Reconcile the session with the project, in one pass over the workspace list:
#
#   * a workspace sitting in one of our worktrees but labelled something else is
#     ADOPTED — renamed to core-<name>. Closing it would kill a live agent and
#     leave a duplicate workspace beside it; renaming keeps the pane, its history
#     and its agent, and makes every other helper here recognise it.
#   * a workspace labelled core-<name> whose worktree is gone is CLOSED.
#   * a workspace pointing outside the project has no business in this session
#     (it is named after the project) and is CLOSED.
#   * anything else inside the project — the root, packages/ — is LEFT ALONE:
#     someone opened it deliberately and it is not a Core worktree.
#
# Runs before the open loop, so an adopted workspace is not opened a second time.
sync_herdr_workspaces() {
    local root id label dir real name
    root="$(cd "${PROJECT_ROOT}" 2>/dev/null && pwd -P)" || return 0

    while IFS=$'\t' read -r id label; do
        [ -n "${id}" ] || continue
        dir="$(herdr_workspace_dir "${id}")"
        # No pane, no cwd, nothing to reason about — leave it be.
        [ -n "${dir}" ] || continue
        # Resolve both sides: on macOS the project is reached through /var while
        # herdr reports /private/var, and a plain prefix test calls everything
        # foreign. Same reasoning as list_foreign_core_worktrees.
        real="$(cd "${dir}" 2>/dev/null && pwd -P)" || real=""

        # Outside the project (or gone entirely, which a core-* label explains).
        if [ -z "${real}" ] || case "${real}/" in "${root}/"*) false ;; *) true ;; esac; then
            case "${label}" in
                core-*) ;;   # an orphan; the message below names the worktree
                *)
                    if herdr_cli workspace close "${id}" >/dev/null 2>&1; then
                        echo -e "  ${RED}✗${NC} closed ${label} ${DIM}— outside this project${NC}"
                    fi
                    continue ;;
            esac
        fi

        # Inside the project: is it one of our Core worktrees?
        # `|| true` is load-bearing: the function returns non-zero for a path that
        # is not one — a workspace whose checkout has since been removed, which is
        # exactly what this loop exists to find — and a bare assignment under
        # `set -e` makes that abort the whole command, silently.
        name="$(worktree_name_for_path "${real}" top 2>/dev/null || true)"

        if [ -n "${name}" ]; then
            # Ours. Fix the label if it is not the one everything else keys on.
            if [ "${label}" != "$(herdr_workspace_label "${name}")" ]; then
                if herdr_cli workspace rename "${id}" "$(herdr_workspace_label "${name}")" >/dev/null 2>&1; then
                    echo -e "  ${GREEN}✓${NC} adopted $(herdr_workspace_label "${name}") ${DIM}(was '${label}')${NC}"
                fi
            fi
            # Workspaces opened before the Terminal tab existed get one here: the
            # open loop skips anything already open, so this is the only route that
            # reaches them. ensure_terminal_tab is a no-op when one is present.
            ensure_terminal_tab "${id}" "${real}" \
                || warn "Could not add a Terminal tab to ${label}"
            ensure_first_tab_label "${id}" || true
            # The panel rides along: it lives in the Terminal tab, so it can only
            # be docked once that tab exists.
            set_workspace_branch_token "${id}" "${name}"
            ensure_panel_pane "${id}" "${real}" "${name}" \
                || warn "Could not add the tryout panel to ${label}"
        fi
    done < <(herdr_cli workspace list 2>/dev/null \
        | jq -r '.result.workspaces[]? | [.workspace_id, .label] | @tsv' 2>/dev/null)

    # Whatever is left labelled core-<name> with no worktree behind it.
    close_orphan_workspaces
}

# Close every workspace whose worktree is gone, so a session matches the project.
# Deliberately unconditional: no prompt, and no exception for a workspace whose
# agent is still working. A `worktree rename` is a remove plus an add to herdr,
# so the old workspace goes and the new one is opened in the same run — the old
# pane's scrollback with it. That is the trade for herdr staying exactly in step.
close_orphan_workspaces() {
    local id label name closed=0
    while IFS=$'\t' read -r id label name; do
        [ -n "${id}" ] || continue
        if herdr_cli workspace close "${id}" >/dev/null 2>&1; then
            echo -e "  ${RED}✗${NC} closed ${label} ${DIM}— $(basename "$(herdr_checkout_dir "${name}")") is gone${NC}"
            closed=$((closed + 1))
        else
            warn "Could not close ${label}"
        fi
    done < <(herdr_orphan_workspaces)
    return 0
}

# A worktree name derived from a branch (or any path segment). herdr names its own
# checkouts from a generated word list on a "worktree/<slug>" branch, so take the last
# segment, drop a typo3-core- prefix, and force it into validate_worktree_name's
# grammar. Empty in, empty out — the caller decides what to do about that.
worktree_name_from_ref() {
    printf '%s' "${1:-}" \
        | sed -e 's|^worktree/||' -e 's|^refs/heads/||' -e 's/^typo3-core-//' \
              -e 's/[^A-Za-z0-9._-]/-/g' \
        | cut -c1-64
}

# Checkouts of the Core repo that live OUTSIDE the project, one path per line. These
# are invisible to every tryout command: not matched by list_core_worktrees' glob, not
# servable, never reachable through the typo3-core symlink. herdr's own New-worktree
# action creates them under its worktrees.directory.
list_foreign_core_worktrees() {
    [ -d "${CORE_DIR}" ] || return 0

    # Compare RESOLVED paths: on macOS the project root is reached through /var
    # while git reports /private/var, and a plain prefix test would call every
    # worktree foreign.
    local root
    root="$(cd "${PROJECT_ROOT}" 2>/dev/null && pwd -P)" || return 0

    git -C "${CORE_DIR}" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print substr($0,10)}' \
        | while IFS= read -r p; do
            [ -n "${p}" ] || continue
            local real
            real="$(cd "${p}" 2>/dev/null && pwd -P)" || real="${p}"
            case "${real}/" in
                "${root}/"*) ;;
                *) echo "${p}" ;;
            esac
          done
}

# One workspace per worktree, in two tabs: the first runs the agent, a second one
# labelled Terminal holds a plain shell. Both are rooted at the worktree. A tab
# rather than a split, so the shell costs the agent no width. Focus stays where the
# caller was unless asked.
# Start claude in a pane. Returns 0 when the agent is up — including the case where
# it is up but blocked on its own UI — so the caller can name the tab for what is
# actually in it. Used by both routes into a workspace: the fresh open, and the
# backfill of one that was already there but had no agent.
start_agent_in_pane() {
    local name="$1" pane="$2" agent start_err rc=0 attempt=0
    [ -n "${pane}" ] || return 1
    agent="$(herdr_agent_name "${name}")"

    # `workspace create` answers before the pane's shell reaches its prompt, and
    # `agent start` needs an idle shell to take over — so a first attempt can lose
    # that race. Retry a few times before believing a failure.
    while :; do
        rc=0
        start_err=$(herdr_cli agent start "${agent}" --kind claude --pane "${pane}" 2>&1 >/dev/null) || rc=$?
        # Success, or a definite answer (the agent is up but blocked on its own
        # UI) — either way, stop.
        [ "${rc}" -eq 0 ] && break
        printf '%s' "${start_err}" | grep -q 'agent_not_ready' && break
        attempt=$((attempt + 1))
        [ "${attempt}" -ge 5 ] && break
        sleep 1
    done

    if [ "${rc}" -eq 0 ]; then
        success "'${name}' — claude '${agent}'"
        return 0
    fi
    if printf '%s' "${start_err}" | grep -q 'agent_not_ready'; then
        # Claude launched but is waiting on its own UI — on a worktree it has not
        # seen before that is the folder-trust prompt. It is running and named, so
        # this is a normal first run, not a failure.
        success "'${name}' — claude '${agent}'"
        info "  ${DIM}'${agent}' is waiting for input (folder trust?) — open core-${name}${NC}"
        return 0
    fi
    warn "Could not start claude in '${name}' — left as a shell"
    return 1
}

open_worktree_in_herdr() {
    local name="$1" use_agent="${2:-true}" focus="${3:-false}" dir ws_json root_pane agent
    local first_tab tab_label="Shell"
    # Every caller validates first, but the name becomes a path and a herdr label —
    # so check here too rather than trusting each new call site to remember.
    validate_worktree_name "${name}" || return 1
    dir="$(herdr_checkout_dir "${name}")"

    if [ ! -d "${dir}" ]; then
        error "No worktree '${name}'"
        error "  → ddev tryout worktree add ${name} <branch>"
        return 1
    fi

    if herdr_worktree_is_open "${dir}"; then
        # Open, but not necessarily COMPLETE. A workspace opened by hand, or by a
        # scheme older than the Terminal tab or the panel, is missing whichever of
        # those did not exist yet — and returning here is what left it that way:
        # `ddev tryout herdr <name>` skips the reconcile pass, so nothing else
        # would ever reach it. Backfill the same three things the fresh path ends
        # with; each is a no-op when already present.
        # By DIRECTORY, not by label: a workspace old enough to be missing the tab
        # and the panel is old enough to be missing the core-<name> label too, and
        # looking it up by the label it does not have was why this branch did
        # nothing at all for the one workspace that needed it.
        local open_ws; open_ws="$(herdr_workspace_id_for_dir "${dir}")"
        if [ -n "${open_ws}" ]; then
            # Adopt the label as well, so everything that keys on it — the sync
            # pass, orphan cleanup, `herdr <name>` focusing — finds it afterwards.
            local want; want="$(herdr_workspace_label "${name}")"
            if [ "$(herdr_workspace_label_of "${open_ws}")" != "${want}" ]; then
                herdr_cli workspace rename "${open_ws}" "${want}" >/dev/null 2>&1 || true
            fi
            # An agent too, if the workspace has none and one was asked for. The
            # fresh path starts it before this early return, so a workspace that
            # predates the agent — or lost it — never got one back.
            if [ "${use_agent}" = "true" ] && ! herdr_workspace_has_agent "${open_ws}"; then
                # The worktree's own pane, never the panel beside it.
                local root; root="$(herdr_workspace_agent_pane "${open_ws}" "${dir}")"
                if [ -n "${root}" ]; then
                    start_agent_in_pane "${name}" "${root}" || true
                fi
            fi
            ensure_terminal_tab "${open_ws}" "${dir}" || true
            # After the agent, so the tab is named for what is now in it.
            ensure_first_tab_label "${open_ws}" || true
            set_workspace_branch_token "${open_ws}" "${name}"
            ensure_panel_pane "${open_ws}" "${dir}" "${name}" || true
        fi
        info "'${name}' is already open — skipping"
        return 0
    fi

    info "Opening '${name}'..."

    local focus_flag="--no-focus"
    [ "${focus}" = "true" ] && focus_flag="--focus"

    # `worktree open` registers the checkout as a workspace WITH git provenance, so
    # herdr groups it under the Core repo exactly like a natively created worktree.
    # `workspace create` sets no provenance, so it is only the fallback for a herdr
    # that does not know the subcommand.
    local label main_dir
    label="$(herdr_workspace_label "${name}")"
    main_dir="$(main_core_worktree_dir)"
    [ -z "${main_dir}" ] && main_dir="${dir}"

    ws_json=$(herdr_cli worktree open \
        --cwd "${main_dir}" --path "${dir}" --label "${label}" "${focus_flag}" 2>&1) \
        || ws_json=""

    if [ -z "${ws_json}" ] || ! printf '%s' "${ws_json}" | jq -e '.result' >/dev/null 2>&1; then
        ws_json=$(herdr_cli workspace create \
            --cwd "${dir}" --label "${label}" "${focus_flag}" 2>&1) || {
            error "herdr could not open '${name}'"
            echo "${ws_json}" >&2
            return 1
        }
    fi

    root_pane=$(printf '%s' "${ws_json}" | jq -r '.result.root_pane.pane_id // empty')
    # The reply carries the first tab beside the root pane, so naming it costs no
    # extra round trip.
    first_tab=$(printf '%s' "${ws_json}" | jq -r '.result.tab.tab_id // empty')
    if [ -z "${root_pane}" ]; then
        error "herdr did not report a pane for '${name}'"
        return 1
    fi

    if [ "${use_agent}" = "true" ]; then
        start_agent_in_pane "${name}" "${root_pane}" && tab_label="Claude"
    else
        success "'${name}' — shell"
    fi

    # Naming the tab and adding the shell are conveniences: a workspace that opened
    # but could not be labelled is still perfectly usable, so neither failure ends
    # the run — several worktrees may still be waiting behind this one.
    [ -n "${first_tab}" ] \
        && herdr_cli tab rename "${first_tab}" "${tab_label}" >/dev/null 2>&1
    local ws_id; ws_id="$(herdr_workspace_id "${name}")"
    ensure_terminal_tab "${ws_id}" "${dir}" \
        || warn "Could not add a Terminal tab for '${name}'"
    set_workspace_branch_token "${ws_id}" "${name}"
    ensure_panel_pane "${ws_id}" "${dir}" "${name}" \
        || warn "Could not add the tryout panel for '${name}'"
    return 0
}

# True when the installed payload is not the one this code came from. Runs on the
# host, cheaply: two file reads and a string compare.
#
# A missing stamp means an install that predates the marker. That is NOT reported
# as stale — we cannot tell how old it is, and warning on every such project would
# train people to ignore the line.
addon_is_stale() {
    local f="${PROJECT_ROOT}/.ddev/tryout/.version" installed
    [ -f "${f}" ] || return 1
    installed="$(tr -d '[:space:]' < "${f}" 2>/dev/null)"
    [ -n "${installed}" ] || return 1
    [ "${installed}" != "${TRYOUT_VERSION}" ]
}

# True when vendor/ was built from a different Core than the active one. This is
# the silent failure mode of a symlink swap without a reinstall.
vendor_core_mismatch() {
    local link resolved active
    link="${PROJECT_ROOT}/vendor/typo3/cms-core"
    [ -L "${link}" ] || return 1
    active=$(active_worktree_name)
    [ -n "${active}" ] || return 1
    resolved=$(cd "$(dirname "${link}")" && cd "$(readlink "${link}")" 2>/dev/null && pwd -P) || return 1
    case "${resolved}" in
        "$(cd "$(core_worktree_dir "${active}")" && pwd -P)"/*) return 1 ;;
        *) return 0 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────
# Served sites
#
# The primary site is asymmetric on purpose: it stays at the project root so every
# existing command, composer.json and single-Core install keeps working untouched.
# The primary/extra distinction lives in these four path helpers ONLY — callers pass
# a site name and never branch themselves.
# ─────────────────────────────────────────────────────────────────────

site_is_primary() { [ "${1:-}" = "${PRIMARY_SITE}" ] || [ -z "${1:-}" ]; }

# Root of a site's TYPO3 instance (composer root).
site_dir() {
    if site_is_primary "${1:-}"; then echo "${PROJECT_ROOT}"; else echo "${SITES_DIR}/$1"; fi
}

site_docroot() { echo "$(site_dir "${1:-}")/public"; }
site_vendor()  { echo "$(site_dir "${1:-}")/vendor"; }

# The Core checkout a site serves: the symlink for the primary, the named worktree
# otherwise — so the primary keeps following `worktree use`.
site_core_dir() {
    if site_is_primary "${1:-}"; then echo "${CORE_DIR}"; else core_worktree_dir "$1"; fi
}

# Hostname: <name>.<project>.ddev.site for extras, the bare project URL for primary.
# DDEV appends .ddev.site itself, so additional_hostnames gets the un-suffixed form.
site_hostname_short() {
    site_is_primary "${1:-}" && { echo "${DDEV_SITENAME:-}"; return; }
    echo "$1.${DDEV_SITENAME:-}"
}
site_hostname() { echo "$(site_hostname_short "${1:-}").ddev.site"; }

# Database name. The primary keeps plain `db` so existing installs are untouched.
site_database() {
    site_is_primary "${1:-}" && { echo "db"; return; }
    # printf, not echo: tr -c would turn echo's trailing newline into an underscore.
    echo "db_$(printf '%s' "$1" | tr -c '[:alnum:]_' '_')"
}

# A site is "served" when its generated marker exists (extras only).
site_is_served() {
    site_is_primary "${1:-}" && return 0
    [ -f "$(site_dir "$1")/.tryout-site" ]
}

# PHP version a site runs, from its marker; falls back to the project default.
site_php_version() {
    local f
    site_is_primary "${1:-}" && { echo "${DDEV_PHP_VERSION:-}"; return; }
    f="$(site_dir "$1")/.tryout-site"
    [ -f "${f}" ] && grep -E '^php=' "${f}" | head -1 | cut -d= -f2 || echo "${DDEV_PHP_VERSION:-}"
}

# Names of all served extra sites (primary excluded).
served_site_names() {
    [ -d "${SITES_DIR}" ] || return 0
    local d name
    for d in "${SITES_DIR}"/*; do
        [ -d "${d}" ] || continue
        name="$(basename "${d}")"
        site_is_served "${name}" && echo "${name}"
    done
}

# --- Site generators ---

# Where a site's generated vhost goes, per webserver_type. DDEV copies both dirs
# into the container; ours deliberately omit the #ddev-generated marker so DDEV
# never overwrites them, and are prefixed so they cannot collide with its own
# apache-site.conf / nginx-site.conf.
site_vhost_file() {
    local name="$1"
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        nginx*) echo "${PROJECT_ROOT}/.ddev/nginx_full/tryout-site-${name}.conf" ;;
        *)      echo "${PROJECT_ROOT}/.ddev/apache/tryout-site-${name}.conf" ;;
    esac
}

# The http-level config that sizes nginx's server-name hash. Separate from the
# per-site vhosts because server_names_hash_bucket_size belongs in `http`, and a
# vhost file is a `server` block. DDEV includes everything in nginx_full/ at http
# scope — its own nginx-site.conf carries a `map` there, which is http-only too.
site_hash_config_file() {
    echo "${PROJECT_ROOT}/.ddev/nginx_full/tryout-server-names-hash.conf"
}

generate_site_vhost() {
    local name="$1" php="$2" file docroot host db sock
    file=$(site_vhost_file "${name}")
    docroot="/var/www/html/sites/${name}/public"
    host=$(site_hostname "${name}")
    db=$(site_database "${name}")
    # Must match tryout-php-fpm.sh, which binds under /run/php/ because /run is
    # root-owned on some providers.
    sock="/run/php/php-fpm-${php}.sock"
    [ "${php}" = "${DDEV_PHP_VERSION:-}" ] && sock="/run/php-fpm.sock"

    mkdir -p "$(dirname "${file}")"
    if [ "${DDEV_WEBSERVER_TYPE:-apache-fpm}" = "nginx-fpm" ]; then
        cat > "${file}" <<NGINX_EOF
# Generated by ddev tryout worktree serve ${name} — edits will be overwritten.
server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name ${host};
    ssl_certificate /etc/ssl/certs/master.crt;
    ssl_certificate_key /etc/ssl/certs/master.key;
    root ${docroot};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }
    location ~ [^/]\.php(/|\$) {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+?\.php)(/.*)\$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param TRYOUT_SITE ${name};
        fastcgi_param TYPO3_DB_DBNAME ${db};
        # Without this PHP never learns the request arrived over TLS, so TYPO3
        # builds http:// URLs and its secure session cookie is never sent back —
        # the backend login then fails with "Please activate Cookies". DDEV's own
        # vhost sets the same parameter.
        fastcgi_param HTTPS \$fcgi_https;
        fastcgi_pass unix:${sock};
    }
}
NGINX_EOF
    else
        cat > "${file}" <<APACHE_EOF
# Generated by ddev tryout worktree serve ${name} — edits will be overwritten.
<VirtualHost *:80 *:443>
    ServerName ${host}
    DocumentRoot ${docroot}

    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/master.crt
    SSLCertificateKeyFile /etc/ssl/certs/master.key

    SetEnvIf X-Forwarded-Proto "https" HTTPS=on
    SetEnv TRYOUT_SITE ${name}
    SetEnv TYPO3_DB_DBNAME ${db}

    <Directory "${docroot}/">
        AllowOverride All
        Require all granted
    </Directory>

    # Overrides the global conf-enabled/php*-fpm.conf handler: sites-enabled is
    # read later and a FilesMatch inside a VirtualHost is more specific.
    <FilesMatch ".+\.ph(?:ar|p|tml)\$">
        SetHandler "proxy:unix:${sock}|fcgi://localhost"
    </FilesMatch>

    ErrorLog /dev/stdout
    CustomLog /dev/stdout combined
</VirtualHost>
APACHE_EOF
    fi
}

# Rewrite .ddev/config.worktrees.yaml from the served sites: hostnames (so mkcert
# covers them) plus one supervised daemon per extra PHP version.
write_worktree_config() {
    local names hosts=() phps=() name php
    names=$(served_site_names)

    for name in ${names}; do
        hosts+=("$(site_hostname_short "${name}")")
        php=$(site_php_version "${name}")
        [ -n "${php}" ] && [ "${php}" != "${DDEV_PHP_VERSION:-}" ] && phps+=("${php}")
    done

    write_server_names_hash "${hosts[@]:-}"

    if [ ${#hosts[@]} -eq 0 ]; then
        rm -f "${WORKTREE_CONFIG}"
        return 0
    fi

    {
        echo "#ddev-silent-no-warn"
        echo "# Generated by ddev tryout worktree serve — do not edit."
        echo "# Hostnames must be registered here so mkcert includes them in the cert."
        echo ""
        echo "additional_hostnames:"
        printf '  - %s\n' "${hosts[@]}"
        # De-duplicate: several sites may share one PHP version.
        if [ ${#phps[@]} -gt 0 ]; then
            echo ""
            echo "web_extra_daemons:"
            printf '%s\n' "${phps[@]}" | sort -u | while read -r v; do
                echo "  - name: tryout-php-${v}"
                echo "    command: \"bash /var/www/html/.ddev/tryout/tryout-php-fpm.sh ${v}\""
                echo "    directory: /var/www/html"
            done
        fi
    } > "${WORKTREE_CONFIG}"
}

# nginx hashes every server_name into buckets of a fixed size, and refuses to
# START when a name does not fit:
#
#   [emerg] could not build server_names_hash, you should increase
#           server_names_hash_bucket_size: 64
#
# which takes the whole web container down — every site, not just the long one.
# The default 64 holds names of roughly 50 characters, and
# `<worktree>.<project>.ddev.site` passes that with a project and a worktree name
# of ordinary length. So size it from the longest name actually served, rounded up
# to a power of two as nginx wants, and never below the 64 it already uses.
write_server_names_hash() {
    local file longest=0 h n
    file="$(site_hash_config_file)"

    for h in "$@"; do
        [ -n "${h}" ] || continue
        # The short form here is what write_worktree_config collects; DDEV appends
        # .ddev.site to reach the name nginx actually hashes.
        n=$(( ${#h} + 11 ))
        [ "${n}" -gt "${longest}" ] && longest="${n}"
    done

    if [ "${longest}" -eq 0 ]; then
        rm -f "${file}" 2>/dev/null || true
        return 0
    fi

    # A bucket holds the name plus nginx's own per-entry overhead and padding, so
    # the usable room is well short of the bucket size. Measured, not guessed: a
    # 49-character name is what broke the default 64 in the first place, which puts
    # the overhead near 16. Allow 24 to stay clear of it, and double from 64 as the
    # nginx docs advise — a bigger bucket costs a few bytes of memory and nothing
    # else, while one too small refuses to start the whole web container.
    local size=64
    while [ "${size}" -lt $(( longest + 24 )) ]; do
        size=$(( size * 2 ))
    done

    mkdir -p "$(dirname "${file}")"
    cat > "${file}" <<HASH_EOF
#ddev-generated
# Generated by ddev tryout worktree serve — do not edit.
# Sized for the longest served hostname (${longest} chars). Without this nginx
# refuses to start once a name outgrows the default bucket, taking every site
# with it.
server_names_hash_bucket_size ${size};
HASH_EOF
}

# --- Applying a config change without ddev restart ---

# Snapshot of the served hostnames, newline-separated and sorted. The gate for
# the fast path: DDEV derives the Traefik routing rule, $VIRTUAL_HOST and the
# certificate SANs from additional_hostnames, so all three go stale exactly when
# this set changes — and only then is a restart unavoidable.
served_hostname_set() {
    local name
    for name in $(served_site_names); do
        site_hostname_short "${name}"
    done | sort
}

# Where the webserver reads its vhosts from, and how it is reloaded. DDEV's
# /start.sh copies /mnt/ddev_config/{nginx_full,apache} into these at container
# start — a COPY, not a mount, which is why a freshly written vhost is visible in
# the container yet not in effect.
site_conf_source_dir() {
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        nginx*) echo "/mnt/ddev_config/nginx_full" ;;
        *)      echo "/mnt/ddev_config/apache" ;;
    esac
}

site_conf_enabled_dir() {
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        nginx*) echo "/etc/nginx/sites-enabled" ;;
        *)      echo "/etc/apache2/sites-enabled" ;;
    esac
}

# Validate the webserver config as it would be loaded. Errors are the caller's to
# report, so stderr is captured rather than shown.
webserver_config_is_valid() {
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        nginx*) nginx -t >/dev/null 2>&1 ;;
        *)      apachectl configtest >/dev/null 2>&1 ;;
    esac
}

# Reload in place, keeping the master process. nginx is a supervisord program in
# the web image, so HUP through supervisorctl reaches it without a pid file (there
# is none at /run/nginx.pid) and without restarting the container.
reload_webserver() {
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in
        nginx*) supervisorctl signal HUP nginx >/dev/null 2>&1 ;;
        *)      apachectl -k graceful >/dev/null 2>&1 ;;
    esac
}

# Copy the generated vhosts into the running webserver and reload it, so a change
# takes effect without `ddev restart`. Container-side only.
#
# Returns non-zero without touching the running config if the result would not
# load — the caller then falls back to advising a restart. That ordering matters:
# an invalid config makes nginx refuse to START, which takes down every site in
# the project, not just the one being changed (this is the
# server_names_hash_bucket_size trap). Validating first makes this strictly safer
# than the restart it replaces, which only discovers the problem once the
# container is already down.
sync_and_reload_webserver() {
    local src dst
    src="$(site_conf_source_dir)"
    dst="$(site_conf_enabled_dir)"

    [ -d "${src}" ] || return 1
    [ -d "${dst}" ] || return 1

    # Clear our own stale copies first: unserve removes a vhost from the source,
    # and a plain cp would leave the old one serving. Scoped to the tryout-site-
    # prefix — DDEV's own nginx-site.conf lives in the same directory.
    rm -f "${dst}"/tryout-site-*.conf 2>/dev/null || true
    rm -f "${dst}"/tryout-server-names-hash.conf 2>/dev/null || true

    # Copy back per served site, by name — never a glob over the source. On a
    # Mutagen project the host's deletion of a vhost has not necessarily reached
    # /mnt/ddev_config by the time unserve calls this, so a glob would faithfully
    # restore the file that was just removed and the dead site would keep serving.
    # served_site_names reads the markers, which are the actual definition of
    # "served" and are correct in here regardless of what the sync has caught up on.
    local name f
    for name in $(served_site_names); do
        f="${src}/tryout-site-${name}.conf"
        [ -f "${f}" ] || continue
        cp "${f}" "${dst}/" 2>/dev/null || true
    done
    if [ -f "${src}/tryout-server-names-hash.conf" ]; then
        cp "${src}/tryout-server-names-hash.conf" "${dst}/" 2>/dev/null || true
    fi

    # DDEV's own config is copied at container start and never removed above, so
    # it needs no restoring here.

    webserver_config_is_valid || return 1
    reload_webserver || return 1
}

# Apply the site config that has just been written. Prints its own outcome, since
# what the user must do next differs per path.
#
#   hostname set changed → a restart is unavoidable: DDEV owns the Traefik routing
#                          rule and the certificate, both keyed on
#                          additional_hostnames, and neither can be refreshed from
#                          in here.
#   hostname set same    → reload the webserver in place.
#
# `before` is the hostname set captured before the change was written.
apply_site_config() {
    local before="$1" after
    after="$(served_hostname_set)"

    if [ "${before}" != "${after}" ]; then
        return 1
    fi

    in_container || return 1
    sync_and_reload_webserver || return 1
}

# Create the site's database and grant the DDEV db user access.
ensure_site_database() {
    local db
    db=$(site_database "$1")
    [ "${db}" = "db" ] && return 0
    info "Ensuring database ${db}..."
    if db_is_postgres; then
        # No IF NOT EXISTS for CREATE DATABASE in Postgres: look first.
        if ! db_root_sql "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
            db_root_sql "CREATE DATABASE \"${db}\"" >/dev/null \
                || { error "Failed to create database ${db}"; return 1; }
        fi
    else
        db_root_sql "CREATE DATABASE IF NOT EXISTS \`${db}\`; GRANT ALL ON \`${db}\`.* TO 'db'@'%';" \
            || { error "Failed to create database ${db}"; return 1; }
    fi
}

# Run a command in a site's context: its PHP version, its composer root, its
# database. Without this every caller has to remember the php<version> binary and
# the TYPO3_DB_DBNAME the vhost would otherwise inject.
site_exec() {
    local name="$1"; shift
    local php dir db bin="php"
    php=$(site_php_version "${name}")
    dir=$(site_dir "${name}")
    db=$(site_database "${name}")
    [ -n "${php}" ] && [ "${php}" != "${DDEV_PHP_VERSION:-}" ] && bin="php${php}"

    # The binary runs directly with "$@": no shell in between, so an argument
    # with spaces — `config:set X "My Site"` — arrives as one argument.
    # shellcheck disable=SC2086 # TRYOUT_EXTRA_ENV is deliberately word-split
    (cd "${dir}" && env TYPO3_DB_DBNAME="${db}" TRYOUT_SITE="${name}" ${TRYOUT_EXTRA_ENV:-} "${bin}" "$@")
}

# First-run TYPO3 setup for a served site, mirroring what post-start.sh does for
# the primary but against that site's docroot, vendor and database.
setup_site_typo3() {
    local name="$1" db php driver server_type
    site_is_served "${name}" || { error "Site '${name}' is not served"; return 1; }
    db=$(site_database "${name}")
    php=$(site_php_version "${name}")

    if [ -f "$(site_dir "${name}")/config/system/settings.php" ]; then
        info "Site '${name}' already configured"
        return 0
    fi

    # No settings.php, but the database may still hold the install: unserve keeps
    # it unless --drop-db was asked for. Put the saved settings back and skip the
    # setup, so an unserve/serve round trip keeps the content and the logins.
    if site_database_has_tables "${name}"; then
        local saved; saved="$(site_saved_settings "${name}")"
        if [ -f "${saved}" ]; then
            mkdir -p "$(site_dir "${name}")/config/system"
            if cp "${saved}" "$(site_dir "${name}")/config/system/settings.php"; then
                success "Site '${name}' restored — existing database kept"
                return 0
            fi
        fi
        # Tables but nothing to restore: a site unserved before this existed, or a
        # database from somewhere else. TYPO3's own setup refuses this, so say why
        # before it does rather than leaving the user with its bare error.
        warn "Database $(site_database "${name}") already holds an install, and there is"
        warn "no saved settings.php for '${name}' to go with it."
        warn "  → ddev tryout worktree unserve ${name} --drop-db   then serve again"
    fi

    driver="mysqli"
    db_is_postgres && driver="postgres"
    server_type="other"
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in apache*) server_type="apache" ;; esac

    info "Running TYPO3 setup for '${name}' (db ${db}, PHP ${php})..."
    TRYOUT_EXTRA_ENV="TYPO3_DB_DRIVER=${driver}" \
        site_exec "${name}" vendor/bin/typo3 setup --no-interaction --force "--server-type=${server_type}" \
        || { error "TYPO3 setup failed for ${name}"; return 1; }
    success "Site '${name}' set up"
}

# What `delete` is about to destroy, one line per site. The host prints it before
# asking for confirmation; the container prints it when it has to ask itself.
delete_warning() {
    local target="$1"; shift
    echo ""
    echo -e "${YELLOW}${BOLD}Warning:${NC} this destroys data for:"
    local s label
    for s in "$@"; do
        label="${s}"
        site_is_primary "${s}" && label="primary"
        echo -e "  ${BOLD}${label}${NC} — database $(site_database "${s}"), $(site_docroot "${s}")/fileadmin, settings.php"
    done
    if [ -z "${target}" ] && [ -n "$(served_site_names)" ]; then
        echo -e "  ${DIM}served sites are untouched — use 'delete <site>' or 'delete --all'${NC}"
    fi
    echo ""
}

# Wipe one site back to a fresh TYPO3 install: its own database, its own
# fileadmin, its own settings.php. Works for the primary and for served sites.
delete_site() {
    local name="$1" db docroot dir driver server_type
    db=$(site_database "${name}")
    docroot=$(site_docroot "${name}")
    dir=$(site_dir "${name}")

    info "[1/4] Recreating database ${db}..."
    if db_is_postgres; then
        db_root_sql "DROP DATABASE IF EXISTS \"${db}\"" >/dev/null 2>&1 || true
        db_root_sql "CREATE DATABASE \"${db}\"" >/dev/null \
            || { error "Failed to reset database ${db}"; return 1; }
    else
        # Re-grant: DROP removes the privileges along with the schema.
        db_root_sql "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\`; GRANT ALL ON \`${db}\`.* TO 'db'@'%';" \
            || { error "Failed to reset database ${db}"; return 1; }
    fi
    success "Database ${db} recreated"

    info "[2/4] Clearing ${docroot#"${PROJECT_ROOT}/"}/fileadmin..."
    [ -d "${docroot}/fileadmin" ] && find "${docroot}/fileadmin" -mindepth 1 -delete 2>/dev/null || true
    success "fileadmin cleared"

    info "[3/4] Removing settings.php..."
    rm -f "${dir}/config/system/settings.php"
    success "Configuration removed"

    driver="mysqli"
    db_is_postgres && driver="postgres"
    server_type="other"
    case "${DDEV_WEBSERVER_TYPE:-apache-fpm}" in apache*) server_type="apache" ;; esac

    info "[4/4] Running TYPO3 setup + extension:setup..."
    TRYOUT_EXTRA_ENV="TYPO3_DB_DRIVER=${driver}" \
        site_exec "${name}" vendor/bin/typo3 setup --no-interaction --force "--server-type=${server_type}" \
        || { error "TYPO3 setup failed for ${name}"; return 1; }
    site_exec "${name}" vendor/bin/typo3 extension:setup >/dev/null 2>&1 || warn "extension:setup had warnings"
    site_exec "${name}" vendor/bin/typo3 cache:flush >/dev/null 2>&1 || warn "cache:flush had warnings"
    success "Setup complete"
}

# PHP versions the web container actually provides, low to high. Read from the
# image rather than hardcoded: DDEV adds versions over time and does not validate
# --php-version, so a stale list here would silently pick a PHP that is not there.
available_php_versions() {
    ls /usr/bin/php8.* 2>/dev/null \
        | sed 's|.*/php||' \
        | grep -E '^8\.[0-9]+$' \
        | sort -V
}

# The PHP constraint a Core checkout states, from require.php in its composer.json.
# Empty when there is none or the file cannot be read; that is the caller's cue to
# fall back rather than guess.
core_php_constraint() {
    local file="$1"
    [ -f "${file}" ] || return 0
    # require.php specifically — a naive grep for "php" finds config.platform.php
    # first, which is a pinned build version, not the constraint.
    php -r '
        $f = $argv[1];
        $d = json_decode(@file_get_contents($f), true);
        echo is_array($d) ? ($d["require"]["php"] ?? "") : "";
    ' "${file}" 2>/dev/null || true
}

# Does PHP <version> (major.minor) satisfy <constraint>? Exit 0 = yes, 1 = no.
#
# Let PHP judge each candidate against the constraint. Core uses "^8.x", but an
# upper bound like ">=8.2 <8.4" has to be honoured too — reading only the floor
# would hand a capped branch a PHP it rejects.
php_satisfies() {
    local constraint="$1" version="$2"
    php -r '
        $c = $argv[1]; $v = $argv[2] . ".0"; $ok = true;
        // Split on whitespace and commas: every clause must hold.
        foreach (preg_split("/[\s,]+/", trim($c), -1, PREG_SPLIT_NO_EMPTY) as $part) {
            if (preg_match("/^\^(\d+)\.(\d+)/", $part, $m)) {
                // ^8.2 means >=8.2 and <9.0
                $ok = $ok && version_compare($v, "{$m[1]}.{$m[2]}.0", ">=")
                          && version_compare($v, ($m[1] + 1) . ".0.0", "<");
            } elseif (preg_match("/^(>=|<=|>|<|=)?\s*(\d+(?:\.\d+){0,2})$/", $part, $m)) {
                $op = $m[1] ?: ">=";
                $ok = $ok && version_compare($v, $m[2], $op === "=" ? "==" : $op);
            }
        }
        exit($ok ? 0 : 1);
    ' "${constraint}" "${version}" 2>/dev/null
}

# The PHP versions the web container provides that satisfy <constraint>, ascending.
matching_php_versions() {
    local constraint="$1" v
    while IFS= read -r v; do
        [ -n "${v}" ] || continue
        php_satisfies "${constraint}" "${v}" && echo "${v}"
    done <<EOF
$(available_php_versions)
EOF
}

# The highest available PHP a worktree's Core will accept.
#
# Core states its requirement per branch — "^8.5" on main, "^8.2" on 13.4 — so the
# project's own PHP is the wrong default for a worktree on another branch. Falls
# back to the project version when the constraint cannot be read, which keeps a
# missing or unparsable composer.json from blocking a serve.
best_php_for_worktree() {
    local name="$1" constraint best
    constraint="$(core_php_constraint "$(core_worktree_dir "${name}")/composer.json")"
    [ -n "${constraint}" ] || { echo "${DDEV_PHP_VERSION:-8.5}"; return; }
    best="$(matching_php_versions "${constraint}" | tail -1)"
    [ -n "${best}" ] || best="${DDEV_PHP_VERSION:-8.5}"
    echo "${best}"
}

# Fail fast when a site's PHP cannot run the Core it is built on.
#
# Composer reports the same mismatch, but as a resolver trace ("your php version
# (8.4.20) does not satisfy that requirement") followed by our hint to re-download,
# which is not the fix. Say what Core wants, what the site has, and the command
# that changes it. Skips when the constraint cannot be read — no host php, no
# composer.json yet — because Composer is the authority then.
check_php_for_core() {
    local dir="${1:-${CORE_DIR}}" php="${2:-${DDEV_PHP_VERSION:-}}" site="${3:-}"
    local constraint branch best
    [ -n "${php}" ] || return 0
    constraint="$(core_php_constraint "${dir}/composer.json")"
    [ -n "${constraint}" ] || return 0
    command -v php >/dev/null 2>&1 || return 0
    php_satisfies "${constraint}" "${php}" && return 0

    branch=$(git -C "${dir}" branch --show-current 2>/dev/null)
    error "TYPO3 Core${branch:+ (${branch})} requires PHP ${constraint}, but $([ -n "${site}" ] && echo "site '${site}' runs" || echo "the project runs") PHP ${php}"
    best="$(matching_php_versions "${constraint}" | tail -1)"
    if [ -n "${site}" ]; then
        error "  → ddev tryout worktree serve ${site} --php ${best:-<version>}"
    else
        error "  → ddev config --php-version=${best:-<version>} && ddev restart"
    fi
    error "  → or switch Core to a branch this PHP can run: ddev tryout checkout <branch>"
    return 1
}

# --- Serve / unserve ---

# Build a site's own composer.json from the root one, repointing the Core path repo
# at that worktree.
generate_site_composer() {
    local name="$1" php="${2:-}"
    info "Generating sites/${name}/composer.tryout.json..."
    php "$(tryout_script site-composer.php)" "${name}" "${php}" >/dev/null \
        || { error "Failed to generate the Composer overlay for ${name}"; return 1; }
}

# Make a worktree into a live site: own tree, composer.json, DB, vhost and daemon.
serve_worktree() {
    local name="$1" php="${2:-}" dir hosts_before
    validate_worktree_name "${name}" || return 1
    site_is_primary "${name}" && { error "'${name}' is reserved"; return 1; }

    # Captured before the .tryout-site marker exists, so it reflects what DDEV
    # last registered. Re-serving an already-served site leaves it unchanged,
    # which is what lets the reload replace the restart.
    hosts_before="$(served_hostname_set)"

    if [ ! -d "$(core_worktree_dir "${name}")" ]; then
        error "No worktree '${name}'"
        error "  → ddev tryout worktree add ${name} <branch>"
        return 1
    fi

    # No --php given: take the highest the branch's Core will accept, not the
    # project's version — a 13.4 worktree in an 8.5 project needs its own answer.
    if [ -z "${php}" ]; then
        php="$(best_php_for_worktree "${name}")"
        info "PHP ${php} (highest this Core accepts; --php overrides)"
    fi
    # An explicit --php can still be one this Core rejects. Refuse before a
    # database and vhost exist for a site that could never install.
    check_php_for_core "$(core_worktree_dir "${name}")" "${php}" "${name}" || return 1
    dir=$(site_dir "${name}")
    mkdir -p "${dir}/config/system" "${dir}/var"

    # The marker IS the definition of "served" (site_is_served), so writing it up
    # front makes a half-built site look real to worktree list,
    # delete --all and write_worktree_config. Remove it if we do not get to the end.
    printf 'php=%s\n' "${php}" > "${dir}/.tryout-site"
    # shellcheck disable=SC2064 # expand dir/name now, not when the trap fires
    trap "rm -f '${dir}/.tryout-site'" RETURN

    # TYPO3 loads config/system/additional.php relative to its OWN root, so a
    # served site would otherwise miss the DDEV overrides — including
    # trustedHostsPattern, without which its hostname is rejected outright.
    # Symlink rather than copy so there stays one source of truth.
    # Four levels up: system -> config -> <name> -> sites -> project root.
    ln -sfn ../../../../config/system/additional.php "${dir}/config/system/additional.php"

    generate_site_composer "${name}" "${php}" || return 1

    # Sysext set is version-specific, so sync against this worktree.
    info "Syncing sites/${name}/composer.tryout.json with its Core sysexts..."
    env PROJECT_ROOT="${dir}" TRYOUT_CORE_DIR="$(core_worktree_dir "${name}")" \
        php "$(tryout_script sync-composer.php)" \
        || { error "composer sync failed for ${name}"; return 1; }

    ensure_site_database "${name}" || return 1

    # Run composer under the site's own PHP so the lock file and the generated
    # platform_check match what its vhost will actually serve.
    info "Installing dependencies for ${name} on PHP ${php} (this takes a moment)..."
    "php${php}" /usr/local/bin/composer install \
        --working-dir="${dir}" --no-interaction \
        || { error "composer install failed for ${name}"; return 1; }

    generate_site_vhost "${name}" "${php}"
    write_worktree_config

    setup_site_typo3 "${name}" || return 1

    trap - RETURN    # got to the end: the marker stands
    success "Site '${name}' prepared — PHP ${php}, db $(site_database "${name}")"
    # The HOST restarts when the hostname set changed — it can see the same
    # markers and `ddev` only works out there. So report what happened here and
    # leave the next step to it, rather than telling the user to do a thing that
    # is already being done.
    if apply_site_config "${hosts_before}"; then
        success "Applied without a restart."
    else
        info "New hostname $(site_hostname "${name}") — it needs DDEV restarted."
    fi
    echo -e "  ${DIM}then: https://$(site_hostname "${name}")/typo3/  (admin / Password.1)${NC}"
}

# Remove the site but keep the worktree and its git state.
# Where a site's settings.php is kept while the site itself is gone. Beside the
# site dir, never inside it: unserve does `rm -rf` on that directory.
site_saved_settings() { echo "${SITES_DIR}/.${1}.settings.php"; }

# Does this site's database already hold a TYPO3 install?
site_database_has_tables() {
    local db count
    db=$(site_database "$1")
    if db_is_postgres; then
        count=$(db_root_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -dc '0-9')
    else
        count=$(db_root_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}';" 2>/dev/null | tr -dc '0-9')
    fi
    [ -n "${count}" ] && [ "${count}" -gt 0 ] 2>/dev/null
}

unserve_worktree() {
    local name="$1" keep_db="${2:-true}" db
    validate_worktree_name "${name}" || return 1
    site_is_served "${name}" || { error "Site '${name}' is not served"; return 1; }

    # The database outlives the site unless --drop-db was asked for, so keep the
    # settings.php that goes with it — otherwise `serve` runs a fresh TYPO3 setup
    # against a populated database and TYPO3 refuses ("contains already N tables").
    # It holds no credentials: those are in additional.php, which serve symlinks.
    local saved settings
    saved="$(site_saved_settings "${name}")"
    settings="$(site_dir "${name}")/config/system/settings.php"
    if [ "${keep_db}" = "true" ] && [ -f "${settings}" ]; then
        mkdir -p "$(dirname "${saved}")"
        cp "${settings}" "${saved}" 2>/dev/null || true
    else
        # Dropping the database makes the old settings meaningless.
        rm -f "${saved}" 2>/dev/null || true
    fi

    rm -f "$(site_vhost_file "${name}")"
    rm -rf "$(site_dir "${name}")"
    write_worktree_config

    if [ "${keep_db}" != "true" ]; then
        db=$(site_database "${name}")
        info "Dropping database ${db}..."
        if db_is_postgres; then
            db_root_sql "DROP DATABASE IF EXISTS \"${db}\"" >/dev/null || true
        else
            db_root_sql "DROP DATABASE IF EXISTS \`${db}\`;" || true
        fi
    fi

    success "Site '${name}' removed (worktree kept)"
    # Removing a site always shrinks the hostname set, so the restart is
    # unavoidable — DDEV owns the routing rule and the certificate. Still drop the
    # vhost from the running webserver, or the site keeps answering on a hostname
    # that no longer has anything behind it.
    if in_container && sync_and_reload_webserver; then
        info "Stopped serving it now; the host releases the hostname."
    else
        info "Its hostname is released when DDEV restarts."
    fi
}

# --- Gerrit patch functions ---

# Resolve a Gerrit change number to its latest patchset ref.
# Sets: PATCH_SUBJECT, PATCH_REF, PATCH_NUMBER, PATCH_STATUS
resolve_patch_ref() {
    local change_id="$1"
    local api_url="${GERRIT_API}/changes/${change_id}?o=CURRENT_REVISION"

    local result
    local exit_code=0
    result=$(bash "$(tryout_script resolve-patch-ref.sh)" "${api_url}" 2>/dev/null) || exit_code=$?

    if [ "${exit_code}" -eq 2 ]; then
        error "Failed to fetch change ${change_id} from Gerrit (HTTP error)"
        error "  → Verify: ${GERRIT_URL}${change_id}"
        return 1
    elif [ "${exit_code}" -ne 0 ]; then
        error "Failed to parse Gerrit response for change ${change_id}"
        error "  → Verify: ${GERRIT_URL}${change_id}"
        return 1
    fi

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
    # shellcheck disable=SC2034 # read by cmd_patch in commands/host/tryout
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

# ─────────────────────────────────────────────────────────────────────
# Contribution setup helpers (TYPO3 Core / Gerrit workflow)
# ─────────────────────────────────────────────────────────────────────

# Resolve the Gerrit username.
# Priority: $1 arg > TRYOUT_GERRIT_USER env > git config tryout.gerritUser > prompt.
# Stores result via `git -C CORE_DIR config tryout.gerritUser` and echoes it.
resolve_gerrit_user() {
    local user="${1:-}"
    if [ -z "${user}" ]; then
        user="${TRYOUT_GERRIT_USER:-}"
    fi
    if [ -z "${user}" ]; then
        user=$(git -C "${CORE_DIR}" config --get tryout.gerritUser 2>/dev/null || true)
    fi
    if [ -z "${user}" ]; then
        if [ -t 0 ]; then
            read -r -p "Gerrit username (review.typo3.org): " user
        fi
    fi
    if [ -z "${user}" ]; then
        error "No Gerrit username provided."
        error "  → ddev tryout cs setup <username>   or   export TRYOUT_GERRIT_USER=<username>"
        return 1
    fi
    git -C "${CORE_DIR}" config tryout.gerritUser "${user}"
    GERRIT_USER="${user}"
}

# Look up a Gerrit account anonymously. Accounts are world-readable on review.typo3.org,
# so no credentials are needed.
# $1: query, e.g. "username:jdoe" or "email:jdoe@example.com"
# Sets GERRIT_ACCOUNT_ID / GERRIT_ACCOUNT_EMAIL / GERRIT_ACCOUNT_NAME on a single match.
# Returns 1 when the lookup failed (offline), 2 when nothing matched.
query_gerrit_account() {
    local query="$1"
    GERRIT_ACCOUNT_ID=""
    GERRIT_ACCOUNT_EMAIL=""
    GERRIT_ACCOUNT_NAME=""

    local result
    local exit_code=0
    result=$(bash "$(tryout_script resolve-gerrit-account.sh)" \
        "${GERRIT_API}" "${query}" 2>/dev/null) || exit_code=$?

    [ "${exit_code}" -eq 3 ] && return 2
    [ "${exit_code}" -ne 0 ] && return 1

    GERRIT_ACCOUNT_ID=$(echo "${result}" | sed -n '1p')
    GERRIT_ACCOUNT_EMAIL=$(echo "${result}" | sed -n '2p')
    GERRIT_ACCOUNT_NAME=$(echo "${result}" | sed -n '3p')
}

# Make sure commits are authored with an address the Gerrit account owns.
#
# The project allows "forgeCommitter" but not "forgeAuthor", so the author address of every
# commit must be a registered email of the account that pushes. Without a repository-local
# user.email, commits silently inherit the global git identity, which is a different account
# for anyone separating business and open source work. Gerrit then rejects the push.
configure_author_identity() {
    local user="$1"

    if ! query_gerrit_account "username:${user}"; then
        warn "Could not look up Gerrit account '${user}' — skipping author identity check"
        return 0
    fi
    if [ -z "${GERRIT_ACCOUNT_EMAIL}" ]; then
        warn "Gerrit account '${user}' exposes no preferred email — set one manually:"
        warn "  git -C typo3-core config user.email <your-gerrit-email>"
        return 0
    fi

    git -C "${CORE_DIR}" config tryout.gerritEmail "${GERRIT_ACCOUNT_EMAIL}"

    local current
    current=$(git -C "${CORE_DIR}" config --local --get user.email 2>/dev/null || true)
    if [ "${current}" = "${GERRIT_ACCOUNT_EMAIL}" ]; then
        success "Author identity already set to ${GERRIT_ACCOUNT_EMAIL}"
        return 0
    fi

    git -C "${CORE_DIR}" config user.email "${GERRIT_ACCOUNT_EMAIL}"
    [ -n "${GERRIT_ACCOUNT_NAME}" ] && git -C "${CORE_DIR}" config user.name "${GERRIT_ACCOUNT_NAME}"
    success "Author identity set to ${GERRIT_ACCOUNT_EMAIL} (repository-local)"

    if [ -n "${current}" ]; then
        warn "Previous value was ${current} — amend commits made before this with:"
        warn "  git -C typo3-core commit --amend --reset-author --no-edit"
    fi
}

# Fall back to the address cs setup cached when Gerrit cannot be reached.
# Only an exact match is conclusive: the cache holds the account's preferred address,
# while an account may legitimately author with any of its registered addresses. A
# differing address is therefore left unknown rather than reported as a mismatch.
author_status_from_cache() {
    local cached
    cached=$(git -C "${CORE_DIR}" config --get tryout.gerritEmail 2>/dev/null || true)
    [ -n "${cached}" ] || return 1
    [ "${cached}" = "${CS_AUTHOR_EMAIL}" ] || return 1

    CS_AUTHOR_STATUS="ok"
    CS_AUTHOR_SOURCE="cache"
}

# Check the configured author email against Gerrit.
# Sets CS_AUTHOR_EMAIL, CS_AUTHOR_SCOPE (local|inherited|none),
# CS_AUTHOR_STATUS (ok|mismatch|unregistered|unknown|no-email) and
# CS_AUTHOR_SOURCE (live|cache), which tells where an "ok" verdict came from.
inspect_author_identity() {
    CS_AUTHOR_EMAIL=$(git -C "${CORE_DIR}" config --get user.email 2>/dev/null || true)
    CS_AUTHOR_SCOPE="none"
    CS_AUTHOR_STATUS="no-email"
    CS_AUTHOR_SOURCE="live"
    [ -z "${CS_AUTHOR_EMAIL}" ] && return 0

    if [ -n "$(git -C "${CORE_DIR}" config --local --get user.email 2>/dev/null || true)" ]; then
        CS_AUTHOR_SCOPE="local"
    else
        CS_AUTHOR_SCOPE="inherited"
    fi

    local user="${CS_USER:-}"
    if [ -z "${user}" ]; then
        CS_AUTHOR_STATUS="unknown"
        return 0
    fi

    # Resolve both sides to account ids: an account may have several registered addresses and
    # only the preferred one is visible anonymously, so comparing email strings is not enough.
    local expected_id
    if ! query_gerrit_account "username:${user}"; then
        author_status_from_cache || CS_AUTHOR_STATUS="unknown"
        return 0
    fi
    expected_id="${GERRIT_ACCOUNT_ID}"

    local rc=0
    query_gerrit_account "email:${CS_AUTHOR_EMAIL}" || rc=$?
    case "${rc}" in
        0) [ "${GERRIT_ACCOUNT_ID}" = "${expected_id}" ] \
               && CS_AUTHOR_STATUS="ok" || CS_AUTHOR_STATUS="mismatch" ;;
        2) CS_AUTHOR_STATUS="unregistered" ;;
        *) author_status_from_cache || CS_AUTHOR_STATUS="unknown" ;;
    esac
}

# Install the Gerrit commit-msg hook (Change-Id) from TYPO3 Core's copy.
install_commit_msg_hook() {
    local src="${CORE_DIR}/Build/git-hooks/commit-msg"
    local dst="${CORE_GIT_DIR}/hooks/commit-msg"

    if [ ! -f "${src}" ]; then
        warn "commit-msg hook not found at ${src} — Core may be too old."
        return 1
    fi
    cp "${src}" "${dst}"
    chmod +x "${dst}"
    success "Installed commit-msg hook (Change-Id generator)"
}

# Install the TYPO3 Core pre-commit hook (CGL / PHP-CS-Fixer checks).
install_pre_commit_hook() {
    local src="${CORE_DIR}/Build/git-hooks/unix+mac/pre-commit"
    local dst="${CORE_GIT_DIR}/hooks/pre-commit"

    if [ ! -f "${src}" ]; then
        warn "pre-commit hook not found at ${src}"
        return 1
    fi
    cp "${src}" "${dst}"
    chmod +x "${dst}"
    success "Installed pre-commit hook (CGL checks)"
}

# Remove installed hooks.
remove_hooks() {
    rm -f "${CORE_GIT_DIR}/hooks/commit-msg" "${CORE_GIT_DIR}/hooks/pre-commit"
    success "Removed commit-msg and pre-commit hooks"
}

# Install the commit-message template and wire it into git config.
install_commit_template() {
    if [ ! -f "${COMMIT_TEMPLATE_SRC}" ]; then
        warn "Commit template not found at ${COMMIT_TEMPLATE_SRC}"
        return 1
    fi
    # Point git directly at the canonical template under .ddev/tryout/.
    # The path is given relative to the typo3-core working tree so it resolves
    # correctly both on the host (when running `git commit` from typo3-core/)
    # and inside the DDEV container.
    local tmpl_path="../.ddev/tryout/gitmessage.txt"
    git -C "${CORE_DIR}" config commit.template "${tmpl_path}"
    # Drop any leftover copy from an older setup; the canonical file lives
    # in .ddev/tryout/ now.
    rm -f "${CORE_GIT_DIR}message.txt"
    success "Commit template wired to ${DIM}${tmpl_path}${NC}"
}

# Configure push URL to Gerrit SSH so `git push` submits to review.
configure_gerrit_push_url() {
    local user="${1:-${GERRIT_USER:-}}"
    if [ -z "${user}" ]; then
        error "configure_gerrit_push_url: no username"
        return 1
    fi
    local push_url="ssh://${user}@${GERRIT_SSH_HOST}:${GERRIT_SSH_PORT}/${GERRIT_PROJECT}"
    git -C "${CORE_DIR}" remote set-url --push origin "${push_url}"
    # Refs go to refs/for/<branch> — user still needs `git push origin HEAD:refs/for/main`.
    success "Push URL set: ${DIM}${push_url}${NC}"
}

# Diagnose Gerrit SSH reachability + authentication.
# Returns 0 on full success. On failure sets CS_SSH_REASON to one of:
#   no-user       no Gerrit username configured
#   unreachable   TCP port 29418 is not reachable
#   no-agent-key  reachable, but ddev-ssh-agent holds no identities
#   denied        keys were presented but Gerrit refused them
diagnose_gerrit_ssh() {
    local user="${1:-${GERRIT_USER:-}}"
    CS_SSH_REASON=""
    if [ -z "${user}" ]; then
        CS_SSH_REASON="no-user"
        return 1
    fi

    # 1. Raw TCP reachability to the Gerrit SSH port.
    #
    # NOT bash's /dev/tcp: on macOS the kernel SIGKILLs a shell that opens one to
    # an external host, so the probe died with "Killed: 9" printed straight to the
    # terminal and the doctor then reported the port unreachable — on a machine
    # where it was reachable, and one line after a successful authenticated call
    # to the very same host. (Verified: /dev/tcp to 127.0.0.1 works, to any
    # external host it is killed, rc=137.)
    #
    # `nc -z -w` is quiet, takes the same flags on the BSD nc macOS ships and on
    # GNU/OpenBSD nc, and reports the truth. Where there is no nc at all, skip
    # this step rather than guess: the auth probe below is a real connection to the
    # same host and port, so an unreachable server cannot slip through — it just
    # says "denied" instead of "unreachable".
    if command -v nc >/dev/null 2>&1; then
        if ! nc -z -w 5 "${GERRIT_SSH_HOST}" "${GERRIT_SSH_PORT}" >/dev/null 2>&1; then
            CS_SSH_REASON="unreachable"
            return 1
        fi
    fi

    # 2. Ask SSH, rather than guess from what an agent happens to hold. This is the
    #    thing being reported on, so it decides — an ssh-add check ahead of it
    #    answers a DIFFERENT question and used to return early on its answer:
    #    a host whose agent is empty but which authenticates from a key on disk
    #    (~/.ssh/id_rsa, offered and accepted by Gerrit — the ordinary case) was
    #    told "no-agent-key" and pointed at an ssh-add it did not need.
    #
    #    Costs one round trip where the early return was free. Worth it: the
    #    short-circuit was cheap because it was answering the wrong question.
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           -p "${GERRIT_SSH_PORT}" "${user}@${GERRIT_SSH_HOST}" gerrit version >/dev/null 2>&1; then
        return 0
    fi

    # 3. It failed — now work out why, to say something better than "denied".
    #    No identity anywhere is its own diagnosis: in the CONTAINER that is the
    #    normal shape of the problem, since ~/.ssh there holds only `config` and
    #    the forwarded ddev-ssh-agent is the only route, so an empty one fails
    #    with a misleading "permission denied". A key present but refused is a
    #    different fix (upload it to Gerrit), so keep the two apart.
    #
    #    The on-disk test mirrors what ssh itself would try by default. Plain
    #    globbing, no bash-4 features.
    local have_key="false" k
    ssh-add -l >/dev/null 2>&1 && have_key="true"
    if [ "${have_key}" = "false" ]; then
        for k in "${HOME}/.ssh"/id_*; do
            case "${k}" in *.pub) continue ;; esac
            [ -r "${k}" ] && { have_key="true"; break; }
        done
    fi
    if [ "${have_key}" = "false" ]; then
        CS_SSH_REASON="no-agent-key"
        return 1
    fi

    CS_SSH_REASON="denied"
    return 1
}

# Back-compat wrapper: older callers just want a 0/non-zero answer.
verify_gerrit_ssh() {
    diagnose_gerrit_ssh "$@"
}

# Produce a short, dim-coloured next-step hint for the current CS_SSH_REASON.
# Used by both the setup flow and the doctor report.
gerrit_ssh_hint() {
    case "${CS_SSH_REASON:-}" in
        no-user)
            echo "→ set a username: ddev tryout cs setup <gerrit-user>" ;;
        unreachable)
            echo "→ check firewall/VPN for ${GERRIT_SSH_HOST}:${GERRIT_SSH_PORT}" ;;
        no-agent-key)
            if in_container; then
                echo "→ ddev auth ssh   (hands your host keys to ddev-ssh-agent)"
            else
                echo "→ load your key into your host SSH agent, e.g.: ssh-add ~/.ssh/id_ed25519"
            fi ;;
        denied)
            echo "→ upload your public key at https://review.typo3.org/settings/#SSHKeys" ;;
        *)
            echo "" ;;
    esac
}

# One line about the HOST's SSH agent, printed after cs setup/doctor ran in the
# container. The probe in there covers ddev-ssh-agent; a push from a host shell
# uses the host's keys instead, and both answers are worth having.
host_gerrit_ssh_report() {
    local user="${1:-}"
    [ -n "${user}" ] || return 0
    if diagnose_gerrit_ssh "${user}"; then
        echo -e "  Host SSH:        ${GREEN}✓${NC} reachable (authenticated) — pushing from a host shell works"
    else
        echo -e "  Host SSH:        ${YELLOW}!${NC} ${CS_SSH_REASON} ${DIM}$(gerrit_ssh_hint)${NC}"
    fi
    echo ""
}

# Report the current state of contribution setup.
# Sets: CS_HOOK_COMMIT_MSG, CS_HOOK_PRE_COMMIT, CS_TEMPLATE, CS_PUSH_URL, CS_USER (0/1 flags or value)
inspect_contribution_setup() {
    CS_HOOK_COMMIT_MSG=0
    CS_HOOK_PRE_COMMIT=0
    CS_TEMPLATE=0
    CS_PUSH_URL=""
    CS_USER=""

    [ -x "${CORE_GIT_DIR}/hooks/commit-msg" ] && CS_HOOK_COMMIT_MSG=1
    [ -x "${CORE_GIT_DIR}/hooks/pre-commit" ]  && CS_HOOK_PRE_COMMIT=1

    local tmpl
    tmpl=$(git -C "${CORE_DIR}" config --get commit.template 2>/dev/null || true)
    if [ -n "${tmpl}" ] && [ -f "${CORE_DIR}/${tmpl}" ]; then
        CS_TEMPLATE=1
    fi

    CS_PUSH_URL=$(git -C "${CORE_DIR}" remote get-url --push origin 2>/dev/null || true)
    CS_USER=$(git -C "${CORE_DIR}" config --get tryout.gerritUser 2>/dev/null || true)
}

# ─────────────────────────────────────────────────────────────────────
# Contribution setup (ddev tryout cs)
# ─────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────
# setup — Wire up hooks, template, push URL
# ─────────────────────────────────────────────────────────────────────
cmd_cs_setup() {
    require_core

    echo ""
    echo -e "${BOLD}TYPO3 Core — Contribution Setup${NC}"
    echo "─────────────────────────────────────"
    echo ""

    info "[1/6] Resolving Gerrit username..."
    if ! resolve_gerrit_user "${1:-}"; then
        exit 1
    fi
    echo -e "       ${DIM}user: ${GERRIT_USER}${NC}"
    echo ""

    info "[2/6] Installing commit-msg hook (Change-Id)..."
    install_commit_msg_hook || warn "commit-msg hook install skipped"
    echo ""

    info "[3/6] Installing pre-commit hook (CGL checks)..."
    install_pre_commit_hook || warn "pre-commit hook install skipped"
    echo ""

    info "[4/6] Installing commit-message template..."
    install_commit_template || warn "template install skipped"
    echo ""

    info "[5/6] Configuring Gerrit push URL..."
    configure_gerrit_push_url "${GERRIT_USER}"
    echo ""

    info "[6/6] Configuring commit author identity..."
    configure_author_identity "${GERRIT_USER}"
    echo ""

    # Optional SSH probe — informational only
    info "Probing Gerrit SSH (${GERRIT_USER}@${GERRIT_SSH_HOST}:${GERRIT_SSH_PORT})..."
    if diagnose_gerrit_ssh "${GERRIT_USER}"; then
        success "SSH reachable — you can push to Gerrit"
    else
        warn "SSH probe failed (${CS_SSH_REASON})"
        echo -e "       ${DIM}$(gerrit_ssh_hint)${NC}"
    fi

    echo ""
    echo "─────────────────────────────────────"
    success "Contribution setup complete!"
    echo ""
    echo -e "  ${BOLD}Push a change for review:${NC}"
    echo -e "    ${DIM}cd typo3-core && git push origin HEAD:refs/for/${BRANCH}${NC}"
    echo ""
    echo -e "  ${BOLD}Diagnose state:${NC} ddev tryout cs doctor"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────
# doctor — Diagnose current contribution setup
# ─────────────────────────────────────────────────────────────────────
cmd_cs_doctor() {
    require_core
    inspect_contribution_setup

    local OK="${GREEN}✓${NC}"
    local FAIL="${RED}✗${NC}"
    local WARN="${YELLOW}!${NC}"

    echo ""
    echo -e "${BOLD}Contribution Setup — Doctor${NC}"
    echo "─────────────────────────────────────"

    if [ -n "${CS_USER}" ]; then
        echo -e "  Gerrit user:     ${OK} ${CS_USER}"
    else
        echo -e "  Gerrit user:     ${FAIL} not set"
        echo -e "                   ${DIM}→ ddev tryout cs setup <username>${NC}"
    fi

    if [ "${CS_HOOK_COMMIT_MSG}" = "1" ]; then
        echo -e "  commit-msg hook: ${OK} installed"
    else
        echo -e "  commit-msg hook: ${FAIL} missing"
    fi

    if [ "${CS_HOOK_PRE_COMMIT}" = "1" ]; then
        echo -e "  pre-commit hook: ${OK} installed"
    else
        echo -e "  pre-commit hook: ${FAIL} missing"
    fi

    if [ "${CS_TEMPLATE}" = "1" ]; then
        echo -e "  Commit template: ${OK} configured"
    else
        echo -e "  Commit template: ${FAIL} not set"
    fi

    if echo "${CS_PUSH_URL}" | grep -q "^ssh://.*@${GERRIT_SSH_HOST}"; then
        echo -e "  Push URL:        ${OK} ${CS_PUSH_URL}"
    elif [ -n "${CS_PUSH_URL}" ]; then
        echo -e "  Push URL:        ${WARN} ${CS_PUSH_URL}"
        echo -e "                   ${DIM}(not pointing at Gerrit SSH)${NC}"
    else
        echo -e "  Push URL:        ${FAIL} origin missing"
    fi

    inspect_author_identity
    case "${CS_AUTHOR_STATUS}" in
        ok)
            echo -e "  Author identity: ${OK} ${CS_AUTHOR_EMAIL}"
            if [ "${CS_AUTHOR_SOURCE}" = "cache" ]; then
                echo -e "                   ${DIM}(from cache — Gerrit unreachable)${NC}"
            fi
            if [ "${CS_AUTHOR_SCOPE}" != "local" ]; then
                echo -e "                   ${WARN} inherited from your global git config"
                echo -e "                   ${DIM}→ ddev tryout cs setup ${CS_USER}${NC}"
            fi
            ;;
        mismatch)
            echo -e "  Author identity: ${FAIL} ${CS_AUTHOR_EMAIL} belongs to another Gerrit account"
            echo -e "                   ${DIM}→ ddev tryout cs setup ${CS_USER}${NC}"
            ;;
        unregistered)
            echo -e "  Author identity: ${FAIL} ${CS_AUTHOR_EMAIL} is not registered on Gerrit"
            echo -e "                   ${DIM}pushes are rejected as \"invalid author\"${NC}"
            echo -e "                   ${DIM}→ ddev tryout cs setup ${CS_USER}${NC}"
            ;;
        no-email)
            echo -e "  Author identity: ${FAIL} no user.email configured"
            echo -e "                   ${DIM}→ ddev tryout cs setup ${CS_USER}${NC}"
            ;;
        *)
            echo -e "  Author identity: ${WARN} ${CS_AUTHOR_EMAIL} (could not verify)"
            ;;
    esac

    # Live SSH check (only if we have a user)
    if [ -n "${CS_USER}" ]; then
        if diagnose_gerrit_ssh "${CS_USER}"; then
            echo -e "  Gerrit SSH:      ${OK} reachable (authenticated)"
        else
            case "${CS_SSH_REASON}" in
                unreachable)
                    echo -e "  Gerrit SSH:      ${FAIL} network unreachable" ;;
                no-agent-key)
                    echo -e "  Gerrit SSH:      ${WARN} no key in ddev-ssh-agent" ;;
                denied)
                    echo -e "  Gerrit SSH:      ${FAIL} auth denied by Gerrit" ;;
                *)
                    echo -e "  Gerrit SSH:      ${FAIL} probe failed (${CS_SSH_REASON})" ;;
            esac
            echo -e "                   ${DIM}$(gerrit_ssh_hint)${NC}"
        fi
    fi

    echo "─────────────────────────────────────"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────
# uninstall — Revert contribution setup
# ─────────────────────────────────────────────────────────────────────
cmd_cs_uninstall() {
    require_core

    info "Removing git hooks..."
    remove_hooks

    info "Unsetting commit template..."
    git -C "${CORE_DIR}" config --unset commit.template 2>/dev/null || true
    rm -f "${CORE_DIR}/.gitmessage.txt"

    info "Resetting origin push URL to fetch URL..."
    local fetch_url
    fetch_url=$(git -C "${CORE_DIR}" remote get-url origin 2>/dev/null || echo "")
    if [ -n "${fetch_url}" ]; then
        git -C "${CORE_DIR}" remote set-url --push origin "${fetch_url}"
    fi

    git -C "${CORE_DIR}" config --unset tryout.gerritUser 2>/dev/null || true
    git -C "${CORE_DIR}" config --unset tryout.gerritEmail 2>/dev/null || true
    success "Contribution setup removed"
}

cmd_cs_help() {
    echo ""
    echo -e "${BOLD}ddev tryout cs${NC} — TYPO3 Core contribution setup"
    echo ""
    echo "Commands:"
    echo -e "  ${BOLD}setup [user]${NC}   Install hooks, template, and Gerrit push URL (default)"
    echo -e "  ${BOLD}doctor${NC}         Diagnose the current contribution setup"
    echo -e "  ${BOLD}uninstall${NC}      Remove hooks, template, and reset push URL"
    echo -e "  ${BOLD}help${NC}           Show this help"
    echo ""
    echo "Username resolution order:"
    echo "  1. argument:   ddev tryout cs setup jdoe"
    echo "  2. env:        TRYOUT_GERRIT_USER=jdoe"
    echo "  3. git config: tryout.gerritUser (cached from previous setup)"
    echo "  4. prompt      (interactive)"
    echo ""
}
