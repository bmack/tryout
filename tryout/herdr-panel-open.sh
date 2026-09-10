#!/usr/bin/env bash
#ddev-generated

# Dock the tryout panel, focus it if it is already there, close it if it is the pane
# you are standing in. Reached from `ddev tryout panel` and from the plugin action.
#
# Every herdr call goes through the local herdr_cli below. A bare `herdr` means the
# DEFAULT session, but worktree workspaces live in `tryout-<project>`; cmd_panel
# works out which one the caller is in and passes it as TRYOUT_PANEL_SESSION.

set -uo pipefail

PANE_LABEL="tryout"
LOCK_DIR="${TMPDIR:-/tmp}/ddev-tryout-panel.lock"
LOCK_STALE_MINS=1
# Must match PANEL_DOCK_RATIO in functions.sh: `ddev tryout herdr` docks panels
# with that one, and the two routes have to produce the same panel. This script
# runs outside DDEV and cannot source that file, so the value is repeated here —
# a unit test pins them together.
DOCK_RATIO="0.78"

err() { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; }

command -v herdr >/dev/null 2>&1 || { err "herdr is not installed on the host"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq is not installed on the host"; exit 1; }
[ "${HERDR_ENV:-}" = "1" ] || { err "Run this from inside herdr."; exit 1; }

# Two focus events can arrive while a split is still being set up; without a lock
# each would see no panel and open one. mkdir is the atomic primitive everywhere.
take_lock() {
    local i=0
    while [ "${i}" -lt 20 ]; do
        if mkdir "${LOCK_DIR}" 2>/dev/null; then
            trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT INT TERM
            return 0
        fi
        # A crashed run must not wedge the panel forever. `find -mtime` is in POSIX
        # and answers on both userlands, unlike stat, whose format flag differs.
        local stale=""
        if [ -d "${LOCK_DIR}" ]; then
            stale=$(find "${LOCK_DIR}" -maxdepth 0 -mmin "+${LOCK_STALE_MINS}" 2>/dev/null)
        fi
        # Break a stale lock, but never spin on it: `continue` here used to skip
        # both the sleep and the counter, so a lock that cannot be removed — one
        # with anything inside it — pinned a CPU forever with no output.
        [ -n "${stale}" ] && rmdir "${LOCK_DIR}" 2>/dev/null
        sleep 0.25
        i=$(( i + 1 ))
    done
    return 1
}

# Every herdr call goes through this. A bare `herdr` means the DEFAULT session,
# but worktree workspaces live in `tryout-<project>` — searching the wrong one is
# what once made the panel look already-open while nothing was on screen.
# TRYOUT_PANEL_SESSION is set by cmd_panel when the caller is in that session;
# empty means the ambient one, which is right for a plain herdr session.
herdr_cli() {
    if [ -n "${TRYOUT_PANEL_SESSION:-}" ]; then
        herdr --session "${TRYOUT_PANEL_SESSION}" "$@"
    else
        herdr "$@"
    fi
}

panes_json() { herdr_cli pane list 2>/dev/null; }

current_tab() {
    printf '%s' "${HERDR_TAB_ID:-}"
}

# Our pane in THIS tab, if it is there. Two rules, both learned the hard way:
# a label alone is not proof the panel is alive — it survives a herdr server
# restart while the process behind it does not — and the tab filter must never
# fall back to "any tab", because every worktree workspace carries a pane with
# this same label, so an unfiltered match finds a foreign panel and docks nothing
# where the user asked.
find_panel_pane() {
    local tab="$1"
    [ -n "${tab}" ] || return 0
    panes_json | jq -r --arg label "${PANE_LABEL}" --arg tab "${tab}" '
        .result.panes[]
        | select(.label == $label and .tab_id == $tab)
        | .pane_id' 2>/dev/null | head -n1
}

# Is that pane RUNNING THE PANEL, not merely alive? `pane process-info` answers for
# any live pane, a shell included, so it cannot tell a panel from the prompt left
# behind when one is closed with q or esc — and treating that as open makes this
# command focus a bare shell instead of docking a panel. The terminal title carries
# the running command, which is what tells them apart. Same test as
# panel_pane_is_running in functions.sh; both routes must agree on "alive".
pane_is_alive() {
    local id="$1"
    [ -n "${id}" ] || return 1
    herdr_cli pane list 2>/dev/null \
        | jq -e --arg p "${id}" \
            '[.result.panes[]? | select(.pane_id == $p)
              | (.terminal_title // "") | test("herdr-panel")] | any' \
            >/dev/null 2>&1
}

# The pane this command was invoked from. NEVER the UI-focused one: herdr's own
# guidance is that "omitting a target may use the UI-focused pane, which can belong
# to the user or another client" — and it does. Docking against it put the panel in
# whichever workspace happened to hold focus, which is how it went missing.
# DDEV passes the caller's environment through to a host command, so HERDR_PANE_ID
# is present and identifies the right pane even while another client holds focus.
calling_pane() {
    printf '%s' "${HERDR_PANE_ID:-}"
}

open_panel() {
    local cwd="$1" target new
    target="$(calling_pane)"
    [ -n "${target}" ] || {
        err "herdr did not say which pane this ran from (HERDR_PANE_ID)"
        err "  → run 'ddev tryout panel' from a pane inside herdr"
        return 1
    }

    # Always split right; the panel is the narrow half. A left dock would need a
    # pane swap afterwards, which is a setting this does not offer yet.
    #
    # The same three variables ensure_panel_pane passes, or this panel is not the
    # one `ddev tryout herdr` opens: without the session its popup would ask the
    # DEFAULT server and silently open nothing, and without the approot it would
    # have to guess where the project is.
    new=$(herdr_cli pane split "${target}" --direction right --ratio "${DOCK_RATIO}" \
            --no-focus --cwd "${cwd}" \
            ${PANEL_WORKTREE:+--env "TRYOUT_PANEL_WORKTREE=${PANEL_WORKTREE}"} \
            --env "TRYOUT_PANEL_APPROOT=${cwd}" \
            --env "TRYOUT_PANEL_SESSION=${TRYOUT_PANEL_SESSION:-}" 2>/dev/null \
          | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
    if [ -z "${new}" ]; then
        err "Could not split a pane for the panel"
        return 1
    fi

    herdr_cli pane rename "${new}" "${PANE_LABEL}" >/dev/null 2>&1 || true
    herdr_cli pane run "${new}" bash "${cwd}/.ddev/tryout/herdr-panel.sh" >/dev/null 2>&1 \
        || { err "Could not start the panel in its pane"; return 1; }
    return 0
}

# Which worktree the caller is standing in, so a panel docked by hand is scoped
# exactly like one `ddev tryout herdr` opens. The calling pane's directory is the
# honest source: DDEV runs this from the project root whatever the user's cwd.
PANEL_WORKTREE=""
caller_dir="$(panes_json \
    | jq -r --arg p "$(calling_pane)" \
        '.result.panes[]? | select(.pane_id == $p) | .foreground_cwd // .cwd' \
        2>/dev/null | head -1)"

APPROOT="${DDEV_APPROOT:-${PWD}}"
[ -f "${APPROOT}/.ddev/tryout/herdr-panel.sh" ] \
    || { err "The tryout add-on is not installed in ${APPROOT}"; exit 1; }

case "${caller_dir}" in
    "${APPROOT}/typo3-core-"*)
        PANEL_WORKTREE="${caller_dir#"${APPROOT}/typo3-core-"}"
        # Only the top of a worktree counts, not a directory inside one.
        case "${PANEL_WORKTREE}" in */*) PANEL_WORKTREE="" ;; esac ;;
esac

take_lock || { err "Another panel operation is in progress"; exit 1; }

TAB="$(current_tab)"
EXISTING="$(find_panel_pane "${TAB}")"

if [ -n "${EXISTING}" ]; then
    if pane_is_alive "${EXISTING}"; then
        # Toggle: running this from the panel itself means close it.
        if [ "${EXISTING}" = "$(calling_pane)" ]; then
            herdr_cli pane close "${EXISTING}" >/dev/null 2>&1
            exit 0
        fi
        # Otherwise it is open in this tab already. herdr 0.9 has no
        # focus-a-pane-by-id — `pane focus` only moves in a DIRECTION, and
        # `--current` is meaningless here because a DDEV host command is not
        # itself a pane. The panel is the right-hand half of the split, so step
        # right from the caller; if that lands elsewhere, say where it is rather
        # than moving focus somewhere unexpected.
        if ! herdr_cli pane focus --pane "$(calling_pane)" --direction right >/dev/null 2>&1; then
            printf 'The tryout panel is already open in this tab (%s).\n' "${EXISTING}"
        fi
        exit 0
    fi
    # A corpse from a restarted server: the label outlived the process. Take it
    # out before opening a new one, or the next run would focus a dead pane.
    herdr_cli pane close "${EXISTING}" >/dev/null 2>&1 || true
fi

open_panel "${APPROOT}"
