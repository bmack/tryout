#!/usr/bin/env bats

# Unit tests for the pure helpers in tryout/functions.sh. These source the library
# directly with a fake project root, so they need no DDEV project and no containers
# and run in milliseconds:
#   bats ./tests/unit.bats

setup() {
  set -eu -o pipefail
  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export FAKEROOT="$(mktemp -d "${BATS_TMPDIR:-/tmp}/tryout-unit.XXXXXX")"

  # functions.sh derives everything from these; sourcing it with no Core checkout
  # present exercises exactly the branch a fresh project is in.
  export DDEV_APPROOT="${FAKEROOT}"
  export DDEV_SITENAME="unitproj"
  export DDEV_PHP_VERSION="8.5"
  export DDEV_WEBSERVER_TYPE="apache-fpm"
  export DDEV_DATABASE="mariadb:10.11"
}

teardown() {
  set -eu -o pipefail
  [ -n "${FAKEROOT:-}" ] && rm -rf "${FAKEROOT}"
}

# Sourcing prints nothing; run helpers through this so failures surface cleanly.
helper() {
  # shellcheck disable=SC1090
  source "${DIR}/tryout/functions.sh" >/dev/null 2>&1
  "$@"
}

# Evaluate an expression with functions.sh sourced. Unlike `helper bash -c`, this
# stays in the same shell, so the library's functions and variables are visible.
helper_eval() {
  # shellcheck disable=SC1090
  source "${DIR}/tryout/functions.sh" >/dev/null 2>&1
  eval "$1"
}

# Lay the payload out under FAKEROOT the way `ddev add-on get` does, then run the
# completion script the way DDEV does: absolute path, argv = the command line,
# an empty word as the literal '', and no DDEV_* variables in the environment.
complete() {
  if [ ! -x "${FAKEROOT}/.ddev/commands/host/autocomplete/tryout" ]; then
    mkdir -p "${FAKEROOT}/.ddev/commands/host/autocomplete" "${FAKEROOT}/.ddev/tryout"
    cp "${DIR}/commands/host/autocomplete/tryout" "${FAKEROOT}/.ddev/commands/host/autocomplete/"
    cp "${DIR}/tryout/functions.sh" "${FAKEROOT}/.ddev/tryout/"
    chmod +x "${FAKEROOT}/.ddev/commands/host/autocomplete/tryout"
  fi
  # cd elsewhere on purpose: DDEV leaves the cwd wherever the user pressed TAB.
  (cd / && env -u DDEV_APPROOT -u DDEV_SITENAME \
    "${FAKEROOT}/.ddev/commands/host/autocomplete/tryout" tryout "$@")
}

# Candidates carry a TAB-separated description and free-text positions emit an
# `_activeHelp_` hint line; tests that care about the names alone go through this.
names() { complete "$@" | grep -v '^_activeHelp_ ' | cut -f1; }

@test "functions.sh is syntactically valid and sources cleanly" {
  set -eu -o pipefail
  run bash -n "${DIR}/tryout/functions.sh"
  assert_success
  run helper true
  assert_success
}

@test "BRANCH falls back to main with no Core checkout" {
  set -eu -o pipefail
  run helper_eval 'echo "${BRANCH}"'
  assert_success
  assert_output "main"
}

@test "TRYOUT_BRANCH overrides the detected branch" {
  set -eu -o pipefail
  export TRYOUT_BRANCH=13.4
  run helper_eval 'echo "${BRANCH}"'
  assert_success
  assert_output "13.4"
}

@test "the primary site resolves to the project root" {
  set -eu -o pipefail
  run helper site_dir
  assert_output "${FAKEROOT}"
  run helper site_dir "@primary"
  assert_output "${FAKEROOT}"
  run helper site_docroot
  assert_output "${FAKEROOT}/public"
}

@test "a named site resolves under sites/" {
  set -eu -o pipefail
  run helper site_dir v13
  assert_output "${FAKEROOT}/sites/v13"
  run helper site_docroot v13
  assert_output "${FAKEROOT}/sites/v13/public"
}

@test "the primary keeps the plain db name, extras get their own" {
  set -eu -o pipefail
  run helper site_database
  assert_output "db"
  run helper site_database v13
  assert_output "db_v13"
}

@test "a site database name is sanitised for characters MySQL rejects" {
  set -eu -o pipefail
  # Dots and dashes are legal in a worktree name but not in a database name.
  run helper site_database "feature-x.1"
  assert_output "db_feature_x_1"
}

@test "hostnames derive from the DDEV project name" {
  set -eu -o pipefail
  run helper site_hostname
  assert_output "unitproj.ddev.site"
  run helper site_hostname v13
  assert_output "v13.unitproj.ddev.site"
  # additional_hostnames wants the un-suffixed form; DDEV appends the TLD itself.
  run helper site_hostname_short v13
  assert_output "v13.unitproj"
}

@test "the primary Core dir follows the symlink, a named one does not" {
  set -eu -o pipefail
  run helper site_core_dir
  assert_output "${FAKEROOT}/typo3-core"
  run helper site_core_dir v13
  assert_output "${FAKEROOT}/typo3-core-v13"
}

@test "worktree names are validated" {
  set -eu -o pipefail
  for good in main v13 feature-x my.branch under_score; do
    run helper validate_worktree_name "${good}"
    assert_success
  done
  for bad in "" "." ".." "has space" "sla/sh" 'semi;colon' '$(whoami)'; do
    run helper validate_worktree_name "${bad}"
    assert_failure
  done
}

@test "the primary counts as served, a missing site does not" {
  set -eu -o pipefail
  run helper site_is_served
  assert_success
  run helper site_is_served v13
  assert_failure

  # A site is served once its marker exists.
  mkdir -p "${FAKEROOT}/sites/v13"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  run helper site_is_served v13
  assert_success
  run helper site_php_version v13
  assert_output "8.2"
}

@test "a site with no marker falls back to the project PHP version" {
  set -eu -o pipefail
  run helper site_php_version
  assert_output "8.5"
}

@test "served_site_names lists only sites with a marker" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/sites/v13" "${FAKEROOT}/sites/v12" "${FAKEROOT}/sites/scratch"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/v12/.tryout-site"

  run helper_eval 'served_site_names | sort | tr "\n" " "'
  assert_output "v12 v13 "
}

@test "the vhost file goes to the directory for the webserver in use" {
  set -eu -o pipefail
  run helper site_vhost_file v13
  assert_output "${FAKEROOT}/.ddev/apache/tryout-site-v13.conf"

  export DDEV_WEBSERVER_TYPE=nginx-fpm
  run helper site_vhost_file v13
  assert_output "${FAKEROOT}/.ddev/nginx_full/tryout-site-v13.conf"
}

@test "require_core exits with a next step when Core is missing" {
  set -eu -o pipefail
  run helper require_core
  assert_failure
  assert_output --partial "TYPO3 Core not found"
  assert_output --partial "ddev tryout download"
}

@test "every shipped script is valid bash" {
  set -eu -o pipefail
  for f in "${DIR}"/tryout/*.sh "${DIR}/commands/host/tryout" \
           "${DIR}/commands/host/autocomplete/tryout"; do
    run bash -n "${f}"
    assert_success
  done
}

@test "every shipped PHP script is valid" {
  set -eu -o pipefail
  for f in "${DIR}"/tryout/*.php; do
    run php -l "${f}"
    assert_success
  done
}

@test "the shipped overlay template is valid JSON and carries its marker" {
  set -eu -o pipefail
  run php -r 'json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);' \
    "${DIR}/tryout/composer.tryout.json"
  assert_success
  run grep -q 'ddev-generated' "${DIR}/tryout/composer.tryout.json"
  assert_success
}

@test "install.yaml lists every file the add-on ships" {
  set -eu -o pipefail
  for entry in commands/host/tryout commands/host/autocomplete/tryout \
               config.tryout.yaml tryout web-build/Dockerfile.tryout; do
    run grep -qE "^  - ${entry}\$" "${DIR}/install.yaml"
    assert_success
  done
}

@test "every project_files entry exists in the repo" {
  set -eu -o pipefail
  run bash -c "
    cd '${DIR}'
    sed -n '/^project_files:/,/^[a-z_]*:/p' install.yaml \
      | sed -n 's/^  - //p' \
      | while read -r p; do [ -e \"\$p\" ] || echo \"MISSING: \$p\"; done
  "
  assert_output ""
}

# --- Tab-completion -------------------------------------------------------
# DDEV runs commands/host/autocomplete/tryout on every TAB, passing the command
# line as argv and reading candidates from stdout. See the script's header for
# the contract these tests pin down.

@test "the completion script ships executable" {
  set -eu -o pipefail
  assert_file_executable "${DIR}/commands/host/autocomplete/tryout"
  run grep -q '#ddev-generated' "${DIR}/commands/host/autocomplete/tryout"
  assert_success
}

@test "the completion script has no CRLF line endings" {
  # DDEV skips an autocomplete script containing \r\n, with only a warning.
  set -eu -o pipefail
  run grep -qU $'\r' "${DIR}/commands/host/autocomplete/tryout"
  assert_failure
}

@test "the command declares no AutocompleteTerms header" {
  # It would set cobra's ValidArgs, which then rejects any second argument during
  # completion — so the autocomplete script never runs and `ddev tryout cs <TAB>`
  # completes nothing. Verified against ddev v1.25.2 with `ddev __complete`.
  set -eu -o pipefail
  run grep -q '^## AutocompleteTerms:' "${DIR}/commands/host/tryout"
  assert_failure
}

@test "completion covers every command the dispatch case accepts" {
  set -eu -o pipefail
  local actions verb
  actions=$(sed -n '/^case "${ACTION}" in/,/^esac/p' "${DIR}/commands/host/tryout" \
    | sed -n 's/^    \([a-z|]*\)).*/\1/p' | tr '|' '\n' | grep -v '^\*$')
  [ -n "${actions}" ]

  run names "''"
  assert_success
  for verb in ${actions}; do
    assert_line "${verb}"
  done
}

@test "completion suggests the top-level commands" {
  set -eu -o pipefail
  run names "''"
  assert_success
  for verb in status download checkout composer patch worktree cs exec reset delete help; do
    assert_line "${verb}"
  done
}

@test "completion is position aware for cs and worktree" {
  set -eu -o pipefail
  run names cs "''"
  assert_success
  assert_line "setup"
  assert_line "doctor"
  assert_line "uninstall"
  # The top-level verbs must NOT come back here — that is the whole point of the
  # script over the flat AutocompleteTerms list.
  refute_line "download"

  run names worktree "''"
  assert_success
  for sub in add list use serve unserve remove; do
    assert_line "${sub}"
  done
  refute_line "status"
}

@test "completion offers the flags a subcommand actually parses" {
  set -eu -o pipefail
  run names download "''"
  assert_line "--reset"

  run names worktree unserve "''"
  assert_line "--drop-db"

  run names worktree use "''"
  assert_line "--force"
}

@test "completion lists the worktrees on disk" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13"

  run names worktree use "''"
  assert_success
  assert_line "main"
  assert_line "v13"
}

@test "completion lists served sites for the commands that take one" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/sites/v13"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"

  run names exec "''"
  assert_success
  assert_line "@primary"
  assert_line "v13"
}

@test "completion never writes to stderr and never fails" {
  # DDEV merges our stderr into the candidate list and drops every suggestion if
  # we exit non-zero, so both are silent breakages. Sweep every dispatch path.
  set -eu -o pipefail
  local args err
  for args in "''" "cs ''" "worktree ''" "worktree add foo ''" "worktree serve ''" \
              "checkout ''" "patch ''" "reset ''" "delete ''" "exec ''" \
              "status ''" "composer ''" "help ''" "download ''" "bogus ''"; do
    # shellcheck disable=SC2086
    err=$(complete ${args} 2>&1 >/dev/null)
    [ -z "${err}" ] || { echo "stderr for '${args}': ${err}"; false; }
    # shellcheck disable=SC2086
    complete ${args} >/dev/null
  done
}

@test "completion survives a missing functions.sh" {
  # A partial install must degrade to the static candidates, never break TAB.
  set -eu -o pipefail
  run names "''"
  assert_success
  rm -f "${FAKEROOT}/.ddev/tryout/functions.sh"

  run names worktree use "''"
  assert_success
  assert_line "--force"
}

# --- herdr integration ----------------------------------------------------
# `ddev tryout herdr` opens one herdr tab per Core worktree. herdr is an optional
# host tool, so these tests cover the pure helpers and the guard clauses only —
# real tab creation mutates a live session and is verified by hand.

@test "herdr agent names are sanitised to herdr's grammar" {
  # Worktree names allow uppercase and dots; agent names must match
  # [a-z][a-z0-9_-]{0,31}.
  set -eu -o pipefail
  run helper herdr_agent_name main
  assert_output "main"

  run helper herdr_agent_name v13
  assert_output "v13"

  run helper herdr_agent_name my.branch
  assert_output "my-branch"

  run helper herdr_agent_name Feature-X
  assert_output "feature-x"

  # Must start with a letter.
  run helper herdr_agent_name 13.4
  assert_output "x13-4"

  # And be at most 32 characters.
  run helper_eval 'herdr_agent_name a-very-long-worktree-name-that-goes-past-the-limit | wc -c'
  assert_output --partial "33"   # 32 chars + newline
}

@test "the herdr session is named after the DDEV project" {
  # Each project gets its own session, so two tryout projects never collide.
  set -eu -o pipefail
  run helper_eval 'DDEV_SITENAME=myproj herdr_session_name'
  assert_output "tryout-myproj"

  # setup() exports DDEV_SITENAME, so clear it in a child env rather than in-shell.
  run env -u DDEV_SITENAME bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    herdr_session_name
  "
  assert_output "tryout"
}

@test "herdr_cli puts --session before the subcommand" {
  # herdr SILENTLY IGNORES --session when it comes after the subcommand and talks to
  # the default session instead — so argument order is load-bearing, not cosmetic.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/bin"
  printf '#!/usr/bin/env bash\necho "ARGV: $*"\n' > "${FAKEROOT}/bin/herdr"
  chmod +x "${FAKEROOT}/bin/herdr"

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    herdr_cli workspace list
  "
  assert_success
  assert_output "ARGV: --session tryout-myproj workspace list"
}

@test "every herdr call goes through the session wrapper" {
  # A bare `herdr <subcommand>` would silently target the user's default session.
  # The only allowed raw call is the deliberate `nohup herdr --session ... server`.
  set -eu -o pipefail
  # Only look at executable lines: strip comments and echo/error strings first, so
  # help text and messages mentioning herdr do not register as calls.
  run bash -c "
    cat '${DIR}/tryout/functions.sh' '${DIR}/commands/host/tryout' \
      '${DIR}'/tryout/herdr-panel*.sh \
      | grep -vE '^[[:space:]]*#' \
      | grep -vE '^[[:space:]]*(echo|printf|error|warn|info|success)\b' \
      | grep -E '(^|[^_[:alnum:]])herdr (workspace|pane|agent|tab|status|session|plugin) ' \
      | grep -v 'herdr_cli' \
      | grep -v 'herdr session attach' \
      | grep -v 'herdr plugin list' || true
  "
  assert_output ""
}

@test "attaching falls back to printing the command when it cannot attach" {
  # Three ways attaching is impossible: no controlling terminal (CI, a script), or
  # already inside herdr, which refuses to nest. Neither may hang or fail.
  set -eu -o pipefail

  # Inside herdr: say how to switch, do not try to nest.
  run env HERDR_ENV=1 DDEV_SITENAME=myproj bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    attach_herdr_session
  "
  assert_success
  assert_output --partial "already in herdr"
  assert_output --partial "tryout-myproj"

  # No controlling terminal: print the command. bats already runs without one.
  run env -u HERDR_ENV DDEV_SITENAME=myproj bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    attach_herdr_session
  "
  assert_success
  assert_output --partial "herdr session attach tryout-myproj"
}

@test "the herdr command reports a missing herdr binary" {
  set -eu -o pipefail
  run bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    export HERDR_ENV=1 HERDR_WORKSPACE_ID=w1
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    PATH=/nonexistent
    herdr_available
  "
  assert_failure
  assert_output --partial "herdr is not installed"
  assert_output --partial "herdr.dev"
}

@test "herdr workspace labels are namespaced" {
  # Workspace labels share one global sidebar with every other project, so a bare
  # worktree name would be ambiguous there.
  set -eu -o pipefail
  run helper herdr_workspace_label main
  assert_output "core-main"

  run helper herdr_workspace_label v13
  assert_output "core-v13"
}

@test "worktree names are derived from a branch and sanitised" {
  # herdr names its own checkouts worktree/<generated-slug>; tryout needs a name
  # validate_worktree_name accepts.
  set -eu -o pipefail
  run helper worktree_name_from_ref "worktree/brave-harbor-dc20"
  assert_output "brave-harbor-dc20"

  run helper worktree_name_from_ref "feature/foo"
  assert_output "feature-foo"

  run helper worktree_name_from_ref "typo3-core-v13"
  assert_output "v13"

  run helper worktree_name_from_ref "13.4"
  assert_output "13.4"
}

@test "foreign worktrees are the ones outside the project root" {
  set -eu -o pipefail
  command -v git >/dev/null 2>&1 || skip 'git not available'
  mkdir -p "${FAKEROOT}/typo3-core"
  git -C "${FAKEROOT}/typo3-core" init -q .
  git -C "${FAKEROOT}/typo3-core" commit -q --allow-empty -m init
  git -C "${FAKEROOT}/typo3-core" worktree add -q "${FAKEROOT}/typo3-core-inside" -b inside
  git -C "${FAKEROOT}/typo3-core" worktree add -q "${BATS_TMPDIR}/tryout-outside-$$" -b outside

  run helper_eval 'list_foreign_core_worktrees'
  assert_success
  refute_output --partial "typo3-core-inside"
  assert_output --partial "tryout-outside-$$"

  git -C "${FAKEROOT}/typo3-core" worktree remove --force "${BATS_TMPDIR}/tryout-outside-$$" || true
}

@test "a missing herdr says how to install it, per platform" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/empty"

  # macOS gets brew; the universal installer is always offered because no Linux
  # distro packages herdr — an apt-get line would just fail.
  run env OSTYPE=darwin24 bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    PATH='${FAKEROOT}/empty'
    herdr_available
  "
  assert_failure
  assert_output --partial "herdr is not installed"
  assert_output --partial "brew install herdr"
  assert_output --partial "herdr.dev/install.sh"

  run env OSTYPE=linux-gnu bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    PATH='${FAKEROOT}/empty'
    herdr_available
  "
  assert_failure
  assert_output --partial "herdr.dev/install.sh"
  # herdr is not in apt/dnf/pacman — never claim otherwise.
  refute_output --partial "apt-get install herdr"
}

@test "a missing jq says how to install it, and needs no uname" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/onlyherdr"
  printf '#!/bin/sh\nexit 0\n' > "${FAKEROOT}/onlyherdr/herdr"
  chmod +x "${FAKEROOT}/onlyherdr/herdr"

  # No uname on this PATH: the platform must come from OSTYPE instead.
  run env OSTYPE=darwin24 bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    PATH='${FAKEROOT}/onlyherdr'
    herdr_available
  "
  assert_failure
  assert_output --partial "jq is not installed"
  assert_output --partial "brew install jq"
  refute_output --partial "uname: command not found"

  run env OSTYPE=linux-gnu bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    PATH='${FAKEROOT}/onlyherdr'
    herdr_available
  "
  assert_failure
  assert_output --partial "jq is not installed"
}

@test "no fractional read -t, which bash 3.2 rejects outright" {
  # `read -t 0.01` is bash 4+. On macOS's bash 3.2 it fails with "invalid timeout
  # specification" — so a drain written that way never runs, and every prompt after
  # a single-key read silently swallows the stale Enter and cancels. Parsing is not
  # enough to catch this: it is a runtime argument error.
  set -eu -o pipefail
  run bash -c "
    cat '${DIR}'/tryout/*.sh \
        '${DIR}/commands/host/tryout' \
      | grep -vE '^[[:space:]]*#' | grep -qE 'read .*-t +[0-9]*\\.[0-9]'
  "
  assert_failure

  # And bash 3.2 really does reject it, so the guard is not theoretical.
  if [ -x /bin/bash ]; then
    run /bin/bash -c 'read -r -t 0.01 x </dev/null'
    assert_failure
  fi
}

@test "every shipped script parses under bash 3.2, which macOS still ships" {
  set -eu -o pipefail
  [ -x /bin/bash ] || skip 'no /bin/bash'
  local f
  for f in "${DIR}"/tryout/*.sh \
           "${DIR}/commands/host/tryout" "${DIR}/commands/host/autocomplete/tryout"; do
    run /bin/bash -n "${f}"
    assert_success
  done
}

@test "no GNU-only utilities are assumed" {
  # These break on macOS's BSD userland. `sed -i` needs a suffix to work on both,
  # which is why the tests use sed -i.bak.
  set -eu -o pipefail
  local bad
  for bad in 'readlink -f' 'grep -P' 'sed -r ' 'stat -c' 'date -d'; do
    run bash -c "
      cat '${DIR}'/tryout/*.sh \
          '${DIR}/commands/host/tryout' '${DIR}/commands/host/autocomplete/tryout' \
        | grep -vE '^[[:space:]]*#' | grep -q -- '${bad}'
    "
    assert_failure
  done

  # A bare `sed -i` with no suffix is GNU-only; BSD would eat the next argument.
  run bash -c "
    cat '${DIR}'/tryout/*.sh '${DIR}/commands/host/tryout' \
      | grep -vE '^[[:space:]]*#' | grep -qE 'sed -i +[^.]'
  "
  assert_failure
}

@test "a served site's vhost tells PHP the request was TLS" {
  # Without `fastcgi_param HTTPS`, TYPO3 builds http:// URLs behind DDEV's TLS
  # terminator and its secure session cookie is never returned — the backend login
  # then fails with "Please activate Cookies" while the page still answers 200, so
  # no status-code check can catch it. The $ must reach nginx literally, which
  # means escaping it inside the generator's unquoted heredoc.
  set -eu -o pipefail
  run grep -q 'fastcgi_param HTTPS \\$fcgi_https;' "${DIR}/tryout/functions.sh"
  assert_success

  # An unescaped $fcgi_https would be eaten by the shell and emit
  # `fastcgi_param HTTPS ;`, which nginx rejects outright — taking the whole
  # container down, not just that site.
  run grep -q 'fastcgi_param HTTPS \$fcgi_https;' "${DIR}/tryout/functions.sh"
  assert_failure
}

@test "the default PHP comes from the branch's own constraint" {
  # Core states its requirement per branch — ^8.5 on main, ^8.2 on 13.4 — so the
  # project's PHP is the wrong default for a worktree on another branch. An upper
  # bound has to be honoured too: reading only the floor would hand a capped
  # branch a PHP it rejects.
  set -eu -o pipefail
  command -v php >/dev/null 2>&1 || skip 'php not available'

  mkdir -p "${FAKEROOT}/typo3-core-capped" "${FAKEROOT}/typo3-core-open" \
           "${FAKEROOT}/typo3-core-nojson"
  printf '{"require":{"php":">=8.2 <8.4"}}' > "${FAKEROOT}/typo3-core-capped/composer.json"
  printf '{"require":{"php":"^8.2"}}'       > "${FAKEROOT}/typo3-core-open/composer.json"
  printf '{}'                               > "${FAKEROOT}/typo3-core-nojson/composer.json"

  # Stub the container lookup: these are the versions the web image ships.
  run env DDEV_PHP_VERSION=8.5 bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    available_php_versions() { printf '8.2\n8.3\n8.4\n8.5\n'; }
    printf '%s %s %s' \
      \"\$(best_php_for_worktree capped)\" \
      \"\$(best_php_for_worktree open)\" \
      \"\$(best_php_for_worktree nojson)\"
  "
  assert_success
  # capped stops at 8.3; open takes the highest; no constraint falls back.
  assert_output "8.3 8.5 8.5"
}

@test "the PHP constraint is read from require, not config.platform" {
  # A naive grep for "php" finds config.platform.php first — a pinned build
  # version, not the constraint.
  set -eu -o pipefail
  run grep -q 'require.*\]\["php"\]' "${DIR}/tryout/functions.sh"
  assert_success
}

@test "a failed serve does not leave the site marked as served" {
  # .tryout-site IS the definition of served, so writing it before the work made a
  # half-built site look real to worktree list and delete --all.
  set -eu -o pipefail
  run grep -q "trap \"rm -f '\${dir}/.tryout-site'\" RETURN" "${DIR}/tryout/functions.sh"
  assert_success
  # cleared only once the site really is built
  run grep -q 'trap - RETURN' "${DIR}/tryout/functions.sh"
  assert_success
}

@test "exec preserves argument boundaries through the container" {
  # `exec v13 typo3 config:set X "My Site"` must arrive as two arguments: the host
  # hands "$@" to the container dispatcher, which hands "$@" to site_exec, which
  # runs the binary directly — no sh -c re-parse anywhere.
  set -eu -o pipefail
  run grep -q 'bash /var/www/html/.ddev/tryout/tryout-container.sh "\$@"' "${DIR}/commands/host/tryout"
  assert_success
  run grep -q 'delegate exec "\${site}" "\$@"' "${DIR}/commands/host/tryout"
  assert_success
  run grep -q 'site_exec "\${site}" "\$@"' "${DIR}/tryout/commands.sh"
  assert_success
  run grep -q 'sh -c' "${DIR}/tryout/functions.sh"
  assert_failure

  # And site_exec itself: a fake php records what it received.
  mkdir -p "${FAKEROOT}/bin" "${FAKEROOT}/sites/v13"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  cat > "${FAKEROOT}/bin/php8.2" <<'FAKE'
#!/bin/sh
printf 'cwd=%s\n' "$(pwd)"
printf 'db=%s site=%s\n' "${TYPO3_DB_DBNAME}" "${TRYOUT_SITE}"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
FAKE
  chmod +x "${FAKEROOT}/bin/php8.2"
  run helper_eval "PATH='${FAKEROOT}/bin:${PATH}' site_exec v13 vendor/bin/typo3 config:set X 'My Site'"
  assert_success
  assert_line "cwd=${FAKEROOT}/sites/v13"
  assert_line "db=db_v13 site=v13"
  assert_line "arg=[vendor/bin/typo3]"
  assert_line "arg=[config:set]"
  assert_line "arg=[X]"
  assert_line "arg=[My Site]"
}

@test "a worktree can be renamed without touching its branch" {
  # herdr's own New-worktree action names a checkout after the branch it invents
  # (worktree/wilie-wonka), and adopt derives one the same way. That is a starting
  # point, not a commitment: the directory name and the branch are independent.
  set -eu -o pipefail
  command -v git >/dev/null 2>&1 || skip 'git not available'

  git -C "${FAKEROOT}" init -q .
  git -C "${FAKEROOT}" commit -q --allow-empty -m init
  mkdir -p "${FAKEROOT}/typo3-core"
  git -C "${FAKEROOT}" worktree add -q "${FAKEROOT}/typo3-core-wilie-wonka" -b wilie-wonka

  run helper_eval 'rename_core_worktree wilie-wonka experiment'
  assert_success

  assert_dir_exist "${FAKEROOT}/typo3-core-experiment"
  assert_dir_not_exist "${FAKEROOT}/typo3-core-wilie-wonka"

  # The branch is the point: it must survive the rename untouched.
  run bash -c "git -C '${FAKEROOT}/typo3-core-experiment' branch --show-current"
  assert_output "wilie-wonka"
}

@test "rename refuses a name that is already taken" {
  set -eu -o pipefail
  command -v git >/dev/null 2>&1 || skip 'git not available'
  git -C "${FAKEROOT}" init -q .
  git -C "${FAKEROOT}" commit -q --allow-empty -m init
  git -C "${FAKEROOT}" worktree add -q "${FAKEROOT}/typo3-core-a" -b a
  mkdir -p "${FAKEROOT}/typo3-core-b"

  run helper_eval 'rename_core_worktree a b'
  assert_failure
  assert_output --partial "already exists"
  assert_dir_exist "${FAKEROOT}/typo3-core-a"
}

@test "adopt takes an optional name so the branch does not dictate the path" {
  set -eu -o pipefail
  run grep -q 'adopt \[<path> \[<name>\]\]' "${DIR}/commands/host/tryout"
  assert_success
  # and rename is offered alongside it
  run grep -q 'rename <old> <new>' "${DIR}/commands/host/tryout"
  assert_success
}

@test "commands that take no arguments say so instead of ignoring them" {
  # `ddev tryout composer install` used to regenerate the overlay and say nothing
  # about `install` — a typo that looked like it worked. Worse, the name suggests
  # it runs Composer, which it does not.
  set -eu -o pipefail
  local c
  for c in status composer help; do
    run grep -qE "(reject_args ${c}|'${c}' takes no arguments)" "${DIR}/commands/host/tryout"
    assert_success
  done

  # composer points at the command the user probably wanted.
  run grep -q 'ddev composer' "${DIR}/commands/host/tryout"
  assert_success

  # help must receive its arguments to be able to reject them.
  run grep -q 'help)     cmd_help "$@"' "${DIR}/commands/host/tryout"
  assert_success
}

@test "completion works while a word is being typed, not just on an empty one" {
  # Every test here used to pass '' as the word being completed, so the partial
  # case went unexercised — and it was broken: the script read $2 as the verb, but
  # with `ddev tryout herd<TAB>` argv is `tryout herd`, so $2 IS the partial word.
  # It matched no case, printed nothing, and zsh fell back to file completion.
  # cobra filters candidates against the partial word itself, so returning the full
  # list is correct.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13"

  run names herd
  assert_success
  assert_line "herdr"

  run names cs doc
  assert_success
  assert_line "doctor"

  run names worktree us
  assert_success
  assert_line "use"

  run names worktree use ma
  assert_success
  assert_line "main"

  # An empty word must keep working too.
  run names "''"
  assert_success
  assert_line "herdr"
}

@test "completion offers herdr, its worktrees and its flags" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13"

  run names "''"
  assert_success
  assert_line "herdr"

  run names herdr "''"
  assert_success
  assert_line "main"
  assert_line "v13"
  assert_line "--no-agent"
  assert_line "--no-focus"
}

@test "completion describes every candidate or explains the free-text word" {
  # DDEV passes each line to cobra verbatim, so `value<TAB>description` renders
  # as two columns and `_activeHelp_ text` as a hint. A bare word would look like
  # a regression in zsh: no description beside it.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/sites/v13"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  local args line
  for args in "''" "worktree ''" "worktree add ''" "worktree add x ''" "worktree use ''" \
              "worktree serve ''" "worktree list ''" "cs ''" "cs setup ''" "herdr ''" \
              "herdr new ''" "checkout ''" "patch ''" "exec ''" "exec v13 ''" \
              "delete ''" "download ''" "status ''"; do
    # shellcheck disable=SC2086
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      case "${line}" in
        "_activeHelp_ "?*) ;;
        *"	"?*) ;;
        *) echo "bare candidate for '${args}': ${line}"; false ;;
      esac
    done < <(complete ${args})
  done
}

@test "completion hints at free-text words instead of staying silent" {
  # DDEV always returns cobra's Default directive, so silence means the shell
  # lists files. A hint above them is the best we can do — so there must be one.
  set -eu -o pipefail
  run complete worktree add "''"
  assert_success
  assert_line --regexp '^_activeHelp_ name for the new worktree'

  run complete worktree rename main "''"
  assert_line --regexp '^_activeHelp_ new name for main'

  run complete cs setup "''"
  assert_line --regexp '^_activeHelp_ .*Gerrit username'

  run complete exec v13 "''"
  assert_line --regexp '^_activeHelp_ command to run in v13'
}

@test "completion offers --plain for worktree list" {
  set -eu -o pipefail
  run names worktree list "''"
  assert_success
  assert_line "--plain"
}

@test "completion offers serve only unserved worktrees and unserve only served ones" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13" "${FAKEROOT}/typo3-core-v12"
  mkdir -p "${FAKEROOT}/sites/v13"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"

  run names worktree serve "''"
  assert_success
  assert_line "main"
  assert_line "v12"
  refute_line "v13"

  run names worktree unserve "''"
  assert_success
  assert_line "v13"
  refute_line "main"
  refute_line "v12"

  # The served one says so, with its PHP version.
  run complete worktree unserve "''"
  assert_line --regexp $'^v13\t.*PHP 8\\.2'
}

@test "completion omits the primary from use and remove" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  run names worktree use "''"
  assert_success
  assert_line "v13"
  refute_line "main"

  run names worktree remove "''"
  refute_output --partial "main"

  # Elsewhere the primary is offered, and labelled.
  run complete herdr "''"
  assert_line --regexp $'^main\tprimary'
}

@test "completion does not offer a flag already on the line" {
  set -eu -o pipefail
  run names worktree add x --serve --
  assert_success
  refute_line "--serve"
  assert_line "--php"

  # refute_line cannot cope with empty output, and nothing is a valid answer here.
  run names download --reset "''"
  refute_output --partial "--reset"

  run names delete --all "''"
  refute_output --partial "--all"
  refute_output --partial "@primary"
  assert_line "--yes"
}

@test "completion shows only flags once a dash is typed" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main"
  run names worktree use --
  assert_success
  assert_line "--force"
  refute_line "main"
}

@test "completion offers PHP versions after --php" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-v13"
  run names worktree serve v13 --php "''"
  assert_success
  assert_line "8.2"
  assert_line "8.5"

  run names worktree add x --php "''"
  assert_line "8.4"
}

@test "completion offers the configured patch numbers" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/.ddev"
  printf 'web_environment:\n  - TRYOUT_PATCHES=56947,12345\n' > "${FAKEROOT}/.ddev/config.tryout-patches.yaml"
  run names patch "''"
  assert_success
  assert_line "56947"
  assert_line "12345"
}

@test "completion covers every worktree, cs and herdr subcommand the command dispatches" {
  set -eu -o pipefail
  local subs sub
  for verb in worktree cs herdr; do
    # The first name of each case label; aliases (remove|rm) are deliberately
    # not offered — two spellings of one thing would only lengthen the list.
    subs=$(sed -n "/^cmd_${verb}()/,/^}/p" "${DIR}/commands/host/tryout" \
      | sed -n 's/^        \([a-z][a-z|-]*\)).*/\1/p' | cut -d'|' -f1)
    [ -n "${subs}" ]
    run names "${verb}" "''"
    assert_success
    for sub in ${subs}; do
      assert_line "${sub}"
    done
  done
}

@test "completion answers instantly" {
  # list_core_worktrees runs a `git status` per worktree; using it for names
  # once made a TAB cost a third of a second. Generous bound, coarse clock.
  set -eu -o pipefail
  local n start end
  for n in 1 2 3 4 5 6; do mkdir -p "${FAKEROOT}/typo3-core-wt${n}"; done
  start=$(date +%s)
  complete worktree use "''" >/dev/null
  complete herdr "''" >/dev/null
  complete exec "''" >/dev/null
  end=$(date +%s)
  [ $(( end - start )) -le 1 ]
}

# --- gum presentation layer -------------------------------------------------
# These pin the two gum behaviours that would otherwise cause silent damage:
# spin must not swallow exit codes (the error handling depends on them), and
# choose reports success without a TTY while choosing nothing.

@test "ui_spin preserves the wrapped command's exit code" {
  set -eu -o pipefail

  # The whole error-handling layer branches on these codes; a spinner that
  # swallows them would report every failed serve/checkout as a success.
  run helper_eval 'ui_spin "working" true'
  assert_success

  run helper_eval 'ui_spin "working" false'
  assert_failure

  run helper_eval 'ui_spin "working" sh -c "exit 3"'
  [ "$status" -eq 3 ]
}

@test "ui_spin does not emit escape sequences when its output is captured" {
  set -eu -o pipefail

  # gum spin writes control characters to a non-TTY; the helper must run the
  # command plainly there, or captured output is corrupted.
  run helper_eval 'ui_spin "working" printf hello'
  assert_success
  assert_output --partial "hello"
  refute_output --partial $'\e['
}

@test "ui_choose fails without a TTY instead of reporting a bogus choice" {
  set -eu -o pipefail

  # gum choose exits 0 with no output when it cannot open a terminal. Trusting
  # that exit code would make a cancelled prompt look like a real answer.
  run helper_eval 'ui_choose "pick one" alpha beta </dev/null'
  assert_failure
  refute_output --partial "alpha"
}

@test "ui_choose falls back to a plain read when a name is piped in" {
  set -eu -o pipefail

  run helper_eval 'printf "beta\n" | ui_choose "pick one" alpha beta'
  assert_success
  assert_output --partial "beta"
}

@test "ui_table renders rows and degrades without gum" {
  set -eu -o pipefail

  run helper_eval 'printf "NAME,STATE\nmain,clean\n" | ui_table'
  assert_success
  assert_output --partial "NAME"
  assert_output --partial "main"
  assert_output --partial "clean"

  # With gum off the PATH the data must still come through, unbordered.
  run helper_eval 'printf "NAME,STATE\nmain,clean\n" | PATH=/usr/bin:/bin ui_table'
  assert_success
  assert_output --partial "main"
}

@test "worktree list --plain is the parseable contract, the default is a table" {
  set -eu -o pipefail

  # tests/e2e/login.spec.ts discovers served sites by regex over --plain. The
  # bordered default table does not match it, so the flag must keep working.
  run grep -n "worktree', 'list', '--plain'" "${DIR}/tests/e2e/login.spec.ts"
  assert_success

  # The flag has to reach the list branch, not be swallowed as a worktree name:
  # the host hands `list` its arguments verbatim, and the container branches on it.
  run grep -q 'delegate worktree list "\$@"' "${DIR}/commands/host/tryout"
  assert_success
  run grep -c -- '--plain' "${DIR}/tryout/commands.sh"
  assert_success
}

@test "gum is optional: install notes its absence but does not refuse" {
  set -eu -o pipefail

  # gum only changes how output looks — every command works without it — so a
  # missing binary must never block installing the add-on.
  run grep -A2 'command -v gum' "${DIR}/install.yaml"
  assert_success
  assert_output --partial "gum"

  # The note has to say where to get it...
  run grep -q 'github.com/charmbracelet/gum' "${DIR}/install.yaml"
  assert_success

  # ...and must not exit: the git check above it does, this one may not.
  run helper_eval '
    block=$(awk "/command -v gum/,/^    fi$/" "'"${DIR}"'/install.yaml")
    printf "%s" "${block}" | grep -q "exit 1" && exit 1
    exit 0'
  assert_success
}

@test "every ui_ helper degrades to plain output when gum is absent" {
  set -eu -o pipefail

  # This is the path a user without gum actually gets, so it has to carry the
  # same information as the styled one — just unstyled.
  local nogum="PATH=/usr/bin:/bin:/usr/sbin:/sbin"

  run helper_eval "printf 'NAME,STATE\nmain,clean\n' | ${nogum} ui_table"
  assert_success
  assert_output --partial "NAME"
  assert_output --partial "main"
  assert_output --partial "clean"

  run helper_eval "printf 'Core: main\n' | ${nogum} ui_box 'Status'"
  assert_success
  assert_output --partial "Status"
  assert_output --partial "Core: main"

  # Exit codes still have to survive the un-spun path.
  run helper_eval "${nogum} ui_spin 'work' true"
  assert_success
  run helper_eval "${nogum} ui_spin 'work' false"
  assert_failure

  # And a piped answer still selects, without gum's chooser.
  run helper_eval "printf 'main\n' | ${nogum} ui_choose 'pick' benni main"
  assert_success
  assert_output --partial "main"

  # A confirm with no terminal is "could not ask" (2), never a yes — with or
  # without gum, and whatever is piped at it.
  run helper_eval "${nogum} ui_confirm 'sure?' </dev/null"
  assert_equal "${status}" 2
  run helper_eval "printf 'y\n' | ${nogum} ui_confirm 'sure?'"
  assert_equal "${status}" 2
}

@test "ui_confirm separates a declined answer from an unanswerable one" {
  set -eu -o pipefail

  # The three-way return is the whole point of the helper. A caller says
  # "Aborted." for a no and "pass --yes" for no-terminal, and cannot tell them
  # apart from gum, which exits 1 for both. 2 means nobody was there to ask.
  run helper_eval "ui_confirm 'sure?' </dev/null"
  assert_equal "${status}" 2
  # Nothing was asked, so nothing may be printed into whatever captured us.
  refute_output --partial "sure?"

  # A piped "y" is not a person answering: no terminal is still 2, never 0.
  # Anything else here would let a script wipe a database by accident.
  run helper_eval "printf 'y\n' | ui_confirm 'sure?'"
  assert_equal "${status}" 2
}

@test "ui_confirm defaults to no, so Enter never confirms" {
  set -eu -o pipefail
  command -v expect >/dev/null 2>&1 || skip "expect not installed"

  # gum preselects Yes unless --default=false, so a bare Enter used to confirm.
  # Every prompt here is [y/N]; Enter has to decline in BOTH renderings.
  local script="source '${DIR}/tryout/functions.sh'; rc=0; ui_confirm 'Delete this?' || rc=\$?; echo \"RC=\${rc}\""

  # gum branch.
  run expect -c "log_user 0
    set timeout 10
    spawn bash -c {${script}}
    expect -re {Delete this}
    send -- \"\r\"
    expect -re {RC=([0-9]+)} { puts \$expect_out(1,string) }"
  assert_output --partial "1"

  # plain branch, gum off PATH.
  run expect -c "log_user 0
    set timeout 10
    spawn bash -c {export PATH=/usr/bin:/bin:/usr/sbin:/sbin; ${script}}
    expect -re {\\[y/N\\]}
    send -- \"\r\"
    expect -re {RC=([0-9]+)} { puts \$expect_out(1,string) }"
  assert_output --partial "1"
}

@test "ui_confirm reads y as yes and an arrow key as no" {
  set -eu -o pipefail
  command -v expect >/dev/null 2>&1 || skip "expect not installed"

  # An arrow key arrives as ESC [ A. Stripping only the ESC would leave a
  # printable "[A"; a stray "y" in such a tail must never read as a yes.
  local script="source '${DIR}/tryout/functions.sh'; export PATH=/usr/bin:/bin:/usr/sbin:/sbin; rc=0; ui_confirm 'Delete this?' || rc=\$?; echo \"RC=\${rc}\""
  local drive="log_user 0
    set timeout 10
    spawn bash -c {${script}}
    expect -re {\\[y/N\\]}"

  run expect -c "${drive}
    send -- \"y\r\"
    expect -re {RC=([0-9]+)} { puts \$expect_out(1,string) }"
  assert_output --partial "0"

  run expect -c "${drive}
    send -- \"\033\[A\r\"
    expect -re {RC=([0-9]+)} { puts \$expect_out(1,string) }"
  assert_output --partial "1"
}

@test "confirmations go through ui_confirm, not a hand-rolled read" {
  set -eu -o pipefail

  # A raw `read -r -p` cannot tell a no from an empty room, and under `set -u`
  # the unset variable it leaves behind aborts the command with a bash error
  # instead of a usable message. That is what cmd_delete used to do.
  run grep -nE 'read -r -p.*\[y/N\]' "${DIR}/commands/host/tryout"
  assert_failure

  # And gum is optional, so a raw `gum confirm` would hard-break the no-gum path.
  run bash -c "grep -n 'gum confirm' '${DIR}/commands/host/tryout' '${DIR}/tryout/commands.sh'"
  assert_failure
}

@test "worktree remove always asks, because it deletes the directory" {
  set -eu -o pipefail

  # It deletes the checkout's directory outright — ~20k files that took minutes to
  # check out. git's refusal to drop a dirty tree is no longer the backstop, since
  # the removal deliberately forces past it, so the question is the only guard
  # left and it must be asked every time.
  local branch
  branch="$(awk '/^        remove\|rm\)/{f=1} f{print} f&&/^            ;;/{exit}' \
    "${DIR}/commands/host/tryout")"

  printf '%s' "${branch}" | grep -q 'ui_confirm' \
    || fail "worktree remove must confirm before an irreversible removal"

  # Grepping for the words alone would pass with the gate rewritten to `if false`.
  # Pin the condition: the ONLY thing that may skip it is an explicit --yes.
  local gate
  gate="$(printf '%s' "${branch}" | grep -n 'ui_confirm' | head -1 | cut -d: -f1)"
  gate="$(printf '%s' "${branch}" | sed -n "1,${gate}p" | grep -E '^\s*if .*; then$' | tail -1)"
  printf '%s' "${gate}" | grep -q 'wt_yes' \
    || fail "only an explicit --yes may skip the question, got: ${gate}"
  printf '%s' "${gate}" | grep -qE 'wt_force|site_is_served' \
    && fail "the question is unconditional now, not gated on what is lost: ${gate}"

  # And --yes is the host's own word: delegating it would fail the container's
  # argument parser.
  printf '%s' "${branch}" | grep -q -- '--yes|-y) wt_yes="true"' \
    || fail "--yes must be consumed on the host"
  printf '%s' "${branch}" | grep -q 'delegate worktree remove "${name}" ${wt_args' \
    || fail "the delegated arguments must be the filtered ones, not \"\$@\""
}

@test "removing a worktree really takes its directory" {
  set -eu -o pipefail
  # A Core checkout always carries untracked and ignored files — vendor/, var/,
  # Build/ — and a plain `git worktree remove` refuses on any of them ("contains
  # modified or untracked files"), leaving the directory behind after reporting
  # success. The user was already asked, and the question named the directory, so
  # the answer has to actually take it.
  local fn
  fn=$(sed -n '/^remove_core_worktree()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'local args=("worktree" "remove" "--force")' \
    || fail "without --force git leaves the directory whenever anything is untracked"

  # And a sweep afterwards, for what git would not delete itself.
  printf '%s' "${fn}" | grep -q 'rm -rf "${dir}"' \
    || fail "a directory git declined to remove must still go"
  # Scoped to the worktree's own path, never a bare or derived one.
  local bad
  bad=$(printf '%s' "${fn}" | grep -E '^\s*rm -rf' | grep -v '"\${dir}"' || true)
  [ -z "${bad}" ] || fail "unscoped removal: ${bad}"

  # It must be deregistered before the sweep, or rm -rf races git's own bookkeeping.
  local git_line rm_line
  git_line=$(printf '%s' "${fn}" | grep -n 'worktree prune' | head -1 | cut -d: -f1)
  rm_line=$(printf '%s' "${fn}" | grep -n 'rm -rf' | head -1 | cut -d: -f1)
  [ "${git_line}" -lt "${rm_line}" ] \
    || fail "prune the worktree before deleting what is left of it"
}

@test "have_tty tests stderr, not stdout, so the chooser survives \$(...)" {
  set -eu -o pipefail

  # Every prompt is read as x="$(ui_choose ...)", which makes stdout a pipe. A
  # have_tty that required [ -t 1 ] would silently disable gum's chooser in the
  # one place it is meant to run — and the plain read it fell back to returned
  # the arrow-key escape sequence as the "choice".
  run grep -A1 '^have_tty()' "${DIR}/tryout/functions.sh"
  assert_success
  refute_output --partial '-t 1'
  assert_output --partial '-t 2'
}

@test "the plain prompt never returns a control sequence as an answer" {
  set -eu -o pipefail

  # An arrow key at a plain `read` arrives as an escape sequence; treating it as
  # a worktree name would send a command off at a nonexistent target.
  run helper_eval 'printf "\033[B\n" | ui_choose "pick" alpha beta'
  assert_failure
}

# --- guided arguments ---------------------------------------------------------
# A command missing its argument asks for it; without a terminal it prints the
# usage line as before. These pin the helpers and the one trap that made every
# prompt invisible: gum draws on stderr.

@test "gum prompts do not redirect stderr, because that is where gum draws" {
  set -eu -o pipefail
  # ui_choose and ui_input once carried 2>/dev/null to hush "could not open
  # TTY"; the effect was a chooser the user could not see. have_tty guards the
  # no-terminal case instead.
  run grep -nE 'gum (choose|filter|input|confirm) .*2>/dev/null' "${DIR}/tryout/functions.sh"
  assert_failure
  # The same trap one level up: hushing an ask_* helper hides the gum UI it draws.
  # The popup did exactly that and its branch chooser answered nothing.
  run bash -c "grep -nE 'ask_(branch|worktree|site|text|patches)[^|]*2>/dev/null' \
    '${DIR}'/tryout/*.sh '${DIR}/commands/host/tryout'"
  assert_failure
}

@test "core_worktree_names filters by primary and served state" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13" "${FAKEROOT}/typo3-core-v12" "${FAKEROOT}/sites/v13"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  run helper core_worktree_names all
  assert_line "main"; assert_line "v13"; assert_line "v12"

  run helper core_worktree_names nonprimary
  refute_line "main"; assert_line "v13"

  run helper core_worktree_names served
  assert_output "v13"

  run helper core_worktree_names unserved
  assert_line "main"; assert_line "v12"; refute_line "v13"
}

@test "ask_worktree takes a piped answer and fails cleanly with none" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-v13"

  run helper_eval 'printf "v13\n" | ask_worktree "which?" all'
  assert_success
  assert_output "v13"

  run helper_eval 'ask_worktree "which?" all </dev/null'
  assert_failure
  refute_output --partial "v13"
}

@test "ask_worktree explains when there is nothing to choose from" {
  set -eu -o pipefail
  run helper_eval 'ask_worktree "which?" all </dev/null'
  assert_failure
  assert_output --partial "No worktree to choose from"
  assert_output --partial "worktree add"
}

@test "ask_branch puts main first and legacy refs last" {
  set -eu -o pipefail
  # A fake list_local_core_branches; ask_branch only orders what it gets.
  run helper_eval '
    list_local_core_branches() { printf "%s\n" 9.5 TYPO3_8-7 13.4 main 14.3 12.4; }
    ui_choose() { shift; printf "%s\n" "$@"; }
    ask_branch "which?"'
  assert_success
  assert_line --index 0 "main"
  assert_line --index 1 "14.3"
  assert_line --index 2 "13.4"
  assert_line --index 3 "12.4"
  assert_line --index 4 "9.5"
  assert_line --index 5 "TYPO3_8-7"
}

@test "explain_missing prints the usage line only where nobody could answer" {
  set -eu -o pipefail
  run helper_eval 'explain_missing "ddev tryout worktree use <name>" </dev/null'
  assert_success
  assert_output --partial "Usage: ddev tryout worktree use <name>"
}

@test "every command that used to fail on a missing argument now asks first" {
  set -eu -o pipefail
  # The old shape was a one-line usage error; each of those sites must reach an
  # ask_* helper before it gives up.
  run grep -cE 'ask_(worktree|site|branch|text) ' "${DIR}/commands/host/tryout"
  assert_success
  [ "${output}" -ge 10 ]
  run grep -E '\[ -z "\$\{name\}" \] && \{ error "Usage' "${DIR}/commands/host/tryout"
  assert_failure
}

@test "ui_spin decides on stderr, the stream gum draws on" {
  set -eu -o pipefail
  # DDEV pipes a host command's stdout, always; a spinner gated on stdout being
  # a terminal never showed under `ddev tryout`.
  run grep -A3 '^ui_spin()' "${DIR}/tryout/functions.sh"
  run grep -nE 'have_gum && \[ -t 2 \]' "${DIR}/tryout/functions.sh"
  assert_success
}

@test "the post-start hook runs inside the web container" {
  # The clone, the patches and composer all happen in there now, so there is
  # nothing to flush to the container and no host git involved.
  set -eu -o pipefail
  run grep -E '^    - exec: bash \.ddev/tryout/post-start\.sh$' "${DIR}/config.tryout.yaml"
  assert_success
  run grep -q 'exec-host' "${DIR}/config.tryout.yaml"
  assert_failure
  run grep -q 'sync_to_container' "${DIR}/tryout/post-start.sh"
  assert_failure
}

@test "a PHP that cannot run the Core on disk is rejected before composer runs" {
  # Composer reports the same mismatch, but as a resolver trace followed by our
  # hint to re-download — which is not the fix. The check names the constraint,
  # the version in use, and the command that changes it.
  set -eu -o pipefail
  command -v php >/dev/null 2>&1 || skip 'php not available'

  mkdir -p "${FAKEROOT}/typo3-core" "${FAKEROOT}/typo3-core-v13"
  printf '{"require":{"php":"^8.5"}}' > "${FAKEROOT}/typo3-core/composer.json"
  printf '{"require":{"php":"^8.2"}}' > "${FAKEROOT}/typo3-core-v13/composer.json"

  # The project on 8.4 against a main Core: refused, with the concrete fix.
  run env DDEV_PHP_VERSION=8.4 bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    available_php_versions() { printf '8.2\n8.3\n8.4\n8.5\n'; }
    check_php_for_core
  "
  assert_failure
  assert_output --partial 'requires PHP ^8.5'
  assert_output --partial 'the project runs PHP 8.4'
  assert_output --partial 'ddev config --php-version=8.5 && ddev restart'

  # A served site gets its own remedy, not the project-wide one.
  run env DDEV_PHP_VERSION=8.5 bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    available_php_versions() { printf '8.2\n8.3\n8.4\n8.5\n'; }
    check_php_for_core '${FAKEROOT}/typo3-core-v13' 8.1 v13
  "
  assert_failure
  assert_output --partial "site 'v13' runs PHP 8.1"
  assert_output --partial 'ddev tryout worktree serve v13 --php 8.5'
}

@test "a PHP the Core accepts passes the check, and so does an unreadable constraint" {
  # No composer.json yet (fresh project before the clone) or no constraint in
  # it: Composer is the authority then, so the check must not block.
  set -eu -o pipefail
  command -v php >/dev/null 2>&1 || skip 'php not available'

  mkdir -p "${FAKEROOT}/typo3-core" "${FAKEROOT}/typo3-core-bare"
  printf '{"require":{"php":"^8.5"}}' > "${FAKEROOT}/typo3-core/composer.json"
  printf '{}' > "${FAKEROOT}/typo3-core-bare/composer.json"

  run env DDEV_PHP_VERSION=8.5 bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    check_php_for_core && check_php_for_core '${FAKEROOT}/typo3-core-bare' 8.1 \
      && check_php_for_core '${FAKEROOT}/nowhere' 8.1 && echo passed
  "
  assert_success
  assert_output "passed"
}

@test "every composer install is preceded by the PHP check" {
  # post-start.sh, rebuild_typo3 and serve_worktree are the places Composer
  # resolves Core; each must ask first, or the resolver trace is what the user
  # sees. The guard has to sit in the same function as the install (or anywhere
  # above it in the flat post-start script).
  set -eu -o pipefail
  local file install check
  for file in "${DIR}/tryout/post-start.sh" "${DIR}/tryout/functions.sh"; do
    grep -vE '^[[:space:]]*#' "${file}" > "${FAKEROOT}/code"
    while IFS= read -r install; do
      # The nearest check_php_for_core above the install that is not separated
      # from it by a function boundary.
      check=$(awk -v to="${install}" '
        /^[a-z_]+\(\) \{/ { fn = NR }
        /check_php_for_core/ && NR < to { n = NR; nfn = fn }
        NR == to { print (n && nfn == fn) ? n : ""; exit }' "${FAKEROOT}/code")
      [ -n "${check}" ] || fail "${file}: composer install at code line ${install} has no check_php_for_core in its function"
    done <<LINES
$(grep -nE 'composer install' "${FAKEROOT}/code" | cut -d: -f1)
LINES
  done
}

@test "the single Core checkout of a fresh project opens in herdr under its branch" {
  # Before any worktree exists there is only typo3-core/ itself. It must resolve
  # to that directory under the name the worktree layout gives it later, so the
  # herdr label survives the migration; on the symlink layout the name maps to
  # typo3-core-<name> as before.
  set -eu -o pipefail
  git init -q -b main "${FAKEROOT}/typo3-core"

  run bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    printf '%s|%s|%s\n' \"\$(plain_core_name)\" \"\$(herdr_checkout_dir main)\" \"\$(herdr_checkout_dir v13)\"
  "
  assert_success
  assert_output "main|${FAKEROOT}/typo3-core|${FAKEROOT}/typo3-core-v13"

  # A branch name that is no valid worktree name falls back to the default.
  git -C "${FAKEROOT}/typo3-core" checkout -q -b 'feature/x' 2>/dev/null
  run bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    plain_core_name
  "
  assert_success
  assert_output "main"

  # The symlink layout: the plain name is empty and lookups go to typo3-core-<name>.
  mv "${FAKEROOT}/typo3-core" "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  run bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    printf '[%s]%s' \"\$(plain_core_name)\" \"\$(herdr_checkout_dir main)\"
  "
  assert_success
  assert_output "[]${FAKEROOT}/typo3-core-main"
}

@test "the herdr command no longer turns a single-checkout project away" {
  set -eu -o pipefail
  run grep -q 'This project has a single Core checkout, not worktrees' "${DIR}/commands/host/tryout"
  assert_failure
}

@test "the extra php-fpm socket lives under /run/php/, in daemon and vhost alike" {
  # The daemon runs as the web user and /run is root-owned on some providers
  # (Colima): a bind there fails with "Permission denied" and every request to the
  # served site is a 502. /run/php/ is where the stock php-fpm writes its pid, so
  # it is writable everywhere. Both sides must agree on the path, or nginx passes
  # requests to a socket nobody listens on.
  set -eu -o pipefail
  run grep -E '^SOCKET=' "${DIR}/tryout/tryout-php-fpm.sh"
  assert_output 'SOCKET="${RUN_DIR}/php-fpm-${VERSION}.sock"'
  run grep -E '^RUN_DIR=' "${DIR}/tryout/tryout-php-fpm.sh"
  assert_output 'RUN_DIR="/run/php"'
  run grep -E '^pid = ' "${DIR}/tryout/tryout-php-fpm.sh"
  assert_output 'pid = ${RUN_DIR}/php-fpm-${VERSION}.pid'

  run grep -E '^[[:space:]]*sock="/run/php/php-fpm-\$\{php\}\.sock"' "${DIR}/tryout/functions.sh"
  assert_success

  # Nothing may bind straight under /run/ any more.
  run grep -E '"/run/php-fpm-' "${DIR}/tryout/tryout-php-fpm.sh" "${DIR}/tryout/functions.sh"
  assert_failure
}

@test "switching Core drops vendor/ before the rebuild" {
  # Composer loads the plugins already in vendor/ before resolving, so a Core
  # switch across majors (class-alias-loader v2 -> v1) dies in the loaded
  # plugin's hook and leaves the site on 500. Both switch paths must wipe first,
  # and in the container — a host-side rm races Mutagen.
  set -eu -o pipefail
  local fn body
  for fn in use_core_worktree ctr_checkout; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${DIR}/tryout/functions.sh" "${DIR}/tryout/commands.sh")
    [ -n "${body}" ] || fail "no function ${fn}"
    printf '%s\n' "${body}" | grep -q 'wipe_site_vendor' \
      || fail "${fn} does not call wipe_site_vendor"
    # The wipe comes before the rebuild.
    [ "$(printf '%s\n' "${body}" | grep -n 'wipe_site_vendor' | head -1 | cut -d: -f1)" \
      -lt "$(printf '%s\n' "${body}" | grep -n 'rebuild_typo3' | tail -1 | cut -d: -f1)" ] \
      || fail "${fn} rebuilds before wiping"
  done
  run grep -E 'rm -rf "\$\(site_vendor "\$\{name\}"\)"' "${DIR}/tryout/functions.sh"
  assert_success
}

# --- git in the container, relative worktree paths --------------------------
# tryout's git work runs inside the web container while editors, herdr and the
# completion read the same checkouts on the host. Worktree metadata records paths,
# and an absolute path is right on one side only; relative paths (git >= 2.48)
# are what let both sides share one worktree.

@test "the web image builds a pinned git that supports relative worktree paths" {
  set -eu -o pipefail
  local f="${DIR}/web-build/Dockerfile.tryout"
  assert_file_exist "${f}"
  run grep -q '^#ddev-generated' "${f}"
  assert_success
  # Version and checksum are pinned, so an image never builds from a tarball
  # nobody has looked at.
  run grep -E '^ARG TRYOUT_GIT_VERSION=2\.(4[8-9]|[5-9][0-9])\.[0-9]+$' "${f}"
  assert_success
  run grep -E '^ARG TRYOUT_GIT_SHA256=[0-9a-f]{64}$' "${f}"
  assert_success
  run grep -q 'sha256sum -c' "${f}"
  assert_success
  # Build dependencies do not stay in the image.
  run grep -q -- '--auto-remove' "${f}"
  assert_success
  run grep -qE '^  - web-build/Dockerfile\.tryout$' "${DIR}/install.yaml"
  assert_success
}

@test "git_supports_relative_worktrees reads the version, not the platform" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/bin"
  printf '#!/bin/sh\necho "git version 2.47.3"\n' > "${FAKEROOT}/bin/git"
  chmod +x "${FAKEROOT}/bin/git"
  run helper_eval "PATH='${FAKEROOT}/bin:${PATH}' git_supports_relative_worktrees"
  assert_failure
  printf '#!/bin/sh\necho "git version 2.48.0"\n' > "${FAKEROOT}/bin/git"
  run helper_eval "PATH='${FAKEROOT}/bin:${PATH}' git_supports_relative_worktrees"
  assert_success
  printf '#!/bin/sh\necho "git version 2.50.1 (Apple Git-155)"\n' > "${FAKEROOT}/bin/git"
  run helper_eval "PATH='${FAKEROOT}/bin:${PATH}' git_supports_relative_worktrees"
  assert_success
}

@test "ensure_relative_worktree_paths converts a worktree recorded with absolute paths" {
  set -eu -o pipefail
  helper git_supports_relative_worktrees || skip "host git < 2.48"
  local main="${FAKEROOT}/typo3-core-main" wt="${FAKEROOT}/typo3-core-x"
  git init -q "${main}"
  git -C "${main}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  git -C "${main}" worktree add -q --detach "${wt}" HEAD
  # The shape a worktree has when the OTHER side created it.
  printf 'gitdir: /var/www/html/typo3-core-main/.git/worktrees/typo3-core-x\n' > "${wt}/.git"
  printf '/var/www/html/typo3-core-x/.git\n' > "${main}/.git/worktrees/typo3-core-x/gitdir"
  run git -C "${wt}" status --short
  assert_failure

  run helper ensure_relative_worktree_paths
  assert_success
  run git -C "${main}" config --get worktree.useRelativePaths
  assert_output "true"
  run cat "${wt}/.git"
  assert_output "gitdir: ../typo3-core-main/.git/worktrees/typo3-core-x"
  run git -C "${wt}" status --short
  assert_success
  # A worktree added afterwards is relative from the start.
  git -C "${main}" worktree add -q --detach "${FAKEROOT}/typo3-core-y" HEAD
  run cat "${FAKEROOT}/typo3-core-y/.git"
  assert_output "gitdir: ../typo3-core-main/.git/worktrees/typo3-core-y"
}

@test "every clone and worktree operation goes through ensure_relative_worktree_paths" {
  set -eu -o pipefail
  # A worktree made without it is absolute and breaks on the other side.
  local fn body
  for fn in add_core_worktree migrate_core_to_worktree_layout; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${DIR}/tryout/functions.sh")
    printf '%s\n' "${body}" | grep -q 'ensure_relative_worktree_paths' \
      || fail "${fn} does not call ensure_relative_worktree_paths"
  done
  # And a fresh clone is configured before anything else happens to it.
  local file clone ensure
  for file in "${DIR}/tryout/post-start.sh" "${DIR}/tryout/commands.sh"; do
    [ -f "${file}" ] || continue
    clone=$(grep -nE '^[[:space:]]*(if ! )?git clone ' "${file}" | head -1 | cut -d: -f1)
    [ -n "${clone}" ] || continue
    ensure=$(awk -v from="${clone}" 'NR > from && /ensure_relative_worktree_paths/ { print NR; exit }' "${file}")
    [ -n "${ensure}" ] || fail "${file}: git clone at line ${clone} is not followed by ensure_relative_worktree_paths"
  done
  # add_core_worktree refuses on a git that cannot write relative paths.
  body=$(sed -n "/^add_core_worktree() {/,/^}/p" "${DIR}/tryout/functions.sh")
  printf '%s\n' "${body}" | grep -q 'git_supports_relative_worktrees' \
    || fail "add_core_worktree does not check the git version"
}

# --- host / container split ---------------------------------------------------
# commands/host/tryout is the entry point: it owns the terminal (prompts, gum,
# herdr) and hands every container-safe verb to tryout-container.sh through ONE
# `ddev exec`. Inside, git, composer, php and the database clients are the
# container's own, so nothing in there may call `ddev` back.

@test "container-side code never shells out to ddev" {
  set -eu -o pipefail
  local f
  for f in tryout/functions.sh tryout/commands.sh tryout/tryout-container.sh tryout/post-start.sh; do
    run bash -c "
      grep -vE '^[[:space:]]*#' '${DIR}/${f}' \
        | grep -E '(^[[:space:]]*|\\\$\\(|&& |\\|\\| |; )(if ! |! )?ddev (exec|composer|typo3|php|mysql|mutagen)( |\$)'
    "
    [ -z "${output}" ] || fail "${f} calls ddev: ${output}"
  done
}

@test "the container dispatcher covers every verb the host delegates" {
  set -eu -o pipefail
  local host_verbs ctr_verbs verb
  host_verbs=$(sed -n '/^case "${ACTION}" in/,/^esac/p' "${DIR}/commands/host/tryout" \
    | sed -n 's/^    \([a-z|]*\)).*/\1/p' | tr '|' '\n' | grep -v '^\*$')
  ctr_verbs=$(sed -n '/^case "${ACTION}" in/,/^esac/p' "${DIR}/tryout/tryout-container.sh" \
    | sed -n 's/^    \([a-z|]*\)).*/\1/p' | tr '|' '\n' | grep -v '^\*$')
  [ -n "${ctr_verbs}" ]
  for verb in ${host_verbs}; do
    case "${verb}" in
      herdr|panel|launch|help) continue ;;  # host by nature: herdr panes, a browser, static text
    esac
    printf '%s\n' "${ctr_verbs}" | grep -qx "${verb}" || fail "container dispatcher lacks '${verb}'"
  done
  run grep -q '^export TRYOUT_IN_CONTAINER=1' "${DIR}/tryout/tryout-container.sh"
  assert_success
  run grep -q 'tryout/commands.sh' "${DIR}/tryout/tryout-container.sh"
  assert_success
}

@test "verbs that need Core are refused on the host before the container is asked" {
  # `ddev tryout patch 1` before ddev start must still say "TYPO3 Core not found"
  # with a next step — not a ddev error about a stopped project.
  set -eu -o pipefail
  local fn body rc dl
  for fn in cmd_patch cmd_reset cmd_checkout cmd_composer cmd_worktree cmd_cs; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${DIR}/commands/host/tryout")
    [ -n "${body}" ] || fail "no function ${fn}"
    rc=$(printf '%s\n' "${body}" | grep -n 'require_core' | head -1 | cut -d: -f1)
    dl=$(printf '%s\n' "${body}" | grep -n 'delegate ' | head -1 | cut -d: -f1)
    [ -n "${rc}" ] || fail "${fn} never calls require_core"
    [ -n "${dl}" ] || fail "${fn} never delegates"
    [ "${rc}" -lt "${dl}" ] || fail "${fn} delegates before require_core"
  done
  # status stays useful with the containers down: the not-cloned answer is local.
  run helper_eval 'source "${DIR}/commands/host/tryout" 2>/dev/null; true'
}

@test "the host forwards the caller's environment to the container" {
  set -eu -o pipefail
  local body
  body=$(sed -n '/^delegate() {/,/^}/p' "${DIR}/commands/host/tryout")
  [ -n "${body}" ] || fail "no delegate()"
  printf '%s\n' "${body}" | grep -q 'ddev exec' || fail "delegate does not use ddev exec"
  printf '%s\n' "${body}" | grep -q 'TRYOUT_BRANCH' || fail "TRYOUT_BRANCH is not forwarded"
  printf '%s\n' "${body}" | grep -q 'TRYOUT_GERRIT_USER' || fail "TRYOUT_GERRIT_USER is not forwarded"
}

@test "database helpers reach the db service from inside the web container" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/bin"
  printf '#!/bin/sh\nprintf "mysql %%s\\n" "$*"\n' > "${FAKEROOT}/bin/mysql"
  printf '#!/bin/sh\nprintf "psql %%s\\n" "$*"\n' > "${FAKEROOT}/bin/psql"
  chmod +x "${FAKEROOT}/bin/mysql" "${FAKEROOT}/bin/psql"
  run helper_eval "PATH='${FAKEROOT}/bin:${PATH}' db_root_sql 'SELECT 1'"
  assert_success
  assert_output "mysql -h db -uroot -proot -e SELECT 1"
  run helper_eval "PATH='${FAKEROOT}/bin:${PATH}' DDEV_DATABASE=postgres:16 db_root_sql 'SELECT 1'"
  assert_success
  assert_output "psql -h db -U db -d postgres -tAc SELECT 1"
}

@test "the SSH hint names ddev auth ssh inside the container, ssh-add on the host" {
  # The container's probe talks to ddev-ssh-agent, the host's to the host agent;
  # the next step differs, and the wrong one sends people to the wrong keychain.
  set -eu -o pipefail
  run helper_eval 'CS_SSH_REASON=no-agent-key; TRYOUT_IN_CONTAINER=1 gerrit_ssh_hint'
  assert_output --partial "ddev auth ssh"
  run helper_eval 'CS_SSH_REASON=no-agent-key; TRYOUT_IN_CONTAINER= gerrit_ssh_hint'
  assert_output --partial "ssh-add"
  # And the host adds its own line after the container's doctor report.
  run grep -c 'host_gerrit_ssh_report' "${DIR}/commands/host/tryout"
  assert_success
  [ "${output}" -ge 2 ]
}

@test "install notes a host git older than 2.48, and only notes it" {
  set -eu -o pipefail
  # The pre-install action, extracted the way DDEV would run it.
  sed -n '/^pre_install_actions:/,/^project_files:/p' "${DIR}/install.yaml" \
    | sed '1d;$d' | sed '1d' | sed 's/^    //' > "${FAKEROOT}/action.sh"
  mkdir -p "${FAKEROOT}/bin"
  printf '#!/bin/sh\necho "git version 2.39.5"\n' > "${FAKEROOT}/bin/git"
  chmod +x "${FAKEROOT}/bin/git"
  run env PATH="${FAKEROOT}/bin:${PATH}" bash "${FAKEROOT}/action.sh"
  assert_success
  assert_output --partial "predates relative worktree paths"
  printf '#!/bin/sh\necho "git version 2.50.1 (Apple Git-155)"\n' > "${FAKEROOT}/bin/git"
  run env PATH="${FAKEROOT}/bin:${PATH}" bash "${FAKEROOT}/action.sh"
  assert_success
  refute_output --partial "predates"
}

@test "shell functions are never run through env" {
  # `env VAR=x run_typo3 …` looks for a binary called run_typo3 and fails with
  # "No such file or directory" — which is how the first-run TYPO3 setup broke
  # once it moved into the container. A variable prefix is the right shape.
  set -eu -o pipefail
  run bash -c "grep -nE '\benv +([A-Z_]+=[^ ]* +)+(run_|site_exec|db_root_sql|ctr_|cmd_)' \
    '${DIR}'/tryout/*.sh '${DIR}/commands/host/tryout'"
  [ -z "${output}" ] || fail "shell function run through env: ${output}"
}

@test "the host is brought up to date after a verb that changes files" {
  # `worktree add x && cd typo3-core-x` on the host must not race Mutagen.
  set -eu -o pipefail
  local body
  body=$(sed -n '/^delegate() {/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s\n' "${body}" | grep -q 'flush_mutagen' || fail "delegate never flushes"
  # …and the read-only verbs are exempt, so status stays instant.
  printf '%s\n' "${body}" | grep -q '"status "\*|"exec "\*' || fail "status/exec are not exempt"
  printf '%s\n' "${body}" | grep -q '"worktree list"\*' || fail "worktree list is not exempt"
}

# --- browsing Gerrit patches ------------------------------------------------
# `ddev tryout patch` with no argument lists the open changes for the branch in
# use and lets the user pick one or several. The list itself is fetched in the
# container (curl + jq); the picker runs on the host, where gum and the terminal
# are.

@test "list-patches parses a Gerrit change listing into pickable rows" {
  set -eu -o pipefail
  local script="${DIR}/tryout/list-patches.sh"
  assert_file_exist "${script}"
  # A fake curl serving the captured payload, XSSI prefix and all.
  mkdir -p "${FAKEROOT}/bin"
  cat > "${FAKEROOT}/bin/curl" <<FAKE
#!/bin/sh
cat "${DIR}/tests/fixtures-gerrit-changes.json"
FAKE
  chmod +x "${FAKEROOT}/bin/curl"

  run env PATH="${FAKEROOT}/bin:${PATH}" bash "${script}" https://review.typo3.org main
  assert_success
  # number<TAB>subject<TAB>owner<TAB>scores — one row per change.
  local first
  first="$(printf '%s\n' "${output}" | head -1)"
  printf '%s' "${first}" | grep -qE '^[0-9]+	' || fail "no change number in: ${first}"
  [ "$(printf '%s' "${first}" | awk -F'\t' '{print NF}')" -eq 4 ] \
    || fail "expected 4 tab-separated fields, got: ${first}"
  assert_output --partial "whitespace module"
  # The owner is a name, not a JSON blob.
  printf '%s' "${first}" | cut -f3 | grep -qE '^[A-Za-zÀ-ÿ. -]+$' \
    || fail "owner column is not a name: $(printf '%s' "${first}" | cut -f3)"
}

@test "list-patches signals fetch and parse failures the way the other resolvers do" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/bin"
  printf '#!/bin/sh\nexit 22\n' > "${FAKEROOT}/bin/curl"
  chmod +x "${FAKEROOT}/bin/curl"
  run env PATH="${FAKEROOT}/bin:${PATH}" bash "${DIR}/tryout/list-patches.sh" https://x main
  [ "${status}" -eq 2 ] || fail "expected exit 2 on a fetch failure, got ${status}"

  printf '#!/bin/sh\nprintf "not json\\n"\n' > "${FAKEROOT}/bin/curl"
  run env PATH="${FAKEROOT}/bin:${PATH}" bash "${DIR}/tryout/list-patches.sh" https://x main
  [ "${status}" -eq 3 ] || fail "expected exit 3 on a parse failure, got ${status}"
}

@test "ui_choose_multi returns every picked line and fails on a cancel" {
  set -eu -o pipefail
  # Without a TTY the plain path reads piped answers, one per line, and an empty
  # answer is a cancel — the same contract ui_choose follows.
  run bash -c "printf 'a\nb\n' | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; ui_choose_multi 'Pick' one two three; }"
  assert_success
  assert_output --partial "a"
  assert_output --partial "b"

  run bash -c "printf '\n' | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; ui_choose_multi 'Pick' one two; }"
  assert_failure
}

@test "the multi picker uses gum choose --no-limit and never redirects its screen" {
  set -eu -o pipefail
  local body
  body=$(sed -n '/^ui_choose_multi() {/,/^}/p' "${DIR}/tryout/functions.sh")
  [ -n "${body}" ] || fail "no ui_choose_multi()"
  printf '%s\n' "${body}" | grep -q -- '--no-limit' || fail "not a multi-select"
  # gum draws on stderr; a 2>/dev/null here gives an invisible prompt.
  if printf '%s\n' "${body}" | grep -q 'gum choose.*2>/dev/null'; then
    fail "gum's screen is redirected"
  fi
  # Same TTY guard as ui_choose: gum exits 0 with no output when it has none.
  printf '%s\n' "${body}" | grep -q 'have_gum && have_tty' || fail "no TTY guard"
}

@test "a bare patch command offers the list before giving up" {
  set -eu -o pipefail
  local body
  body=$(sed -n '/^cmd_patch() {/,/^}/p' "${DIR}/commands/host/tryout")
  [ -n "${body}" ] || fail "no cmd_patch()"
  printf '%s\n' "${body}" | grep -q 'pick_patches' \
    || fail "cmd_patch never offers the patch list"
  # The fetch is separate from the pick: a spinner must not run over a chooser.
  printf '%s\n' "${body}" | grep -q 'fetch_open_patches' || fail "no fetch step"
  # And it still delegates the actual work.
  printf '%s\n' "${body}" | grep -q 'delegate patch' || fail "cmd_patch does not delegate"
}

@test "picked patch numbers are appended to the patch list, once each" {
  set -eu -o pipefail
  local f="${FAKEROOT}/.ddev/config.tryout-patches.yaml"
  mkdir -p "${FAKEROOT}/.ddev"

  # An empty list, the shape a fresh install has.
  cat > "${f}" <<'YAML'
# Gerrit Patches
#
# Example: TRYOUT_PATCHES=56947,12345

web_environment:
  - TRYOUT_PATCHES=
YAML
  run helper_eval "persist_patches 95074 95671"
  assert_success
  run grep -c '^# Gerrit Patches' "${f}"
  assert_output "1"
  run grep '  - TRYOUT_PATCHES=' "${f}"
  assert_output "  - TRYOUT_PATCHES=95074,95671"

  # A populated list gains only what is new, in order, with no duplicate.
  run helper_eval "persist_patches 95671 12345"
  assert_success
  run grep '  - TRYOUT_PATCHES=' "${f}"
  assert_output "  - TRYOUT_PATCHES=95074,95671,12345"

  # The rest of the file is preserved verbatim.
  run grep -c 'Example: TRYOUT_PATCHES=56947,12345' "${f}"
  assert_output "1"
}

@test "persisting refuses politely when the patch list is not there" {
  set -eu -o pipefail
  run helper_eval "persist_patches 1"
  assert_failure
}

@test "several picked patches are applied in order and rebuilt once" {
  # A rebuild is a full composer install; doing it per patch would run it three
  # times for a three-patch pick.
  set -eu -o pipefail
  local body
  body=$(sed -n '/^ctr_patch() {/,/^}/p' "${DIR}/tryout/commands.sh")
  [ -n "${body}" ] || fail "no ctr_patch()"
  printf '%s\n' "${body}" | grep -q 'for id in "${ids\[@\]}"' || fail "patches are not applied in a loop"
  # Exactly one rebuild call in the multi-patch branch.
  [ "$(printf '%s\n' "${body}" | sed -n '/for id in/,/^    else/p' | grep -c 'rebuild_typo3')" -eq 1 ] \
    || fail "expected one rebuild for the whole batch"
}

@test "the site moved to a flag so change numbers can be positional" {
  set -eu -o pipefail
  local ctr host
  ctr=$(sed -n '/^ctr_patch() {/,/^}/p' "${DIR}/tryout/commands.sh")
  printf '%s\n' "${ctr}" | grep -q -- '--site)' || fail "container does not accept --site"
  # And the old two-argument form still reaches it.
  host=$(sed -n '/^cmd_patch() {/,/^}/p' "${DIR}/commands/host/tryout")
  # The id-carrying delegate specifically: a site given after the change number
  # must still reach the container as --site, or it lands in the id slot.
  printf '%s\n' "${host}" | grep -q -- 'delegate patch ${site:+--site "${site}"} "${id}"' \
    || fail "host does not translate patch <id> <site> into --site"
  # And --site is accepted from the user too: the panel knows the site but not the
  # change number, and positionally the id comes first.
  printf '%s\n' "${host}" | grep -q -- '--site)' \
    || fail "host does not accept --site"
}

@test "the picker is skipped when a patch list is configured or there is no terminal" {
  # `ddev start` and any scripted call must keep applying TRYOUT_PATCHES rather
  # than opening a chooser nobody can answer.
  set -eu -o pipefail
  local body
  body=$(sed -n '/^cmd_patch() {/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s\n' "${body}" | grep -q 'TRYOUT_PATCHES' || fail "a configured list does not short-circuit"
  printf '%s\n' "${body}" | grep -q '! have_tty' || fail "no TTY guard before the picker"
}

@test "the patch list is fetched under a spinner, and picked without one" {
  # gum spin and gum choose both own the screen; running the chooser inside the
  # spinner's pipeline makes the prompt unusable.
  set -eu -o pipefail
  local fetch pick
  fetch=$(sed -n '/^fetch_open_patches() {/,/^}/p' "${DIR}/tryout/functions.sh")
  pick=$(sed -n '/^pick_patches() {/,/^}/p' "${DIR}/tryout/functions.sh")
  [ -n "${fetch}" ] || fail "no fetch_open_patches()"
  [ -n "${pick}" ] || fail "no pick_patches()"
  printf '%s\n' "${fetch}" | grep -q 'ui_spin' || fail "the fetch does not spin"
  if printf '%s\n' "${pick}" | grep -q 'ui_spin'; then fail "the picker spins"; fi
  printf '%s\n' "${pick}" | grep -q 'ui_choose_multi' || fail "the picker does not choose"
  # An unreachable Gerrit is a failure, not an empty list.
  printf '%s\n' "${fetch}" | grep -q 'return 1' || fail "a failed fetch is not signalled"
}

@test "pick_patches turns TSV rows into labels and returns the numbers" {
  set -eu -o pipefail
  # Rows arrive on stdin; without gum the chooser reads the answer from the same
  # stream, so a picked label can follow the rows.
  # Rows are arguments, so stdin stays free for the no-gum chooser's answer.
  run bash -c "printf '95074   [BUGFIX] Something\n' \
    | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; \
        pick_patches 'Pick' \
          \"\$(printf '95074\\t[BUGFIX] Something\\tBenni Mack\\tCR+2 V+2')\" \
          \"\$(printf '95671\\t[BUGFIX] Other\\tOli Bartsch\\tV+1')\"; }"
  assert_success
  assert_output "95074"
}

@test "the picker takes its rows as arguments, leaving stdin for the answer" {
  # Reading rows from stdin would swallow the very input the no-gum chooser needs.
  set -eu -o pipefail
  local body
  body=$(sed -n '/^pick_patches() {/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s\n' "${body}" | grep -qE 'for row in "\$@"' || fail "rows are not arguments"
  if printf '%s\n' "${body}" | grep -qE 'while IFS= read -r row'; then
    fail "pick_patches consumes stdin"
  fi
}

@test "the picker leaves the key hints to gum" {
  # gum 2.0 toggles with x, not space, and draws its own footer saying so; a
  # hint of ours in the header would just be a second place to get it wrong.
  set -eu -o pipefail
  if grep -rn 'space to select' "${DIR}/commands/host/tryout" "${DIR}/tryout/functions.sh"; then
    fail "a hard-coded toggle key is spelled out in a prompt"
  fi
}

@test "patch labels line up even with non-ASCII subjects and owners" {
  # printf's %-Ns pads by BYTES: a "…" or an accented name silently shortens its
  # column and pushes everything after it out of line.
  set -eu -o pipefail
  run helper_eval 'printf "[%s]" "$(pad_display "abc" 6)"'
  assert_output "[abc   ]"
  # Three bytes, one column: the padding must still reach six.
  run helper_eval 'printf "[%s]" "$(pad_display "a…c" 6)"'
  assert_output "[a…c   ]"
  run helper_eval 'printf "[%s]" "$(pad_display "Frédéric" 10)"'
  assert_output "[Frédéric  ]"
  # Longer than the field: left alone, never truncated mid-character.
  run helper_eval 'printf "[%s]" "$(pad_display "abcdefgh" 4)"'
  assert_output "[abcdefgh]"

  # And the renderer uses it rather than printf padding.
  local body
  body=$(sed -n '/^pick_patches() {/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s\n' "${body}" | grep -q 'pad_display' || fail "pick_patches pads by bytes"
}

@test "list-patches truncates with ASCII so the columns stay byte-aligned" {
  set -eu -o pipefail
  # The code, not the comment that explains why.
  if grep -vE '^[[:space:]]*(#|//)' "${DIR}/tryout/list-patches.sh" | grep -q '…'; then
    fail "a multi-byte ellipsis in the truncation shortens the padded column"
  fi
}

@test "the persist prompt names each change, not just its number" {
  # "Add 93838 to your patch list?" tells the user nothing about what 93838 is,
  # and it is about to be written into a config file they keep.
  set -eu -o pipefail
  run helper_eval "describe_patches '95347 93838' \
    \"\$(printf '95347\\t[TASK] Skip database setup\\tWouter Wolters\\tV+1')\" \
    \"\$(printf '93838\\t[FEATURE] Translate forms\\tJosua Vogel\\tV+1')\""
  assert_success
  assert_line "95347 - [TASK] Skip database setup"
  assert_line "93838 - [FEATURE] Translate forms"

  # A number nobody listed still gets a line rather than vanishing.
  run helper_eval "describe_patches '11111' \
    \"\$(printf '95347\\t[TASK] Something\\tX\\tV+1')\""
  assert_success
  assert_output "11111"

  # And the prompt uses it.
  local body
  body=$(sed -n '/^cmd_patch() {/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s\n' "${body}" | grep -q 'describe_patches' \
    || fail "the confirmation still lists bare numbers"
}

# --- picking a site ---------------------------------------------------------

@test "ask_site shows what each site is, and returns the name behind it" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/sites/v13" "${FAKEROOT}/sites/v12"
  printf 'php=8.4\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  printf 'php=8.2\n' > "${FAKEROOT}/sites/v12/.tryout-site"

  # The label carries the URL and PHP version; the answer is the bare name.
  run bash -c "printf 'v13          https://v13.unitproj.ddev.site  PHP 8.4\n' \
    | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; ask_site 'Which?'; }"
  assert_success
  assert_output "v13"

  # The primary is offered as "primary" but answers with the sentinel, which is
  # what site_is_primary understands.
  run bash -c "printf 'primary       https://unitproj.ddev.site\n' \
    | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; \
        DDEV_PRIMARY_URL=https://unitproj.ddev.site ask_site 'Which?'; }"
  assert_success
  assert_output "@primary"
}

@test "ask_site offers the extra entries it is given, unchanged" {
  # delete uses this for --all: wiping everything is a pick, not a flag to recall.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/sites/v13"
  printf 'php=8.4\n' > "${FAKEROOT}/sites/v13/.tryout-site"
  run bash -c "printf -- '--all         every site\n' \
    | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; ask_site 'Which?' '--all         every site'; }"
  assert_success
  assert_output -- "--all         every site"

  # Typing just the name works too: the caller matches on the first word.
  run bash -c "printf -- '--all\n' \
    | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; ask_site 'Which?' '--all         every site'; }"
  assert_success
  assert_output -- "--all"
}

@test "exec, reset and delete all ask which site when there are several" {
  set -eu -o pipefail
  local fn body
  for fn in cmd_exec cmd_reset cmd_delete; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${DIR}/commands/host/tryout")
    [ -n "${body}" ] || fail "no ${fn}"
    printf '%s\n' "${body}" | grep -q 'ask_site' || fail "${fn} never offers a site list"
    printf '%s\n' "${body}" | grep -q 'explain_missing' \
      || fail "${fn} does not fall through to the usage line"
  done

  # reset and delete only ask once something else is served — a single-site
  # project keeps working without a prompt.
  for fn in cmd_reset cmd_delete; do
    body=$(sed -n "/^${fn}() {/,/^}/p" "${DIR}/commands/host/tryout")
    printf '%s\n' "${body}" | grep -q 'served_site_names' \
      || fail "${fn} asks even with no served site"
  done
}

@test "a picked primary does not reach the container as a sentinel" {
  # "@primary" is the host's word for the default; ctr_delete parses positional
  # arguments and would take it for a site name.
  set -eu -o pipefail
  local body
  body=$(sed -n '/^cmd_delete() {/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s\n' "${body}" | grep -q 'site_is_primary "${target}" && target=""' \
    || fail "the primary sentinel is forwarded verbatim"
}

# --- picking a worktree -----------------------------------------------------

@test "ask_worktree labels each worktree with its branch, HEAD and state" {
  set -eu -o pipefail
  local main="${FAKEROOT}/typo3-core-main" wt="${FAKEROOT}/typo3-core-v13"
  git init -q "${main}"
  git -C "${main}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  git -C "${main}" worktree add -q --detach "${wt}" HEAD
  mkdir -p "${FAKEROOT}/sites/v13"
  printf 'php=8.4\n' > "${FAKEROOT}/sites/v13/.tryout-site"

  # The rendered rows carry branch, HEAD, state and what the site is.
  run helper worktree_labels all
  assert_success
  assert_output --partial "main"
  assert_output --partial "primary"
  assert_output --partial "v13"
  assert_output --partial "(detached)"
  assert_output --partial "PHP 8.4"

  # …but the answer is still the bare name the callers pass on.
  run bash -c "printf 'v13\n' | { source '${DIR}/tryout/functions.sh' >/dev/null 2>&1; ask_worktree 'Which?'; }"
  assert_success
  assert_output "v13"
}

@test "ask_worktree keeps filtering by primary and served state" {
  set -eu -o pipefail
  local main="${FAKEROOT}/typo3-core-main" wt="${FAKEROOT}/typo3-core-v13"
  git init -q "${main}"
  git -C "${main}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  git -C "${main}" worktree add -q --detach "${wt}" HEAD
  mkdir -p "${FAKEROOT}/sites/v13"
  printf 'php=8.4\n' > "${FAKEROOT}/sites/v13/.tryout-site"

  # served: only v13. unserved and nonprimary: only main / only what is left.
  run helper worktree_labels served
  assert_output --partial "v13"
  refute_output --partial "primary"

  run helper worktree_labels nonprimary
  assert_output --partial "v13"

  run helper worktree_labels unserved
  refute_output --partial "v13"
}

@test "worktree adopt offers the strays instead of taking all of them" {
  set -eu -o pipefail
  local body
  body=$(awk '/^        adopt\)/,/^            ;;/' "${DIR}/commands/host/tryout")
  [ -n "${body}" ] || fail "no adopt branch"
  printf '%s\n' "${body}" | grep -q 'ui_choose_multi' \
    || fail "adopt does not offer a multi-select"
  # --dry-run still just reports, and an explicit path still bypasses the picker.
  printf '%s\n' "${body}" | grep -q 'dry="true"' || fail "--dry-run is gone"
  printf '%s\n' "${body}" | grep -q 'one_path' || fail "the explicit-path form is gone"
}

@test "every worktree subcommand that names a worktree can pick one" {
  set -eu -o pipefail
  local sub body
  for sub in "use" "remove|rm" "serve" "unserve" "rename" "adopt"; do
    body=$(awk -v pat="        ${sub})" 'index($0, pat) == 1, /^            ;;/' \
      "${DIR}/commands/host/tryout")
    [ -n "${body}" ] || fail "no '${sub}' branch"
    printf '%s\n' "${body}" | grep -qE 'ask_worktree|ui_choose_multi' \
      || fail "'${sub}' never offers a worktree list"
  done
}

# --- the installed copy going stale -----------------------------------------
# `ddev add-on get` copies the payload once and never refreshes it, so a project
# installed before a change keeps the old command AND the old completion script.
# Completion then still works but offers the older feature set, which is
# indistinguishable from "autocomplete is broken".

# --- the herdr command panel ------------------------------------------------
# The panel is a bash TUI in a herdr pane. Its risky parts are the ones a parse
# check cannot see: mouse-sequence decoding, and leaving the terminal as it was.

# Load the panel's definitions without running its input loop, which would block.
panel_defs() {
  sed '/^mouse_on$/,$d' "${DIR}/tryout/herdr-panel.sh"
}

@test "the panel's input loop starts at a bare mouse_on, which the tests cut at" {
  set -eu -o pipefail
  # Four tests below load the panel's definitions by deleting everything from the
  # `mouse_on` that starts the input loop — without it they would block on read.
  # Rename that line and they stop testing anything while still passing, so pin it.
  run grep -cx 'mouse_on' "${DIR}/tryout/herdr-panel.sh"
  assert_success
  assert_output "1"
  # And what remains above it must still define the pieces those tests drive.
  run bash -c "sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh' | grep -c '^handle_escape()'"
  assert_output "1"
}

@test "a click maps to the command on that row, and misses are ignored" {
  set -eu -o pipefail
  # Rows are absolute screen rows; FIRST_ROW is where the list starts. Getting this
  # off by one would run the wrong command, which is worse than doing nothing.
  # A served worktree gives the longest menu, so there are rows to miss past.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-benni" \
           "${FAKEROOT}/sites/benni"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/benni/.tryout-site"

  run env TRYOUT_PANEL_WORKTREE=benni TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "
    eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    run_selected() { echo \"PICKED=\${LABELS[\${SEL}]}\"; }
    handle_escape '[<0;5;4m'
    handle_escape '[<0;5;8m'
    before=\${SEL}
    handle_escape '[<0;5;99m'
    echo \"AFTER_MISS=\${SEL} BEFORE=\${before}\"
  "
  assert_success
  assert_line "PICKED=status"                 # first row, at FIRST_ROW
  assert_line "PICKED=reset"                  # fifth row
  assert_line --partial "AFTER_MISS=4 BEFORE=4"   # a click past the list moves nothing
}

@test "the panel acts on release and ignores a press, so a drag does not fire" {
  set -eu -o pipefail
  run /bin/bash -c "
    eval \"\$(sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    run_selected() { echo 'RAN'; }
    handle_escape '[<0;5;5M'   # press
    echo 'AFTER_PRESS'
    handle_escape '[<0;5;5m'   # release
  "
  assert_success
  # The press must not have run anything; only the release does.
  assert_equal "${lines[0]}" "AFTER_PRESS"
  assert_line "RAN"
}

@test "the wheel scrolls the selection instead of running a command" {
  set -eu -o pipefail
  run /bin/bash -c "
    eval \"\$(sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    run_selected() { echo 'RAN'; }
    handle_escape '[<65;5;5M'   # wheel down
    handle_escape '[<65;5;5M'
    handle_escape '[<64;5;5M'   # wheel up
    echo \"SEL=\${SEL}\"
  "
  assert_success
  assert_output --partial "SEL=1"
  refute_output --partial "RAN"
}

@test "a malformed mouse sequence is ignored, not mis-dispatched" {
  set -eu -o pipefail
  run /bin/bash -c "
    eval \"\$(sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    run_selected() { echo 'RAN'; }
    handle_escape '[<garbage'
    handle_escape '[<0;5m'
    handle_escape ''
    echo \"SEL=\${SEL}\"
  "
  assert_success
  assert_output --partial "SEL=0"
  refute_output --partial "RAN"
}

@test "the panel always restores mouse mode and the cursor" {
  set -eu -o pipefail
  # An abandoned mouse mode leaves the user's pane spraying escape codes into
  # whatever they type next, so the restore must survive any exit path.
  run grep -qE '^trap cleanup EXIT INT TERM' "${DIR}/tryout/herdr-panel.sh"
  assert_success
  # Disable sequences, and the cursor back on.
  run grep -q '1006l' "${DIR}/tryout/herdr-panel.sh"; assert_success
  run grep -q '1000l' "${DIR}/tryout/herdr-panel.sh"; assert_success
  run grep -q '25h'   "${DIR}/tryout/herdr-panel.sh"; assert_success
}

@test "the panel never depends on right-click, which herdr keeps for itself" {
  set -eu -o pipefail
  # herdr intercepts right-click for its own pane menu unless the user sets
  # right_click_passthrough_modifier, so a right-click handler would be dead code
  # for almost everyone. Button 2 is right; only 0 (left) and 64/65 (wheel) are ours.
  run grep -nE '"2"\)|btn.*=.*2[^0-9]' "${DIR}/tryout/herdr-panel.sh"
  assert_failure
}

@test "the panel and its popup are wired to the same verb list" {
  set -eu -o pipefail
  # The popup runs whatever the panel hands it, so a verb the panel offers must be
  # one `ddev tryout` actually dispatches — a typo here is a dead row.
  local verbs host_case
  # Read the list as text: sourcing the script would install its cleanup trap,
  # whose escape codes then land in the captured output as a bogus entry.
  # The menu is built per worktree state now, so ask it for its rows rather than
  # reading a static array. The primary's list is the widest.
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  verbs=$(TRYOUT_PANEL_WORKTREE=main TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "
    eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    printf '%s\n' \"\${ARGS[@]}\"
  " 2>/dev/null)
  host_case=$(sed -n '/^case "${ACTION}" in/,/^esac/p' "${DIR}/commands/host/tryout")
  local v
  while IFS= read -r v; do
    [ -n "${v}" ] || continue
    printf '%s\n' "${host_case}" | grep -qE "^    ${v%% *}[)|]" \
      || fail "panel offers '${v}' but the command does not dispatch '${v%% *}'"
  done <<< "${verbs}"
}

@test "the panel docks against the calling pane, never the UI-focused one" {
  set -eu -o pipefail
  # This is the bug that made the panel vanish: splitting from whichever pane held
  # UI focus put it in another client's workspace entirely. herdr's own guidance —
  # "omitting a target may use the UI-focused pane, which can belong to the user or
  # another client" — is why the target must come from HERDR_PANE_ID, which DDEV
  # passes through to a host command.
  run grep -nE 'focused *== *true|focused_pane' "${DIR}/tryout/herdr-panel-open.sh"
  assert_failure
  run grep -q 'HERDR_PANE_ID' "${DIR}/tryout/herdr-panel-open.sh"
  assert_success

  # `--current` is meaningless here too: a DDEV host command is not itself a pane,
  # so herdr would fall back to the focused one and reintroduce the same bug.
  run grep -n 'pane \(split\|focus\).*--current' "${DIR}/tryout/herdr-panel-open.sh"
  assert_failure
}

@test "the panel refuses outside herdr instead of splitting nothing" {
  set -eu -o pipefail
  run grep -q 'HERDR_ENV' "${DIR}/tryout/herdr-panel-open.sh"
  assert_success
  # And the host verb says so too, rather than handing the user a herdr error.
  local branch
  branch=$(sed -n '/^cmd_panel()/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s' "${branch}" | grep -q 'HERDR_ENV' \
    || fail "cmd_panel must refuse outside herdr"
}

@test "the popup resolves the project from the CWD, not from its own path" {
  set -eu -o pipefail
  # A plugin action is registered per machine, so $0 points at whichever checkout
  # installed it. Only the pane's directory says which project the user is in.
  run grep -q 'resolve_approot' "${DIR}/tryout/herdr-panel-run.sh"
  assert_success
  run bash -c "cd /tmp && bash '${DIR}/tryout/herdr-panel-run.sh' status </dev/null 2>&1"
  assert_output --partial "No DDEV project here"
}

@test "the popup never spawns a pane, and only launch skips the popup" {
  set -eu -o pipefail
  # checkout/reset/patch once got a pane of their own, to keep a multi-minute
  # rebuild out of a session-modal popup. It left a stray pane behind after every
  # run — the clutter the panel exists to avoid — so they run in the popup, which
  # streams their [1/4] progress as a live log rather than a frozen box.
  run grep -nE 'is_slow|hand_off' "${DIR}/tryout/herdr-panel-run.sh"
  assert_failure
  # The popup must never split anything: one command, one popup, nothing left over.
  run grep -n 'pane split' "${DIR}/tryout/herdr-panel-run.sh"
  assert_failure
  # Nor may the panel itself.
  run grep -n 'pane split' "${DIR}/tryout/herdr-panel.sh"
  assert_failure

  # The exception runs the other way: launch skips the popup entirely and runs in
  # the panel. It raises the browser, so a popup only puts a box in front of it.
  # Nothing else may claim that — a verb that prompts, takes minutes, or prints a
  # screenful needs the popup's room and its TTY. status is the near miss: fast
  # and read-only, but a screenful in a ~25-column strip.
  local menu direct
  menu=$(sed -n '/^build_menu()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  direct=$(printf '%s\n' "${menu}" | grep -c 'add .* direct$' || true)
  [ "${direct}" -eq 2 ] || fail "expected exactly two direct rows, found ${direct}"
  printf '%s' "${menu}" | grep -q 'add "launch frontend" .* direct$' \
    || fail "launch frontend must run in the panel"
  printf '%s' "${menu}" | grep -q 'add "launch backend" .* direct$' \
    || fail "launch backend must run in the panel"
  # Both are the same verb; nothing else may claim the direct path.
  local other
  other=$(printf '%s\n' "${menu}" | grep 'add .* direct$' | grep -cv 'add "launch ' || true)
  [ "${other}" -eq 0 ] || fail "${other} row(s) other than launch tagged direct"
}

# --- the Claude / Terminal tabs ---------------------------------------------
# herdr labels a workspace's first tab "1", which says nothing about what is in
# it. Each worktree gets that tab named for its contents plus a Terminal tab.

# A herdr stub that answers tab list and pane list as well as workspace list, so
# the tab helpers can be driven without a running herdr.
fake_herdr_tabs() {
  mkdir -p "${FAKEROOT}/bin"
  printf '%s' "${1:-}" > "${FAKEROOT}/tabs.json"
  printf '%s' "${2:-}" > "${FAKEROOT}/panes.json"
  cat > "${FAKEROOT}/bin/herdr" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "--session" ] && shift 2
if [ "\$1" = "tab" ] && [ "\$2" = "list" ]; then cat "${FAKEROOT}/tabs.json"; exit 0; fi
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then cat "${FAKEROOT}/panes.json"; exit 0; fi
echo "CALL: \$*" >> "${FAKEROOT}/calls.log"
FAKE
  chmod +x "${FAKEROOT}/bin/herdr"
  : > "${FAKEROOT}/calls.log"
}

run_with_fake_herdr() {
  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    $1
  "
}

@test "a workspace without a Terminal tab gets exactly one" {
  set -eu -o pipefail
  fake_herdr_tabs '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1"}]}}'
  run_with_fake_herdr 'ensure_terminal_tab w1 /tmp/wt'
  assert_success

  run cat "${FAKEROOT}/calls.log"
  assert_output --partial "tab create --workspace w1"
  assert_output --partial "--label Terminal"
  # --no-focus: the agent is what the user came for; opening must not land them
  # in the shell instead.
  assert_output --partial "--no-focus"
}

@test "a workspace that already has a Terminal tab gets no second one" {
  set -eu -o pipefail
  # This is what makes the backfill safe to run on every bare `ddev tryout herdr`.
  fake_herdr_tabs '{"result":{"tabs":[
    {"tab_id":"w1:t1","label":"Claude"},
    {"tab_id":"w1:t2","label":"Terminal"}
  ]}}'
  run_with_fake_herdr 'ensure_terminal_tab w1 /tmp/wt'
  assert_success

  run cat "${FAKEROOT}/calls.log"
  refute_output --partial "tab create"
}

@test "the first tab is named Claude only when an agent is actually in it" {
  set -eu -o pipefail
  # Naming a tab for an agent that is not running is worse than leaving it "1".
  fake_herdr_tabs \
    '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1"}]}}' \
    '{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent":"claude"}]}}'
  run_with_fake_herdr 'ensure_first_tab_label w1'
  assert_success
  run cat "${FAKEROOT}/calls.log"
  assert_line "CALL: tab rename w1:t1 Claude"

  # No agent anywhere in the workspace: it is a shell, and says so.
  fake_herdr_tabs \
    '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1"}]}}' \
    '{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent":null}]}}'
  run_with_fake_herdr 'ensure_first_tab_label w1'
  assert_success
  run cat "${FAKEROOT}/calls.log"
  assert_line "CALL: tab rename w1:t1 Shell"
}

@test "a tab the user named themselves is never renamed" {
  set -eu -o pipefail
  # Only herdr's default "1" is ours to replace. Anything else was chosen.
  fake_herdr_tabs \
    '{"result":{"tabs":[{"tab_id":"w1:t1","label":"my notes"}]}}' \
    '{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent":"claude"}]}}'
  run_with_fake_herdr 'ensure_first_tab_label w1'
  assert_success
  run cat "${FAKEROOT}/calls.log"
  refute_output --partial "tab rename"
}

@test "the tab helpers do nothing without a workspace id" {
  set -eu -o pipefail
  # herdr_workspace_id returns empty for a workspace that is not open; neither
  # helper may then act on whatever herdr considers current.
  fake_herdr_tabs '{"result":{"tabs":[]}}' '{"result":{"panes":[]}}'
  run_with_fake_herdr 'ensure_terminal_tab "" /tmp/wt; ensure_first_tab_label ""'
  assert_success
  run cat "${FAKEROOT}/calls.log"
  refute_output --partial "tab create"
  refute_output --partial "tab rename"
}

@test "opening a worktree names its tab from the agent it actually started" {
  set -eu -o pipefail
  # The agent-start outcomes decide the name, so the label cannot drift from what
  # the success/warn lines report. start_agent_in_pane owns those outcomes — both
  # routes into a workspace use it, the fresh open and the backfill of one that was
  # already there — and it answers 0 whenever the agent is up.
  local fn ag
  fn=$(sed -n '/^open_worktree_in_herdr()/,/^}/p' "${DIR}/tryout/functions.sh")
  ag=$(sed -n '/^start_agent_in_pane()/,/^}/p' "${DIR}/tryout/functions.sh")
  [ -n "${ag}" ] || fail "no start_agent_in_pane"

  # Default is Shell; only a started agent promotes it to Claude.
  printf '%s' "${fn}" | grep -q 'tab_label="Shell"' \
    || fail "the tab must default to Shell"
  printf '%s' "${fn}" | grep -q 'start_agent_in_pane .* && tab_label="Claude"' \
    || fail "a started agent must promote the tab to Claude"
  printf '%s' "${fn}" | grep -q 'ensure_terminal_tab' \
    || fail "opening a worktree must add its Terminal tab"

  # Two of the three outcomes mean "the agent is up": started, and started but
  # blocked on its own UI (the folder-trust prompt on a first run). Only the third
  # is a failure, and only it leaves the tab a shell.
  [ "$(printf '%s' "${ag}" | grep -c 'return 0')" -eq 2 ] \
    || fail "both agent-running outcomes must report success"
  printf '%s' "${ag}" | grep -q 'agent_not_ready' \
    || fail "a first run waiting on folder trust is not a failure"
  printf '%s' "${ag}" | grep -q 'Could not start claude' \
    || fail "a real failure must say so"

  # And the tab label follows the agent LATER too: a workspace that gains one on a
  # backfill was already renamed Shell, so a rename that only fires on herdr's own
  # "1" would leave it saying Shell beside a running claude.
  # Pin the SELECTOR, not just the word "Shell" — that appears in the rename call
  # below whatever the selector matches, so a grep for it passes either way.
  local lbl sel
  lbl=$(sed -n '/^ensure_first_tab_label()/,/^}/p' "${DIR}/tryout/functions.sh")
  sel=$(printf '%s\n' "${lbl}" | sed -n '/tabs\[0\]/,/tab_id/p')
  [ -n "${sel}" ] || fail "no first-tab selector"
  printf '%s' "${sel}" | grep -q 'Shell' \
    || fail "an already-named Shell tab must be re-checked, not skipped"
}

# --- the per-worktree panel -------------------------------------------------
# Each workspace gets a panel scoped to its own worktree. What a worktree IS
# decides what can be done to it, and the menu must never offer otherwise.

# Build the panel's menu for a given worktree, without running its input loop.
panel_menu() { # $1=worktree $2=approot
  TRYOUT_PANEL_WORKTREE="$1" TRYOUT_PANEL_APPROOT="$2" \
  /bin/bash -c "
    eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    echo \"STATE=\${STATE}\"
    i=0; while [ \$i -lt \${#LABELS[@]} ]; do
      printf 'ROW %s|%s\n' \"\${LABELS[\$i]}\" \"\${ARGS[\$i]}\"; i=\$((i+1))
    done
  " 2>/dev/null
}

@test "escape closes the panel and runs nothing" {
  set -eu -o pipefail
  # A bare ESC arrives with an empty tail — nothing followed it. Arrows and mouse
  # reports come through the same function WITH a tail, so only the empty case may
  # quit, and none of them may run a command on the way out.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-lonely"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  run env TRYOUT_PANEL_WORKTREE=lonely TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "
    eval \"\$(sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    run_selected() { echo 'RAN'; }
    handle_escape '' && echo 'esc:continue' || echo 'esc:quit'
    handle_escape '[A' && echo 'up:continue' || echo 'up:quit'
    handle_escape '[B' && echo 'down:continue' || echo 'down:quit'
    handle_escape '[<0;5;99m' >/dev/null && echo 'click:continue' || echo 'click:quit'
  "
  assert_success
  assert_line "esc:quit"
  assert_line "up:continue"
  assert_line "down:continue"
  assert_line "click:continue"
  refute_output --partial "RAN"

  # And the loop has to act on that signal, or ESC just spins.
  run grep -q 'handle_escape "$(read_escape_tail)" || break' "${DIR}/tryout/herdr-panel.sh"
  assert_success
}

@test "the selected row is highlighted with explicit colours" {
  set -eu -o pipefail
  # ESC[7m only swaps whatever the terminal's CURRENT colours are, so on a dark
  # theme the selection came out invisible. An explicit pair cannot be themed away.
  run grep -q '\\033\[7m' "${DIR}/tryout/herdr-panel.sh"
  assert_failure
  # An explicit foreground;background pair, whatever the exact colours are.
  run grep -qE "SEL_ON='.*[0-9]+;[0-9]+m'" "${DIR}/tryout/herdr-panel.sh"
  assert_success

  # And it really reaches the selected row, spanning its full width.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-lonely"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  run env TRYOUT_PANEL_WORKTREE=lonely TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "
    eval \"\$(sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    render
  "
  assert_success
  assert_output --partial $'\033[97;40m'
}

@test "the panel draws with newlines, never screen coordinates" {
  set -eu -o pipefail
  # `ESC[row;colH` addresses the SCREEN, not the pane. In a split those rows land
  # wherever the pane is not, which made the panel unreadable: only the first row
  # showed and the rest went elsewhere. Sequential output needs no coordinates.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-lonely"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  run env TRYOUT_PANEL_WORKTREE=lonely TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "
    eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    render
  "
  assert_success
  # A cursor-position escape is ESC [ <n> ; <n> H — none may appear.
  refute_output --regexp $'\033\[[0-9]+;[0-9]+H'
  # Every command still reaches the screen, one per line.
  assert_output --partial "worktree serve"
  assert_output --partial "worktree use"
}

@test "the panel proves the popup started, since herdr says ok either way" {
  set -eu -o pipefail
  # `plugin pane open` answers {"type":"ok"} whether or not a UI was there to draw
  # into. With none — a session nobody is viewing — herdr accepts the request and
  # drops it, and trusting that ok made Enter look like it did nothing at all.
  local fn
  fn=$(sed -n '/^run_selected()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${fn}" | grep -q 'popup_started' \
    || fail "the panel must confirm the popup actually started"
  # And it must fall through to running inline when it did not.
  printf '%s' "${fn}" | grep -q 'RUNNER' \
    || fail "a popup that never appeared must fall back to running here"

  # The check itself: polls for the process, gives up rather than hanging.
  run bash -c "
    popup_started() {
      local i=0
      while [ \"\${i}\" -lt 5 ]; do
        pgrep -f 'no-such-process-xyzzy' >/dev/null 2>&1 && return 0
        sleep 0.2; i=\$(( i + 1 ))
      done
      return 1
    }
    popup_started && echo started || echo 'gave up'
  "
  assert_output "gave up"
}

@test "the popup opens at the project root, where its relative path resolves" {
  set -eu -o pipefail
  # The manifest runs the popup as `bash .ddev/tryout/herdr-panel-run.sh`, and
  # herdr resolves that relative path against --cwd. A panel lives IN a worktree,
  # which has no .ddev/ beneath it — so passing $PWD there means the popup never
  # starts, while herdr still answers ok. The worktree is carried separately in
  # TRYOUT_PANEL_WORKTREE, so nothing is lost by rooting the popup at the project.
  local fn
  fn=$(sed -n '/^run_selected()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${fn}" | grep -q 'cwd "${APPROOT:-${PWD}}"' \
    || fail "the popup must open at the project root, not the worktree"
  printf '%s' "${fn}" | grep -q 'entrypoint run --cwd "${PWD}"' \
    && fail "--cwd \$PWD is the worktree; the popup cannot start there"

  # And the manifest really is relative, which is why this matters.
  run grep -q 'command = \["bash", ".ddev/tryout/herdr-panel-run.sh"\]' \
    "${DIR}/tryout/herdr-plugin.toml"
  assert_success
}

@test "both ways of docking a panel produce the same pane" {
  set -eu -o pipefail
  # `ddev tryout herdr` and `ddev tryout panel` open the same panel, so it must
  # also LOOK the same: same width, same working directory. They came to differ
  # once — one docked a 38% pane rooted at the worktree, the other a 22% one
  # rooted at the project — and the difference was plainly visible.
  local by_herdr by_panel r1 r2
  by_herdr=$(sed -n '/^ensure_panel_pane()/,/^}/p' "${DIR}/tryout/functions.sh")
  by_panel=$(sed -n '/^open_panel()/,/^}/p' "${DIR}/tryout/herdr-panel-open.sh")

  # The ratio lives in a constant on each side; they must hold the same number.
  r1=$(sed -n 's/^PANEL_DOCK_RATIO="\([0-9.]*\)".*/\1/p' "${DIR}/tryout/functions.sh")
  r2=$(sed -n 's/^DOCK_RATIO="\([0-9.]*\)".*/\1/p' "${DIR}/tryout/herdr-panel-open.sh")
  [ -n "${r1}" ] || fail "functions.sh has no PANEL_DOCK_RATIO"
  [ -n "${r2}" ] || fail "herdr-panel-open.sh has no DOCK_RATIO"
  assert_equal "${r1}" "${r2}"

  # Both must split with that constant rather than a literal.
  printf '%s' "${by_herdr}" | grep -q 'ratio "${PANEL_DOCK_RATIO}"' \
    || fail "ddev tryout herdr does not dock at the shared ratio"
  printf '%s' "${by_panel}" | grep -q 'ratio "${DOCK_RATIO}"' \
    || fail "ddev tryout panel does not dock at the shared ratio"

  # And both root the pane at the project, not a worktree.
  printf '%s' "${by_herdr}" | grep -q 'cwd "${PROJECT_ROOT}"' \
    || fail "ddev tryout herdr must dock the panel at the project root"
}

@test "both ways of docking a panel hand it the same environment" {
  set -eu -o pipefail
  # `ddev tryout herdr` and `ddev tryout panel` open the same panel, so they must
  # tell it the same three things. Without the session its popup asks the DEFAULT
  # server and silently opens nothing — which is how the two paths came to behave
  # differently in the first place.
  local by_herdr by_panel v
  by_herdr=$(sed -n '/^ensure_panel_pane()/,/^}/p' "${DIR}/tryout/functions.sh")
  by_panel=$(sed -n '/^open_panel()/,/^}/p' "${DIR}/tryout/herdr-panel-open.sh")

  for v in TRYOUT_PANEL_APPROOT TRYOUT_PANEL_SESSION TRYOUT_PANEL_WORKTREE; do
    printf '%s' "${by_herdr}" | grep -q "${v}" \
      || fail "ddev tryout herdr does not pass ${v}"
    printf '%s' "${by_panel}" | grep -q "${v}" \
      || fail "ddev tryout panel does not pass ${v}"
  done
}

@test "a panel with no worktree offers no command with an empty argument" {
  set -eu -o pipefail
  # Started by hand outside any worktree, WORKTREE is empty. "worktree serve " with
  # nothing after it is a button that can only fail, so the list falls back to the
  # project-wide verbs instead.
  run env -u TRYOUT_PANEL_WORKTREE -u TRYOUT_PANEL_APPROOT /bin/bash -c "
    cd /tmp
    eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    printf '[%s]\n' \"\${ARGS[@]}\"
  "
  assert_success
  refute_output --partial "worktree serve ]"
  refute_output --partial "worktree use ]"
  refute_output --regexp '\[[a-z ]+ \]'
}

@test "a sibling workspace's popup is not mistaken for this panel's own" {
  set -eu -o pipefail
  # Nothing observable from the panel identifies its own popup: herdr answers ok
  # regardless, the verb travels in the environment (unreadable from outside on
  # macOS), and the popup's parent is the herdr server, not the panel. A pgrep on
  # the script name matches every workspace's popup. So the popup says so itself,
  # by touching a marker unique to this panel and this run.
  local fn
  fn=$(sed -n '/^popup_started()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${fn}" | grep -q 'marker' \
    || fail "popup_started must wait on a marker, not a process name"
  printf '%s' "${fn}" | grep -q 'pgrep' \
    && fail "pgrep cannot tell our popup from a sibling's"

  # The runner must create it, or every popup looks like a failure.
  run grep -q 'TRYOUT_PANEL_STARTED' "${DIR}/tryout/herdr-panel-run.sh"
  assert_success
  # And the panel must pass it.
  run grep -q 'TRYOUT_PANEL_STARTED=' "${DIR}/tryout/herdr-panel.sh"
  assert_success

  # Behaviour: absent marker means not started; one that appears means started.
  run bash -c "
    popup_started() {
      local marker=\"\$1\" i=0
      while [ \"\${i}\" -lt 5 ]; do
        [ -f \"\${marker}\" ] && return 0
        sleep 0.2; i=\$(( i + 1 ))
      done
      return 1
    }
    m=\"\${TMPDIR:-/tmp}/bats-marker.\$\$\"
    rm -f \"\${m}\"
    popup_started \"\${m}\" && echo 'saw a missing marker' || echo 'absent'
    ( sleep 0.3; : > \"\${m}\" ) &
    popup_started \"\${m}\" && echo 'present' || echo 'missed it'
    rm -f \"\${m}\"
  "
  assert_line "absent"
  assert_line "present"
}

@test "nothing the panel runs can block its pane forever" {
  set -eu -o pipefail
  # The inline path runs IN the panel's own pane. An unbounded read there holds
  # that pane until a keystroke that may never come: the panel stops redrawing and
  # the whole workspace looks dead. Every wait must be bounded, and the panel must
  # redraw however the runner ended.
  local fn
  fn=$(sed -n '/^pause()/,/^}/p' "${DIR}/tryout/herdr-panel-run.sh")
  printf '%s' "${fn}" | grep -qE 'read .*-t +[0-9]+' \
    || fail "pause must time out rather than wait forever"

  # And the panel must not abandon its pane if the runner fails or is killed.
  local sel
  sel=$(sed -n '/^run_selected()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${sel}" | grep -q 'RUNNER}" "${verb}" || true' \
    || fail "the panel must redraw however the runner exits"
  printf '%s' "${sel}" | grep -q 'mouse_on' \
    || fail "the panel must restore mouse mode after running inline"
}

@test "status output states its own colour instead of inheriting one" {
  set -eu -o pipefail
  # A herdr popup does not inherit the pane's colours, so text with none of its
  # own — the "Core:" labels and their values — was unreadable there. Stating the
  # colour fixes it for every theme and every background, which repainting the
  # popup could not: herdr has 11 themes and no way to ask which is active.
  local body
  body=$(sed -n '/^ctr_status_body()/,/^}/p' "${DIR}/tryout/commands.sh")

  # Every line the status prints says what colour it is.
  local bare
  bare=$(printf '%s' "${body}" | grep -c 'echo -e "' || true)
  [ "${bare}" -gt 0 ] || fail "no status output found"
  printf '%s' "${body}" | grep 'echo -e "' | grep -v '${TEXT}' \
    && fail "a status line inherits the terminal's colour instead of stating one"

  # The icons return TO that colour rather than resetting to nothing, or the text
  # after them on the same line goes bare again.
  printf '%s' "${body}" | grep -q 'local OK="${GREEN}✓${TEXT}"' \
    || fail "the OK icon must return to the text colour, not reset"

  # And the popup itself repaints nothing: the terminal's own theme decides.
  run grep -qE '033\]1[01];' "${DIR}/tryout/herdr-panel-run.sh"
  assert_failure
}

@test "the popup waits to be read even with no keyboard behind it" {
  set -eu -o pipefail
  # `read || true` returns instantly on EOF, so the window would close before the
  # output could be seen — indistinguishable from the command never running.
  local fn
  fn=$(sed -n '/^pause()/,/^}/p' "${DIR}/tryout/herdr-panel-run.sh")
  printf '%s' "${fn}" | grep -q '\[ -t 0 \]' \
    || fail "pause must check for a terminal before reading"
  printf '%s' "${fn}" | grep -q 'sleep' \
    || fail "with no terminal it must hold the output, not vanish"
}

@test "the panel notices when the primary moves out from under it" {
  set -eu -o pipefail
  # `worktree use X` from a shell or another panel repoints typo3-core. A panel
  # that only computed its state at startup would keep claiming a role it no
  # longer has — and, before the rows named themselves, act on the wrong checkout.
  mkdir -p "${FAKEROOT}/typo3-core-alpha" "${FAKEROOT}/typo3-core-beta" \
           "${FAKEROOT}/sites/alpha" "${FAKEROOT}/sites/beta"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/alpha/.tryout-site"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/beta/.tryout-site"
  ln -s typo3-core-alpha "${FAKEROOT}/typo3-core"

  local draw="
    eval \"\$(sed '/^mouse_on\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
    trap - EXIT INT TERM
    build_menu
    render
    printf '\nSTATE=%s\n' \"\${STATE}\"
  "

  run env TRYOUT_PANEL_WORKTREE=alpha TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "${draw}"
  assert_success
  assert_output --partial "STATE=primary"

  # Move the primary elsewhere; the same panel must now report itself as served.
  rm "${FAKEROOT}/typo3-core"
  ln -s typo3-core-beta "${FAKEROOT}/typo3-core"

  run env TRYOUT_PANEL_WORKTREE=alpha TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "${draw}"
  assert_success
  assert_output --partial "STATE=served"

  # And render is what re-asks, by rebuilding the whole menu: the ROWS have to
  # follow a state change too, not just the header. The popup path is why it must
  # happen here — it returns as soon as the popup starts, so there is no later
  # moment it could rebuild from.
  local fn
  # Comments stripped: this function's own comment explains why it calls
  # build_menu, so a grep over the raw text passes even when the call is gone.
  fn=$(sed -n '/^render()/,/^}/p' "${DIR}/tryout/herdr-panel.sh" | grep -v '^[[:space:]]*#')
  printf '%s' "${fn}" | grep -q 'build_menu' \
    || fail "render must rebuild the menu, or the rows go stale"

  # Behaviour: the rows follow, not only the state line. alpha is served above,
  # so unserving it must drop the rows that need a site.
  local rows
  rows="$(panel_menu alpha "${FAKEROOT}")"
  printf '%s' "${rows}" | grep -q 'ROW reset|' || fail "a served panel offers reset"
  rm "${FAKEROOT}/sites/alpha/.tryout-site"
  rows="$(panel_menu alpha "${FAKEROOT}")"
  printf '%s' "${rows}" | grep -q 'ROW reset|' \
    && fail "reset survived unserving: the rows did not follow the state"
  printf '%s' "${rows}" | grep -q 'ROW worktree serve|' \
    || fail "an unserved panel must offer the way to give it a site"
}

@test "a new worktree gets a branch of its own, tracking the base" {
  set -eu -o pipefail
  # Named after the WORKTREE, not the base: git allows one worktree per branch,
  # so a second checkout off main would fail outright. --track is what records
  # the base — BRANCH reads `branch --show-current`, which returns the worktree's
  # own name here, so without an upstream `origin/<name>` would be looked up and
  # does not exist.
  local fn
  fn=$(sed -n '/^add_core_worktree()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'worktree add -B "${name}" --track' \
    || fail "the branch must be named after the worktree and track its base"
  printf '%s' "${fn}" | grep -q 'attach="${3:-true}"' \
    || fail "a branch is the default now; --detach opts out"
  # Re-using a name would be silently reset by -B, losing what it pointed at.
  printf '%s' "${fn}" | grep -q 'refs/heads/${name}' \
    || fail "an existing branch of that name must be refused, not reset"

  # --detach still reaches the detaching path.
  printf '%s' "${fn}" | grep -q 'worktree add --detach' \
    || fail "--detach must still be possible"
  run grep -q -- '--detach)  attach="false"' "${DIR}/tryout/commands.sh"
  assert_success
}

@test "download updates the worktree it is given, not always the primary" {
  set -eu -o pipefail
  # It took no site at all, so it only ever updated the primary — the one thing
  # you cannot use it for when the work is in a worktree.
  local fn
  fn=$(sed -n '/^ctr_download()/,/^}/p' "${DIR}/tryout/commands.sh")

  printf '%s' "${fn}" | grep -q 'CORE_DIR="$(site_core_dir "${site}")"' \
    || fail "download must resolve the named site's checkout"
  # The base comes from the recorded upstream; the branch name is the worktree's.
  printf '%s' "${fn}" | grep -q 'rev-parse --abbrev-ref' \
    || fail "the base must come from the tracked upstream"
  # Rebase, never merge: Gerrit takes one commit with one Change-Id.
  printf '%s' "${fn}" | grep -q 'pull --rebase' \
    || fail "the update must rebase"
  # A detached checkout has nothing to rebase, and must say so rather than fail
  # obscurely on a branch that is not there.
  printf '%s' "${fn}" | grep -q 'Detached checkout' \
    || fail "a detached worktree must be told why it cannot update"
}

@test "download rebuilds the site it updated, not the primary" {
  set -eu -o pipefail
  # It resolved CORE_DIR for the named worktree but then called the two helpers
  # bare, so both defaulted to the primary: `download jiiha` pulled jiiha's Core
  # and ran composer install against the site whose vendor tree had not moved.
  local fn
  fn=$(sed -n '/^ctr_download()/,/^}/p' "${DIR}/tryout/commands.sh")

  printf '%s' "${fn}" | grep -q 'reset_core_to_main "${site}"' \
    || fail "the reset must drop the cache of the site it reset"
  printf '%s' "${fn}" | grep -q 'rebuild_typo3 "${site}"' \
    || fail "the rebuild must target the site that was updated"
  printf '%s' "${fn}" | grep -qE '^\s*(reset_core_to_main|rebuild_typo3)\s*$' \
    && fail "a bare call here silently rebuilds the primary"

  # Every hint must name the same site, or following it hits the primary's Core.
  printf '%s' "${fn}" | grep -q 'ddev tryout download --reset' \
    && fail "a --reset hint without the site points at the wrong checkout"
  printf '%s' "${fn}" | grep -q 'site_is_primary "${site}" || site_arg=' \
    || fail "the hints need a site suffix built once"
}

@test "reset moves the branch it is on, never checks out the base" {
  set -eu -o pipefail
  # BRANCH is the BASE a worktree tracks, while the worktree carries a branch of
  # its own name. Checking out the base here fails twice over: another worktree
  # already holds it ("'main' is already used by worktree at …"), and creating it
  # fails because the branch exists. `reset --hard` moves whatever is checked
  # out — a branch or a detached HEAD — which is what was wanted all along.
  local fn
  fn=$(sed -n '/^reset_core_to_main()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'reset --hard "origin/${BRANCH}"' \
    || fail "reset must move the current branch to the base tip"
  printf '%s' "${fn}" | grep -qE 'checkout (-b )?"\$\{BRANCH\}"' \
    && fail "reset must not check out the base branch"

  # Behaviour: a branch that is not the base survives the reset and lands on it.
  run bash -c "
    set -euo pipefail
    d=\$(mktemp -d); u=\$(mktemp -d)
    git init -q -b main \"\${u}\"; git -C \"\${u}\" commit -q --allow-empty -m base
    git clone -q \"\${u}\" \"\${d}\" 2>/dev/null
    git -C \"\${d}\" checkout -q -b feature
    git -C \"\${d}\" commit -q --allow-empty -m mine
    git -C \"\${d}\" reset --hard origin/main >/dev/null 2>&1
    echo \"on=\$(git -C \"\${d}\" branch --show-current) at=\$(git -C \"\${d}\" log --oneline -1 --format=%s)\"
    rm -rf \"\${d}\" \"\${u}\"
  "
  assert_success
  assert_output "on=feature at=base"
}

@test "a worktree with no recorded upstream still updates" {
  set -eu -o pipefail
  # `rev-parse --abbrev-ref @{upstream}` EXITS 128 when a branch has no upstream,
  # and the container runs under `set -e` — so reading it without guarding the
  # failure killed the command outright. Every worktree created before tracking
  # was recorded hits this, which is most of them on an existing project.
  local fn
  fn=$(sed -n '/^ctr_download()/,/^}/p' "${DIR}/tryout/commands.sh")
  printf '%s' "${fn}" | grep -q "abbrev-ref '@{upstream}' 2>/dev/null || true" \
    || fail "reading a missing upstream must not abort under set -e"
  # And the prefix strip must not be a pipe: pipefail would resurrect the failure.
  printf '%s' "${fn}" | grep -q 'abbrev-ref.*| *sed' \
    && fail "piping rev-parse reintroduces its exit code under pipefail"

  # Behaviour: a branch with no upstream leaves BRANCH empty and carries on.
  run bash -c "
    set -euo pipefail
    d=\$(mktemp -d)
    git init -q -b feature \"\${d}\" 2>/dev/null
    git -C \"\${d}\" commit -q --allow-empty -m x
    B=\"\$(git -C \"\${d}\" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)\"
    B=\"\${B#origin/}\"
    echo \"reached with BRANCH=[\${B}]\"
    rm -rf \"\${d}\"
  "
  assert_success
  assert_output --partial "reached with BRANCH=[]"
}

@test "worktree_name_for_path names the worktree a path sits in" {
  set -eu -o pipefail
  # `launch` reads the cwd with this, and sync_herdr_workspaces reads a pane's
  # cwd with it. One definition, because the two subtleties below are easy to
  # get wrong twice: /private/var, and how deep a match is allowed to be.
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/typo3-core-jiiha/Build" "${root}/typo3-core-main" "${root}/packages"
  ln -sfn typo3-core-main "${root}/typo3-core"

  run bash -c "
    set -euo pipefail
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    PROJECT_ROOT='${root}'
    plain_core_name() { echo plainclone; }
    p() { printf '%s ' \"\$(worktree_name_for_path \"\$1\" \"\${2:-any}\" || echo none)\"; }
    p '${root}/typo3-core-jiiha'
    p '${root}/typo3-core-jiiha' top
    p '${root}/typo3-core-jiiha/Build'
    p '${root}/typo3-core-jiiha/Build' top
    p '${root}/packages'
    p '${root}'
    p '${root}/typo3-core'
    echo
  "
  assert_success
  # in-worktree | same, top | subdir | subdir rejected by top | not ours | root | via the symlink
  assert_output "jiiha jiiha jiiha none none none main "
  rm -rf "${root}"
}

@test "launch opens the worktree you are standing in" {
  set -eu -o pipefail
  local fn
  fn=$(sed -n '/^cmd_launch()/,/^}/p' "${DIR}/commands/host/tryout")
  [ -n "${fn}" ] || fail "no cmd_launch"

  # The cwd is the whole point: a bare `launch` inside a checkout must not ask.
  printf '%s' "${fn}" | grep -q 'worktree_name_for_path "${PWD}"' \
    || fail "launch must resolve the worktree from the cwd"
  # The active worktree IS the primary, and only the primary knows its own URL
  # (a non-standard port lives in DDEV_PRIMARY_URL, not in the hostname).
  printf '%s' "${fn}" | grep -q 'active_worktree_name' \
    || fail "the active worktree must resolve to the primary site"
  printf '%s' "${fn}" | grep -q 'DDEV_PRIMARY_URL' \
    || fail "the primary URL must come from DDEV, not be rebuilt"
  # An unserved checkout has no URL; opening some other site's would be worse
  # than refusing, so it refuses with the two ways to give it one.
  printf '%s' "${fn}" | grep -q 'is not served' \
    || fail "an unserved worktree must be refused, not silently redirected"
  # And outside a worktree it asks, then falls through to the usage line.
  printf '%s' "${fn}" | grep -q 'ask_site' \
    || fail "launch must ask when the cwd answers nothing"
  printf '%s' "${fn}" | grep -q 'explain_missing' \
    || fail "a cancelled pick must explain instead of failing bare"
}

@test "launch takes the active worktree by name, not just @primary" {
  set -eu -o pipefail
  # The active worktree has no sites/<name>/ marker — it IS the primary — so
  # looking it up by name reads as "not served". The panel passes exactly that
  # (its own worktree name, primary included), and so does anyone typing the
  # name `worktree list` shows them.
  local fn
  fn=$(sed -n '/^cmd_launch()/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s' "${fn}" | grep -q 'active_worktree_name 2>/dev/null.*site="${PRIMARY_SITE}"' \
    || fail "the active worktree's name must resolve to the primary site"

  # The panel names its own worktree for launch, the way it does for reset.
  local menu
  menu=$(sed -n '/^build_menu()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${menu}" | grep -q 'add "launch .*@primary' \
    && fail "the panel must never pass the @primary sentinel"
  printf '%s' "${menu}" | grep -q 'add "launch frontend" .* "launch ${site}"' \
    || fail "the panel must launch its own worktree"
  printf '%s' "${menu}" | grep -q 'add "launch backend" .* "launch ${site} --backend"' \
    || fail "the backend row must add --backend to its own site"
}

@test "launch is host-only and never reaches the container" {
  set -eu -o pipefail
  # There is no browser in the web container, and nothing here needs one — so
  # unlike almost every other verb, launch does its work on the host.
  local fn
  fn=$(sed -n '/^cmd_launch()/,/^}/p' "${DIR}/commands/host/tryout")
  printf '%s' "${fn}" | grep -q 'delegate ' \
    && fail "launch must not delegate: the container has no browser"

  # open_url must not try either, and must still print the URL when it cannot open.
  local ou
  ou=$(sed -n '/^open_url()/,/^}/p' "${DIR}/tryout/functions.sh")
  [ -n "${ou}" ] || fail "no open_url"
  printf '%s' "${ou}" | grep -q 'TRYOUT_IN_CONTAINER' \
    || fail "open_url must not spawn an opener inside the container"
  printf '%s' "${ou}" | grep -q 'xdg-open' \
    || fail "open_url must handle Linux"
  printf '%s' "${ou}" | grep -q 'darwin\*|Darwin' \
    || fail "open_url must handle macOS"

  # No opener is not a failure: the URL is the useful part.
  run bash -c "
    set -euo pipefail
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    TRYOUT_IN_CONTAINER=1 open_url https://example.ddev.site
  "
  assert_success
  assert_output --partial "https://example.ddev.site"
}

@test "worktree add is offered where a worktree comes from, remove where it can go" {
  set -eu -o pipefail
  # They are opposites in scope. Creating a worktree is a project-level act and
  # the popup asks for everything it needs, so it belongs where nothing is scoped.
  # Removing one is about a specific checkout, so it belongs on that checkout's
  # own panel — where it names itself and the popup only has to confirm.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-cold" \
           "${FAKEROOT}/typo3-core-live" "${FAKEROOT}/sites/live"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/live/.tryout-site"

  # No worktree: add, and nothing to remove.
  run panel_menu "" "${FAKEROOT}"
  assert_success
  assert_output --partial "ROW worktree add|worktree add"
  refute_output --partial "ROW worktree remove|"

  # A scoped worktree offers remove, naming itself — and never add.
  local w
  for w in main live cold; do
    run panel_menu "${w}" "${FAKEROOT}"
    assert_success
    assert_output --partial "ROW worktree remove|worktree remove ${w}"
    refute_output --partial "ROW worktree add|"
  done

  # The ORIGIN clone is the exception, both ways round. It owns the shared object
  # store, so remove_core_worktree refuses to drop it — a remove row there could
  # only ever fail, which is the promise this menu exists not to make. And it is
  # the clone every other worktree branches from, so it is where making one
  # belongs. `git worktree add` writes a .git FILE; the origin keeps a directory.
  mkdir -p "${FAKEROOT}/typo3-core-main/.git"
  for w in main live cold; do
    run panel_menu "${w}" "${FAKEROOT}"
    assert_success
    if [ "${w}" = "main" ]; then
      assert_output --partial "ROW worktree add|worktree add"
      refute_output --partial "ROW worktree remove|"
    else
      assert_output --partial "ROW worktree remove|worktree remove ${w}"
      refute_output --partial "ROW worktree add|"
    fi
  done

  # remove never carries the sentinel: cmd_worktree passes its argument through.
  run panel_menu main "${FAKEROOT}"
  assert_success
  refute_output --partial "@primary"

  # It goes through the popup, not the direct path: it prompts before deleting a
  # checkout, and a confirmation cannot happen in a pane with no terminal.
  local menu
  menu=$(sed -n '/^build_menu()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${menu}" | grep -q 'add "worktree remove" .* direct$' \
    && fail "remove must not skip the popup: it has to confirm first"
  printf '%s' "${menu}" | grep -q 'add "worktree add" .* direct$' \
    && fail "add must not skip the popup: it asks for a name and a branch"
  printf '%s' "${menu}" | grep -q 'add "worktree add"' \
    || fail "the off-worktree panel must offer worktree add"
}

@test "the panel shows its branch and applied patches below the rows" {
  set -eu -o pipefail
  command -v git >/dev/null || skip "git not available"
  # Commits on top of the upstream ARE the applied patches — the same measure
  # `ddev tryout status` reports.
  local root="${FAKEROOT}/gitinfo"
  mkdir -p "${root}/sites/live" "${root}/typo3-core-main"
  ln -s typo3-core-main "${root}/typo3-core"
  printf 'php=8.3\n' > "${root}/sites/live/.tryout-site"
  git init -q -b main "${root}/up"
  git -C "${root}/up" commit -q --allow-empty -m base
  git clone -q "${root}/up" "${root}/typo3-core-live" 2>/dev/null

  draw() {
    TRYOUT_PANEL_WORKTREE=live TRYOUT_PANEL_APPROOT="${root}" /bin/bash -c "
      eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
      trap - EXIT INT TERM
      build_menu; refresh_git_info; render >/dev/null; render
    " 2>/dev/null | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'
  }

  # Clean: the branch, and no patch line.
  run draw
  assert_success
  assert_output --partial "main"
  # Not a bare "patch": that is also a menu row. The count line is what must be
  # absent when nothing is applied.
  refute_output --regexp '[0-9]+ patch'

  # One commit on top is one patch, singular.
  git -C "${root}/typo3-core-live" commit -q --allow-empty -m 'a patch'
  run draw
  assert_output --partial "1 patch"
  refute_output --partial "1 patches"

  # Two is plural.
  git -C "${root}/typo3-core-live" commit -q --allow-empty -m 'another'
  run draw
  assert_output --partial "2 patches"

  # A detached checkout says so rather than showing nothing: it has no branch and
  # no upstream, so both reads come back empty and the line would have vanished.
  git -C "${root}/typo3-core-live" checkout -q --detach HEAD
  run draw
  assert_output --partial "detached"
}

@test "the git reads are cached, never run on a keystroke" {
  set -eu -o pipefail
  # render runs on EVERY keystroke, so an arrow key must not pay for git. Working
  # out the base of a DETACHED head is the one that really bites: it means
  # for-each-ref --contains over every remote branch, 0.7s on a real Core.
  local fn rn
  # Comments stripped: this function's own comment names for-each-ref while
  # explaining why it is avoided, and a raw grep cannot tell the two apart.
  fn=$(sed -n '/^refresh_git_info()/,/^}/p' "${DIR}/tryout/herdr-panel.sh" \
       | grep -v '^[[:space:]]*#')
  rn=$(sed -n '/^render()/,/^}/p' "${DIR}/tryout/herdr-panel.sh" | grep -v '^[[:space:]]*#')
  [ -n "${fn}" ] || fail "no refresh_git_info"

  if printf '%s' "${rn}" | grep -q 'refresh_git_info'; then
    fail "render must read the cache, not refill it"
  fi
  if printf '%s' "${rn}" | grep -qE '\bgit '; then
    fail "render must not run git at all"
  fi
  # And the expensive detached lookup is not in the panel to begin with.
  if printf '%s' "${fn}" | grep -q 'for-each-ref'; then
    fail "the detached-base lookup is far too slow for a redraw"
  fi
  # It is refilled where something could have changed it: after a command.
  local sel
  sel=$(sed -n '/^run_selected()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${sel}" | grep -q 'refresh_after_command\|GIT_STALE=1' \
    || fail "a command that ran must refresh the cache"
  # The popup returns on START, so it cannot refresh at return time — it marks the
  # cache stale and the next keystroke picks the answer up.
  printf '%s' "${sel}" | grep -q 'GIT_STALE=1' \
    || fail "the popup path must defer its refresh"
}

@test "nginx gets a server-name hash big enough for the longest hostname" {
  set -eu -o pipefail
  # nginx hashes every server_name into fixed-size buckets and REFUSES TO START
  # when one does not fit:
  #   [emerg] could not build server_names_hash, you should increase
  #           server_names_hash_bucket_size: 64
  # That takes the whole web container down — every site, not just the long one.
  # A 49-character name is what broke it: jochen-super-duper on a project called
  # typo3-worktree-test. Neither name is unreasonable.
  local root="${FAKEROOT}/hash"
  mkdir -p "${root}/.ddev/nginx_full"

  gen() { # hostnames (short form) -> the bucket size written
    helper_eval "
      PROJECT_ROOT='${root}'
      write_server_names_hash $(printf "'%s' " "$@")
      grep -o 'bucket_size [0-9]*' '${root}/.ddev/nginx_full/tryout-server-names-hash.conf' 2>/dev/null
    " 2>/dev/null
  }

  # Short names keep the nginx default; there is no reason to inflate it.
  run gen "benni.small"
  assert_success
  assert_output "bucket_size 64"

  # The name that actually broke it must land above 64.
  run gen "jochen-super-duper.typo3-worktree-test"
  assert_success
  assert_output "bucket_size 128"

  # The longest of the set decides, not the first or the last.
  run gen "a.b" "jochen-super-duper.typo3-worktree-test" "c.d"
  assert_success
  assert_output "bucket_size 128"

  # It is a power of two, as nginx wants.
  local size
  size="$(gen "a-very-long-worktree-name-indeed.and-a-long-project-name-too" \
          | sed 's/bucket_size //')"
  [ -n "${size}" ] || fail "no size for a very long name"
  case "${size}" in
    64|128|256|512|1024) ;;
    *) fail "bucket size ${size} is not a power of two nginx would take" ;;
  esac

  # With nothing served there is no hash to size, and the file goes — otherwise it
  # would outlive the sites it was written for.
  helper_eval "PROJECT_ROOT='${root}'; write_server_names_hash ''" 2>/dev/null
  [ ! -f "${root}/.ddev/nginx_full/tryout-server-names-hash.conf" ] \
    || fail "the hash config must go when nothing is served"
}

@test "the hash config is written wherever the hostnames are, and removed with them" {
  set -eu -o pipefail
  # It has to be regenerated by the same function that collects the hostnames, or
  # serving a worktree with a long name writes a vhost nginx then chokes on.
  local fn
  fn=$(sed -n '/^write_worktree_config()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')
  printf '%s' "${fn}" | grep -q 'write_server_names_hash' \
    || fail "the hash must be resized whenever the served set changes"

  # It lives at http scope, not in a server block: DDEV includes nginx_full/ there
  # — its own nginx-site.conf carries a `map`, which is http-only too.
  local path
  path=$(sed -n '/^site_hash_config_file()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${path}" | grep -q 'nginx_full' \
    || fail "the hash config belongs where DDEV includes http-level config"

  # And uninstalling takes it with the vhosts. The existing glob is tryout-site-*,
  # which does not match this file.
  run grep -q 'tryout-server-names-hash.conf' "${DIR}/install.yaml"
  assert_success
}

@test "unserve is offered only where there is a site to take away" {
  set -eu -o pipefail
  # It is the inverse of serve, and unserve_worktree refuses a site that is not
  # served — so on an unserved checkout the row could only ever fail.
  mkdir -p "${FAKEROOT}/typo3-core-main/.git" "${FAKEROOT}/typo3-core-cold" \
           "${FAKEROOT}/typo3-core-live" "${FAKEROOT}/sites/live"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/live/.tryout-site"

  # The primary and a served worktree both have a site.
  local w
  for w in main live; do
    run panel_menu "${w}" "${FAKEROOT}"
    assert_success
    assert_output --partial "ROW worktree unserve|worktree unserve ${w}"
  done

  # An unserved checkout offers serve instead — there is nothing to take away.
  run panel_menu cold "${FAKEROOT}"
  assert_success
  refute_output --partial "ROW worktree unserve|"
  assert_output --partial "ROW worktree serve|worktree serve cold"
}

@test "a worktree verb reloads the workspaces and wakes the panel that ran it" {
  set -eu -o pipefail
  # `worktree remove` and `unserve` strand a workspace whose checkout is gone, and
  # the popup is the only place that knows when the command actually finished — the
  # panel returns as soon as the popup STARTS. A bare `ddev tryout herdr` is the
  # reconcile pass for exactly that.
  local fn
  fn=$(sed -n '/^case "${rc}:${VERB}" in/,/^esac$/p' "${DIR}/tryout/herdr-panel-run.sh")
  [ -n "${fn}" ] || fail "no post-command reload"

  # Only for worktree verbs: the pass walks every workspace, which is wasted work
  # after a patch or a launch.
  printf '%s' "${fn}" | grep -q 'worktree' \
    || fail "the reload must be scoped to the verbs that change the worktree set"
  # And only on success — a failed command changed nothing.
  printf '%s' "${fn}" | grep -q '0:' \
    || fail "a failed command must not trigger a reload"
  printf '%s' "${fn}" | grep -q 'ddev tryout herdr' \
    || fail "the reload is the reconcile pass"
  # --no-focus, because this is a background reconcile and not the user asking to
  # be taken anywhere. `cmd_herdr` focuses the FIRST worktree alphabetically by
  # default, so without it every panel command threw you out of the space you were
  # working in. herdr moves focus by itself when the focused workspace closes, so
  # the "unless it was removed" case needs nothing here.
  printf '%s' "${fn}" | grep -q 'ddev tryout herdr --no-focus' \
    || fail "the reconcile must not steal focus from the space you are in"

  # It must NOT move the focus. An earlier version jumped to the origin clone on
  # the theory that the popup's own workspace might have just been removed; that
  # yanks the user somewhere they did not ask to go, which is worse than the case
  # it guarded against.
  local run
  run=$(cat "${DIR}/tryout/herdr-panel-run.sh")
  printf '%s' "${run}" | grep -q 'workspace focus' \
    && fail "the popup must leave the focus where the user put it"

  # The panel is woken for ANY success, not only these verbs — serve and unserve
  # change its rows, checkout and patch its branch line — so that lives outside
  # this case block now.
  # The CALL, not the definition — `wake_panel` names itself either way.
  local run
  run=$(cat "${DIR}/tryout/herdr-panel-run.sh" | grep -v '^[[:space:]]*#' \
        | grep -v '^wake_panel()')
  printf '%s' "${run}" | grep -qE '^\s+wake_panel$' \
    || fail "the panel that ran the command must be told to redraw"
}

@test "the popup closes itself on success and stays open on failure" {
  set -eu -o pipefail
  # Clicking a row and then having to dismiss a report of a success is friction —
  # and a popup nobody dismisses BLOCKS the next one: herdr answers `ui_busy: a
  # popup pane is already open`. Verified live, with one stuck on a confirmation
  # prompt for four minutes.
  local run
  run=$(cat "${DIR}/tryout/herdr-panel-run.sh" | grep -v '^[[:space:]]*#')

  # Success: wake the panel, then leave.
  printf '%s' "${run}" | grep -q 'if \[ "${rc}" -eq 0 \]; then'     || fail "success must be handled apart from failure"
  printf '%s' "${run}" | grep -q 'exit 0'     || fail "a successful command must close its own popup"

  # Except where the OUTPUT is the point: status renders a screenful and exec
  # shows whatever was typed. Closing those on success flashes the answer past.
  printf '%s' "${run}" | grep -q 'status\*|exec\*'     || fail "the read-only verbs must keep their output on screen"

  # Failure always holds, with the error and the pause — the popup is the only
  # place it is written.
  printf '%s' "${run}" | grep -q 'exited ${rc}'     || fail "a failure must say so"
  printf '%s' "${run}" | grep -q '^pause$'     || fail "a failure must wait rather than vanish"

  # Behaviour: the branch each rc takes.
  run bash -c '
    rc=0; VERB="worktree serve x"
    if [ "${rc}" -eq 0 ]; then
      case "${VERB}" in status*|exec*) ;; *) echo "CLOSES"; exit 0 ;; esac
    fi
    echo "PAUSES"'
  assert_output "CLOSES"

  run bash -c '
    rc=0; VERB="status"
    if [ "${rc}" -eq 0 ]; then
      case "${VERB}" in status*|exec*) ;; *) echo "CLOSES"; exit 0 ;; esac
    fi
    echo "PAUSES"'
  assert_output "PAUSES"

  run bash -c '
    rc=1; VERB="worktree serve x"
    if [ "${rc}" -eq 0 ]; then
      case "${VERB}" in status*|exec*) ;; *) echo "CLOSES"; exit 0 ;; esac
    fi
    echo "PAUSES"'
  assert_output "PAUSES"
}

@test "the popup wakes its panel with a key the panel ignores" {
  set -eu -o pipefail
  # The panel blocks in `read` with no timeout, so one byte is what makes it
  # redraw — and render rebuilds the whole menu, so one byte is all it needs.
  # But the byte must fall THROUGH the loop's case: q quits, Enter runs the
  # selected row, ESC closes, j/k move the selection. Any of those would do
  # something the user never asked for.
  local fn key
  fn=$(sed -n '/^wake_panel()/,/^}/p' "${DIR}/tryout/herdr-panel-run.sh" \
       | grep -v '^[[:space:]]*#')
  [ -n "${fn}" ] || fail "no wake_panel"

  printf '%s' "${fn}" | grep -q 'pane send-keys' \
    || fail "waking the panel means sending it a key"
  key=$(printf '%s\n' "${fn}" | sed -n 's/.*send-keys[^ ]* "\${TRYOUT_PANEL_PANE}" \([a-z]*\).*/\1/p')
  [ -n "${key}" ] || fail "could not read the key it sends"
  case "${key}" in
    q|j|k|enter|escape|esc) fail "'${key}' is handled by the panel loop and would act" ;;
  esac
  # And that key really is unhandled: the loop's case must not mention it.
  local loop
  loop=$(sed -n '/^while :; do/,/^done$/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${loop}" | grep -qE "^\s+${key}\)" \
    && fail "the panel's case handles '${key}'"

  # No pane means the runner was called positionally, with no panel behind it —
  # and `send-keys` with an empty pane id is an error, not a no-op. Pin the GUARD,
  # not just the variable: it appears in the send-keys line either way.
  printf '%s' "${fn}" | grep -q '\[ -n "\${TRYOUT_PANEL_PANE:-}" \] || return' \
    || fail "wake_panel must no-op when there is no panel to wake"
  # It runs where herdr may not be.
  printf '%s' "${fn}" | grep -q 'command -v herdr' \
    || fail "a missing herdr must be survivable"

  # And the panel actually tells the popup which pane that is. herdr sets
  # HERDR_PANE_ID in every pane it runs, so the panel already knows its own.
  local sel
  sel=$(sed -n '/^run_selected()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${sel}" | grep -q 'TRYOUT_PANEL_PANE=${HERDR_PANE_ID' \
    || fail "the popup must be told which pane to wake"
}

@test "a woken panel repaints its branch line in the same draw" {
  set -eu -o pipefail
  # The git cache is refilled on the keystroke after a popup — including the one
  # the popup sends itself. If that refill happens AFTER render, the repaint shows
  # the old branch and patch count and needs a second key to catch up, which for a
  # key the user did not press means it simply stays wrong.
  local loop refill draw
  loop=$(sed -n '/^while :; do/,/^done$/p' "${DIR}/tryout/herdr-panel.sh" \
         | grep -v '^[[:space:]]*#')
  refill=$(printf '%s\n' "${loop}" | grep -n 'refresh_after_command' | head -1 | cut -d: -f1)
  draw=$(printf '%s\n' "${loop}" | grep -n '^\s*render$' | head -1 | cut -d: -f1)
  [ -n "${refill}" ] || fail "the loop never refills the git cache"
  [ -n "${draw}" ] || fail "the loop never draws"
  [ "${refill}" -lt "${draw}" ] \
    || fail "the refill must precede the draw, or the repaint is one key behind"
}
@test "a worktree made from the panel opens as a workspace" {
  set -eu -o pipefail
  # The panel lives IN herdr, so a worktree created from it that did not appear
  # there is a worktree you then have to go and open by hand. --herdr is what
  # creates the workspace, starts its agent and focuses it.
  local menu
  menu=$(sed -n '/^build_menu()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  local bare
  bare=$(printf '%s\n' "${menu}" | grep -c '"worktree add"$' || true)
  [ "${bare}" -eq 0 ] || fail "${bare} panel row(s) create a worktree without opening it"
  printf '%s' "${menu}" | grep -q 'add "worktree add" .* "worktree add --herdr"' \
    || fail "the panel must pass --herdr so the workspace appears"
}

@test "a workspace whose checkout is gone does not abort the sync" {
  set -eu -o pipefail
  # worktree_name_for_path returns non-zero for a path that is not one of ours —
  # which is exactly what a workspace left behind by `worktree remove` looks like,
  # and precisely what the reconcile loop exists to find. Assigned bare under
  # `set -e` that aborted the whole command with no output at all.
  local fn
  fn=$(sed -n '/^sync_herdr_workspaces()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${fn}" | grep -q 'worktree_name_for_path .* || true' \
    || fail "a path that is not ours must not abort the reconcile pass"

  # Behaviour: the assignment form used here survives a non-zero return.
  run bash -c "
    set -euo pipefail
    f() { return 1; }
    name=\"\$(f 2>/dev/null || true)\"
    echo \"reached with name=[\${name}]\"
  "
  assert_success
  assert_output "reached with name=[]"
}

@test "the origin clone is told apart by its .git, not by its name" {
  set -eu -o pipefail
  # "main" is just the name this project happens to use; another may call the
  # origin clone anything, and `worktree use` can point the primary at any of them.
  # What actually distinguishes it is the object store: `git worktree add` writes a
  # .git FILE pointing back at the main clone, which keeps a real .git DIRECTORY.
  # One filesystem test, so render can re-ask on every draw.
  mkdir -p "${FAKEROOT}/typo3-core-origin/.git" "${FAKEROOT}/typo3-core-derived"
  : > "${FAKEROOT}/typo3-core-derived/.git"
  ln -s typo3-core-derived "${FAKEROOT}/typo3-core"

  probe() { # $1=worktree -> yes/no
    TRYOUT_PANEL_WORKTREE="$1" TRYOUT_PANEL_APPROOT="${FAKEROOT}" /bin/bash -c "
      eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
      trap - EXIT INT TERM
      is_origin_checkout && echo yes || echo no
    " 2>/dev/null
  }

  # The origin clone, even though it is NOT the primary here.
  [ "$(probe origin)" = "yes" ] || fail "a .git directory means the origin clone"
  # The primary, which is an ordinary worktree.
  [ "$(probe derived)" = "no" ] || fail "a .git file means an added worktree"
  # Nothing to test against.
  [ "$(probe gone)" = "no" ] || fail "a checkout that is not there is not the origin"
  [ "$(probe '')" = "no" ] || fail "no worktree is not the origin"
}

@test "the launch rows come last, in frontend then backend order" {
  set -eu -o pipefail
  # They sit at the end deliberately: the rows above act on the checkout, these
  # two only look at it. Anything appended after them would separate the pair.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-live" \
           "${FAKEROOT}/sites/live"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/live/.tryout-site"

  local w out last2
  # Both shapes that have a site: the served worktree and the primary, whose
  # trailing rows differ (worktree use vs composer).
  for w in live main; do
    out="$(panel_menu "${w}" "${FAKEROOT}")"
    [ -n "${out}" ] || fail "no menu for ${w}"
    last2="$(printf '%s\n' "${out}" | grep '^ROW ' | tail -2)"
    printf '%s\n' "${last2}" | head -1 | grep -q '^ROW launch frontend|' \
      || fail "frontend is not second to last for ${w}: ${last2}"
    printf '%s\n' "${last2}" | tail -1 | grep -q '^ROW launch backend|' \
      || fail "backend is not last for ${w}: ${last2}"
  done
}

@test "every panel row carries all four of its fields" {
  set -eu -o pipefail
  # Four parallel arrays and no associative ones, so a row that fell out of step
  # would read another row's arguments — a command run on the wrong worktree,
  # which is the whole class of bug this menu exists to prevent.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-cold" \
           "${FAKEROOT}/typo3-core-live" "${FAKEROOT}/sites/live"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/live/.tryout-site"

  counts() { # $1=worktree — every menu shape, since each builds a different list
    TRYOUT_PANEL_WORKTREE="$1" TRYOUT_PANEL_APPROOT="${FAKEROOT}" \
    /bin/bash -c "
      eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
      trap - EXIT INT TERM
      # TWICE: the inline path rebuilds the menu after every run, and an array
      # the rebuild forgets to reset keeps growing while the others do not.
      build_menu; build_menu
      echo \"\${#LABELS[@]} \${#HINTS[@]} \${#ARGS[@]} \${#DIRECT[@]}\"
    " 2>/dev/null
  }

  local w n
  for w in main live cold ""; do
    n="$(counts "${w}")"
    [ -n "${n}" ] || fail "menu for '${w:-<none>}' produced nothing"
    # All four equal, whatever the length.
    printf '%s\n' "${n}" | grep -qE '^([0-9]+) \1 \1 \1$' \
      || fail "arrays out of step for '${w:-<none>}': ${n}"
  done

  # Equal lengths are not enough: a DIRECT that recorded nothing, or one left
  # stale from an earlier build, keeps every count identical while sending the
  # wrong row down the wrong path. So check the VALUES line up with the labels,
  # and that a second build_menu — which the inline path does run — is clean.
  rows() { # $1=worktree -> "<label> <direct>" per row, twice-built
    TRYOUT_PANEL_WORKTREE="$1" TRYOUT_PANEL_APPROOT="${FAKEROOT}" \
    /bin/bash -c "
      eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
      trap - EXIT INT TERM
      build_menu; build_menu
      i=0; while [ \$i -lt \${#LABELS[@]} ]; do
        printf '%s=%s\n' \"\${LABELS[\$i]}\" \"\${DIRECT[\$i]}\"; i=\$((i+1))
      done
    " 2>/dev/null
  }

  local out
  out="$(rows live)"
  printf '%s\n' "${out}" | grep -qx 'launch frontend=direct' \
    || fail "launch frontend lost its direct tag: ${out}"
  printf '%s\n' "${out}" | grep -qx 'launch backend=direct' \
    || fail "launch backend lost its direct tag: ${out}"
  # And nothing else carries one, so a stale array cannot misroute a slow verb.
  [ "$(printf '%s\n' "${out}" | grep -c '=direct$')" -eq 2 ] \
    || fail "rows other than the two launches are tagged direct: ${out}"
  [ "$(printf '%s\n' "${out}" | grep -c '=$')" -ge 5 ] \
    || fail "rows that should be untagged are not: ${out}"
}

@test "launch runs from the panel without a popup, and a failure is still seen" {
  set -eu -o pipefail
  local fn rd
  fn=$(sed -n '/^run_selected()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")

  # The direct branch must come BEFORE the marker file is minted, or every Enter
  # on such a row leaves one in TMPDIR that nothing ever collects.
  local d_line m_line
  d_line=$(printf '%s\n' "${fn}" | grep -n 'DIRECT\[' | head -1 | cut -d: -f1)
  m_line=$(printf '%s\n' "${fn}" | grep -n 'local marker=' | head -1 | cut -d: -f1)
  [ -n "${d_line}" ] || fail "run_selected never consults DIRECT"
  [ -n "${m_line}" ] || fail "no marker line to order against"
  [ "${d_line}" -lt "${m_line}" ] || fail "the direct branch must precede the marker"

  rd=$(sed -n '/^run_direct()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  [ -n "${rd}" ] || fail "no run_direct"
  # Success is silent — the pane is a narrow strip and the browser already said
  # it — but stderr is kept, or a failed launch is indistinguishable from a
  # successful one. The order is the whole trick; see the behavioural test below.
  printf '%s' "${rd}" | grep -q '2>&1 >/dev/null' \
    || fail "run_direct must keep stderr and drop stdout, in that order"
  # It must not take the pane over: no clear, no mouse handover. That dance is
  # the inline fallback's, and copying it would restore what this removes.
  printf '%s' "${rd}" | grep -q '2J' \
    && fail "the direct path must never clear the pane"
  printf '%s' "${rd}" | grep -q 'mouse_off' \
    && fail "the direct path must not hand the terminal over"
  # A bad approot must not read as success: `cd … && cmd` short-circuits to rc 0
  # with no output, which would make every run quietly do nothing.
  printf '%s' "${rd}" | grep -q 'if \[ ! -d "${root}" \]' \
    || fail "run_direct must fail a missing project instead of short-circuiting"
  # And the message reaches the user through render, not a printf the next draw
  # would wipe before it could be read.
  printf '%s' "${rd}" | grep -q 'NOTICE="\$(printf' \
    || fail "run_direct must report the captured error through NOTICE"
  local rn
  rn=$(sed -n '/^render()/,/^}/p' "${DIR}/tryout/herdr-panel.sh")
  printf '%s' "${rn}" | grep -q 'NOTICE=""' \
    || fail "render must clear the notice, so it shows exactly once"
}

@test "the panel's direct path swallows success output and keeps the error" {
  set -eu -o pipefail
  # `2>&1 >/dev/null` is the classic thing to write backwards, and reversed it
  # drops both streams — a silent-failure bug no grep of the source would catch.
  # So run the REAL run_direct against a stub ddev, rather than a copy of its
  # redirection, which would pass however the shipped one is written.
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  drive() { # $1=stub body -> "NOTICE=[…]"
    TRYOUT_PANEL_WORKTREE=main TRYOUT_PANEL_APPROOT="${FAKEROOT}" \
    /bin/bash -c "
      eval \"\$(sed '/^build_menu\$/,\$d' '${DIR}/tryout/herdr-panel.sh')\"
      trap - EXIT INT TERM
      ddev() { $1 }
      NOTICE=''
      run_direct 'launch main'
      echo \"NOTICE=[\${NOTICE}]\"
    " 2>/dev/null
  }

  # Success says nothing: the browser coming forward is the report.
  run drive "echo 'Opened https://x.ddev.site'; return 0;"
  assert_success
  assert_output "NOTICE=[]"

  # Failure keeps stderr, drops the stdout noise, and shows the first real line.
  run drive "echo 'stdout noise'; echo '' >&2; echo \"No served site 'x'\" >&2; return 1;"
  assert_success
  assert_output "NOTICE=[No served site 'x']"
  refute_output --partial "stdout noise"

  # And a long error is cut to what the strip can hold, rather than wrapping over
  # the menu it is reporting about.
  run drive "echo \"Worktree 'x' is not served — it has no URL and cannot be opened\" >&2; return 1;"
  assert_success
  local n
  n="${output#NOTICE=[}"; n="${n%]}"
  [ "${#n}" -le 24 ] || fail "notice is ${#n} chars; the pane is a ~25-column strip"
  [ "${#n}" -gt 0 ]  || fail "a long error must still say something"
}

@test "the panel offers download where there is a site to update" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-lonely" \
           "${FAKEROOT}/typo3-core-live" "${FAKEROOT}/sites/live"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/live/.tryout-site"

  run panel_menu live "${FAKEROOT}"
  assert_success
  assert_output --partial "download|download live"

  # The primary names itself too — never the sentinel, which reset would choke on.
  run panel_menu main "${FAKEROOT}"
  assert_success
  assert_output --partial "download|download main"

  # A bare checkout has no site, so there is nothing to update.
  run panel_menu lonely "${FAKEROOT}"
  assert_success
  refute_output --partial "ROW download|"
}

@test "exec is offered only where there is a site to run in" {
  set -eu -o pipefail
  # cmd_exec REJECTS a site that is neither primary nor served, so offering it on
  # a bare checkout would be a row that can only error. It also takes the site
  # positionally, which is why the primary gets the @primary sentinel rather than
  # an empty string — empty would shift the command into the site's place.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-lonely" \
           "${FAKEROOT}/typo3-core-live" "${FAKEROOT}/sites/live"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/live/.tryout-site"

  # Served: its own name.
  run panel_menu live "${FAKEROOT}"
  assert_success
  assert_output --partial "exec|exec live"

  # Primary: its own name, not the sentinel. A bare or sentinel site follows the
  # typo3-core symlink at run time, which is how a panel came to switch whichever
  # worktree happened to be primary rather than its own.
  run panel_menu main "${FAKEROOT}"
  assert_success
  assert_output --partial "exec|exec main"
  refute_output --partial "@primary"

  # Bare checkout: not offered at all.
  run panel_menu lonely "${FAKEROOT}"
  assert_success
  refute_output --partial "ROW exec|"
}

@test "an unserved worktree is offered no command that needs a site" {
  set -eu -o pipefail
  # Most worktrees are just checkouts. checkout/reset/patch need a site, so on
  # one of those they would fail — or worse, silently act on the primary.
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-lonely"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  run panel_menu lonely "${FAKEROOT}"
  assert_success
  assert_line "STATE=unserved"
  # The two ways to give it a site are exactly what it offers instead.
  assert_output --partial "worktree serve|worktree serve lonely"
  assert_output --partial "worktree use|worktree use lonely"
  refute_output --partial "ROW checkout|"
  refute_output --partial "ROW reset|"
  refute_output --partial "ROW patch|"
}

@test "a served worktree carries its own site, so nothing asks which one" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/typo3-core-benni" \
           "${FAKEROOT}/sites/benni"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  printf 'php=8.3\n' > "${FAKEROOT}/sites/benni/.tryout-site"

  run panel_menu benni "${FAKEROOT}"
  assert_success
  assert_line "STATE=served"
  # Every site-scoped verb names the site, which is what suppresses the prompt.
  assert_output --partial "reset|reset benni"
  assert_output --partial "patch|patch --site benni"
  # checkout takes --site, because the branch has to come first positionally.
  assert_output --partial "checkout|checkout --site benni"
}

@test "each verb gets the site form it actually accepts" {
  set -eu -o pipefail
  # cmd_reset hands its argument straight to the container, and unlike cmd_patch
  # and cmd_delete it does NOT blank "@primary" first — the container's parser
  # would reject it.
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"

  run panel_menu main "${FAKEROOT}"
  assert_success
  assert_line "STATE=primary"
  # Every scoped row names THIS worktree, the primary included: a siteless command
  # resolves through the typo3-core symlink when it runs, so it would switch
  # whichever worktree is primary at that moment rather than this one.
  assert_output --partial "checkout|checkout --site main"
  assert_output --partial "reset|reset main"
  assert_output --partial "exec|exec main"
  # reset passes its argument straight through without blanking the sentinel, so
  # that literal must never reach it — a real name is what it wants.
  refute_output --partial "@primary"
}

@test "the overlay requires exactly the sysexts on disk, nothing by branch name" {
  set -eu -o pipefail
  # typo3/theme-camino used to be appended whenever the branch looked like main or
  # v14+. On 13.4 there is no typo3/sysext/theme_camino, so the entry pointed a
  # path repository at a directory that does not exist:
  #   Source path "…/typo3-core-main/typo3/sysext/theme_camino" is not found
  # which fails composer install and with it the whole checkout. A detached
  # worktree made it worse: the fallback read EXT:core's branch-alias, got "main",
  # and added camino to a 13.4 tree. The sysexts present decide, and nothing else.
  command -v php >/dev/null || skip "php not available"

  # A fake Core: two sysexts, no theme_camino — a 13.4-shaped tree.
  local core="${FAKEROOT}/core13" proj="${FAKEROOT}/proj13"
  mkdir -p "${core}/typo3/sysext/core" "${core}/typo3/sysext/backend" "${proj}"
  printf '{"name":"typo3/cms-core","extra":{"branch-alias":{"dev-main":"13.4.x-dev"}}}\n' \
    > "${core}/typo3/sysext/core/composer.json"
  printf '{"name":"typo3/cms-backend"}\n' > "${core}/typo3/sysext/backend/composer.json"
  printf '{"name":"x/y","require":{"typo3/theme-camino":"@dev","acme/own":"^1.0"}}\n' \
    > "${proj}/composer.tryout.json"

  run env PROJECT_ROOT="${proj}" TRYOUT_CORE_DIR="${core}" \
      php "${DIR}/tryout/sync-composer.php"
  assert_success

  local req
  req=$(python3 -c "
import json; print(' '.join(sorted(json.load(open('${proj}/composer.tryout.json'))['require'])))")
  # Not required, because it is not there.
  printf '%s' "${req}" | grep -q 'typo3/theme-camino' \
    && fail "camino required on a tree that has no theme_camino: ${req}"
  # The sysexts that ARE there, and the user's own package, all survive.
  printf '%s' "${req}" | grep -q 'typo3/cms-core' || fail "cms-core missing: ${req}"
  printf '%s' "${req}" | grep -q 'typo3/cms-backend' || fail "cms-backend missing: ${req}"
  printf '%s' "${req}" | grep -q 'acme/own' || fail "custom package dropped: ${req}"

  # And where the sysext IS present, the ordinary scan picks it up — so main keeps
  # camino without anything special-casing it.
  local core14="${FAKEROOT}/core14" proj14="${FAKEROOT}/proj14"
  mkdir -p "${core14}/typo3/sysext/core" "${core14}/typo3/sysext/theme_camino" "${proj14}"
  printf '{"name":"typo3/cms-core"}\n' > "${core14}/typo3/sysext/core/composer.json"
  printf '{"name":"typo3/theme-camino"}\n' > "${core14}/typo3/sysext/theme_camino/composer.json"
  printf '{"name":"x/y","require":{}}\n' > "${proj14}/composer.tryout.json"

  run env PROJECT_ROOT="${proj14}" TRYOUT_CORE_DIR="${core14}" \
      php "${DIR}/tryout/sync-composer.php"
  assert_success
  run python3 -c "
import json; print('typo3/theme-camino' in json.load(open('${proj14}/composer.tryout.json'))['require'])"
  assert_output "True"
}

@test "the agent's tab is found by position, not by its label" {
  set -eu -o pipefail
  # ensure_first_tab_label names it "Claude" when an agent is running and "Shell"
  # when none is, and a user can rename it again — so keying on any label would
  # lose the panel's home the moment one of those happened.
  fake_herdr_tabs '{"result":{"tabs":[
    {"tab_id":"w1:t1","label":"Claude"},
    {"tab_id":"w1:t2","label":"Terminal"}]}}'
  run_with_fake_herdr 'herdr_agent_tab_id w1'
  assert_success
  assert_output "w1:t1"

  # Same answer with no agent, where the first tab is called Shell...
  fake_herdr_tabs '{"result":{"tabs":[
    {"tab_id":"w1:t1","label":"Shell"},
    {"tab_id":"w1:t2","label":"Terminal"}]}}'
  run_with_fake_herdr 'herdr_agent_tab_id w1'
  assert_success
  assert_output "w1:t1"

  # ...and with a name nobody predicted.
  fake_herdr_tabs '{"result":{"tabs":[
    {"tab_id":"w1:t1","label":"my notes"},
    {"tab_id":"w1:t2","label":"Terminal"}]}}'
  run_with_fake_herdr 'herdr_agent_tab_id w1'
  assert_success
  assert_output "w1:t1"

  # A workspace with no tabs answers nothing rather than a bogus id.
  fake_herdr_tabs '{"result":{"tabs":[]}}'
  run_with_fake_herdr 'herdr_agent_tab_id w1'
  assert_success
  assert_output ""
}

@test "an already-open workspace still gets its tab and panel" {
  set -eu -o pipefail
  # Open is not the same as complete. A workspace opened by hand, or before the
  # Terminal tab and the panel existed, is missing whatever came later — and the
  # early return for "already open" is what kept it that way: `ddev tryout herdr
  # <name>` skips the reconcile pass, so nothing else ever reached it. That is
  # how typo3-core-main ended up as the one workspace with no tryout panel.
  local fn
  fn=$(sed -n '/^open_worktree_in_herdr()/,/^}/p' "${DIR}/tryout/functions.sh")

  # The skip branch, from "is open" to its return, must do the backfill.
  local skip
  # Comments stripped: they name these helpers while explaining them, so a grep
  # over the raw text passes even when the call itself is gone.
  skip=$(printf '%s\n' "${fn}" | sed -n '/herdr_worktree_is_open/,/^    fi$/p' \
         | grep -v '^[[:space:]]*#')
  [ -n "${skip}" ] || fail "no already-open branch"
  printf '%s' "${skip}" | grep -q 'ensure_panel_pane' \
    || fail "an open workspace must still get the panel"
  printf '%s' "${skip}" | grep -q 'ensure_terminal_tab' \
    || fail "an open workspace must still get its Terminal tab"
  # Each is a no-op when already present, so this is safe to run every time —
  # but it must not abort the run when one fails, since other worktrees follow.
  printf '%s' "${skip}" | grep -q 'ensure_panel_pane .* || true' \
    || fail "a backfill failure must not end the run"
  # It must find the workspace by DIRECTORY, not by label. A workspace old enough
  # to be missing the tab and the panel is old enough to be missing the
  # core-<name> label too, so looking it up by that label found nothing and the
  # whole branch did nothing — which is exactly how typo3-core-main stayed broken
  # through a fix that was supposed to repair it.
  printf '%s' "${skip}" | grep -q 'herdr_workspace_id_for_dir' \
    || fail "the backfill must find the workspace by directory, not by label"
  printf '%s' "${skip}" | grep -qE 'herdr_workspace_id "' \
    && fail "a label lookup cannot find a workspace whose label is the problem"
  # And it adopts the label, so everything keyed on it finds the workspace after.
  printf '%s' "${skip}" | grep -q 'workspace rename' \
    || fail "the backfill must adopt the core-<name> label"
  # An agent too, when the workspace has none and one was asked for.
  printf '%s' "${skip}" | grep -q 'start_agent_in_pane' \
    || fail "a workspace with no agent must get one"
  printf '%s' "${skip}" | grep -q 'use_agent' \
    || fail "--no-agent must still be honoured on the backfill"
  printf '%s' "${skip}" | grep -q 'herdr_workspace_has_agent' \
    || fail "an agent already running must not be restarted"
}

@test "the backfill starts its agent in the worktree, not in the panel" {
  set -eu -o pipefail
  # The panel pane sits in the PROJECT ROOT, not the worktree — that is deliberate,
  # so its popup's relative path resolves. Starting claude there would run it in
  # the wrong directory, so the pane is chosen by cwd and the panel excluded by
  # label. Both conditions matter: cwd alone still matches nothing useful if the
  # panel ever moved, and label alone would match the Terminal pane.
  local fn
  fn=$(sed -n '/^herdr_workspace_agent_pane()/,/^}/p' "${DIR}/tryout/functions.sh")
  [ -n "${fn}" ] || fail "no herdr_workspace_agent_pane"
  printf '%s' "${fn}" | grep -q '.cwd == \$d' \
    || fail "the agent pane must be the one sitting in the worktree"
  printf '%s' "${fn}" | grep -q '(.label // "") != \$l' \
    || fail "the panel must be excluded: it lives in the project root"
}

@test "worktree add takes its name from the loop, never from a flag" {
  set -eu -o pipefail
  # The panel runs `worktree add --herdr`. Reading $1 as the name BEFORE stripping
  # flags made the name the literal string "--herdr" — non-empty, so the prompt
  # below never fired, and it was delegated as the worktree name. Verified live:
  # the container received `worktree add --herdr 13.4` and git failed on it.
  local body
  body=$(sed -n '/^cmd_worktree()/,/^}/p' "${DIR}/commands/host/tryout" \
         | sed -n '/^        add)/,/^            ;;/p' | grep -v '^[[:space:]]*#')
  [ -n "${body}" ] || fail "no worktree add branch"

  printf '%s' "${body}" | grep -q 'local name="${1:-}"' \
    && fail "the name must not be read before the flags are stripped"
  printf '%s' "${body}" | grep -q 'if \[ -z "${name}" \]; then name="$1"' \
    || fail "the first non-flag word is the name, the second the branch"
  # An unknown flag is an error, not a worktree called "-x".
  printf '%s' "${body}" | grep -q -- '-\*)' \
    || fail "unknown flags must be rejected"
  # And the prompt is still reachable for a bare invocation.
  printf '%s' "${body}" | grep -q 'ask_text' \
    || fail "a missing name must still be asked for"
}

@test "a worktree name can never start with a hyphen" {
  set -eu -o pipefail
  # It becomes a directory, a git branch and a herdr label — none of which take a
  # leading hyphen — and it is exactly what a mis-parsed flag looks like. The old
  # regex ^[A-Za-z0-9._-]+$ accepted "--herdr" quite happily.
  local n
  for n in --herdr -x - --serve; do
    run helper_eval "validate_worktree_name '${n}'"
    assert_failure
  done
  # Real names still pass.
  for n in bugfix-12345 v13.4 main my_tree a; do
    run helper_eval "validate_worktree_name '${n}'"
    assert_success
  done
}

@test "re-serving a worktree keeps the database it still has" {
  set -eu -o pipefail
  # unserve deletes the site but KEEPS the database unless --drop-db was asked
  # for, and the only "already set up" signal was settings.php — which went with
  # the site. So serve ran a fresh `typo3 setup` against a populated database and
  # TYPO3 refused: "The selected database contains already 146 tables." --force
  # does not help; the table check happens first, at database selection.
  local fn un
  fn=$(sed -n '/^setup_site_typo3()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')
  un=$(sed -n '/^unserve_worktree()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')

  # The database is the second signal, since it can outlive the site.
  printf '%s' "${fn}" | grep -q 'site_database_has_tables' \
    || fail "a populated database means the site is already set up"
  # And the saved settings go back, rather than the setup running.
  printf '%s' "${fn}" | grep -q 'site_saved_settings' \
    || fail "the preserved settings.php must be restored"

  # unserve preserves it only when the database survives — dropping the database
  # makes the old settings meaningless.
  printf '%s' "${un}" | grep -q 'site_saved_settings' \
    || fail "unserve must preserve settings.php"
  printf '%s' "${un}" | grep -q 'keep_db.*= "true"' \
    || fail "preserve only when the database is kept"

  # It is kept OUTSIDE the site dir, which unserve rm -rf's.
  local path
  path=$(sed -n '/^site_saved_settings()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${path}" | grep -q 'SITES_DIR}/\.' \
    || fail "the saved copy must not live inside the directory unserve deletes"

  # Behaviour: the table count is read from the site's OWN database.
  local q
  q=$(sed -n '/^site_database_has_tables()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${q}" | grep -q 'site_database' \
    || fail "the count must be for this site's database"
  printf '%s' "${q}" | grep -q 'db_is_postgres' \
    || fail "postgres counts its tables differently"
}

@test "every workspace reports its own branch to the sidebar" {
  set -eu -o pipefail
  # herdr's own `branch` row is computed from the workspace's repo_root, which for
  # a linked worktree points at the ORIGIN CLONE — so it rendered only for the one
  # checkout owning the repo, and that value is not on the API's worktree struct to
  # correct. A custom token is the way in.
  local fn
  fn=$(sed -n '/^set_workspace_branch_token()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')
  [ -n "${fn}" ] || fail "no set_workspace_branch_token"

  printf '%s' "${fn}" | grep -q 'workspace report-metadata' \
    || fail "the token is reported through report-metadata"
  printf '%s' "${fn}" | grep -q 'wt_branch=' \
    || fail "a CUSTOM token: --token branch= does not feed herdr's built-in row"
  # The branch comes from the worktree, not from wherever the command runs.
  printf '%s' "${fn}" | grep -q 'core_worktree_dir' \
    || fail "the branch must be read from that worktree's checkout"
  # An empty token makes the row vanish, and half a project's worktrees are
  # typically detached — so they say so instead.
  printf '%s' "${fn}" | grep -q 'b="detached"' \
    || fail "a detached checkout must still report something"

  # Set wherever the add-on already knows both the workspace and the worktree.
  local callers
  callers=$(grep -c 'set_workspace_branch_token "' "${DIR}/tryout/functions.sh" || true)
  [ "${callers}" -ge 3 ] \
    || fail "expected it on every open and reconcile path, found ${callers}"

  # And refreshed after the verbs that move a branch.
  local run
  # Comments stripped and the PATTERN pinned: "checkout" also appears in the
  # comment explaining why it is there, so a bare grep passes without the arm.
  run=$(sed -n '/^case "${rc}:${VERB}" in/,/^esac$/p' "${DIR}/tryout/herdr-panel-run.sh" \
        | grep -v '^[[:space:]]*#')
  printf '%s' "${run}" | grep -q '0:checkout' \
    || fail "checkout moves the branch, so it must refresh too"
}

@test "nothing pays for a dirty check it does not print" {
  set -eu -o pipefail
  # list_core_worktrees runs two `git diff` calls per worktree. A TYPO3 Core
  # checkout is ~20k tracked files, so on a Mutagen project that is ~3.8s per
  # worktree cold — 24s over eight, and the whole of the "reloading workspaces…"
  # pause after a panel command. The reconcile threw the answer away with
  # `cut -f1`; status read it into a variable and never printed it.
  local herdr_fn status_fn
  herdr_fn=$(sed -n '/^cmd_herdr()/,/^}/p' "${DIR}/commands/host/tryout" \
             | grep -v '^[[:space:]]*#')
  status_fn=$(sed -n '/^ctr_status_body()/,/^}/p' "${DIR}/tryout/commands.sh" \
              | grep -v '^[[:space:]]*#')

  # The reconcile wants names, so it asks for names.
  printf '%s' "${herdr_fn}" | grep -q 'list_core_worktrees' \
    && fail "the reconcile must not run a dirty check for names it discards"
  printf '%s' "${herdr_fn}" | grep -q 'core_worktree_names' \
    || fail "the reconcile must use the cheap helper"

  # status prints name, branch and head — never the dirty flag.
  printf '%s' "${status_fn}" | grep -qE '\blist_core_worktrees\b' \
    && fail "status must not pay for a column it does not show"
  printf '%s' "${status_fn}" | grep -q 'list_core_worktrees_fast' \
    || fail "status must use the cheap lister"

  # And it asks once: the count and the loop want the same rows.
  local calls
  calls=$(printf '%s\n' "${status_fn}" | grep -c 'list_core_worktrees_fast' || true)
  [ "${calls}" -eq 1 ] \
    || fail "status calls its lister ${calls} times; once is enough"
}

@test "worktree list keeps the STATE column it is asked for" {
  set -eu -o pipefail
  # It is the one caller that PRINTS dirtiness, it is run by hand, and --plain is
  # a documented contract (NAME HEAD BRANCH STATE PHP DB URL) that
  # tests/e2e/login.spec.ts parses. It keeps the expensive lister.
  local fn
  fn=$(sed -n '/^ctr_worktree()/,/^}/p' "${DIR}/tryout/commands.sh" \
       | grep -v '^[[:space:]]*#')
  printf '%s' "${fn}" | grep -qE '\blist_core_worktrees\b' \
    || fail "worktree list needs the dirty column"
  # The PRINTED field, not just the name: `${dirty}` also appears in the `read`
  # that unpacks the row, so a grep for it passes even when the column is gone.
  printf '%s' "${fn}" | grep -qE 'printf.*\$\{dirty\}|"\$\{branch\}" "\$\{dirty\}"' \
    || fail "the STATE column must still be printed"
}

@test "the two worktree listers agree on their shared fields" {
  set -eu -o pipefail
  # Same rows, one column fewer — so a caller reading positionally cannot have a
  # field shift under it. Both must resolve the active worktree the same way too,
  # since both mark it in the last field.
  command -v git >/dev/null || skip "git not available"
  local root="${FAKEROOT}/listers"
  mkdir -p "${root}"
  local w
  for w in alpha beta; do
    git init -q -b "br-${w}" "${root}/typo3-core-${w}"
    git -C "${root}/typo3-core-${w}" commit -q --allow-empty -m x
  done
  ln -s typo3-core-alpha "${root}/typo3-core"

  emit() { # $1=function
    helper_eval "
      PROJECT_ROOT='${root}'
      CORE_DIR='${root}/typo3-core'
      CORE_WORKTREE_PREFIX='${root}/typo3-core-'
      $1
    " 2>/dev/null
  }

  local slow fast
  slow="$(emit list_core_worktrees)"
  fast="$(emit list_core_worktrees_fast)"
  [ -n "${slow}" ] || fail "no rows from list_core_worktrees"
  [ -n "${fast}" ] || fail "no rows from list_core_worktrees_fast"

  # Same worktrees, same order.
  [ "$(printf '%s\n' "${slow}" | cut -f1)" = "$(printf '%s\n' "${fast}" | cut -f1)" ] \
    || fail "the two listers disagree on which worktrees exist"
  # name, head, branch identical; the fast one simply stops there.
  [ "$(printf '%s\n' "${slow}" | cut -f1,2,3)" = "$(printf '%s\n' "${fast}" | cut -f1,2,3)" ] \
    || fail "the shared fields must match"
  # The active marker is the LAST field in both — 5th vs 4th.
  [ "$(printf '%s\n' "${slow}" | cut -f5)" = "$(printf '%s\n' "${fast}" | cut -f4)" ] \
    || fail "both must mark the active worktree in their last field"
}

@test "a pane labelled tryout counts as a panel only if it runs one" {
  set -eu -o pipefail
  # `pane process-info` answers for ANY live pane, a bare shell included, so it can
  # only spot a pane whose process is GONE — never one running the wrong thing.
  # Closing a panel with q or esc drops it back to its shell and leaves the label,
  # and that read as healthy: seven of eight panels sat like that while every
  # `ddev tryout herdr` reported success and every test in this file passed.
  # The terminal title carries the running command, which is what tells them apart.
  fake_herdr_tabs '{"result":{"tabs":[]}}' '{"result":{"panes":[
    {"pane_id":"w1:p3","label":"tryout",
     "terminal_title":"bash /p/.ddev/tryout/herdr-panel.sh"},
    {"pane_id":"w2:p3","label":"tryout",
     "terminal_title":"jochen@laptop"},
    {"pane_id":"w3:p3","label":"tryout"}]}}'

  run_with_fake_herdr 'panel_pane_is_running w1:p3 && echo yes || echo no'
  assert_success
  assert_output "yes"

  # A shell wearing the label is NOT a panel — the whole point.
  run_with_fake_herdr 'panel_pane_is_running w2:p3 && echo yes || echo no'
  assert_success
  assert_output "no"

  # No title at all is not a panel either, and must not error.
  run_with_fake_herdr 'panel_pane_is_running w3:p3 && echo yes || echo no'
  assert_success
  assert_output "no"

  # Neither is a pane that is not there.
  run_with_fake_herdr 'panel_pane_is_running gone:p9 && echo yes || echo no'
  assert_success
  assert_output "no"
}

@test "both panel routes agree on what alive means" {
  set -eu -o pipefail
  # ensure_panel_pane decides whether to replace a panel; herdr-panel-open.sh
  # decides whether one is already open and only needs focusing. With the weak
  # test, the second focused a bare shell instead of docking a panel.
  local fn open
  fn=$(sed -n '/^ensure_panel_pane()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')
  open=$(sed -n '/^pane_is_alive()/,/^}/p' "${DIR}/tryout/herdr-panel-open.sh" \
         | grep -v '^[[:space:]]*#')

  printf '%s' "${fn}" | grep -q 'panel_pane_is_running' \
    || fail "ensure_panel_pane must check the pane runs the panel"
  printf '%s' "${open}" | grep -q 'herdr-panel' \
    || fail "the toggle must check the same thing"

  # Neither may fall back to "any live process".
  local f
  for f in tryout/functions.sh tryout/herdr-panel-open.sh; do
    run grep -n 'result != null' "${DIR}/${f}"
    assert_failure
  done
}

@test "the panel script is retried until it is actually running" {
  set -eu -o pipefail
  # `pane run` types into the pane's shell, and `pane split` answers before that
  # shell has reached its prompt — so a first attempt can be typed into nothing.
  # herdr answering ok proves only that it delivered the keystrokes. This is the
  # same race start_agent_in_pane already retries for, and it is how panes end up
  # labelled but bare.
  local fn
  fn=$(sed -n '/^ensure_panel_pane()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')

  printf '%s' "${fn}" | grep -q 'pane run' \
    || fail "the panel has to be started somehow"
  # Fired once and forgotten is what left the panes bare.
  printf '%s' "${fn}" | grep -q 'pane run .* || return 1' \
    && fail "one attempt is not enough: the keystrokes can be lost"
  # It must confirm, not assume.
  printf '%s' "${fn}" | grep -q 'panel_pane_is_running "${new}"' \
    || fail "the start must be confirmed before it is believed"
  # And give up rather than spin forever: a panel that never starts must not hang
  # `ddev tryout herdr` for the worktrees queued behind it. Pin the BOUND, not the
  # word "attempt", which survives in the increment.
  printf '%s' "${fn}" | grep -qE '\[ "\$\{attempt\}" -ge [0-9]+ \] && break' \
    || fail "the retry must be bounded"
}

@test "the panel pane is docked once, beside the agent" {
  set -eu -o pipefail
  # It sits next to the agent, not in the Terminal tab: the panel drives the
  # worktree the agent is working in, so it belongs where you are looking. Keyed
  # on the FIRST tab rather than its label, which ensure_first_tab_label sets to
  # "Claude" or "Shell" and a user may change again.
  local fn
  fn=$(sed -n '/^ensure_panel_pane()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${fn}" | grep -q 'herdr_agent_tab_id' \
    || fail "the panel must dock beside the agent"
  printf '%s' "${fn}" | grep -q 'herdr_terminal_tab_id' \
    && fail "the panel no longer docks into the Terminal tab"
  # The split target is the agent's pane, never a panel already sitting there —
  # splitting that would nest one panel inside another.
  printf '%s' "${fn}" | grep -q '(.label // "") != \$l' \
    || fail "the split target must exclude the panel itself"
  # An existing panel is MOVED, not closed and redocked: closing kills a running
  # panel, and every workspace opened before this has one in the Terminal tab.
  printf '%s' "${fn}" | grep -q 'pane move' \
    || fail "a panel in the old place must be moved, not recreated"
  # Both ways of placing it leave focus alone: a reconcile pass runs over every
  # workspace, and without this each one would pull focus onto its panel.
  local placements nofocus code
  code=$(printf '%s\n' "${fn}" | grep -v '^[[:space:]]*#')
  placements=$(printf '%s\n' "${code}" | grep -c 'pane \(split\|move\)' || true)
  nofocus=$(printf '%s\n' "${code}" | grep -c '\-\-no-focus' || true)
  [ "${placements}" -eq "${nofocus}" ] \
    || fail "${placements} placement(s) but ${nofocus} --no-focus"
  # Idempotent: the backfill runs on every bare `ddev tryout herdr`.
  printf '%s' "${fn}" | grep -q 'PANEL_PANE_LABEL' \
    || fail "it must look for an existing panel before docking another"
  # And it carries the session, or a bare herdr inside the panel means the
  # DEFAULT one — the bug that made the panel open where nobody was looking.
  printf '%s' "${fn}" | grep -q 'TRYOUT_PANEL_SESSION' \
    || fail "the panel must be told which session it lives in"
  printf '%s' "${fn}" | grep -q 'TRYOUT_PANEL_WORKTREE' \
    || fail "the panel must be told which worktree it drives"
}

@test "checkout takes --site, so the branch can still be asked for" {
  set -eu -o pipefail
  # A served worktree's panel knows the site but not the branch, and positionally
  # the branch comes first — hence a flag.
  run bash -c "
    set -- --site benni 13.4
    args=(); site=''
    while [ \$# -gt 0 ]; do
      case \"\$1\" in
        --site)   site=\"\${2:-}\"; shift 2 || shift ;;
        --site=*) site=\"\${1#--site=}\"; shift ;;
        *)        args+=(\"\$1\"); shift ;;
      esac
    done
    set -- \${args[@]+\"\${args[@]}\"}
    echo \"branch=\${1:-} site=\${site}\"
  "
  assert_output "branch=13.4 site=benni"

  # The old positional form still works, or every existing invocation breaks.
  run grep -n 'local target_branch="\${1:-}"' "${DIR}/commands/host/tryout"
  assert_success
}

@test "the payload carries a version, and install records it" {
  set -eu -o pipefail
  run helper_eval 'printf "%s" "${TRYOUT_VERSION}"'
  assert_success
  [ -n "${output}" ] || fail "TRYOUT_VERSION is empty"
  # A plain integer, bumped by hand: nothing here can read git at install time.
  printf '%s' "${output}" | grep -qE '^[0-9]+$' \
    || fail "TRYOUT_VERSION should be an integer, got '${output}'"

  # install.yaml stamps the same value into the installed tree.
  run grep -q 'tryout/.version' "${DIR}/install.yaml"
  assert_success
  # …and removal takes it out again.
  local removal
  removal=$(sed -n '/^removal_actions:/,$p' "${DIR}/install.yaml")
  printf '%s\n' "${removal}" | grep -q '.version' || fail "removal leaves .version behind"
}

@test "addon_is_stale compares the installed stamp against the payload" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/.ddev/tryout"

  # No stamp at all: an install predating the marker. Not stale — we cannot
  # know, and crying wolf on every old project would train people to ignore it.
  run helper addon_is_stale
  assert_failure

  # Same version: current.
  helper_eval 'printf "%s\n" "${TRYOUT_VERSION}"' > "${FAKEROOT}/.ddev/tryout/.version"
  run helper addon_is_stale
  assert_failure

  # Older stamp: stale.
  printf '0\n' > "${FAKEROOT}/.ddev/tryout/.version"
  run helper addon_is_stale
  assert_success

  # Newer stamp than the running code — the command itself is the old copy.
  # Still worth reporting: something is out of step either way.
  printf '99999\n' > "${FAKEROOT}/.ddev/tryout/.version"
  run helper addon_is_stale
  assert_success
}

@test "status warns about a stale install, on the host, before delegating" {
  set -eu -o pipefail
  local body
  body=$(sed -n '/^cmd_status() {/,/^}/p' "${DIR}/commands/host/tryout")
  [ -n "${body}" ] || fail "no cmd_status()"
  printf '%s\n' "${body}" | grep -q 'addon_is_stale' \
    || fail "status never checks whether the install is stale"
  # It must come before the delegate, or a stopped project never shows it.
  local check delegate
  check=$(printf '%s\n' "${body}" | grep -n 'addon_is_stale' | head -1 | cut -d: -f1)
  delegate=$(printf '%s\n' "${body}" | grep -n 'delegate status' | head -1 | cut -d: -f1)
  [ -n "${check}" ] && [ -n "${delegate}" ] || fail "cannot locate both"
  [ "${check}" -lt "${delegate}" ] || fail "the staleness check runs after delegating"
  # And it names the command that fixes it.
  printf '%s\n' "${body}" | grep -q 'add-on get' || fail "no next step given"
}

# --- keeping herdr in step with the worktrees -------------------------------
# `ddev tryout herdr` used to only ever ADD: it opened a workspace per worktree
# and skipped the ones already open. Nothing closed a workspace whose worktree
# had been removed — its pane sat in a directory that no longer existed.

# A herdr stub that answers `workspace list` with the given JSON and logs every
# other call, so a test can see exactly what was closed.
fake_herdr() {
  mkdir -p "${FAKEROOT}/bin"
  printf '%s' "$1" > "${FAKEROOT}/ws.json"
  cat > "${FAKEROOT}/bin/herdr" <<FAKE
#!/usr/bin/env bash
# Drop the leading "--session <name>" the wrapper adds.
[ "\$1" = "--session" ] && shift 2
if [ "\$1" = "workspace" ] && [ "\$2" = "list" ]; then
  cat "${FAKEROOT}/ws.json"
  exit 0
fi
echo "CALL: \$*" >> "${FAKEROOT}/calls.log"
FAKE
  chmod +x "${FAKEROOT}/bin/herdr"
  : > "${FAKEROOT}/calls.log"
}

@test "a workspace whose worktree is gone is an orphan; one still on disk is not" {
  set -eu -o pipefail
  # v13 exists on disk, v12 does not.
  mkdir -p "${FAKEROOT}/typo3-core-v13"
  ln -s typo3-core-v13 "${FAKEROOT}/typo3-core"
  fake_herdr '{"result":{"workspaces":[
    {"workspace_id":"w1","label":"core-v13"},
    {"workspace_id":"w2","label":"core-v12"}
  ]}}'

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    herdr_orphan_workspaces
  "
  assert_success
  assert_output --partial "w2"
  assert_output --partial "core-v12"
  refute_output --partial "core-v13"
}

@test "workspaces that are not ours are never touched, however stale they look" {
  # The session is per project, but a user may have opened anything in it. Only
  # the core-<name> label marks a workspace as one this command manages.
  set -eu -o pipefail
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr '{"result":{"workspaces":[
    {"workspace_id":"w1","label":"my-notes"},
    {"workspace_id":"w2","label":"typo3-core-main"},
    {"workspace_id":"w3","label":"core-gone"}
  ]}}'

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    herdr_orphan_workspaces
  "
  assert_success
  assert_output --partial "core-gone"
  refute_output --partial "my-notes"
  # Labelled like a directory, but not our scheme — leave it alone.
  refute_output --partial "typo3-core-main"
}

@test "close_orphan_workspaces closes each orphan once, by id, and says so" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr '{"result":{"workspaces":[
    {"workspace_id":"w1","label":"core-main"},
    {"workspace_id":"w2","label":"core-v12"},
    {"workspace_id":"w3","label":"core-bugfix"}
  ]}}'

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    close_orphan_workspaces
  "
  assert_success
  assert_output --partial "core-v12"
  assert_output --partial "core-bugfix"

  run cat "${FAKEROOT}/calls.log"
  assert_line "CALL: workspace close w2"
  assert_line "CALL: workspace close w3"
  # main is still on disk, so it is left open.
  refute_output --partial "close w1"
}

@test "nothing is closed when every worktree is still there" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr '{"result":{"workspaces":[{"workspace_id":"w1","label":"core-main"}]}}'

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    close_orphan_workspaces
  "
  assert_success
  run cat "${FAKEROOT}/calls.log"
  assert_output ""
}

@test "a single-clone project's one workspace is never an orphan" {
  # Before any worktree exists, typo3-core/ is a plain clone and the workspace is
  # labelled after its branch — herdr_checkout_dir resolves that to typo3-core/.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core"
  git init -q "${FAKEROOT}/typo3-core"
  git -C "${FAKEROOT}/typo3-core" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "${FAKEROOT}/typo3-core" branch -M main
  fake_herdr '{"result":{"workspaces":[{"workspace_id":"w1","label":"core-main"}]}}'

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    herdr_orphan_workspaces
  "
  assert_success
  assert_output ""
}

@test "herdr syncs on a bare run, and leaves other workspaces alone when named" {
  set -eu -o pipefail
  local body
  body=$(sed -n '/^cmd_herdr() {/,/^}$/p' "${DIR}/commands/host/tryout")
  [ -n "${body}" ] || fail "no cmd_herdr()"
  printf '%s\n' "${body}" | grep -q 'close_orphan_workspaces' \
    || fail "cmd_herdr never closes orphaned workspaces"
  # Guarded on no worktree having been named: a targeted command must not close
  # workspaces that have nothing to do with it.
  printf '%s\n' "${body}" | grep -q '\[ -z "\${only}" \] && close_orphan_workspaces' \
    || fail "the cleanup is not guarded by an empty \${only}"
  # …and it runs after the open loop, so a rename settles in one command.
  local open_at close_at
  open_at=$(printf '%s\n' "${body}" | grep -n 'open_worktree_in_herdr' | head -1 | cut -d: -f1)
  close_at=$(printf '%s\n' "${body}" | grep -n 'close_orphan_workspaces' | head -1 | cut -d: -f1)
  [ "${open_at}" -lt "${close_at}" ] || fail "orphans are closed before the open loop"
}

# --- the session drifting from the project ----------------------------------
# Closing orphans is only half of "keep herdr in step". A workspace can also
# carry the wrong label for a worktree that is genuinely ours (anything opened
# before the core-<name> scheme), or point somewhere outside the project
# entirely. The first is adopted — renamed, so its agent and scrollback live —
# and only the second is closed.

# As fake_herdr, but also answers `pane list`, since a workspace's directory is
# read from its pane cwd: `workspace create` records no worktree field at all.
fake_herdr_panes() {
  mkdir -p "${FAKEROOT}/bin"
  printf '%s' "$1" > "${FAKEROOT}/ws.json"
  printf '%s' "$2" > "${FAKEROOT}/panes.json"
  cat > "${FAKEROOT}/bin/herdr" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "--session" ] && shift 2
if [ "\$1" = "workspace" ] && [ "\$2" = "list" ]; then cat "${FAKEROOT}/ws.json"; exit 0; fi
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then cat "${FAKEROOT}/panes.json"; exit 0; fi
echo "CALL: \$*" >> "${FAKEROOT}/calls.log"
FAKE
  chmod +x "${FAKEROOT}/bin/herdr"
  : > "${FAKEROOT}/calls.log"
}

@test "a workspace on our worktree but mislabelled is adopted, not closed" {
  # This is the wC/'typo3-core-main' shape: same directory, older label. Closing
  # it would kill a live agent and open a duplicate beside it.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr_panes \
    '{"result":{"workspaces":[{"workspace_id":"wC","label":"typo3-core-main"}]}}' \
    "{\"result\":{\"panes\":[{\"pane_id\":\"wC:p1\",\"workspace_id\":\"wC\",\"cwd\":\"${FAKEROOT}/typo3-core-main\"}]}}"

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    sync_herdr_workspaces
  "
  assert_success
  assert_output --partial "core-main"

  run cat "${FAKEROOT}/calls.log"
  assert_line "CALL: workspace rename wC core-main"
  refute_output --partial "workspace close"
}

@test "a workspace pointing outside the project is closed" {
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/elsewhere"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr_panes \
    '{"result":{"workspaces":[
       {"workspace_id":"wA","label":"core-main"},
       {"workspace_id":"wB","label":"scratch"}
     ]}}' \
    "{\"result\":{\"panes\":[
       {\"pane_id\":\"wA:p1\",\"workspace_id\":\"wA\",\"cwd\":\"${FAKEROOT}/typo3-core-main\"},
       {\"pane_id\":\"wB:p1\",\"workspace_id\":\"wB\",\"cwd\":\"/tmp\"}
     ]}}"

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    sync_herdr_workspaces
  "
  assert_success
  run cat "${FAKEROOT}/calls.log"
  assert_line "CALL: workspace close wB"
  # The one that is genuinely ours and correctly labelled is left alone.
  refute_output --partial "close wA"
  refute_output --partial "rename wA"
}

@test "a workspace inside the project but not on a worktree is left alone" {
  # The project root itself, or packages/ — someone opened it deliberately. It is
  # not a Core worktree, so this command has no business closing it.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main" "${FAKEROOT}/packages"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr_panes \
    '{"result":{"workspaces":[{"workspace_id":"wP","label":"packages"}]}}' \
    "{\"result\":{\"panes\":[{\"pane_id\":\"wP:p1\",\"workspace_id\":\"wP\",\"cwd\":\"${FAKEROOT}/packages\"}]}}"

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    sync_herdr_workspaces
  "
  assert_success
  run cat "${FAKEROOT}/calls.log"
  assert_output ""
}

@test "an adopted workspace is not opened a second time" {
  # The whole point of adopting: herdr_worktree_is_open keys on pane cwd, so once
  # the label is fixed the open loop must still see it as already open.
  set -eu -o pipefail
  mkdir -p "${FAKEROOT}/typo3-core-main"
  ln -s typo3-core-main "${FAKEROOT}/typo3-core"
  fake_herdr_panes \
    '{"result":{"workspaces":[{"workspace_id":"wC","label":"typo3-core-main"}]}}' \
    "{\"result\":{\"panes\":[{\"pane_id\":\"wC:p1\",\"workspace_id\":\"wC\",\"cwd\":\"${FAKEROOT}/typo3-core-main\"}]}}"

  run env DDEV_SITENAME=myproj PATH="${FAKEROOT}/bin:${PATH}" bash -c "
    export DDEV_APPROOT='${FAKEROOT}'
    source '${DIR}/tryout/functions.sh' >/dev/null 2>&1
    herdr_worktree_is_open '${FAKEROOT}/typo3-core-main' && echo OPEN
  "
  assert_success
  assert_output --partial "OPEN"
}

@test "the sync runs before the open loop, so adoption prevents a duplicate" {
  set -eu -o pipefail
  local body sync_at open_at
  body=$(sed -n '/^cmd_herdr() {/,/^}$/p' "${DIR}/commands/host/tryout")
  printf '%s\n' "${body}" | grep -q 'sync_herdr_workspaces' \
    || fail "cmd_herdr never reconciles the session"
  sync_at=$(printf '%s\n' "${body}" | grep -n 'sync_herdr_workspaces' | head -1 | cut -d: -f1)
  open_at=$(printf '%s\n' "${body}" | grep -n 'open_worktree_in_herdr' | head -1 | cut -d: -f1)
  [ "${sync_at}" -lt "${open_at}" ] \
    || fail "adoption must happen before the open loop, or a duplicate is opened"
}

# --- creating a worktree ----------------------------------------------------
# Every route must end at <project>/typo3-core-<name>, and must ask which branch
# the checkout is based on rather than silently taking whatever Core is on.

@test "the branch is asked for even when the name came in as an argument" {
  set -eu -o pipefail
  # Naming a worktree says nothing about which branch it sits on. The popup passes
  # a name and no branch, so a prompt nested inside `if [ -z "$name" ]` would leave
  # it silently based on whatever Core happens to be checked out.
  run helper_eval '
    have_tty() { return 0; }
    ask_branch() { printf "13.4"; }
    BRANCH=main
    ASKED_BRANCH=""
    ask_new_worktree_branch "usage" && printf "%s" "${ASKED_BRANCH}"'
  assert_success
  assert_output "13.4"
}

@test "an explicitly given branch is not asked about again" {
  set -eu -o pipefail
  run helper_eval '
    have_tty() { return 0; }
    ask_branch() { printf "13.4"; }
    BRANCH=main
    ASKED_BRANCH="12.4"
    ask_new_worktree_branch "usage" && printf "%s" "${ASKED_BRANCH}"'
  assert_success
  assert_output "12.4"
}

@test "with no terminal the branch falls back to BRANCH instead of blocking" {
  set -eu -o pipefail
  # ddev start and any script must never stop here. ui_choose returns non-zero
  # without a TTY, so asking unconditionally would abort a non-interactive add.
  run helper_eval '
    have_tty() { return 1; }
    ask_branch() { printf "should-not-be-called"; return 1; }
    BRANCH=14.3
    ASKED_BRANCH=""
    ask_new_worktree_branch "usage" && printf "%s" "${ASKED_BRANCH}"'
  assert_success
  assert_output "14.3"
}

@test "cancelling the branch picker stops the command" {
  set -eu -o pipefail
  run helper_eval '
    have_tty() { return 0; }
    ask_branch() { return 1; }
    BRANCH=main
    ASKED_BRANCH=""
    ask_new_worktree_branch "ddev tryout worktree add <name> [<branch>]"'
  assert_failure
  # A cancel is not a usage error: explain_missing says so only without a terminal.
  refute_output --partial "Usage:"
}

@test "both creation routes ask for the branch outside the name check" {
  set -eu -o pipefail
  # The regression this guards: `ask_branch` sitting inside `if [ -z "${name}" ]`,
  # so `herdr new <name>` and `worktree add <name>` never ask.
  local f="${DIR}/commands/host/tryout"
  run grep -c 'ask_new_worktree_branch' "${f}"
  assert_success
  assert_output "2"
  # And no creation route may still call ask_branch from inside the name guard —
  # that is the exact shape of the bug: the branch question skipped whenever a
  # name was already there. Take the whole guard block, not a fixed -A window.
  local guard
  guard=$(awk '/^cmd_herdr_new\(\)/,/^}/' "${f}" | awk '/if \[ -z /,/^    fi$/')
  [ -n "${guard}" ] || fail "could not find the name guard in cmd_herdr_new"
  if printf '%s\n' "${guard}" | grep -q 'ask_branch'; then
    fail "cmd_herdr_new asks for the branch only when the name is missing"
  fi
}

@test "worktree_name_from_ref strips a branch down to a directory name" {
  set -eu -o pipefail
  # herdr names its own checkouts on a worktree/<slug> branch.
  run helper worktree_name_from_ref "worktree/curious-fox"
  assert_output "curious-fox"
  run helper worktree_name_from_ref "refs/heads/bugfix-9421"
  assert_output "bugfix-9421"
  # An already-prefixed name must not become typo3-core-typo3-core-x.
  run helper worktree_name_from_ref "typo3-core-v13"
  assert_output "v13"
  # Anything a directory cannot hold becomes a dash — including the slash of a
  # branch prefix that is not one of herdr's own, which stays part of the name.
  run helper worktree_name_from_ref "feature/TYPO3 v14!"
  assert_output "feature-TYPO3-v14-"
}

@test "patch asks which site first, and lists that site's branch" {
  # The site decides which Core checkout is patched, and therefore which branch's
  # open changes are worth showing: offering main's changes for a 13.4 site is
  # simply the wrong list. So the site is resolved BEFORE the fetch.
  set -eu -o pipefail
  local body site_at fetch_at
  body=$(sed -n '/^cmd_patch() {/,/^}$/p' "${DIR}/commands/host/tryout")
  [ -n "${body}" ] || fail "no cmd_patch()"

  printf '%s\n' "${body}" | grep -q 'ask_site' || fail "patch never asks for a site"
  site_at=$(printf '%s\n' "${body}" | grep -n 'ask_site' | head -1 | cut -d: -f1)
  fetch_at=$(printf '%s\n' "${body}" | grep -n 'fetch_open_patches' | head -1 | cut -d: -f1)
  [ -n "${fetch_at}" ] || fail "no fetch"
  [ "${site_at}" -lt "${fetch_at}" ] \
    || fail "the site must be chosen before the changes are fetched"

  # A named site still skips the question, and an explicit change number is
  # applied without one either.
  printf '%s\n' "${body}" | grep -q 'served_site_names' \
    || fail "patch asks even when nothing else is served"
}

@test "the branch listed for a served site is that site's own, not the primary's" {
  set -eu -o pipefail
  local body
  body=$(sed -n '/^cmd_patch() {/,/^}$/p' "${DIR}/commands/host/tryout")
  # Without this a 13.4 worktree would be offered main's open changes.
  printf '%s\n' "${body}" | grep -q 'site_core_dir' \
    || fail "the site's own Core checkout is never consulted"
  printf '%s\n' "${body}" | grep -q 'detect_detached_base_branch' \
    || fail "a served site's base branch is never detected"
}

@test "a reload only replaces a restart when the hostname set is unchanged" {
  set -eu -o pipefail
  # DDEV derives the Traefik routing rule, $VIRTUAL_HOST and the certificate SANs
  # from additional_hostnames. All three go stale exactly when the served set
  # changes — and none of them can be refreshed from inside the container. So the
  # gate is the hostname set, and nothing else.
  local root="${FAKEROOT}/reloadgate"
  mkdir -p "${root}/sites/keep" "${root}/sites/gone"
  printf 'php=8.3\n' > "${root}/sites/keep/.tryout-site"
  printf 'php=8.3\n' > "${root}/sites/gone/.tryout-site"

  snap() {
    helper_eval "
      PROJECT_ROOT='${root}'
      SITES_DIR='${root}/sites'
      DDEV_SITENAME='proj'
      served_hostname_set
    " 2>/dev/null
  }

  local before after
  before="$(snap)"
  # Re-serving an existing site changes nothing about the set: same path taken.
  after="$(snap)"
  [ "${before}" = "${after}" ] || fail "an unchanged set must compare equal"

  # Removing one changes it, so the restart stays required.
  rm -f "${root}/sites/gone/.tryout-site"
  after="$(snap)"
  [ "${before}" != "${after}" ] || fail "dropping a site must change the set"

  # And it is order-independent: the comparison is on a sorted set, not on the
  # order the directories happen to be read in.
  printf '%s\n' "${before}" | sort -c \
    || fail "the snapshot must be sorted, or two equal sets can compare different"
}

@test "the vhost sync clears our stale copies but never DDEV's own" {
  set -eu -o pipefail
  # sites-enabled is a COPY made by DDEV's /start.sh, not a mount. unserve removes
  # a vhost from nginx_full/, and without clearing the copy the dead site keeps
  # serving. The clear must be scoped: DDEV's nginx-site.conf lives in the same
  # directory, and taking it out would break every site in the project.
  local fn
  fn=$(sed -n '/^sync_and_reload_webserver()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'rm -f "${dst}"/tryout-site-\*\.conf' \
    || fail "stale per-site vhosts must be cleared, or unserve leaves them serving"
  printf '%s' "${fn}" | grep -q 'tryout-server-names-hash.conf' \
    || fail "the hash config is ours too and must be cleared with the vhosts"

  # Never a blanket wipe of the directory: that is DDEV's, not ours.
  printf '%s' "${fn}" | grep -qE 'rm -rf "\$\{dst\}"( |$)' \
    && fail "the enabled dir holds DDEV's own config; only our prefix may be removed"

  # Every removal is scoped to a tryout- prefix.
  local bad
  bad=$(printf '%s' "${fn}" | grep -E '^\s*rm ' | grep -v 'tryout-' || true)
  [ -z "${bad}" ] || fail "unscoped removal in the sync: ${bad}"
}

@test "the config is validated before the running webserver is reloaded" {
  set -eu -o pipefail
  # An invalid config makes nginx refuse to START, taking down every site in the
  # project — the server_names_hash_bucket_size trap. Validating first means a bad
  # generated vhost leaves the running config untouched, which is strictly safer
  # than the restart this replaces: that one only finds out once it is already down.
  local fn
  fn=$(sed -n '/^sync_and_reload_webserver()/,/^}/p' "${DIR}/tryout/functions.sh")

  local check_line reload_line
  check_line=$(printf '%s' "${fn}" | grep -n 'webserver_config_is_valid' | head -1 | cut -d: -f1)
  # grep -w and a tail: the function's OWN name contains reload_webserver, and
  # matching line 1 would make the ordering check pass no matter what.
  reload_line=$(printf '%s' "${fn}" | grep -n '^[[:space:]]*reload_webserver' | head -1 | cut -d: -f1)
  [ -n "${check_line}" ] || fail "the config must be validated before a reload"
  [ -n "${reload_line}" ] || fail "the sync must actually reload"
  [ "${check_line}" -lt "${reload_line}" ] \
    || fail "validation must come BEFORE the reload, or a bad config still lands"

  # And a failed check must abort rather than carry on.
  printf '%s' "${fn}" | grep -q 'webserver_config_is_valid || return 1' \
    || fail "a config that would not load must stop the reload"
}

@test "the reload keeps the webserver up instead of restarting the container" {
  set -eu -o pipefail
  # nginx is a supervisord program in the web image and there is no /run/nginx.pid,
  # so HUP goes through supervisorctl. The point of the whole change is not
  # bouncing the container, so a restart verb here would defeat it.
  local fn
  fn=$(sed -n '/^reload_webserver()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'supervisorctl signal HUP nginx' \
    || fail "nginx reloads by HUP through supervisord"
  printf '%s' "${fn}" | grep -q 'apachectl -k graceful' \
    || fail "the apache branch must reload too; apache-fpm is the default type"

  printf '%s' "${fn}" | grep -qE 'supervisorctl (restart|stop|start)' \
    && fail "restarting the process drops connections the reload exists to keep"
  :
}

@test "nothing container-side calls ddev to apply a config change" {
  set -eu -o pipefail
  # ddev is only a stub inside the web image. The reload path runs there, so it
  # must use the container's own tools.
  local block
  block=$(sed -n '/^# --- Applying a config change without ddev restart ---/,/^# Create the site.s database/p' \
          "${DIR}/tryout/functions.sh" | grep -v '^[[:space:]]*#')
  [ -n "${block}" ] || fail "could not locate the reload block"
  printf '%s' "${block}" | grep -qE '(^|[^-[:alnum:]])ddev ' \
    && fail "the reload path must not shell out to ddev"
  :
}

@test "both webserver types are handled wherever the reload branches" {
  set -eu -o pipefail
  # site_vhost_file already defaults to apache-fpm, so a branch that only knew
  # nginx would silently do nothing on an apache project — the site would look
  # served and never answer.
  local f
  for f in site_conf_source_dir site_conf_enabled_dir webserver_config_is_valid reload_webserver; do
    local fn
    fn=$(sed -n "/^${f}()/,/^}/p" "${DIR}/tryout/functions.sh")
    [ -n "${fn}" ] || fail "${f} is missing"
    printf '%s' "${fn}" | grep -q 'nginx\*)' \
      || fail "${f} must branch on the nginx case"
    printf '%s' "${fn}" | grep -q '\*)' \
      || fail "${f} needs an apache fallback, which is the default webserver type"
  done
}

@test "serve reloads in place, unserve still asks for the restart it needs" {
  set -eu -o pipefail
  # Removing a site always shrinks the hostname set, so unserve can never take the
  # fast path — but it must still drop the vhost, or the site keeps answering on a
  # hostname with nothing behind it.
  local fn
  fn=$(sed -n '/^serve_worktree()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${fn}" | grep -q 'hosts_before="\$(served_hostname_set)"' \
    || fail "serve must snapshot the hostname set before it writes the marker"
  printf '%s' "${fn}" | grep -q 'apply_site_config "\${hosts_before}"' \
    || fail "serve must decide its path from that snapshot"

  # The snapshot has to be taken before the marker is written, or the site being
  # served is already in it and the set always looks unchanged.
  local snap_line marker_line
  snap_line=$(printf '%s' "${fn}" | grep -n 'served_hostname_set' | head -1 | cut -d: -f1)
  marker_line=$(printf '%s' "${fn}" | grep -n "printf 'php=" | head -1 | cut -d: -f1)
  [ -n "${marker_line}" ] || fail "serve no longer writes the .tryout-site marker?"
  [ "${snap_line}" -lt "${marker_line}" ] \
    || fail "snapshot after the marker would always compare equal"

  # unserve still drops the vhost immediately, or the dead site keeps answering.
  # It no longer tells the user to restart: the HOST does that itself, and `ddev`
  # does not work in here anyway.
  fn=$(sed -n '/^unserve_worktree()/,/^}/p' "${DIR}/tryout/functions.sh")
  printf '%s' "${fn}" | grep -q 'sync_and_reload_webserver' \
    || fail "unserve must drop the vhost now, or the dead site keeps serving"
  printf '%s' "${fn}" | grep -q "ddev restart" \
    && fail "the container must not ask for a restart the host already runs"
  :
}

@test "the vhosts are copied back by name, never by globbing the source" {
  set -eu -o pipefail
  # On a Mutagen project the host's deletion of a vhost has not necessarily
  # reached /mnt/ddev_config by the time unserve calls the sync. A glob over the
  # source would then faithfully copy back the file that was just removed, and the
  # unserved site would keep answering on a hostname with nothing behind it —
  # observed on a real project before this was fixed. served_site_names reads the
  # markers, which ARE the definition of served and are right in the container
  # whatever the file sync has caught up on.
  local fn
  fn=$(sed -n '/^sync_and_reload_webserver()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')

  printf '%s' "${fn}" | grep -q 'for name in \$(served_site_names)' \
    || fail "the copy must be driven by the served set, not by the source directory"

  # The glob is the bug: cp "${src}"/*.conf would restore a just-deleted vhost.
  printf '%s' "${fn}" | grep -qE 'cp "\$\{src\}"/\*' \
    && fail "globbing the source re-copies vhosts that unserve just removed"

  # Every copy names a single file.
  local copies
  copies=$(printf '%s' "${fn}" | grep -E '^\s*cp ' || true)
  [ -n "${copies}" ] || fail "the sync must copy something"
  printf '%s' "${copies}" | grep -q '\*' \
    && fail "a wildcard copy defeats the point: ${copies}"
  :
}

@test "the panel start is confirmed after a wait, never straight after pane run" {
  set -eu -o pipefail
  # `pane run` answers in ~17ms; the pane's terminal title — all
  # panel_pane_is_running has to go on — takes ~700ms to appear. Checking with no
  # wait between them therefore reported "not running" every single time, however
  # well the panel had started, and the retry then typed the command AT A LIVE
  # PANEL. Those keystrokes end in a newline, which the panel reads as Enter, so it
  # ran the selected row: `status` on a fresh panel. Measured on a real herdr
  # session; this is the whole bug.
  # Scoped to the START loop: panel_pane_is_running is also used far above, on the
  # existing-panel branch, where no pane run precedes it.
  local fn
  fn=$(sed -n '/^ensure_panel_pane()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#' | sed -n '/pane run/,$p')

  # A wait has to sit between starting it and judging it.
  local run_line check_line sleep_line
  run_line=$(printf '%s' "${fn}" | grep -n 'pane run' | head -1 | cut -d: -f1)
  check_line=$(printf '%s' "${fn}" | grep -n 'panel_pane_is_running' | head -1 | cut -d: -f1)
  sleep_line=$(printf '%s' "${fn}" | grep -n 'sleep' | head -1 | cut -d: -f1)
  [ -n "${run_line}" ] && [ -n "${check_line}" ] || fail "the panel must be started and confirmed"
  [ -n "${sleep_line}" ] || fail "there must be a wait before the verdict"
  [ "${sleep_line}" -gt "${run_line}" ] \
    || fail "the wait belongs after pane run, not before it"
  [ "${sleep_line}" -lt "${check_line}" ] \
    || fail "confirming with no wait is the bug: it always fails and retries into a live panel"

  # And it must still give up, or a panel that never starts hangs every worktree
  # queued behind it.
  printf '%s' "${fn}" | grep -qE '\[ "\$\{attempt\}" -ge [0-9]+ \] && break' \
    || fail "the retry must stay bounded"
}

@test "the panel throws away input that arrived before it could draw" {
  set -eu -o pipefail
  # Nothing a human typed can be buffered before the first menu is on screen, so
  # anything sitting there was typed by something else — `pane run` starts a
  # command by typing it, newline and all, and that newline reads as Enter. The
  # drain is what stops a byte the user never pressed from running a row.
  local script
  script="${DIR}/tryout/herdr-panel.sh"

  grep -q 'drain_stdin' "${script}" || fail "the panel must drain stdin at startup"

  # It has to happen BEFORE the loop, or it drains nothing worth draining.
  local drain_line loop_line
  drain_line=$(grep -n '^drain_stdin$' "${script}" | head -1 | cut -d: -f1)
  loop_line=$(grep -n '^while :; do' "${script}" | head -1 | cut -d: -f1)
  [ -n "${drain_line}" ] || fail "the drain must actually be called, not just defined"
  [ -n "${loop_line}" ] || fail "the main loop is gone?"
  [ "${drain_line}" -lt "${loop_line}" ] \
    || fail "draining after the loop starts is too late"

  # bash 3.2 rejects a fractional -t outright, so a drain written that way would
  # never run at all — the very trap the existing timeout test guards.
  local fn
  fn=$(sed -n '/^drain_stdin()/,/^}/p' "${script}")
  printf '%s' "${fn}" | grep -qE 'read .*-t +[0-9]+\.' \
    && fail "a fractional -t makes the drain a runtime error on macOS"
  printf '%s' "${fn}" | grep -qE 'read .*-t +[0-9]+' \
    || fail "the drain needs a timeout, or it blocks the panel forever"
}

@test "every panel colour names its own foreground" {
  set -eu -o pipefail
  # A bare attribute — ESC[1m bold, ESC[2m dim — only MODIFIES the colour the pane
  # already carries, and an unselected row printed with no escape at all keeps
  # whatever foreground was there. SEL_ON pins the selected row's background to
  # black, so on a pane whose default foreground is dark the entire menu drew
  # black on black: the rows were present, the panel just looked empty apart from
  # the one highlighted row. Nothing here may depend on a colour it did not set.
  local script="${DIR}/tryout/herdr-panel.sh"
  # Colour codes contain semicolons, so the value has to be pulled out whole:
  # take everything between the quotes after NAME=. Several share a line.
  local bad="" name val
  for name in BOLD DIM CYAN RED SEL_ON ROW; do
    val=$(sed -n "s/.*${name}='\\([^']*\\)'.*/\\1/p" "${script}" | head -1)
    [ -n "${val}" ] || fail "${name} is missing from the palette"
    # An explicit foreground: a 30-37 / 90-97 SGR code, or a 256-colour 38;5;N.
    printf '%s' "${val}" | grep -qE '(^|\[|;)(3[0-7]|9[0-7])(m|;)|38;5;[0-9]+' \
      || bad="${bad} ${name}"
  done
  [ -z "${bad}" ] \
    || fail "these set an attribute but no foreground, so they inherit:${bad}"

  # And the unselected row must actually be painted, not printed bare.
  local fn
  fn=$(sed -n '/^render()/,/^}/p' "${script}")
  printf '%s' "${fn}" | grep -qE 'printf "   \$\{ROW\}' \
    || fail "an unselected row printed bare inherits the pane's foreground"
}

@test "the restart runs on the host, and only when the hostname set moved" {
  set -eu -o pipefail
  # DDEV owns the Traefik rule, $VIRTUAL_HOST and the certificate SANs, all keyed
  # on additional_hostnames — none refreshable from inside the container. So a
  # hostname that just appeared or went needs a restart. An UNCHANGED set does not:
  # serve_worktree already reloaded the webserver in place, and a restart costs
  # minutes on a Mutagen project for nothing.
  local fn
  fn=$(sed -n '/^restart_if_hosts_changed()/,/^}/p' "${DIR}/commands/host/tryout")
  [ -n "${fn}" ] || fail "the host has no restart helper"

  printf '%s' "${fn}" | grep -q 'ddev restart' \
    || fail "it has to actually restart, not just advise one"
  # The gate: same set, no restart.
  printf '%s' "${fn}" | grep -q '\[ "${before}" != "${after}" \] || return 0' \
    || fail "an unchanged hostname set must not pay for a restart"
  # And an opt-out, so serving several worktrees can restart once at the end.
  printf '%s' "${fn}" | grep -q 'TRYOUT_NO_RESTART' \
    || fail "--no-restart must be honoured"

  # It lives on the HOST: ddev is only a stub in the web image.
  grep -q '^restart_if_hosts_changed()' "${DIR}/commands/host/tryout" \
    || fail "the restart helper belongs in the host command"
  local f
  for f in functions.sh commands.sh; do
    run grep -q 'restart_if_hosts_changed' "${DIR}/tryout/${f}"
    assert_failure   # container-side files must not carry it
  done
}

@test "every verb that moves a hostname snapshots before delegating" {
  set -eu -o pipefail
  # The snapshot has to be taken BEFORE the container writes or removes the
  # .tryout-site marker, or the set always compares equal and nothing restarts.
  # serve, unserve and rename all move it; `add` does too, but only with --serve.
  local host="${DIR}/commands/host/tryout"
  local verb
  for verb in serve unserve; do
    local block
    block=$(sed -n "/^        ${verb})\$/,/^            ;;/p" "${host}")
    [ -n "${block}" ] || fail "no ${verb} dispatch block"
    printf '%s' "${block}" | grep -q 'served_hostname_set' \
      || fail "${verb} must snapshot the hostname set"
    printf '%s' "${block}" | grep -q 'restart_if_hosts_changed' \
      || fail "${verb} must restart when that set moved"

    # Snapshot first, delegate second: reversed, the marker is already written.
    local snap_line del_line
    snap_line=$(printf '%s' "${block}" | grep -n 'served_hostname_set' | head -1 | cut -d: -f1)
    del_line=$(printf '%s' "${block}" | grep -n 'delegate ' | head -1 | cut -d: -f1)
    [ "${snap_line}" -lt "${del_line}" ] \
      || fail "${verb} snapshots after the work, so the set always looks unchanged"
  done

  # --no-restart is the host's own word; delegating it would fail the container's
  # argument parser, so it must be stripped before the call.
  local sblock
  sblock=$(sed -n "/^        serve)\$/,/^            ;;/p" "${host}")
  printf '%s' "${sblock}" | grep -q -- '--no-restart) TRYOUT_NO_RESTART=1' \
    || fail "--no-restart must be consumed on the host, not delegated"
}

@test "removing a worktree takes its branch, unless that would lose work" {
  set -eu -o pipefail
  # The branch outlives the worktree, and add_core_worktree refuses a name whose
  # branch exists — so a leftover blocks re-creating a worktree of the same name,
  # with an error about a branch nobody is thinking about ("A branch 'jochen'
  # already exists" when the folder is plainly gone). Removing it closes that.
  local fn
  fn=$(sed -n '/^remove_core_worktree()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'branch "${del}" "${name}"' \
    || fail "remove must delete the worktree's branch too"

  # -d, not -D: git refuses -d on a branch holding unmerged work, and that refusal
  # IS the guard against an unpushed commit vanishing with the checkout. A bare -D
  # would destroy it silently.
  printf '%s' "${fn}" | grep -q 'local del="-d"' \
    || fail "the default must be -d, so git can refuse to lose unmerged work"
  printf '%s' "${fn}" | grep -q '\[ "${force}" = "true" \] && del="-D"' \
    || fail "--force is the only way to -D"

  # A refusal must be reported, not swallowed: the branch is still there and the
  # user has to know why.
  printf '%s' "${fn}" | grep -q "not merged" \
    || fail "a kept branch must say why it was kept"
}

@test "a leftover branch explains itself when it blocks a new worktree" {
  set -eu -o pipefail
  # The folder is gone, so "A branch 'x' already exists" sends people hunting for
  # a directory that is not there. Name the case and the command that clears it —
  # but change nothing: a command that FAILED must not delete a ref on its way out.
  local fn
  fn=$(sed -n '/^add_core_worktree()/,/^}/p' "${DIR}/tryout/functions.sh")

  printf '%s' "${fn}" | grep -q 'its worktree is gone; the branch outlived it' \
    || fail "the message must say the worktree is gone, not just that a branch exists"
  printf '%s' "${fn}" | grep -qE 'branch -d \$\{name\}|branch -d \$\{name\}' \
    || printf '%s' "${fn}" | grep -q 'branch -d' \
    || fail "it must name the command that clears a spent branch"

  # Advisory only. `branch -d` inside this error path would mutate state on a
  # failed command; only merge-base (a read) may be used to pick the wording.
  local acts
  acts=$(printf '%s' "${fn}" | grep -E '^\s*(if )?git -C .* branch (-d|-D) ' \
         | grep -v 'error ' || true)
  [ -z "${acts}" ] \
    || fail "add must not delete a branch while failing: ${acts}"
}

@test "the Gerrit port probe does not use bash /dev/tcp" {
  set -eu -o pipefail
  # macOS SIGKILLs a shell that opens /dev/tcp to an EXTERNAL host — verified:
  # 127.0.0.1 works, any outside address dies with rc=137. The subshell's death
  # printed "Killed: 9" straight to the user's terminal, and diagnose_gerrit_ssh
  # read the failure as "the port is unreachable" — on a machine where it was
  # reachable, one line after an authenticated call to that very host and port.
  local fn
  fn=$(sed -n '/^diagnose_gerrit_ssh()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')

  printf '%s' "${fn}" | grep -q '/dev/tcp' \
    && fail "/dev/tcp is killed by macOS for external hosts; use nc"

  # nc -z -w takes the same flags on the BSD nc macOS ships and on GNU nc.
  # -G would be BSD-only, which the portability rules forbid.
  printf '%s' "${fn}" | grep -q 'nc -z -w' \
    || fail "the reachability probe must use a portable, quiet nc"
  printf '%s' "${fn}" | grep -q 'nc .*-G ' \
    && fail "-G is BSD-only; -w works on both"

  # No nc must not mean a false verdict: step 3 opens a real connection to the
  # same host and port, so skipping is safe and guessing is not.
  printf '%s' "${fn}" | grep -q 'command -v nc' \
    || fail "the probe must be skipped where nc is absent, not assumed to fail"
  :
}

@test "the Gerrit SSH verdict comes from SSH, not from what an agent holds" {
  set -eu -o pipefail
  # An `ssh-add -l` gate AHEAD of the auth probe answers a different question and
  # used to return early on its answer: a host whose agent is empty but which
  # authenticates from a key on disk — ~/.ssh/id_rsa offered and accepted by
  # Gerrit, the ordinary case — was told "no-agent-key" and pointed at an ssh-add
  # it did not need, right after `ddev auth ssh` had correctly filled the
  # CONTAINER's agent. Ask the thing being reported on, then explain.
  local fn
  fn=$(sed -n '/^diagnose_gerrit_ssh()/,/^}/p' "${DIR}/tryout/functions.sh" \
       | grep -v '^[[:space:]]*#')

  local auth_line agent_line
  auth_line=$(printf '%s' "${fn}" | grep -n 'gerrit version' | head -1 | cut -d: -f1)
  agent_line=$(printf '%s' "${fn}" | grep -n 'ssh-add -l' | head -1 | cut -d: -f1)
  [ -n "${auth_line}" ] || fail "the auth probe is gone"
  [ -n "${agent_line}" ] || fail "the agent check is gone; it still classifies a failure"
  [ "${auth_line}" -lt "${agent_line}" ] \
    || fail "ssh-add before the auth probe is the bug: it short-circuits a working host"

  # no-agent-key must mean no identity ANYWHERE — an empty agent alone is not it,
  # because ssh authenticates from ~/.ssh/id_* without one.
  printf '%s' "${fn}" | grep -q 'id_\*' \
    || fail "an on-disk key must count, or an empty agent is misreported"
  printf '%s' "${fn}" | grep -q 'case "${k}" in \*.pub) continue ;; esac' \
    || fail "a .pub file is not a usable identity"

  # Both reasons must survive: they have different fixes.
  printf '%s' "${fn}" | grep -q 'CS_SSH_REASON="no-agent-key"' \
    || fail "the container's real case must still be diagnosable"
  printf '%s' "${fn}" | grep -q 'CS_SSH_REASON="denied"' \
    || fail "a key that Gerrit refuses is a different fix from having none"
}
