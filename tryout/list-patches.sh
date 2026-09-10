#!/usr/bin/env bash
#ddev-generated

# Runs inside the web container, where curl/jq are always available.
# Usage: list-patches.sh <gerrit-api-base> <branch> [<limit>] [<extra-query>]
#
# Prints one open change per line, newest first, as four TAB-separated fields:
#   number <TAB> subject <TAB> owner <TAB> scores
# Exit 2 = fetch failed, 3 = parse failed — the same contract as
# resolve-patch-ref.sh, so the callers branch on it in one place.

set -euo pipefail

api="$1"
branch="${2:-main}"
limit="${3:-50}"
extra="${4:-}"

# A branch of "-" means every branch: the same list without the branch filter.
query="project:Packages/TYPO3.CMS+status:open"
[ "${branch}" = "-" ] || query="${query}+branch:${branch}"
[ -n "${extra}" ] && query="${query}+${extra}"

# LABELS gives the review state, DETAILED_ACCOUNTS the owner's name (without it
# Gerrit returns only an account id, which says nothing to a human).
response=$(curl -sf "${api}/changes/?q=${query}&n=${limit}&o=LABELS&o=DETAILED_ACCOUNTS") || exit 2

# Strip the Gerrit XSSI prefix )]}'
json=$(echo "${response}" | tail -n +2)

# A response that is not Gerrit JSON loses its only line here, and jq accepts
# empty input without complaint — so an unparseable answer would look like "no
# open changes". Catch it before that.
[ -n "${json}" ] || exit 3
echo "${json}" | jq -e . >/dev/null 2>&1 || exit 3

echo "${json}" | jq -r '
    # "label" is a jq keyword, hence the name.
    def score($which):
        (.labels[$which] // {}) as $l
        | if   $l.approved then "+2"
          elif $l.rejected then "-2"
          elif ($l.value // 0) > 0 then "+1"
          elif ($l.value // 0) < 0 then "-1"
          else "" end;

    .[]
    | (._number | tostring) as $n
    # One line, no tabs: both would break the field separator below.
    # Truncate with "...", not "…": bash pads with printf %-Ns, which counts
    # BYTES, and a three-byte ellipsis in a 68-character subject leaves the
    # column two short — every truncated row then runs into the owner beside it.
    | ((.subject // "no subject") | gsub("[\n\t]"; " ")
        | if (. | length) > 68 then (.[0:65] + "...") else . end) as $s
    | (if .work_in_progress then "WIP " else "" end) as $wip
    | ((.owner.name // "?") | gsub("[\n\t]"; " ")) as $o
    | ([ (score("Code-Review") | if . == "" then empty else "CR" + . end),
         (score("Verified")    | if . == "" then empty else "V"  + . end) ]
       | join(" ")) as $sc
    | [$n, ($wip + $s), $o, $sc] | @tsv
' || exit 3
