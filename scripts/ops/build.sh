#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "build: unexpected failure at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

usage() {
  cat <<'EOF'
Usage: ./scripts/ops/build.sh <git-ref>

Fetches the requested branch, tag or commit, runs the locked install, checks,
tests and frontend/API builds, then writes two checksummed artifacts to
ARTIFACT_DIR (default: <repository>/artifacts):
  africair-<short-sha>.tar.gz       static frontend
  africair-api-<short-sha>.tar.gz   API runtime and production dependencies

Exit codes:
  0   success
  2   invalid arguments or missing required tool
  10  repository clone, fetch or checkout failed
  20  frozen dependency installation failed
  30  TypeScript checks or tests failed
  40  frontend build, API build or artifact packaging failed

Set REPOSITORY_URL to override the current checkout's origin remote.
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 || -z $1 ]]; then
  usage >&2
  exit 2
fi

for tool in git pnpm node jq tar sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'build: required command not found: %s\n' "$tool" >&2
    exit 2
  fi
done

node_major=$(node -p 'process.versions.node.split(".")[0]')
if [[ $node_major != 22 ]]; then
  printf 'build: Node.js 22 is required; found %s\n' "$(node --version)" >&2
  exit 40
fi

git_ref=$1
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
if [[ -n ${REPOSITORY_URL:-} ]]; then
  repository_url=$REPOSITORY_URL
else
  repository_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null) || {
    printf 'build: no origin remote; set REPOSITORY_URL\n' >&2
    exit 10
  }
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/africair-build.XXXXXXXX")
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

if ! git clone --no-checkout "$repository_url" "$work_dir/source" ||
  ! git -C "$work_dir/source" fetch --depth=1 origin "$git_ref" ||
  ! git -C "$work_dir/source" checkout --detach FETCH_HEAD; then
  printf 'build: could not fetch or check out ref: %s\n' "$git_ref" >&2
  exit 10
fi

cd "$work_dir/source"
if ! pnpm install --frozen-lockfile; then
  printf 'build: frozen dependency installation failed\n' >&2
  exit 20
fi

if ! pnpm check || ! pnpm test; then
  printf 'build: TypeScript checks or tests failed\n' >&2
  exit 30
fi

if ! pnpm build || ! pnpm build:api; then
  printf 'build: frontend or API build failed\n' >&2
  exit 40
fi

commit=$(git rev-parse HEAD)
short_sha=$(git rev-parse --short=12 HEAD)
built_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
built_by=$(id -un)
node_version=$(node --version)

jq \
  --arg commit "$commit" \
  --arg ref "$git_ref" \
  --arg builtAt "$built_at" \
  --arg builtBy "$built_by" \
  --arg nodeVersion "$node_version" \
  '. + {commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion}' \
  dist/version.json >dist/version.json.tmp
mv dist/version.json.tmp dist/version.json

output_dir=${ARTIFACT_DIR:-"$repo_root/artifacts"}
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
api_stage="$work_dir/api-package"
mkdir -p "$api_stage"

if ! pnpm --filter @africair/api deploy --prod --legacy "$api_stage/server"; then
  printf 'build: could not create an isolated API production package\n' >&2
  exit 40
fi
mkdir -p "$api_stage/server/dist" "$api_stage/server/migrations"
cp -a server/dist/. "$api_stage/server/dist/"
cp -a server/migrations/. "$api_stage/server/migrations/"
jq -n --arg commit "$commit" --arg ref "$git_ref" \
  '{commit: $commit, ref: $ref}' >"$api_stage/build.json"

web_artifact="africair-${short_sha}.tar.gz"
api_artifact="africair-api-${short_sha}.tar.gz"
if ! tar -czf "$output_dir/$web_artifact.tmp" -C "$work_dir/source" dist ||
  ! tar -czf "$output_dir/$api_artifact.tmp" -C "$api_stage" server build.json; then
  printf 'build: artifact packaging failed\n' >&2
  exit 40
fi
mv "$output_dir/$web_artifact.tmp" "$output_dir/$web_artifact"
mv "$output_dir/$api_artifact.tmp" "$output_dir/$api_artifact"
(
  cd "$output_dir"
  sha256sum "$web_artifact" >"$web_artifact.sha256"
  sha256sum "$api_artifact" >"$api_artifact.sha256"
)

printf 'build: created %s and %s for commit %s\n' "$web_artifact" "$api_artifact" "$commit"
