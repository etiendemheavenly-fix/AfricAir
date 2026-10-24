#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: sudo ./scripts/ops/rollback.sh\nSwitch the active AfricAir release to the previous release.\n'
}

trap 'status=$?; printf "rollback: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 || $EUID -ne 0 ]]; then
  usage >&2
  exit 2
fi

for tool in curl jq nginx systemctl flock; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'rollback: missing command: %s\n' "$tool" >&2; exit 2; }
done

exec 9>/run/lock/africair-deploy.lock
if ! flock -n 9; then
  printf 'rollback: another deployment or rollback is already running\n' >&2
  exit 1
fi

root=/opt/africair
current="$root/current"
previous="$root/previous"
[[ -L $current && -L $previous ]] || { printf 'rollback: current or previous release link is missing\n' >&2; exit 1; }

old_current=$(readlink -f -- "$current")
target=$(readlink -f -- "$previous")
[[ -d $old_current && $old_current == "$root/releases/"* ]] || { printf 'rollback: current link does not target a valid release\n' >&2; exit 1; }
[[ -d $target && $target == "$root/releases/"* ]] || { printf 'rollback: previous link does not target a valid release\n' >&2; exit 1; }
expected_commit=$(jq -er '.commit' "$target/version.json")

atomic_link() {
  local target_path=$1 link=$2 temp="${2}.tmp.$$"
  rm -f -- "$temp"
  ln -s -- "$target_path" "$temp"
  mv -Tf -- "$temp" "$link"
}

api_current="$root/api/current"
api_previous="$root/api/previous"
old_api=
old_api_previous=
target_api=
web_switched=0
api_switched=0
web_previous_changed=0
api_previous_changed=0

restore_links() {
  trap - ERR
  if ((web_switched)); then
    atomic_link "$old_current" "$current"
  fi
  if ((web_previous_changed)); then
    atomic_link "$target" "$previous"
  fi
  if ((api_switched)); then
    atomic_link "$old_api" "$api_current"
  fi
  if ((api_previous_changed)); then
    atomic_link "$old_api_previous" "$api_previous"
  fi
  if ((api_switched)); then
    systemctl restart africair-api.service || true
  fi
  if ((web_switched)) && nginx -t; then
    systemctl reload nginx || true
  fi
}

on_error() {
  local status=$?
  printf 'rollback: failed; restoring the releases that were active before this rollback\n' >&2
  restore_links
  exit "$status"
}
trap on_error ERR

if [[ -L $api_current && -L $api_previous ]]; then
  old_api=$(readlink -f -- "$api_current")
  old_api_previous=$(readlink -f -- "$api_previous")
  target_api=$old_api_previous
  [[ -d $old_api && $old_api == "$root/api/releases/"* ]] || { printf 'rollback: API current link does not target a valid release\n' >&2; false; }
  if [[ -d $target_api && $target_api == "$root/api/releases/"* ]]; then
    atomic_link "$old_api" "$api_previous"
    api_previous_changed=1
    atomic_link "$target_api" "$api_current"
    api_switched=1
    systemctl restart africair-api.service
  fi
fi

atomic_link "$old_current" "$previous"
web_previous_changed=1
atomic_link "$target" "$current"
web_switched=1
nginx -t
systemctl reload nginx
health_body=$(curl --fail --silent --show-error --max-time 5 http://127.0.0.1/healthz) || health_body=
[[ $health_body == ok ]] || { printf 'rollback: health check failed for previous release\n' >&2; false; }
deployed_commit=$(curl --fail --silent --show-error --max-time 5 http://127.0.0.1/version.json | jq -er '.commit')
[[ ${deployed_commit,,} == ${expected_commit,,} ]] || { printf 'rollback: served commit does not match previous release\n' >&2; false; }

trap - ERR

printf 'rollback: active release is %s\n' "$target"
