#!/usr/bin/env bash
# Publishes an image to the registry from an OCI image layout (README.md, "Publishing from CI"):
# every blob to R2 first, the version tag in KV last, so a tag never points to something missing.
#
#   scripts/publish-image.sh [--remote] OCI_DIR REPO VERSION
#   skopeo copy containers-storage:localhost/nyra:2026.10.3 oci:out:2026.10.3
#   scripts/publish-image.sh --remote out nyra 2026.10.3     # --remote: the real R2 and KV (CI only)
#
# Remote: the `aws` CLI (preinstalled on ubuntu-24.04 runners) against the R2 S3 endpoint, with
# R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY (a token that can only write nyra-images) for the
# blobs, and CLOUDFLARE_API_TOKEN (read by wrangler) for the KV tag. Without --remote it writes the
# local wrangler state, like seed-local.sh; LOCAL_STATE_DIR=<dir> keeps that state elsewhere (tests).
#
# Nothing is uploaded unless the whole layout is consistent. Existing blobs are never overwritten.
# The channels/<repo>/releases.json line is printed, not written: a human or a PR adds it.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "publish-image: $*" >&2; exit 1; }
remote=false
if [ "${1:-}" = --remote ]; then remote=true; shift; fi
[ $# -eq 3 ] || die "usage: publish-image.sh [--remote] OCI_DIR REPO VERSION"
layout="$1" repo="$2" version="$3"
[[ "$repo" =~ ^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*$ ]] || die "invalid repository: $repo"
# The same rule as `version` in sheet-rules.jq, so releases.json accepts it.
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "invalid version: $version"
blobs="$layout/blobs/sha256"
[ -d "$blobs" ] || die "no $blobs: not an OCI image layout"

# --- Check the layout, before anything leaves this machine ------------------------------------
for f in "$blobs"/*; do
  [ -f "$f" ] || die "no blobs in $blobs"
  hex=$(basename "$f")
  [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || die "not a sha256 file name: $hex"
  [ "$(sha256sum <"$f" | cut -d' ' -f1)" = "$hex" ] || die "blob $hex does not match its digest"
done
[ "$(jq '.manifests | length' "$layout/index.json")" = 1 ] || die "index.json must list exactly one manifest"
manifest=$(jq -r '.manifests[0].digest' "$layout/index.json")
[[ "$manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid manifest digest: $manifest"
# Each descriptor is "<digest> <size>": the config and the layers (a missing one prints "null").
descriptors=$(jq -er '.config, .layers[] | "\(.digest) \(.size)"' "$blobs/${manifest#sha256:}") ||
  die "$manifest is not an image manifest"
while read -r digest size; do
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid digest in the manifest: $digest"
  file="$blobs/${digest#sha256:}"
  [ -f "$file" ] || die "missing blob $digest"
  [ "$(stat -c %s "$file")" = "$size" ] || die "blob $digest is not $size bytes"
done <<<"$descriptors"

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
  wrangler="npx wrangler --env local"
  persist=()
  [ -z "${LOCAL_STATE_DIR:-}" ] || persist=(--persist-to "$LOCAL_STATE_DIR")
  size_of() { $wrangler r2 object get "nyra-images/$1" --local "${persist[@]}" --pipe 2>/dev/null | wc -c | grep -vx 0; }
  put() { $wrangler r2 object put "nyra-images/$1" --local "${persist[@]}" --cache-control "$cache" --file "$2" >/dev/null; }
  kv_target="--env local --local ${persist[*]}"
fi

uploaded=0 skipped=0
for f in "$blobs"/*; do
  key="blobs/sha256/$(basename "$f")"
  # Content-addressed: an existing key already holds the same bytes.
  if size_of "$key" >/dev/null; then skipped=$((skipped + 1)); continue; fi
  put "$key" "$f"
  uploaded=$((uploaded + 1))
done
echo "blobs: $uploaded uploaded, $skipped already present"

# The tag is written only when every object is there with the right size.
for f in "$blobs"/*; do
  [ "$(size_of "blobs/sha256/$(basename "$f")")" = "$(stat -c %s "$f")" ] || die "$(basename "$f") is not in R2 with the right size"
done

# shellcheck disable=SC2086 # kv_target is several words on purpose
npx wrangler kv key put "tag/$repo/$version" "{\"digest\":\"$manifest\"}" --binding TAGS $kv_target >/dev/null
echo "tag $repo:$version -> $manifest"
echo "add to channels/$repo/releases.json:  \"$version\": \"$manifest\""
