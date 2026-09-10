#!/usr/bin/env bash
#ddev-generated

# Runs inside the web container, where curl/jq are always available.
# Usage: resolve-patch-ref.sh <gerrit-api-change-url>
# Prints subject/ref/number/status on success. Exit 2 = fetch failed, 3 = parse failed.

set -euo pipefail

api_url="$1"

response=$(curl -sf "${api_url}") || exit 2

# Strip the Gerrit XSSI prefix )]}'
json=$(echo "${response}" | tail -n +2)

echo "${json}" | jq -r '
    .current_revision as $rev |
    .revisions[$rev] as $r |
    (.subject // "No subject" | gsub("\n"; " ") | ltrimstr(" ") | rtrimstr(" ")),
    $r.ref,
    ($r._number | tostring),
    (.status // "UNKNOWN")
' || exit 3
