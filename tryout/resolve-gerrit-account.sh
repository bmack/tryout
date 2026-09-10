#!/usr/bin/env bash
#ddev-generated

# Runs inside the web container, where curl/jq are always available.
# Usage: resolve-gerrit-account.sh <gerrit-api-base> <query>
# Prints account id/email/name on a single match. Exit 2 = fetch failed, 3 = not exactly one match.

set -euo pipefail

api_base="$1"
query="$2"

response=$(curl -sf -G "${api_base}/accounts/" \
    --data-urlencode "q=${query}" \
    --data-urlencode "o=DETAILS") || exit 2

# Strip the Gerrit XSSI prefix )]}'
json=$(echo "${response}" | tail -n +2)

[ "$(echo "${json}" | jq -r 'length' 2>/dev/null)" = "1" ] || exit 3

echo "${json}" | jq -r '
    (.[0]._account_id | tostring),
    (.[0].email // ""),
    (.[0].name // "")
' || exit 3
