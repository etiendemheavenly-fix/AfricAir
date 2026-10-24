#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; logger -t africair-health -p user.err "health check script failed at line $LINENO (exit $status)"; exit "$status"' ERR

state_dir=/var/lib/africair
state_file="$state_dir/health-failures"
health_url=${AFRICAIR_HEALTH_URL:-http://127.0.0.1/healthz}

if [[ $EUID -ne 0 ]]; then
  logger -t africair-health -p user.err 'health check must run as root'
  exit 1
fi
install -d -o root -g root -m 0750 "$state_dir"

if curl --fail --silent --show-error --max-time 5 "$health_url" >/dev/null; then
  if [[ -f $state_file ]] && [[ $(<"$state_file") != 0 ]]; then
    printf '0\n' >"$state_file.tmp"
    chmod 0640 "$state_file.tmp"
    mv -f -- "$state_file.tmp" "$state_file"
  fi
  logger -t africair-health -p user.info "health check passed: $health_url"
  exit 0
fi

failures=0
if [[ -f $state_file ]]; then
  read -r failures <"$state_file" || failures=0
fi
[[ $failures =~ ^[0-9]+$ ]] || failures=0
failures=$((failures + 1))
printf '%s\n' "$failures" >"$state_file.tmp"
chmod 0640 "$state_file.tmp"
mv -f -- "$state_file.tmp" "$state_file"
logger -t africair-health -p user.err "health check failed ($failures consecutive failures): $health_url"

if [[ $failures -eq 3 ]]; then
  if nginx -t && systemctl reload nginx; then
    logger -t africair-health -p user.warning 'WARNING: three consecutive failures; nginx configuration checked and nginx reloaded'
  else
    logger -t africair-health -p user.warning 'WARNING: three consecutive failures; nginx reload failed'
  fi
fi
