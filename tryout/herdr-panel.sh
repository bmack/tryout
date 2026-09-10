#!/usr/bin/env bash
#ddev-generated

# The tryout command panel: a narrow herdr pane listing the commands worth reaching
# for, driven by click or keystroke.
#
# It runs INSIDE the pane it draws. herdr calls go through the local herdr_cli
# below, which pins the session its creator was in: a bare `herdr` means the
# DEFAULT session, and these workspaces live in `tryout-<project>`. Getting that
# wrong is why the panel once opened where nobody was looking.
#
# Mouse: herdr forwards clicks and wheel to a pane app that asks for them, so
# enabling SGR reporting is all that is needed. Right-click is NOT available — herdr
# keeps it for its own pane menu unless the user sets right_click_passthrough_modifier
# in their global config, so nothing here may depend on it.

set -uo pipefail

# Every colour here names its own FOREGROUND. A bare attribute (ESC[1m bold,
# ESC[2m dim) only modifies the colour the pane already had, so on a pane whose
# default foreground is dark the whole panel drew dark-on-dark and looked blank.
BOLD='\033[1;97m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
# Dim carries its OWN foreground for the same reason ROW below does: bare ESC[2m
# dims whatever colour the pane already had, so on a pane with a dark default the
# secondary lines — state, branch, hint, footer — came out invisible rather than
# quiet. 37 (white) dimmed is the grey this wants; 2m alone is a guess about the
# terminal.
DIM='\033[2;37m'
# The selected row. Explicit white-on-black, never reverse video: ESC[7m swaps
# whatever the terminal's CURRENT colours are, which in a dark theme can come out
# near-invisible — the selection was there, you just could not see it.
SEL_ON='\033[97;40m'
# An UNSELECTED row, and the reason it needs a colour of its own: printing it bare
# leaves it at whatever foreground the pane happens to carry, and SEL_ON pins the
# background to black (40) for the selected row. A pane whose default foreground is
# dark therefore drew every other row black on black — the rows were there, the
# menu just looked empty apart from the highlight. Say white explicitly, so the
# panel never depends on a colour it did not set.
ROW='\033[97m'

# Where this panel is and what it drives. The pane's creator knows all three and
# hands them over, because this runs outside DDEV and cannot source functions.sh:
# that file wants DDEV_APPROOT and sets forty globals a herdr pane has none of.
WORKTREE="${TRYOUT_PANEL_WORKTREE:-}"
APPROOT="${TRYOUT_PANEL_APPROOT:-}"

# Started by hand rather than by the workspace: work out where we are.
if [ -z "${APPROOT}" ]; then
    d="${PWD}"
    while [ -n "${d}" ] && [ "${d}" != "/" ]; do
        if [ -d "${d}/.ddev" ]; then APPROOT="${d}"; break; fi
        d="$(dirname "${d}")"
    done
fi
if [ -z "${WORKTREE}" ] && [ -n "${APPROOT}" ]; then
    case "${PWD}" in
        "${APPROOT}/typo3-core-"*)
            WORKTREE="${PWD#"${APPROOT}/typo3-core-"}"
            case "${WORKTREE}" in */*) WORKTREE="" ;; esac ;;
    esac
fi

# What this worktree is decides what can be done to it. Both tests are the same
# filesystem checks site_is_served and active_worktree_name make — two reads, no
# container round trip, nothing sourced.
#   primary        it IS the project's site
#   served         it has a URL and database of its own
#   unserved       a checkout and nothing more, which most worktrees are
# Is this the clone that owns the git object store — the origin repository — rather
# than a worktree added beside it? `git worktree add` writes a .git FILE pointing
# back at the main clone, which keeps a real .git DIRECTORY. One filesystem test,
# cheap enough for the rebuild render does on every draw.
is_origin_checkout() {
    [ -n "${WORKTREE}" ] && [ -n "${APPROOT}" ] || return 1
    [ -d "${APPROOT}/typo3-core-${WORKTREE}/.git" ]
}

# Branch and applied-patch count, cached. Unlike worktree_state these are git
# reads, and render runs on EVERY keystroke — an arrow key must not pay for them.
# So they are refreshed only when something could have changed them: at startup,
# and after a command this panel ran.
GIT_BRANCH=""
GIT_AHEAD=""
# Whether the reads below actually ran. Without it an empty GIT_BRANCH is
# ambiguous: a detached HEAD, or no checkout to ask about at all.
GIT_READ=0
# Set when a popup was launched: it returns on start, not on completion, so the
# answer is only reliable by the next keystroke.
GIT_STALE=0

refresh_git_info() {
    GIT_BRANCH=""; GIT_AHEAD=""; GIT_READ=0
    [ -n "${WORKTREE}" ] && [ -n "${APPROOT}" ] || return 0
    local dir="${APPROOT}/typo3-core-${WORKTREE}"
    [ -d "${dir}" ] || return 0
    GIT_READ=1

    GIT_BRANCH="$(git -C "${dir}" symbolic-ref --short -q HEAD 2>/dev/null)" || GIT_BRANCH=""

    # Commits on top of the upstream ARE the applied patches — the same measure
    # `ddev tryout status` reports. Only where an upstream is recorded: working it
    # out for a detached HEAD means for-each-ref --contains over every remote
    # branch, which took 0.7s on a real Core and has no place in a redraw.
    if [ -n "${GIT_BRANCH}" ]; then
        GIT_AHEAD="$(git -C "${dir}" rev-list --count '@{upstream}..HEAD' 2>/dev/null)" || GIT_AHEAD=""
    fi
    return 0
}

worktree_state() {
    [ -n "${WORKTREE}" ] && [ -n "${APPROOT}" ] || { echo "unserved"; return 0; }
    local active=""
    [ -L "${APPROOT}/typo3-core" ] \
        && active="$(basename "$(readlink "${APPROOT}/typo3-core")" | sed 's|^typo3-core-||')"
    if [ "${WORKTREE}" = "${active}" ]; then
        echo "primary"
    elif [ -f "${APPROOT}/sites/${WORKTREE}/.tryout-site" ]; then
        echo "served"
    else
        echo "unserved"
    fi
}

# Four parallel arrays, because bash 3.2 has no associative ones: what the row
# says, what it means, the arguments it runs, and whether it may run right here.
LABELS=(); HINTS=(); ARGS=(); DIRECT=()
# $4 "direct": fast, silent on success, needs no terminal — for such a verb the
# popup is a modal box in front of what it just did. The default is the popup,
# which is right for anything that prompts, takes minutes, or prints more than a
# line. Adding a second direct row means re-arguing that case; a test counts them.
add() { LABELS+=("$1"); HINTS+=("$2"); ARGS+=("$3"); DIRECT+=("${4:-}"); }

# A one-shot message under the menu. It cannot simply be printed: render clears
# the pane at the top of every draw and the loop redraws BEFORE it blocks on a
# key, so anything printed here is wiped before it can be read. render shows this
# and clears it, so it survives exactly until the next keystroke.
NOTICE=""

# The menu is built from the state, so a row never promises something that cannot
# work here: checkout/reset/patch need a site, and on an unserved worktree there is
# none — they would fail, or worse, silently act on the primary instead.
build_menu() {
    LABELS=(); HINTS=(); ARGS=(); DIRECT=()
    STATE="$(worktree_state)"

    # Always this panel's OWN worktree, the primary included. A bare command with
    # no site follows the typo3-core symlink at the moment it runs, so it switches
    # whoever is primary THEN — not the checkout this panel is about. Naming it
    # resolves through site_core_dir instead, which reads typo3-core-<name>
    # directly. "@primary" is never used here: cmd_reset passes its argument
    # straight through and the container's parser does not take that word.
    local site="${WORKTREE}"

    add "status" "project overview" "status"
    if [ -z "${WORKTREE}" ]; then
        # Started by hand outside any worktree, so nothing here is scoped to one.
        # Offering `worktree serve` with no name would just error; the project-wide
        # verbs are the honest list.
        add "checkout" "switch TYPO3 version" "checkout"
        add "patch" "apply a Gerrit change" "patch"
        add "composer" "regenerate the overlay" "composer"
        # Only here: making a worktree is a project-level act, and the popup asks
        # for the name and the branch. A scoped panel offers `worktree remove`
        # instead — the one that is about the checkout it is looking at.
        add "worktree add" "create it and open it here" "worktree add --herdr"
    elif [ "${STATE}" = "unserved" ]; then
        add "worktree serve" "give it its own URL" "worktree serve ${WORKTREE}"
        add "worktree use" "make it the primary" "worktree use ${WORKTREE}"
        if is_origin_checkout; then
            add "worktree add" "create it and open it here" "worktree add --herdr"
        else
            add "worktree remove" "delete this checkout" "worktree remove ${WORKTREE}"
        fi
    else
        add "checkout" "switch TYPO3 version" "checkout${site:+ --site ${site}}"
        add "patch" "apply a Gerrit change" "patch${site:+ --site ${site}}"
        add "download" "update from its base branch" "download${site:+ ${site}}"
        add "reset" "reset Core + rebuild" "reset${site:+ ${site}}"
        add "exec" "run a command in it" "exec ${site}"
        # composer has no site: it always rewrites the PRIMARY overlay. Offering
        # it on a served worktree's panel would silently target the wrong Core —
        # exactly what this menu exists to prevent.
        [ "${STATE}" = "primary" ] \
            && add "composer" "regenerate the overlay" "composer"
        [ "${STATE}" = "served" ] \
            && add "worktree use" "make it the primary" "worktree use ${WORKTREE}"
        # The inverse of serve, so only where there is a site to take away. It keeps
        # the database by default — `--drop-db` is the popup's to ask for — because
        # unserving is about the URL, not the data.
        add "worktree unserve" "stop serving it" "worktree unserve ${WORKTREE}"
        # The origin clone offers `add`: it owns the object store every other
        # worktree branches from, so that is where making one belongs. It never
        # offers `remove` — remove_core_worktree refuses to drop the checkout
        # holding that store, so the row could only ever fail, which is the promise
        # this menu exists not to make. Every other worktree is the other way
        # round: remove names itself, so the popup has only to confirm, and it does
        # confirm, because a served worktree takes its site and database with it.
        if is_origin_checkout; then
            add "worktree add" "create it and open it here" "worktree add --herdr"
        else
            add "worktree remove" "delete this checkout" "worktree remove ${WORKTREE}"
        fi
        # Last, and the only rows that run right here with no popup: they raise
        # the browser and are done, so a popup would just sit in front of it.
        # Two rows rather than one with a flag — the panel has no way to ask.
        add "launch frontend" "open the site in the browser" "launch ${site}" direct
        add "launch backend" "open /typo3/ in the browser" "launch ${site} --backend" direct
    fi
    # A list can shrink — unserving drops rows — and reading past its end would
    # abort the panel under set -u.
    [ "${SEL}" -lt "${#LABELS[@]}" ] || SEL=$(( ${#LABELS[@]} - 1 ))
    [ "${SEL}" -ge 0 ] || SEL=0
}

# Row of the first command, counted from the top of THIS PANE (1-based): the
# header takes two lines and a blank one follows. A mouse event reports a
# pane-relative row, which is why nothing here may think in screen coordinates.
FIRST_ROW=4
SEL=0
STATE="unserved"

# The session the creating command was in. Empty when this was started by hand,
# where the ambient session is already the right one.
herdr_cli() {
    if [ -n "${TRYOUT_PANEL_SESSION:-}" ]; then
        herdr --session "${TRYOUT_PANEL_SESSION}" "$@"
    else
        herdr "$@"
    fi
}

# The popup body, normally the file beside this one. Fall back to the installed
# copy when $0 says otherwise, so the inline path still works however this was
# started.
self_dir() { cd "$(dirname "$0")" 2>/dev/null && pwd; }
RUNNER="$(self_dir)/herdr-panel-run.sh"
[ -f "${RUNNER}" ] || RUNNER="${APPROOT}/.ddev/tryout/herdr-panel-run.sh"

mouse_on()  { printf '\033[?1000h\033[?1006h\033[?25l'; }
mouse_off() { printf '\033[?1006l\033[?1000l\033[?25h'; }

# Terminal state must always come back, however this exits — an abandoned mouse mode
# leaves the user's pane emitting escape codes into whatever they type next.
cleanup() {
    mouse_off
    printf '\033[2J\033[H'
}
trap cleanup EXIT INT TERM

# Drawn top to bottom with plain newlines, never `ESC[row;colH`. herdr scopes the
# pane-relative sequences — ESC[2J and ESC[H clear and home THIS pane, verified by
# the neighbouring shell keeping its prompt while this redraws — but absolute row
# addressing was landing the rows outside it, leaving only the first one visible.
# Sequential output needs no coordinates at all, so the question does not arise.
render() {
    local i=0
    # Rebuild the whole menu, not just the header. What this worktree IS can change
    # under an open panel — `worktree use` elsewhere, or a command this panel just
    # ran — and the rows have to follow, not only the state line. The popup path
    # especially: it returns as soon as the popup STARTS, long before its command
    # finishes, so there is no later moment it could rebuild from. Cheap enough to
    # do unconditionally: build_menu is the same two filesystem reads the header
    # needed anyway, and the draw only happens on a keystroke.
    build_menu
    printf '\033[2J\033[H'
    # Which worktree this drives and what it is: the same panel in another
    # workspace offers a different list, and that only reads if the scope is shown.
    printf "  ${BOLD}tryout${NC}${WORKTREE:+ ${CYAN}${WORKTREE}${NC}}\n"
    printf "  ${DIM}%s${NC}\n\n" "${STATE}"
    while [ "${i}" -lt "${#LABELS[@]}" ]; do
        if [ "${i}" -eq "${SEL}" ]; then
            printf "  ${SEL_ON} %-18s ${NC}\n" "${LABELS[${i}]}"
        else
            printf "   ${ROW}%-18s${NC} \n" "${LABELS[${i}]}"
        fi
        i=$(( i + 1 ))
    done
    # Below the items: what this checkout is sitting on, and what is on top of it.
    if [ "${GIT_READ}" = "1" ]; then
        printf "\n  ${DIM}%s${NC}\n" "${GIT_BRANCH:-detached}"
        if [ -n "${GIT_AHEAD}" ] && [ "${GIT_AHEAD}" -gt 0 ] 2>/dev/null; then
            printf "  ${DIM}%s patch%s${NC}\n" "${GIT_AHEAD}" \
                "$([ "${GIT_AHEAD}" -eq 1 ] || echo es)"
        fi
    fi
    printf "\n  ${DIM}%s${NC}\n" "${HINTS[${SEL}]}"
    # What a direct row had to say, shown once. Cleared here rather than by a
    # timer or a keypress: the next draw is the next keystroke, which is exactly
    # how long a one-line failure wants to stay up.
    if [ -n "${NOTICE}" ]; then
        printf "\n  ${RED}✗${NC} %s\n" "${NOTICE}"
        NOTICE=""
    fi
    printf "\n  ${DIM}↑↓ or click · enter runs · esc closes${NC}"
}

# A click reports a row within this pane; map it to a list index. Anything outside
# the list is not an error, just not a selection.
row_to_index() {
    local row="$1" idx=$(( row - FIRST_ROW ))
    [ "${idx}" -ge 0 ] && [ "${idx}" -lt "${#LABELS[@]}" ] || return 1
    printf '%s' "${idx}"
}

# Did the popup we just asked for actually start? herdr answers ok whether or not
# it had a UI to draw into, so the only honest test is whether its process exists.
# Give it a moment: `plugin pane open` returns before the command is up.
# Measured at well under 200ms when it works, so a second of polling is generous
# without making a keypress feel slow. `sleep` takes a fraction on both userlands —
# it is `read -t` that bash 3.2 rejects, and this is not that.
popup_started() {
    local marker="$1" i=0
    while [ "${i}" -lt 5 ]; do
        [ -f "${marker}" ] && return 0
        sleep 0.2
        i=$(( i + 1 ))
    done
    return 1
}

# A row that runs right here: no popup, no screen clear, nothing to dismiss.
run_direct() {
    local verb="$1" err rc
    # Test the directory rather than leaning on `cd … && ddev`: that short-circuits
    # to rc 0 with no output, so a bad APPROOT would make every run quietly do
    # nothing at all — success and silence being indistinguishable here.
    local root="${APPROOT:-${PWD}}"
    if [ ! -d "${root}" ]; then
        NOTICE="no project here"
        return 0
    fi
    # stdout goes nowhere. On success it is one line — "Opened https://…" — that
    # the browser coming to the front already said better, and this pane is a
    # ~25-column strip with no room for it. stderr is kept, because a failure that
    # vanished would be the worst outcome of running without a popup.
    #
    # `2>&1 >/dev/null` in THAT order: reversed, both streams are dropped and every
    # failure is silent. ${verb} is unquoted on purpose — "launch benni" is two
    # words — as herdr-panel-run.sh runs it. The cd stays inside the substitution's
    # subshell, so the panel's own cwd never moves.
    # shellcheck disable=SC2086
    err="$(cd "${root}" && ddev tryout ${verb} 2>&1 >/dev/null)"
    rc=$?
    [ "${rc}" -eq 0 ] && return 0

    # No `command -v ddev` guard: a missing ddev lands here as the shell's own
    # "command not found" with rc 127, which is a better message than a bespoke one.
    NOTICE="$(printf '%s' "${err}" | grep -v '^[[:space:]]*$' | head -1 | cut -c1-24)"
    return 0
}

# A command may have moved the branch or applied a patch, so re-read after one runs
# — the one moment the cache can go stale. Not on a keystroke: see refresh_git_info.
refresh_after_command() { GIT_STALE=0; refresh_git_info; }

run_selected() {
    # The arguments, not the label: a row reads "reset" but runs "reset benni".
    local verb="${ARGS[${SEL}]}"

    # Some rows want no popup at all. Tested BEFORE the marker below, or every
    # Enter on such a row leaves a marker file in TMPDIR that nothing collects.
    # There is deliberately no fallback to the popup when it fails: a popup would
    # do nothing better, and it is the box in front of the browser that this
    # exists to avoid.
    if [ -n "${DIRECT[${SEL}]}" ]; then
        run_direct "${verb}"
        refresh_after_command
        return 0
    fi

    local popup_err=""
    # A marker unique to this panel and this run: the popup touches it to prove it
    # really started, since nothing observable from here otherwise distinguishes
    # our popup from a sibling workspace's.
    local marker="${TMPDIR:-/tmp}/tryout-panel-started.$$.${SEL}"
    rm -f "${marker}" 2>/dev/null || true
    # Why the popup did or did not appear is invisible from inside the pane, so
    # leave a trace. TRYOUT_PANEL_DEBUG is off unless someone asks for it.
    [ -n "${TRYOUT_PANEL_DEBUG:-}" ] && \
        printf '%s verb=[%s] herdr_env=[%s] session=[%s]\n' \
            "$(date +%T)" "${verb}" "${HERDR_ENV:-}" "${TRYOUT_PANEL_SESSION:-}" \
            >> "${TMPDIR:-/tmp}/tryout-panel.log"

    # The popup prompts and runs: it is modal, so it can own the screen while gum
    # asks. A plugin pane takes no positional arguments, so the verb rides in the
    # environment.
    #
    # --cwd is the PROJECT ROOT, never this worktree: the manifest runs the popup
    # as `bash .ddev/tryout/herdr-panel-run.sh`, a relative path herdr resolves
    # against --cwd. From a worktree there is no .ddev/ beneath it, so the popup
    # cannot start at all — and herdr still answers ok. The worktree is already
    # carried in TRYOUT_PANEL_WORKTREE, so nothing is lost by rooting it here.
    #
    # `plugin pane open` answering ok is NOT proof the popup appeared. It renders
    # into an attached UI, and with none — a session nobody is viewing — herdr
    # accepts the request and silently drops it. Verified: the popup's command runs
    # only in a session with a client attached. So confirm the process actually
    # started before believing it, or Enter looks like it did nothing at all.
    if [ "${HERDR_ENV:-}" = "1" ] && command -v herdr >/dev/null 2>&1 \
       && popup_err="$(herdr_cli plugin pane open --plugin ddev-tryout \
            --entrypoint run --cwd "${APPROOT:-${PWD}}" \
            --env "TRYOUT_PANEL_VERB=${verb}" \
            --env "TRYOUT_PANEL_STARTED=${marker}" \
            --env "TRYOUT_PANEL_PANE=${HERDR_PANE_ID:-}" 2>&1)" \
       && printf '%s' "${popup_err}" | grep -q '"type":"ok"' \
       && popup_started "${marker}"; then
        [ -n "${TRYOUT_PANEL_DEBUG:-}" ] && \
            printf '  popup ok: %s\n' "${popup_err}" >> "${TMPDIR:-/tmp}/tryout-panel.log"
        rm -f "${marker}" 2>/dev/null || true
        # The popup is still running: it returns on START, not on completion. So
        # mark the cache stale and let the next keystroke pick the answer up —
        # by then the command has had time to finish.
        GIT_STALE=1
        return 0
    fi
    [ -n "${TRYOUT_PANEL_DEBUG:-}" ] && \
        printf '  popup FAILED: %s\n' "${popup_err:-<not attempted>}" \
            >> "${TMPDIR:-/tmp}/tryout-panel.log"
    rm -f "${marker}" 2>/dev/null || true

    # No popup — not linked, or nobody is viewing this session. Run it here rather
    # than pretending one appeared, and hand the terminal over properly while it
    # runs, because the command prompts and its gum needs a normal screen.
    mouse_off
    printf '\033[2J\033[H'
    # `|| true`: however the runner ends — a failing command, a missing file, a
    # signal — the panel must come back. Leaving the pane on whatever it printed
    # is what makes the whole thing look dead.
    "${RUNNER}" "${verb}" || true
    # Back to the panel: without this the loop keeps drawing but the mouse is dead,
    # so every later click would go unnoticed.
    mouse_on
    # Serving or unserving changes what this worktree is, so the list it offers
    # has to change with it — and the command may have moved the branch too.
    build_menu
    refresh_after_command
}

# --- input ------------------------------------------------------------------
# SGR mouse: ESC [ < btn ; col ; row (M press | m release). Read the tail of an
# escape sequence up to its final letter, then decide what it was.
# No timeout: bash 3.2 rejects a fractional `read -t` outright, and `-t 0` only
# tests readiness without consuming. An escape sequence arrives as one burst and
# ends in a letter, so the terminator is the boundary to read up to. A bare ESC
# (the user pressing Escape) is the one case that would block, so it is bounded by
# a whole-second timeout, which 3.2 does accept.
read_escape_tail() {
    local seq="" ch
    while IFS= read -rsn1 -t 1 ch; do
        seq="${seq}${ch}"
        case "${ch}" in
            [A-Za-z~]) break ;;
        esac
    done
    printf '%s' "${seq}"
}

handle_escape() {
    local seq="$1"
    # Nothing followed the ESC, so the user pressed Escape itself: close, and run
    # nothing. Only the bare key quits — arrows and mouse reports arrive here too,
    # with a tail, and must go on being handled below.
    [ -n "${seq}" ] || return 1
    local mouse='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'
    if [[ "${seq}" =~ $mouse ]]; then
        local btn="${BASH_REMATCH[1]}" row="${BASH_REMATCH[3]}" kind="${BASH_REMATCH[4]}"
        # Wheel up/down are buttons 64/65 and arrive as presses.
        case "${btn}" in
            64) [ "${SEL}" -gt 0 ] && SEL=$(( SEL - 1 )); return 0 ;;
            65) [ "${SEL}" -lt $(( ${#LABELS[@]} - 1 )) ] && SEL=$(( SEL + 1 )); return 0 ;;
        esac
        # Act on release, so a press-and-drag off the row does not fire.
        [ "${kind}" = "m" ] || return 0
        [ "${btn}" = "0" ] || return 0
        local idx
        idx="$(row_to_index "${row}")" || return 0
        SEL="${idx}"
        run_selected
        return 0
    fi
    case "${seq}" in
        "[A") [ "${SEL}" -gt 0 ] && SEL=$(( SEL - 1 )) ;;
        "[B") [ "${SEL}" -lt $(( ${#LABELS[@]} - 1 )) ] && SEL=$(( SEL + 1 )) ;;
    esac
    return 0
}

build_menu
refresh_git_info
mouse_on

# Throw away anything already waiting on stdin before the first draw. Nothing a
# human typed can be here yet — the panel has not drawn a menu to type at — so
# whatever is buffered was typed BY something else.
#
# `herdr pane run` is that something else: it starts a command by typing it into
# the pane's shell, ending with a newline. Aimed at a pane where this panel is
# already reading, the command text is consumed a byte at a time and the trailing
# newline arrives as an empty `read`, which the loop below treats as Enter — so
# the panel ran the selected row, `status` on a fresh panel, that nobody chose.
# ensure_panel_pane no longer re-runs at a live panel, and this makes sure no
# other caller can do it either.
#
# One whole second: bash 3.2 rejects a fractional -t outright (a unit test pins
# that), and this runs once at startup where a second costs nothing.
drain_stdin() {
    local _discard
    while IFS= read -rsn1 -t 1 _discard; do :; done
    return 0
}
drain_stdin

while :; do
    # Before the draw, not after: a popup launched earlier has had time to finish,
    # and refilling here means the very next repaint shows its result. After
    # `render` the values would be a draw behind — right in the variables, wrong on
    # screen until something else provoked another draw.
    if [ "${GIT_STALE}" -eq 1 ]; then refresh_after_command; fi
    render
    IFS= read -rsn1 key || break
    case "${key}" in
        $'\033') handle_escape "$(read_escape_tail)" || break ;;
        ""|$'\n') run_selected ;;
        j) [ "${SEL}" -lt $(( ${#LABELS[@]} - 1 )) ] && SEL=$(( SEL + 1 )) ;;
        k) [ "${SEL}" -gt 0 ] && SEL=$(( SEL - 1 )) ;;
        q) break ;;
    esac
done
