#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: ./scripts/ops/report.sh [json-access-log]\n'
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

logfile=${1:-/var/log/nginx/africair.access.json}
[[ -r $logfile ]] || { printf 'report: cannot read log file: %s\n' "$logfile" >&2; exit 1; }

printf '%s\n' 'Top 10 client IPs'
jq -r '.remote_addr // "-"' "$logfile" |
  sort | uniq -c | sort -nr | awk 'NR <= 10 { print $2, $1 }'

printf '\n%s\n' 'Requests by status class'
jq -r '(.status | tostring | .[0:1]) + "xx"' "$logfile" |
  sort | uniq -c | sort -k2,2 | awk '{ print $2, $1 }'

printf '\n%s\n' 'Top 10 requested paths'
jq -r '(.request_uri // "-") | split("?")[0]' "$logfile" |
  sort | uniq -c | sort -nr | awk 'NR <= 10 { print $2, $1 }'

printf '\n%s\n' 'Requests per minute in the last hour'
jq -r 'select(.time_epoch? and ((.time_epoch | tonumber) >= (now - 3600))) | ((.time_epoch | tonumber) | strftime("%Y-%m-%dT%H:%M"))' "$logfile" |
  sort | uniq -c | sort -k2,2 | awk '{ print $2, $1 }'
