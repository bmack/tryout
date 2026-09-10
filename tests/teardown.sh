#!/usr/bin/env bash

# Shared teardown. Loaded from a `teardown()`:
#   teardown() { load teardown.sh; }

set -eu -o pipefail

ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
# Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
# See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
if [ -n "${GITHUB_ENV:-}" ]; then
  [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
else
  [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
fi
