#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/ops/deploy.sh <frontend-artifact.tar.gz> [api-artifact.tar.gz]

Verifies each adjacent .sha256 file, unpacks releases under /opt/africair,
atomically switches the current symlink, validates nginx and the deployed
commit, and restores the previous release if validation fails.

An API artifact is optional. If supplied, it must have the same commit as the
frontend artifact and the africair-api.service must already be configured.
EOF
}

trap 'status=$?; printf "deploy: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  printf 'deploy: run as root\n' >&2
  exit 1
fi

for tool in tar sha256sum jq curl nginx systemctl flock; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'deploy: missing command: %s\n' "$tool" >&2; exit 2; }
done

exec 9>/run/lock/africair-deploy.lock
if ! flock -n 9; then
  printf 'deploy: another deployment or rollback is already running\n' >&2
  exit 1
fi

web_artifact=$(readlink -f -- "$1")
api_artifact=
if [[ $# -eq 2 ]]; then
  api_artifact=$(readlink -f -- "$2")
fi

verify_checksum() {
  local artifact=$1 checksum="${1}.sha256"
  [[ -f $artifact && -f $checksum ]] || {
    printf 'deploy: artifact or checksum is missing: %s\n' "$artifact" >&2
    return 1
  }
  (cd -- "$(dirname -- "$artifact")" && sha256sum --check --status "$(basename -- "$checksum")")
}

validate_archive() {
  local artifact=$1 expected_root=$2
  tar -tzf "$artifact" | awk -v root="$expected_root" '
    /^\// || /(^|\/)\.\.(\/|$)/ { exit 1 }
    {
      path=$0
      sub(/\/$/, "", path)
      if (root == "server" && path == "build.json") next
      if (path != root && index(path, root "/") != 1) exit 1
    }
  '
}

verify_checksum "$web_artifact" || { printf 'deploy: frontend checksum verification failed\n' >&2; exit 1; }
validate_archive "$web_artifact" dist || { printf 'deploy: unsafe or invalid frontend archive\n' >&2; exit 1; }
commit=$(tar -xOf "$web_artifact" dist/version.json | jq -er '.commit')
[[ $commit =~ ^[0-9a-fA-F]{7,40}$ ]] || { printf 'deploy: invalid commit in frontend version.json\n' >&2; exit 1; }

if [[ -n $api_artifact ]]; then
  verify_checksum "$api_artifact" || { printf 'deploy: API checksum verification failed\n' >&2; exit 1; }
  validate_archive "$api_artifact" server || { printf 'deploy: unsafe or invalid API archive\n' >&2; exit 1; }
  api_commit=$(tar -xOf "$api_artifact" build.json | jq -er '.commit')
  [[ $api_commit == "$commit" ]] || { printf 'deploy: API and frontend commits do not match\n' >&2; exit 1; }
fi

root=/opt/africair
web_releases="$root/releases"
current="$root/current"
previous="$root/previous"
release_id="$(date -u +'%Y%m%dT%H%M%S%NZ')-${commit:0:12}"
release="$web_releases/$release_id"
old_release=
old_previous=
if [[ -L $current ]]; then
  old_release=$(readlink -f -- "$current")
  [[ -d $old_release && $old_release == "$web_releases/"* ]] || {
    printf 'deploy: current link does not point to a valid AfricAir release\n' >&2
    exit 1
  }
fi
if [[ -L $previous ]]; then
  old_previous=$(readlink -f -- "$previous")
fi
api_current="$root/api/current"
api_previous="$root/api/previous"
api_release=
old_api_release=
old_api_previous=
web_switched=0
api_switched=0
api_previous_changed=0
web_previous_changed=0

atomic_link() {
  local target=$1 link=$2 temp="${2}.tmp.$$"
  rm -f -- "$temp"
  ln -s -- "$target" "$temp"
  mv -Tf -- "$temp" "$link"
}

restore_links() {
  trap - ERR
  if ((api_switched)); then
    if [[ -n $old_api_release ]]; then
      atomic_link "$old_api_release" "$api_current"
    else
      rm -f -- "$api_current"
    fi
  fi
  if ((api_previous_changed)); then
    if [[ -n $old_api_previous ]]; then
      atomic_link "$old_api_previous" "$api_previous"
    else
      rm -f -- "$api_previous"
    fi
  fi
  if ((api_switched)); then
    systemctl restart africair-api.service || true
  fi
  if ((web_switched)); then
    if [[ -n $old_release ]]; then
      atomic_link "$old_release" "$current"
    else
      rm -f -- "$current"
    fi
  fi
  if ((web_previous_changed)); then
    if [[ -n $old_previous ]]; then
      atomic_link "$old_previous" "$previous"
    else
      rm -f -- "$previous"
    fi
  fi
  if ((web_switched)); then
    if nginx -t; then
      systemctl reload nginx || true
    fi
  fi
}

on_error() {
  local status=$?
  printf 'deploy: validation failed; restoring the previous release\n' >&2
  restore_links
  exit "$status"
}
trap on_error ERR

mkdir -p -- "$web_releases"
install -d -o africair -g africair -m 0755 "$release"
tar -xzf "$web_artifact" --strip-components=1 -C "$release"
chown -R africair:africair "$release"

if [[ -n $api_artifact ]]; then
  api_releases="$root/api/releases"
  api_release="$api_releases/$release_id"
  mkdir -p -- "$api_releases"
  install -d -o africair -g africair -m 0755 "$api_release"
  tar -xzf "$api_artifact" -C "$api_release"
  chown -R africair:africair "$api_release"
  if [[ -L $api_current ]]; then
    old_api_release=$(readlink -f -- "$api_current")
    [[ -d $old_api_release && $old_api_release == "$root/api/releases/"* ]] || {
      printf 'deploy: API current link does not point to a valid API release\n' >&2
      exit 1
    }
  fi
  if [[ -L $api_previous ]]; then
    old_api_previous=$(readlink -f -- "$api_previous")
  fi
  if [[ -n $old_api_release ]]; then
    atomic_link "$old_api_release" "$api_previous"
    api_previous_changed=1
  fi
  atomic_link "$api_release" "$api_current"
  api_switched=1
  systemctl restart africair-api.service
fi

if [[ -n $old_release ]]; then
  atomic_link "$old_release" "$previous"
  web_previous_changed=1
fi
atomic_link "$release" "$current"
web_switched=1

nginx -t
systemctl reload nginx

healthy=0
for attempt in {1..10}; do
  health_body=$(curl --fail --silent --show-error --max-time 5 http://127.0.0.1/healthz) || health_body=
  if [[ $health_body == ok ]]; then
    deployed_commit=$(curl --fail --silent --show-error --max-time 5 http://127.0.0.1/version.json | jq -er '.commit')
    if [[ ${deployed_commit,,} == ${commit,,} ]]; then
      healthy=1
      break
    fi
  fi
  sleep 2
done
if ((!healthy)); then
  printf 'deploy: health check or deployed commit did not match %s\n' "$commit" >&2
  false
fi

trap - ERR

prune_releases() {
  local release_dir=$1 active_link=$2 previous_link=$3
  local active_target= previous_target
  local index candidate
  if [[ -L $active_link ]]; then
    active_target=$(readlink -f -- "$active_link")
  fi
  if [[ -L $previous_link ]]; then
    previous_target=$(readlink -f -- "$previous_link")
  fi
  mapfile -t names < <(find "$release_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  for ((index=5; index<${#names[@]}; index++)); do
    candidate="$release_dir/${names[index]}"
    if [[ $candidate != "$active_target" && $candidate != "$previous_target" ]]; then
      rm -rf -- "$candidate"
    fi
  done
}
prune_releases "$web_releases" "$current" "$previous"
if [[ -n $api_artifact ]]; then
  prune_releases "$root/api/releases" "$api_current" "$api_previous"
fi

printf 'deploy: active release %s (%s)\n' "$release_id" "$commit"
