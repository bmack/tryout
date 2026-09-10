#!/usr/bin/env bash
#ddev-generated

# One command from the tryout panel, run in a herdr popup.
#
# Everything runs here, where there is a TTY and therefore gum: the verbs prompt
# with their own ask_* helpers rather than this script reimplementing any of them.
# The popup is session-modal, so a long verb does hold the session until it is
# done — accepted deliberately, because the alternative left a stray pane behind
# after every run.
#
# The panel is opened per project but this script is reached through a globally
# registered plugin action, so the project is resolved from the CWD, not from $0.

set -uo pipefail

RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Wait for the reader, but only where there is one. With no terminal `read` hits
# EOF and returns at once, so the window would close before anything could be read
# — which looks exactly like the command never ran.
pause() {
    printf "\n  ${DIM}press any key to close${NC} "
    if [ -t 0 ]; then
        # ALWAYS bounded. Run inline in the panel's own pane, an unbounded read
        # holds that pane forever if the keystroke never comes — the panel stops
        # redrawing and the whole thing looks dead. 60s is long enough to read
        # the output and short enough to always come back.
        read -r -n1 -s -t 60 2>/dev/null || true
    else
        # Nobody to press a key: hold the output long enough to be read.
        sleep 5
    fi
    printf '\n'
}

fail() {
    printf "${RED}✗${NC} %s\n" "$*"
    pause
    exit 1
}

# The CWD decides, not $0: a plugin action is registered for the whole machine, so
# $0 points at whichever checkout installed it. A popup inherits the focused pane's
# directory, which is the project the user is actually looking at.
resolve_approot() {
    local dir="${PWD}"
    while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
        if [ -d "${dir}/.ddev" ] && compgen -G "${dir}/.ddev/config*.yaml" >/dev/null 2>&1; then
            echo "${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    return 1
}

# Positional when run directly (the no-herdr fallback); TRYOUT_PANEL_VERB when
# opened as a plugin pane, which takes no arguments of its own.
VERB="${1:-${TRYOUT_PANEL_VERB:-}}"
[ -n "${VERB}" ] || fail "No command given."

# Tell the panel we actually started. It cannot find out any other way: herdr
# answers "ok" whether or not it had a UI to draw into, the verb travels in the
# environment (unreadable from outside on macOS), and the popup's parent is the
# herdr server rather than the panel — so neither pgrep nor ppid can identify it.
PANEL_STARTED_MARKER="${TMPDIR:-/tmp}/tryout-panel-started.$$"
if [ -n "${TRYOUT_PANEL_STARTED:-}" ]; then
    PANEL_STARTED_MARKER="${TRYOUT_PANEL_STARTED}"
    : > "${PANEL_STARTED_MARKER}" 2>/dev/null || true
fi

# The creator knew the project root; only work it out when started by hand.
APPROOT="${TRYOUT_PANEL_APPROOT:-}"
[ -n "${APPROOT}" ] || APPROOT="$(resolve_approot)" \
    || fail "No DDEV project here — the tryout panel only drives one from inside it."
[ -f "${APPROOT}/.ddev/tryout/functions.sh" ] \
    || fail "$(basename "${APPROOT}") is a DDEV project, but the tryout add-on is not installed in it."
command -v ddev >/dev/null 2>&1 || fail "ddev not found on the host."

# The session these workspaces live in, derived the way herdr_session_name does —
# this script cannot source functions.sh, and DDEV exports DDEV_SITENAME only to
# commands it runs itself, while this one is launched by herdr.
herdr_session() {
    local n="${DDEV_SITENAME:-}"
    if [ -z "${n}" ] && [ -f "${APPROOT}/.ddev/config.yaml" ]; then
        n="$(sed -n 's/^name: *//p' "${APPROOT}/.ddev/config.yaml" 2>/dev/null \
             | head -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
    fi
    [ -n "${n}" ] && { printf 'tryout-%s' "${n}"; return; }
    printf 'tryout'
}

# Nudge the panel that launched this popup into redrawing.
#
# The panel blocks in `read` with no timeout, and its popup path returns the moment
# the popup STARTS — so after a command that changed what the worktree is, it sits
# there showing the world as it was, until the user happens to press a key. One
# keystroke is all it needs: render rebuilds the whole menu, so a single byte
# repaints the rows, the state line and the branch line together.
#
# `space` deliberately: the panel's loop handles q, j, k, Enter and ESC — quit,
# move, run, close — and lets everything else fall through to a clean redraw.
#
# No pane means this was not opened by a panel (the runner takes a verb positionally
# too), so there is nothing to wake.
wake_panel() {
    [ -n "${TRYOUT_PANEL_PANE:-}" ] || return 0
    command -v herdr >/dev/null 2>&1 || return 0
    herdr --session "$(herdr_session)" pane send-keys "${TRYOUT_PANEL_PANE}" space \
        >/dev/null 2>&1 || true
    return 0
}

cd "${APPROOT}" || fail "Cannot enter ${APPROOT}"

printf "\n  ${BOLD}ddev tryout %s${NC}\n\n" "${VERB}"

# Every verb runs right here, however long it takes. Splitting a pane for the slow
# ones left one behind after every run, which is the clutter the panel exists to
# avoid; and the long verbs stream their own [1/4] progress, so a popup showing
# them is a live log rather than a frozen box.
# shellcheck disable=SC2086
ddev tryout ${VERB}
rc=$?

# A verb that changes which worktrees exist leaves the herdr session out of step:
# `worktree remove` and `unserve` strand a workspace whose checkout is gone, and
# `add` without --herdr leaves a worktree with none. A bare `ddev tryout herdr`
# is the reconcile pass for exactly that — it opens what is missing and closes
# what is orphaned — so run it here, where the command has actually finished.
#
# Only for those verbs: it walks every workspace, which is wasted work after a
# patch or a launch, and only on success, since a failed command changed nothing.
case "${rc}:${VERB}" in
    # checkout moves the branch, so the sidebar token for this worktree is now
    # wrong; the reconcile pass re-reports it for every workspace along the way.
    # Cheaper than a bespoke path, and it is the same pass either verb needs.
    0:worktree\ *|0:checkout*)
        printf "\n  ${DIM}reloading workspaces…${NC}\n"
        # --no-focus: this is a background reconcile, not the user asking to be
        # taken somewhere. Without it every panel command lands you on the FIRST
        # worktree alphabetically, whichever space you were actually working in.
        ddev tryout herdr --no-focus >/dev/null 2>&1 || true
        ;;
esac

# Done, and nothing went wrong: close the popup rather than making the user
# dismiss a report of a success. ANY verb can change what the panel shows — serve
# and unserve change its rows, checkout and patch its branch line — so the panel
# is woken whatever ran, not just for the verbs that need the reconcile above.
#
# The exception is a verb whose OUTPUT is the point. `status` renders a screenful
# of project state and `exec` shows whatever was typed; closing those the instant
# they succeed would flash the answer past unread. They changed nothing, so the
# panel is woken anyway and only the pause is kept.
#
# A failure always keeps the popup: its output is the only place the error is
# written, and closing over it would leave a panel that looks unchanged.
if [ "${rc}" -eq 0 ]; then
    wake_panel
    case "${VERB}" in
        status*|exec*) ;;
        *)             exit 0 ;;
    esac
fi

[ "${rc}" -eq 0 ] || printf "\n${RED}✗${NC} exited ${rc}\n"
pause
exit "${rc}"
