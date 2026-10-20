#!/usr/bin/env bash
# Publishes an image to the registry from an OCI image layout (README.md, "Publishing from CI"):
# every blob to R2 first, the version tag in KV last, so a tag never points to something missing.
#
#   scripts/publish-image.sh [--remote] OCI_DIR REPO VERSION
#   skopeo copy containers-storage:localhost/nyra-base:2026.10.3 oci:out:2026.10.3
#   scripts/publish-image.sh --remote out nyra-base 2026.10.3     # --remote: the real R2 and KV (CI only)
#
# Remote: the `aws` CLI (preinstalled on ubuntu-24.04 runners) against the R2 S3 endpoint, with
# R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY (a token that can only write nyra-images) for the
# blobs, and CLOUDFLARE_API_TOKEN (read by wrangler) for the KV tag. Without --remote it writes the
# local wrangler state, like seed-local.sh; LOCAL_STATE_DIR=<dir> keeps that state elsewhere (tests).
#
# Nothing is uploaded unless the manifest, its config and its layers are all present and match their
# digests (nothing else in the layout is read or uploaded). Existing blobs are never overwritten and
# a released version is never re-pointed: the same digest is a no-op, another one is refused.
# The channels/<repo>/releases.json line is printed, not written: a human or a PR adds it.
set -euo pipefail
die() { echo "publish-image: $*" >&2; exit 1; }
remote=false
if [ "${1:-}" = --remote ]; then remote=true; shift; fi
[ $# -eq 3 ] || die "usage: publish-image.sh [--remote] OCI_DIR REPO VERSION"
# Absolute before the cd below, or a relative OCI_DIR would point into registry/.
layout=$(realpath -- "$1") || die "no such directory: $1"
repo="$2" version="$3"
cd "$(dirname "$0")/.."
[[ "$repo" =~ ^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*$ ]] || die "invalid repository: $repo"
# The same rule as `version` in sheet-rules.jq, so releases.json accepts it.
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "invalid version: $version"
blobs="$layout/blobs/sha256"
[ -d "$blobs" ] || die "no $blobs: not an OCI image layout"

# --- Check the layout, before anything leaves this machine ------------------------------------
# Regular files only: a symlink would let the upload read any file the runner can read.
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
[ ! -L "$layout/blobs" ] && [ ! -L "$blobs" ] || die "blobs must be real directories"
regular "$layout/index.json" || die "index.json is not a regular file"
[ "$(jq '.manifests | length' "$layout/index.json")" = 1 ] || die "index.json must list exactly one manifest"
manifest=$(jq -r '.manifests[0].digest' "$layout/index.json")
[[ "$manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid manifest digest: $manifest"

# check_blob DIGEST [SIZE]: a regular file, named by its digest, with the right content and size.
check_blob() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid digest: $1"
  local file="$blobs/${1#sha256:}"
  regular "$file" || die "missing blob $1 (or not a regular file)"
  [ "$(sha256sum <"$file" | cut -d' ' -f1)" = "${1#sha256:}" ] || die "blob $1 does not match its digest"
  [ -z "${2:-}" ] || [ "$(stat -c %s "$file")" = "$2" ] || die "blob $1 is not $2 bytes"
}
# Only what the manifest references is checked and uploaded: the manifest, its config and layers.
check_blob "$manifest"
# Each descriptor is "<digest> <size>" (a missing config or layers prints "null").
descriptors=$(jq -er '.config, .layers[] | "\(.digest) \(.size)"' "$blobs/${manifest#sha256:}") ||
  die "$manifest is not an image manifest"
keys=("blobs/sha256/${manifest#sha256:}")
while read -r digest size; do
  check_blob "$digest" "$size"
  keys+=("blobs/sha256/${digest#sha256:}")
done <<<"$descriptors"
mapfile -t keys < <(printf '%s\n' "${keys[@]}" | sort -u)

# --- R2: size_of KEY prints the size of an object, fails if it does not exist; put KEY FILE ----
cache="public, max-age=31536000, immutable"
if $remote; then
  export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is not set}"
  export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is not set}"
  export AWS_DEFAULT_REGION=auto
  # R2 does not support the additional checksums that aws-cli 2.23+ sends by default.
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  endpoint=https://67094f0a1adf21bd1d8e27d2f213c3c8.r2.cloudflarestorage.com
  size_of() { aws s3api head-object --endpoint-url "$endpoint" --bucket nyra-images --key "$1" \
    --query ContentLength --output text 2>/dev/null; }
  put() { aws s3 cp --only-show-errors --endpoint-url "$endpoint" --cache-control "$cache" "$2" "s3://nyra-images/$1"; }
  kv_target="--remote"
else
  wrangler="npx --no-install wrangler --env local"
  persist=()
  [ -z "${LOCAL_STATE_DIR:-}" ] || persist=(--persist-to "$LOCAL_STATE_DIR")
  size_of() { $wrangler r2 object get "nyra-images/$1" --local "${persist[@]}" --pipe 2>/dev/null | wc -c | grep -vx 0; }
  put() { $wrangler r2 object put "nyra-images/$1" --local "${persist[@]}" --cache-control "$cache" --file "$2" >/dev/null; }
  kv_target="--env local --local ${persist[*]}"
fi
# --no-install: a missing `npm ci` must fail, never download wrangler next to a token.
# shellcheck disable=SC2086 # kv_target is several words on purpose
wrangler_kv() {
  npx --no-install wrangler kv key "$@" --binding TAGS $kv_target; }

# A released version is never re-pointed. `list` (unlike `get`) succeeds with [] for an absent key,
# so an error here is a real failure and not mistaken for "absent".
tag="tag/$repo/$version"
existing=$(wrangler_kv list --prefix "$tag") || die "cannot read $tag"
current=$(jq -r --arg k "$tag" '.[] | select(.name == $k) | .name' <<<"$existing") || die "cannot read $tag"
if [ -n "$current" ]; then
  current=$(wrangler_kv get "$tag") || die "cannot read $tag"
  if [ "$(jq -r '.digest' <<<"$current")" = "$manifest" ]; then
    echo "tag $repo:$version already -> $manifest: nothing to do"
    exit 0
  fi
  die "$repo:$version is already released with another digest: refusing to re-point it"
fi

uploaded=0 skipped=0
for key in "${keys[@]}"; do
  # Content-addressed: an existing key already holds the same bytes.
  if size_of "$key" >/dev/null; then skipped=$((skipped + 1)); continue; fi
  put "$key" "$layout/$key"
  uploaded=$((uploaded + 1))
done
echo "blobs: $uploaded uploaded, $skipped already present"

# The tag is written only when every object is there with the right size.
for key in "${keys[@]}"; do
  [ "$(size_of "$key")" = "$(stat -c %s "$layout/$key")" ] || die "$key is not in R2 with the right size"
done

wrangler_kv put "$tag" "{\"digest\":\"$manifest\"}" >/dev/null
echo "tag $repo:$version -> $manifest"
echo "add to channels/$repo/releases.json:  \"$version\": \"$manifest\""
