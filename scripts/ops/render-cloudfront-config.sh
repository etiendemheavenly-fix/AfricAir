#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/ops/render-cloudfront-config.sh <api-origin-domain> <output-file>

Render the CloudFront distribution config with the origin-auth token fetched
from SSM Parameter Store. The output file contains a secret; keep it private
and outside the repository, and remove it after using it with the AWS CLI.
EOF
}

fail() {
  printf 'render-cloudfront-config: %s\n' "$1" >&2
  exit 1
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}

for tool in aws jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

api_origin_domain=$1
output_file=$2
[[ $api_origin_domain =~ ^[A-Za-z0-9.-]+$ ]] || fail 'invalid API origin domain'

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
template="$repo_root/deploy/cloudfront-distribution-config.json"
[[ -f $template ]] || fail "distribution template not found: $template"

output_dir=$(dirname -- "$output_file")
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
output_file="$output_dir/$(basename -- "$output_file")"
case "$output_file" in
  "$repo_root"/*) fail 'output must be outside the repository because it contains a secret' ;;
esac
[[ ! -e $output_file ]] || fail 'output file already exists; choose a new path'

origin_token=$(MSYS_NO_PATHCONV=1 aws ssm get-parameter \
  --name /africair/demo/origin-header \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value \
  --output text) || fail 'could not read the origin-auth token from SSM'
[[ $origin_token =~ ^[A-Za-z0-9_-]{43}$ ]] || fail 'origin-auth token is missing or invalid'

windows_acl=0
windows_user=
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    for tool in icacls.exe whoami.exe; do
      command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
    done
    windows_user=$(whoami.exe | tr -d '\r') || fail 'could not determine the Windows user'
    [[ -n $windows_user ]] || fail 'could not determine the Windows user'
    windows_acl=1
    ;;
esac

restrict_windows_acl() {
  local path=$1 grants=$2
  icacls.exe "$path" /inheritance:r /grant:r \
    "${windows_user}:${grants}" \
    "*S-1-5-18:${grants}" \
    "*S-1-5-32-544:${grants}" >/dev/null
}

umask 077
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/africair-cloudfront.XXXXXXXX")
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT
if (( windows_acl )) && ! restrict_windows_acl "$temp_dir" '(OI)(CI)F'; then
  rm -rf -- "$temp_dir" || fail 'could not restrict the temporary directory ACL or remove its secret'
  fail 'could not restrict the temporary directory ACL'
fi
printf '%s' "$origin_token" >"$temp_dir/origin-token"
unset origin_token

jq \
  --arg apiOriginDomain "$api_origin_domain" \
  --rawfile originToken "$temp_dir/origin-token" \
  '.Origins.Items |= map(
    if .Id == "AfricAirApiOrigin" then
      .DomainName = $apiOriginDomain |
      .CustomHeaders.Items[0].HeaderValue = $originToken
    else .
    end
  )' \
  "$template" >"$temp_dir/distribution-config.json"

jq -e '
  .Origins.Items | any(.Id == "AfricAirApiOrigin" and
    .CustomHeaders.Items[0].HeaderValue != "RENDER_FROM_SSM_PARAMETER")
' "$temp_dir/distribution-config.json" >/dev/null ||
  fail 'rendered config did not contain the API origin and secret header'

install -m 0600 "$temp_dir/distribution-config.json" "$output_file"
if (( windows_acl )) && ! restrict_windows_acl "$output_file" 'F'; then
  rm -f -- "$output_file" || fail "could not restrict output permissions or remove the secret-bearing file: $output_file"
  fail 'could not restrict Windows permissions on the output file'
fi
printf 'render-cloudfront-config: wrote private config to %s\n' "$output_file"
