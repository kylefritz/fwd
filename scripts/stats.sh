#!/bin/sh
# How many people use fwd.
#
# Downloads come from GitHub's count for each release's fwd.zip, which
# includes self-updates. Installs come from the ping each update check sends
# to the stats server (worker/), stored in the fwd_pings Analytics Engine
# dataset: blob1 install ID, blob2 version, blob3 channel, blob4 kind
# (release, homebrew, source), blob5 macOS, blob6 country, blob7 IP.
# The install ID "test" is the check ping sent when the Worker was deployed.
#
# The Cloudflare token needs "Account Analytics Read". It's read from
# CLOUDFLARE_API_TOKEN (set in the repo's .envrc), or else from the macOS
# keychain item "fwd-stats":
#   security add-generic-password -a "$USER" -s fwd-stats -w
set -eu

# The repo's git-ignored .envrc holds the token; hooks don't run direnv.
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -f .envrc ]; then . ./.envrc; fi
ACCOUNT="${CLOUDFLARE_ACCOUNT_ID:-d945de32e870f58f386eb588413a9960}"
TOKEN="${CLOUDFLARE_API_TOKEN:-$(security find-generic-password -s fwd-stats -w 2>/dev/null || true)}"

echo "Downloads of fwd.zip (GitHub; includes self-updates)"
gh api "repos/kylefritz/fwd/releases?per_page=100" --paginate \
  --jq '.[] | [.tag_name, ((.assets[] | select(.name == "fwd.zip") | .download_count) // 0)] | @tsv' \
  | awk -F'\t' '{ printf "  %-22s %6d\n", $1, $2; total += $2 } END { printf "  %-22s %6d\n", "total", total }'

if [ -z "$TOKEN" ]; then
  echo
  echo "No Cloudflare token: set CLOUDFLARE_API_TOKEN or add the keychain item"
  echo "  security add-generic-password -a \"\$USER\" -s fwd-stats -w"
  exit 0
fi

query() {
  curl -fsS "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/analytics_engine/sql" \
    -H "Authorization: Bearer $TOKEN" --data "$1 FORMAT JSONEachRow"
}

echo
echo "Installs (from update-check pings; Analytics Engine keeps 3 months)"
query "SELECT count(DISTINCT blob1) AS installs, count(DISTINCT blob7) AS ips,
         count(DISTINCT blob6) AS countries, SUM(_sample_interval) AS pings,
         min(timestamp) AS first, max(timestamp) AS last
       FROM fwd_pings WHERE blob1 NOT IN ('', 'test')" \
  | jq -r '"  \(.installs) unique installs from \(.ips) IPs in \(.countries) countries; \(.pings) pings, \(.first) to \(.last)"'

echo
echo "Active installs by day (last 14 days)"
query "SELECT toDate(timestamp) AS day, count(DISTINCT blob1) AS installs
       FROM fwd_pings WHERE blob1 != 'test' AND timestamp > NOW() - INTERVAL '14' DAY
       GROUP BY day ORDER BY day" \
  | jq -r '"  \(.day)  \(.installs)"'

echo
echo "Last 7 days, by version, channel and install type"
query "SELECT blob2 AS version, blob3 AS channel, blob4 AS kind, count(DISTINCT blob1) AS installs
       FROM fwd_pings WHERE blob1 != 'test' AND timestamp > NOW() - INTERVAL '7' DAY
       GROUP BY version, channel, kind ORDER BY installs DESC" \
  | jq -r '"  \(.installs)  \(.version)  \(.channel)  \(.kind)"'

echo
echo "Last 30 days, by country and macOS"
query "SELECT blob6 AS country, count(DISTINCT blob1) AS installs
       FROM fwd_pings WHERE blob1 != 'test' AND timestamp > NOW() - INTERVAL '30' DAY
       GROUP BY country ORDER BY installs DESC LIMIT 10" \
  | jq -r '"  \(.installs)  \(if .country == "" then "?" else .country end)"'
query "SELECT blob5 AS macos, count(DISTINCT blob1) AS installs
       FROM fwd_pings WHERE blob1 != 'test' AND timestamp > NOW() - INTERVAL '30' DAY
       GROUP BY macos ORDER BY installs DESC LIMIT 5" \
  | jq -r '"  \(.installs)  macOS \(.macos)"'
