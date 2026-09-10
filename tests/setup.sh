#!/usr/bin/env bash

# Shared setup for every tryout test file. Loaded from a `setup()`:
#   setup() { load setup.sh; }
#
# Creates a throwaway DDEV project in ~/tmp and leaves the shell inside it, with
# the add-on NOT yet installed — each test installs it the way it wants to.

bats_require_minimum_version 1.8.0

set -eu -o pipefail

# Override this variable for your add-on:
export GITHUB_REPO=bmack/tryout

TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
bats_load_library bats-assert
bats_load_library bats-file
bats_load_library bats-support

export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
export PROJNAME="test-$(basename "${GITHUB_REPO}")"
mkdir -p "${HOME}/tmp"
export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
export DDEV_NONINTERACTIVE=true
export DDEV_NO_INSTRUMENTATION=true
ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
cd "${TESTDIR}"

# tryout drives TYPO3, so the project type and docroot are fixed. PHP is pinned so
# the assertions below do not drift with the DDEV default.
run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site \
  --project-type=typo3 --docroot=public --php-version=8.5
assert_success
