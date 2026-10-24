#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "bootstrap: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/ops/bootstrap.sh

Prepare a fresh Ubuntu 24.04 host for AfricAir:
  - install Node.js 22 LTS, Corepack, nginx, git, ufw, jq and curl;
  - create the locked-down africair system user and release directories;
  - install nginx, logrotate and health-monitoring systemd configuration.

Run this on a new server, or inspect the script before applying it to an
existing host. It configures UFW to allow OpenSSH, HTTP and HTTPS only.
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  printf 'bootstrap: run as root (for example, sudo %s)\n' "$0" >&2
  exit 1
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
base_packages=(ca-certificates curl gnupg git nginx ufw jq postgresql)
missing_packages=()

for package in "${base_packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    missing_packages+=("$package")
  fi
done

node_major=0
if ((${#missing_packages[@]} > 0)); then
  apt-get update
  apt-get install -y "${missing_packages[@]}"
fi

if command -v node >/dev/null 2>&1; then
  node_major=$(node -p 'process.versions.node.split(".")[0]')
fi

if [[ $node_major -ne 22 ]]; then
  keyring=/usr/share/keyrings/nodesource.gpg
  source_file=/etc/apt/sources.list.d/nodesource.list
  if [[ ! -s $keyring ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
      gpg --dearmor --batch --yes -o "$keyring"
    chmod 0644 "$keyring"
  fi
  source_content='deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main'
  if [[ ! -f $source_file ]] || [[ $(<"$source_file") != "$source_content" ]]; then
    printf '%s\n' "$source_content" >"$source_file"
  fi
  apt-get update
  apt-get install -y nodejs
  node_major=$(node -p 'process.versions.node.split(".")[0]')
  if [[ $node_major -ne 22 ]]; then
    printf 'bootstrap: Node.js 22 was required, but apt installed major version %s\n' "$node_major" >&2
    exit 1
  fi
fi

if ! command -v corepack >/dev/null 2>&1; then
  npm install --global corepack
fi
corepack enable

if ! getent passwd africair >/dev/null; then
  useradd --system --home-dir /opt/africair --no-create-home --shell /usr/sbin/nologin africair
else
  if ! getent group africair >/dev/null; then
    printf 'bootstrap: existing africair user has no africair group; inspect the account before continuing\n' >&2
    exit 1
  fi
  existing_shell=$(getent passwd africair | cut -d: -f7)
  if [[ $existing_shell != /usr/sbin/nologin ]]; then
    usermod --shell /usr/sbin/nologin africair
  fi
fi

install -d -o africair -g africair -m 0755 \
  /opt/africair/releases \
  /opt/africair/shared \
  /opt/africair/api/releases
install -d -o root -g root -m 0750 /var/lib/africair
install -d -o root -g root -m 0755 /etc/africair

install_if_changed() {
  local source=$1 destination=$2 mode=$3 owner=$4 group=$5
  if [[ ! -f $destination ]] || ! cmp -s "$source" "$destination"; then
    install -o "$owner" -g "$group" -m "$mode" "$source" "$destination"
    config_changed=1
  fi
}

config_changed=0
install_if_changed "$repo_root/deploy/nginx/africair.conf" /etc/nginx/sites-available/africair 0644 root root
install_if_changed "$repo_root/deploy/nginx/security-headers.conf" /etc/nginx/snippets/africair-security-headers.conf 0644 root root
install_if_changed "$repo_root/deploy/logrotate/africair" /etc/logrotate.d/africair 0644 root root
install_if_changed "$repo_root/scripts/ops/healthcheck.sh" /opt/africair/shared/healthcheck.sh 0755 root root
install_if_changed "$repo_root/deploy/systemd/africair-health.service" /etc/systemd/system/africair-health.service 0644 root root
install_if_changed "$repo_root/deploy/systemd/africair-health.timer" /etc/systemd/system/africair-health.timer 0644 root root
install_if_changed "$repo_root/deploy/systemd/africair-api.service" /etc/systemd/system/africair-api.service 0644 root root

if [[ ! -L /etc/nginx/sites-enabled/africair ]] ||
  [[ $(readlink /etc/nginx/sites-enabled/africair) != /etc/nginx/sites-available/africair ]]; then
  ln -sfn /etc/nginx/sites-available/africair /etc/nginx/sites-enabled/africair
  config_changed=1
fi

if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  config_changed=1
fi

ufw status verbose | grep -q 'Default: deny (incoming)' || ufw default deny incoming
ufw status verbose | grep -q 'Default: allow (outgoing)' || ufw default allow outgoing
ufw status | grep -q 'OpenSSH.*ALLOW' || ufw allow OpenSSH
ufw status | grep -Eq '^80/tcp[[:space:]]+ALLOW' || ufw allow 80/tcp
ufw status | grep -Eq '^443/tcp[[:space:]]+ALLOW' || ufw allow 443/tcp
ufw status | grep -q '^Status: active' || ufw --force enable

if ((config_changed)); then
  nginx -t
  systemctl reload nginx 2>/dev/null || systemctl start nginx
  systemctl daemon-reload
fi

systemctl enable --now nginx
systemctl enable --now africair-health.timer

printf 'bootstrap: host setup complete; Node %s, nginx active, health timer enabled\n' "$(node --version)"
