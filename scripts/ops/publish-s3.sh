#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <dist-dir> <bucket> <distribution-id>\n' "$0" >&2
  exit 2
}

fail() {
  printf 'publish-s3: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage
command -v aws >/dev/null 2>&1 || fail 'AWS CLI is required'

dist_dir=$1
bucket=$2
distribution_id=$3

[[ -d "$dist_dir" ]] || fail "dist directory not found: $dist_dir"
dist_dir=$(cd "$dist_dir" && pwd -P)
[[ -d "$dist_dir/assets" ]] || fail "assets directory not found in $dist_dir"
[[ -f "$dist_dir/index.html" ]] || fail "index.html not found in $dist_dir"
[[ -f "$dist_dir/version.json" ]] || fail "version.json not found in $dist_dir; run pnpm build first"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail 'invalid S3 bucket name'
[[ "$distribution_id" =~ ^[A-Z0-9]+$ ]] || fail 'invalid CloudFront distribution ID'

s3_uri="s3://${bucket}"
immutable_cache='public,max-age=31536000,immutable'
revalidate_cache='public,max-age=0,must-revalidate'

# Publish dependencies before the HTML that references them.
aws s3 sync "$dist_dir/assets/" "$s3_uri/assets/" --cache-control "$immutable_cache"
aws s3 sync "$dist_dir/" "$s3_uri/" \
  --exclude 'assets/*' \
  --exclude 'index.html' \
  --exclude 'version.json' \
  --cache-control "$revalidate_cache"
aws s3 cp "$dist_dir/index.html" "$s3_uri/index.html" --cache-control 'no-cache'
aws s3 cp "$dist_dir/version.json" "$s3_uri/version.json" --cache-control 'no-cache'

# Keep the previous release's hashed assets until the new HTML is live.
aws s3 sync "$dist_dir/assets/" "$s3_uri/assets/" --delete --cache-control "$immutable_cache"
aws s3 sync "$dist_dir/" "$s3_uri/" \
  --delete \
  --exclude 'assets/*' \
  --exclude 'index.html' \
  --exclude 'version.json' \
  --cache-control "$revalidate_cache"

MSYS_NO_PATHCONV=1 aws cloudfront create-invalidation \
  --distribution-id "$distribution_id" \
  --paths '/index.html' '/version.json'
