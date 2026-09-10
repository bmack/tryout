#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
#   brew tap bats-core/bats-core
#   brew install bats-core bats-assert bats-file bats-support
# And run this in the add-on root directory:
#   bats ./tests
# To exclude release tests:
#   bats ./tests --filter-tags '!release'
# The slow tests that clone TYPO3 Core and start it live in tests/lifecycle.bats:
#   bats ./tests/test.bats            # fast: install, config, removal
#   bats ./tests/lifecycle.bats       # slow: real TYPO3, patches, worktrees
# For debugging:
#   bats ./tests --show-output-of-passing-tests --verbose-run --print-output-on-failure

# The shared setup/teardown live in tests/setup.sh and tests/teardown.sh so that
# every .bats file in this directory uses exactly the same throwaway project. They
# set the variables DDEV's add-on conventions require, named here so the
# `ddev utility addon-update-checker` lint can see them in this file too:
#   GITHUB_REPO, DDEV_NONINTERACTIVE=true, DDEV_NO_INSTRUMENTATION=true,
#   bats_load_library (bats-assert/bats-file/bats-support), and the GITHUB_ENV
#   branch in teardown() that preserves TESTDIR as a CI artifact.

# Every `ddev restart` here passes --skip-hooks: this add-on's post-start hook
# clones TYPO3 Core (~600 MB), runs composer install and sets up TYPO3, which is
# minutes per test. That path is exercised deliberately in tests/lifecycle.bats;
# here we are testing what installation puts on disk and how it behaves.

setup() { load setup.sh; }
health_checks() { load health_checks.sh; }
teardown() { load teardown.sh; }

# ─────────────────────────────────────────────────────────────────────
# Install
# ─────────────────────────────────────────────────────────────────────

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y --skip-hooks
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y --skip-hooks
  assert_success
  health_checks
}

@test "install is idempotent" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  # A second install is the documented update path and must not fail or warn
  # about files it cannot overwrite.
  run ddev add-on get "${DIR}"
  assert_success
  # Nothing the add-on ships may be left unmanageable, and the user's patch list
  # is not a project_files entry, so an update must warn about nothing at all.
  refute_output --partial "NOT overwriting"
  health_checks
}

# ─────────────────────────────────────────────────────────────────────
# Configuration the add-on contributes
# ─────────────────────────────────────────────────────────────────────

@test "config.tryout.yaml sets the TYPO3 environment in the container" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y --skip-hooks
  assert_success

  run ddev exec 'echo $TYPO3_CONTEXT'
  assert_success
  assert_output "Development"

  # Composer is redirected at the overlay — the whole point of the design.
  run ddev exec 'echo $COMPOSER'
  assert_success
  assert_output "composer.tryout.json"

  run ddev exec 'echo $TYPO3_SETUP_ADMIN_USERNAME'
  assert_success
  assert_output "admin"
}

@test "the add-on does not take over the project's own config.yaml" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # name/type/docroot/php_version belong to the user's `ddev config`, and the
  # add-on must not ship or overwrite them.
  run grep -E '^(name|type|docroot|php_version):' "${TESTDIR}/.ddev/config.tryout.yaml"
  assert_failure

  run grep -q "name: ${PROJNAME}" "${TESTDIR}/.ddev/config.yaml"
  assert_success
  run grep -q 'docroot: public' "${TESTDIR}/.ddev/config.yaml"
  assert_success
}

@test "the post-start hook is registered" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run grep -q 'bash .ddev/tryout/post-start.sh' "${TESTDIR}/.ddev/config.tryout.yaml"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────
# The Composer overlay
# ─────────────────────────────────────────────────────────────────────

@test "an existing composer.json is never rewritten" {
  set -eu -o pipefail
  cat > "${TESTDIR}/composer.json" <<'JSON'
{
    "name": "acme/site",
    "require": { "psr/log": "^3.0" },
    "extra": { "acme-marker": "must-survive" }
}
JSON
  cp "${TESTDIR}/composer.json" "${TESTDIR}/composer.json.orig"

  run ddev add-on get "${DIR}"
  assert_success

  run diff "${TESTDIR}/composer.json" "${TESTDIR}/composer.json.orig"
  assert_success

  # The user's file is pulled in by composer-merge-plugin, not copied into ours.
  run grep -q '"include"' "${TESTDIR}/composer.tryout.json"
  assert_success
  run grep -q 'psr/log' "${TESTDIR}/composer.tryout.json"
  assert_failure
  rm -f "${TESTDIR}/composer.json.orig"
}

@test "an existing overlay is preserved across a reinstall" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # The overlay carries the generated require block plus anything the user added,
  # so a reinstall must not reset it to the empty template.
  # Stand in for what `ddev tryout composer` generates plus a package the user
  # added themselves. A plain sed keeps this independent of a container.
  sed -i.bak 's#"require": {#"require": {\n        "acme/thing": "^1.0",#' \
    "${TESTDIR}/composer.tryout.json"
  run grep -q 'acme/thing' "${TESTDIR}/composer.tryout.json"
  assert_success

  run ddev add-on get "${DIR}"
  assert_success
  run grep -q 'acme/thing' "${TESTDIR}/composer.tryout.json"
  assert_success
}

@test "the overlay declares the Core and packages path repositories" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run grep -q 'typo3-core/typo3/sysext/\*' "${TESTDIR}/composer.tryout.json"
  assert_success
  run grep -q 'packages/\*' "${TESTDIR}/composer.tryout.json"
  assert_success
  run grep -q 'wikimedia/composer-merge-plugin' "${TESTDIR}/composer.tryout.json"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────
# Files outside .ddev/ — the guarded stage-then-copy contract
# ─────────────────────────────────────────────────────────────────────

@test "a foreign .gitignore is appended to, not replaced" {
  set -eu -o pipefail
  printf 'node_modules/\n*.log\n' > "${TESTDIR}/.gitignore"

  run ddev add-on get "${DIR}"
  assert_success

  # The user's entries survive...
  run grep -qxF 'node_modules/' "${TESTDIR}/.gitignore"
  assert_success
  # ...and what tryout must ignore was added.
  run grep -qxF '/composer.tryout.json' "${TESTDIR}/.gitignore"
  assert_success
  run grep -qxF '/typo3-core' "${TESTDIR}/.gitignore"
  assert_success
  # It is the user's file, so it must not be claimed with a marker.
  run grep -q '#ddev-generated' "${TESTDIR}/.gitignore"
  assert_failure
}

@test "appending to a foreign .gitignore does not duplicate on reinstall" {
  set -eu -o pipefail
  printf 'node_modules/\n' > "${TESTDIR}/.gitignore"
  run ddev add-on get "${DIR}"
  assert_success
  run ddev add-on get "${DIR}"
  assert_success

  run bash -c "grep -cxF '/composer.tryout.json' '${TESTDIR}/.gitignore'"
  assert_output "1"
}

@test "a greenfield project gets the full self-ignoring .gitignore" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  assert_file_exist "${TESTDIR}/.gitignore"
  run grep -q '#ddev-generated' "${TESTDIR}/.gitignore"
  assert_success
  # It ignores itself, so dropping tryout into a checkout leaves git status clean.
  run grep -qxF '.gitignore' "${TESTDIR}/.gitignore"
  assert_success
}

@test "reinstall does not clobber a file the user took ownership of" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # Removing the marker is the documented way to take ownership.
  sed -i.bak 's/#ddev-generated/#user-owned/' "${TESTDIR}/config/system/additional.php"
  echo '// my own change' >> "${TESTDIR}/config/system/additional.php"

  run ddev add-on get "${DIR}"
  assert_success
  assert_output --partial "Skipping config/system/additional.php"
  run grep -q 'my own change' "${TESTDIR}/config/system/additional.php"
  assert_success
}

@test "additional.php is gated on IS_DDEV_PROJECT" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run grep -q "getenv('IS_DDEV_PROJECT')" "${TESTDIR}/config/system/additional.php"
  assert_success
  # It must read the per-site database name the served-site vhosts inject.
  run grep -q "TYPO3_DB_DBNAME" "${TESTDIR}/config/system/additional.php"
  assert_success
}

# ─────────────────────────────────────────────────────────────────────
# Command behaviour that needs no TYPO3 Core checkout
# ─────────────────────────────────────────────────────────────────────

@test "commands that need Core fail with a next step before it is cloned" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev tryout patch 12345
  assert_failure
  assert_output --partial "TYPO3 Core not found"
  assert_output --partial "ddev tryout download"
}

@test "an unknown subcommand fails and prints help" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev tryout nonsense
  assert_failure
  assert_output --partial "Unknown command: nonsense"
  assert_output --partial "TYPO3 development toolkit"
}

@test "tryout cs is available as a subcommand and diagnoses an unset instance" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  # `cs` used to be a top-level `ddev cs`; it must not come back as one.
  assert_file_not_exist "${TESTDIR}/.ddev/commands/host/cs"

  run ddev tryout cs help
  assert_success
  assert_output --partial "ddev tryout cs"
  assert_output --partial "doctor"
}

@test "tryout exec rejects an unknown site" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev tryout exec nosuchsite true
  assert_failure
  assert_output --partial "No served site"
}

@test "worktree list reports no worktrees before Core is cloned" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev tryout worktree list
  assert_failure
  assert_output --partial "TYPO3 Core not found"
}

# ─────────────────────────────────────────────────────────────────────
# Removal
# ─────────────────────────────────────────────────────────────────────

@test "removal takes every installed file back out" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  run ddev add-on remove tryout
  assert_success
  # Every shipped file carries a marker, so nothing should be refused.
  refute_output --partial "Unwilling to remove"

  assert_dir_not_exist "${TESTDIR}/.ddev/tryout"
  assert_file_not_exist "${TESTDIR}/.ddev/commands/host/tryout"
  assert_file_not_exist "${TESTDIR}/.ddev/commands/host/autocomplete/tryout"
  assert_file_not_exist "${TESTDIR}/.ddev/config.tryout.yaml"
  assert_file_not_exist "${TESTDIR}/.ddev/config.tryout-patches.yaml"
  assert_file_not_exist "${TESTDIR}/.ddev/web-build/Dockerfile.tryout"
  assert_file_not_exist "${TESTDIR}/.ddev/tryout/.version"
  assert_file_not_exist "${TESTDIR}/composer.tryout.json"
  assert_file_not_exist "${TESTDIR}/composer.tryout.lock"
  assert_file_not_exist "${TESTDIR}/config/system/additional.php"
  assert_file_not_exist "${TESTDIR}/.gitignore"

  # The project's own config is untouched.
  assert_file_exist "${TESTDIR}/.ddev/config.yaml"

  run ddev add-on list --installed
  assert_success
  refute_output --partial "tryout"
}

@test "removal keeps files the user took ownership of" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  sed -i.bak '/ddev-generated/d' "${TESTDIR}/composer.tryout.json"
  sed -i.bak 's/#ddev-generated/#user-owned/' "${TESTDIR}/config/system/additional.php"

  run ddev add-on remove tryout
  assert_success
  assert_file_exist "${TESTDIR}/composer.tryout.json"
  assert_file_exist "${TESTDIR}/config/system/additional.php"
}

@test "an edited patch list survives an update and a removal" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  sed -i.bak 's/TRYOUT_PATCHES=$/TRYOUT_PATCHES=95606/' "${TESTDIR}/.ddev/config.tryout-patches.yaml"

  # Updating must neither overwrite it nor complain that it cannot.
  run ddev add-on get "${DIR}"
  assert_success
  refute_output --partial "NOT overwriting"
  run grep -q 'TRYOUT_PATCHES=95606' "${TESTDIR}/.ddev/config.tryout-patches.yaml"
  assert_success

  run ddev add-on remove tryout
  assert_success
  refute_output --partial "Unwilling to remove"
  assert_file_exist "${TESTDIR}/.ddev/config.tryout-patches.yaml"
  run grep -q 'TRYOUT_PATCHES=95606' "${TESTDIR}/.ddev/config.tryout-patches.yaml"
  assert_success
}

@test "the add-on can be reinstalled after removal" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev add-on remove tryout
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y --skip-hooks
  assert_success
  health_checks
}
