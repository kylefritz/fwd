#!/bin/sh
# How many people use fwd.
#
# Downloads come from GitHub's count for each release's fwd.zip, which
# includes self-updates. Active installs come from the ping each update check sends to the stats server
# (worker/), and need CLOUDFLARE_ACCOUNT_ID and a CLOUDFLARE_API_TOKEN with
# "Account Analytics Read".
set -eu

echo "Downloads of fwd.zip by release"
gh api "repos/kylefritz/fwd/releases?per_page=100" --paginate \
  --jq '.[] | [.tag_name, ((.assets[] | select(.name == "fwd.zip") | .download_count) // 0)] | @tsv' \
  | awk -F'\t' '{ printf "  %-22s %6d\n", $1, $2; total += $2 } END { printf "  %-22s %6d\n", "total", total }'

if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ] || [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo
  echo "Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN to see active installs."
  exit 0
fi

query() {
  curl -fsS "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/analytics_engine/sql" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" --data "$1 FORMAT JSONEachRow"
}

echo
echo "Installs that checked for updates, by day (last 14 days)"
query "SELECT toDate(timestamp) AS day, count(DISTINCT blob1) AS installs, count(DISTINCT blob7) AS ips
       FROM fwd_pings WHERE timestamp > NOW() - INTERVAL '14' DAY
       GROUP BY day ORDER BY day" \
  | jq -r '"  \(.day)  \(.installs) installs, \(.ips) IPs"'

echo
echo "Installs by version and channel (last 7 days)"
query "SELECT blob2 AS version, blob3 AS channel, count(DISTINCT blob1) AS installs
       FROM fwd_pings WHERE timestamp > NOW() - INTERVAL '7' DAY
       GROUP BY version, channel ORDER BY installs DESC" \
  | jq -r '"  \(.version) (\(.channel)): \(.installs)"'
