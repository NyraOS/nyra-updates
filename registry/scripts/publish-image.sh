#!/usr/bin/env bash
# Publishes an image to the registry from an OCI image layout (README.md, "Publishing from CI"):
# every blob to R2 first, the version tag in KV last, so a tag never points to something missing.
#
#   scripts/publish-image.sh [--remote] OCI_DIR REPO TAG    # TAG: a version, or sha256-<hex>.sig
#   skopeo copy containers-storage:localhost/nyra-base:2026.10.3 oci:out:2026.10.3
#   scripts/publish-image.sh --remote out nyra-base 2026.10.3     # --remote: the real R2 and KV (CI only)
#
# Remote needs only bash, curl, jq and the `aws` CLI (preinstalled on ubuntu-24.04 runners): no Node,
# npm or wrangler next to the tokens. The blobs go through `aws` against the R2 S3 endpoint, with
# R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY (a token that can only write nyra-images); the KV tag
# goes through curl to the Cloudflare REST API, with CLOUDFLARE_KV_TOKEN. Each secret is handed
# only to the process that uses it and removed from the environment of everything else. Without
# --remote it writes the local wrangler state (no tokens), like seed-local.sh;
# LOCAL_STATE_DIR=<dir> keeps that state elsewhere (tests).
#
# TAG is exactly a version or the signature tag of an image, sha256-<64 lowercase hex>.sig (a cosign
# signature is a one-manifest OCI layout, published like an image). In remote mode a version is
# written only when the signature tag of its manifest already exists in KV and that signature
# manifest is in R2: the signature comes before the version tag.
#
# Nothing is uploaded unless the manifest, its config and its layers are all present and match their
# digests (nothing else in the layout is read or uploaded). Existing blobs are never overwritten and
# a released version is never re-pointed: the same digest is a no-op, another one is refused.
# The channels/<repo>/releases.json line is printed, not written: a human or a PR adds it.
set -euo pipefail
die() { echo "publish-image: $*" >&2; exit 1; }
remote=false
if [ "${1:-}" = --remote ]; then remote=true; shift; fi
[ $# -eq 3 ] || die "usage: publish-image.sh [--remote] OCI_DIR REPO TAG"
# Absolute before the cd below, or a relative OCI_DIR would point into registry/.
layout=$(realpath -- "$1") || die "no such directory: $1"
repo="$2" tagname="$3"
cd "$(dirname "$0")/.."
[[ "$repo" =~ ^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*)*$ ]] || die "invalid repository: $repo"
# The same rule as `version` in sheet-rules.jq, so releases.json accepts it.
version_re='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
sig_re='^sha256-[0-9a-f]{64}\.sig$'
[[ "$tagname" =~ $version_re || "$tagname" =~ $sig_re ]] || die "invalid tag (a version or sha256-<hex>.sig): $tagname"
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
# --- KV: kv_list PREFIX prints a JSON array of {name}; kv_get KEY; kv_put KEY VALUE ------------
cache="public, max-age=31536000, immutable"
if $remote; then
  # Plain shell variables, removed from the environment: a secret reaches only the process that uses it.
  r2_key_id="${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is not set}"
  r2_secret="${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is not set}"
  kv_token="${CLOUDFLARE_KV_TOKEN:?CLOUDFLARE_KV_TOKEN is not set}"
  unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CLOUDFLARE_KV_TOKEN
  [[ "$kv_token" =~ ^[A-Za-z0-9_-]+$ ]] || die "CLOUDFLARE_KV_TOKEN has unexpected characters"
  # The prefix assignments set the variables for this one command only, and not in its argv.
  # R2 does not support the additional checksums that aws-cli 2.23+ sends by default.
  aws_r2() {
    AWS_ACCESS_KEY_ID=$r2_key_id AWS_SECRET_ACCESS_KEY=$r2_secret AWS_DEFAULT_REGION=auto \
      AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
      aws "$@"; }
  endpoint=https://67094f0a1adf21bd1d8e27d2f213c3c8.r2.cloudflarestorage.com
  size_of() { aws_r2 s3api head-object --endpoint-url "$endpoint" --bucket nyra-images --key "$1" \
    --query ContentLength --output text 2>/dev/null; }
  put() { aws_r2 s3 cp --only-show-errors --endpoint-url "$endpoint" --cache-control "$cache" "$2" "s3://nyra-images/$1"; }

  # The IDs come from wrangler.toml, read strictly: exactly one top-level account_id, and the id
  # of the [[kv_namespaces]] block whose binding is TAGS (not the [env.*] ones).
  toml_ids=$(awk '
    /^\[/ { section = $0; binding = "" }
    section == "" && /^account_id = "[0-9a-f]{32}"$/ { print "account", $3 }
    section == "[[kv_namespaces]]" && /^binding = "TAGS"$/ { binding = "TAGS" }
    section == "[[kv_namespaces]]" && binding == "TAGS" && /^id = "[0-9a-f]{32}"$/ { print "kv", $3 }
  ' wrangler.toml | tr -d '"') || die "cannot read wrangler.toml"
  account_id=$(sed -n 's/^account //p' <<<"$toml_ids")
  kv_id=$(sed -n 's/^kv //p' <<<"$toml_ids")
  [[ "$account_id" =~ ^[0-9a-f]{32}$ && "$kv_id" =~ ^[0-9a-f]{32}$ ]] ||
    die "wrangler.toml: account_id or the TAGS namespace id is missing or not unique"
  kv_api="https://api.cloudflare.com/client/v4/accounts/$account_id/storage/kv/namespaces/$kv_id"
  # The token is a curl config on stdin (printf is a builtin): it is never in any argv.
  kv_curl() { printf 'header = "Authorization: Bearer %s"\n' "$kv_token" |
    curl -K - --silent --show-error --fail "$@"; }
  uri() { jq -rn --arg s "$1" '$s | @uri'; }
  kv_list() { kv_curl "$kv_api/keys?prefix=$(uri "$1")" | jq -e 'select(.success) | .result'; }
  kv_get() { kv_curl "$kv_api/values/$(uri "$1")"; }
  kv_put() { kv_curl -X PUT -H 'Content-Type: text/plain' --data-binary "$2" "$kv_api/values/$(uri "$1")" |
    jq -e '.success' >/dev/null; }
else
  wrangler="npx --no-install wrangler --env local"
  persist=()
  [ -z "${LOCAL_STATE_DIR:-}" ] || persist=(--persist-to "$LOCAL_STATE_DIR")
  size_of() { $wrangler r2 object get "nyra-images/$1" --local "${persist[@]}" --pipe 2>/dev/null | wc -c | grep -vx 0; }
  put() { $wrangler r2 object put "nyra-images/$1" --local "${persist[@]}" --cache-control "$cache" --file "$2" >/dev/null; }
  # --no-install: a missing `npm ci` must fail, never download wrangler.
  kv_list() { npx --no-install wrangler kv key list --prefix "$1" --binding TAGS --env local --local "${persist[@]}"; }
  kv_get() { npx --no-install wrangler kv key get "$1" --binding TAGS --env local --local "${persist[@]}"; }
  kv_put() { npx --no-install wrangler kv key put "$1" "$2" --binding TAGS --env local --local "${persist[@]}"; }
fi

# A released tag is never re-pointed. A list (unlike a get) succeeds with [] for an absent key,
# so an error here is a real failure and not mistaken for "absent".
tag="tag/$repo/$tagname"
existing=$(kv_list "$tag") || die "cannot read $tag"
current=$(jq -r --arg k "$tag" '.[] | select(.name == $k) | .name' <<<"$existing") || die "cannot read $tag"
if [ -n "$current" ]; then
  current=$(kv_get "$tag") || die "cannot read $tag"
  if [ "$(jq -r '.digest' <<<"$current")" = "$manifest" ]; then
    echo "tag $repo:$tagname already -> $manifest: nothing to do"
    exit 0
  fi
  die "$repo:$tagname is already released with another digest: refusing to re-point it"
fi

# Signature before version tag: the signature tag of this manifest must exist, and its manifest must be in R2.
if $remote && [[ "$tagname" =~ $version_re ]]; then
  sig_tag="tag/$repo/sha256-${manifest#sha256:}.sig"
  sig_listed=$(kv_list "$sig_tag") || die "cannot read $sig_tag"
  [ -n "$(jq -r --arg k "$sig_tag" '.[] | select(.name == $k) | .name' <<<"$sig_listed")" ] ||
    die "$repo:$tagname has no signature: $sig_tag is not published"
  sig_digest=$(kv_get "$sig_tag" | jq -er '.digest') || die "cannot read $sig_tag"
  [[ "$sig_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$sig_tag has an invalid digest"
  size_of "blobs/sha256/${sig_digest#sha256:}" >/dev/null || die "the signature manifest $sig_digest is not in R2"
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

kv_put "$tag" "{\"digest\":\"$manifest\"}" >/dev/null
echo "tag $repo:$tagname -> $manifest"
if [[ "$tagname" =~ $version_re ]]; then
  echo "add to channels/$repo/releases.json:  \"$tagname\": \"$manifest\""
fi
