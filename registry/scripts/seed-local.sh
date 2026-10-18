#!/usr/bin/env bash
# Seeds the LOCAL registry state (.wrangler/state, used by `npm run dev`) from an OCI image layout,
# the same way CI publishes to the real R2 bucket and KV namespace: blobs first, tags last.
#
#   scripts/seed-local.sh <oci-layout-dir> <repository> <tag>=<ref.name in index.json> ...
#   scripts/seed-local.sh .wrangler/oci nyra stable=busybox beta=busybox-zstd
#
# Make a layout with skopeo, for example from the Podman machine (FCOS ships skopeo):
#   podman machine ssh skopeo copy --override-arch arm64 \
#     docker://docker.io/library/busybox:latest oci:$PWD/.wrangler/oci:busybox
set -euo pipefail
cd "$(dirname "$0")/.."
layout="$1" repo="$2"; shift 2
wrangler="npx wrangler --env local"

uploaded=0 skipped=0
for f in "$layout"/blobs/sha256/*; do
  key="blobs/sha256/$(basename "$f")"
  # Content-addressed: an existing key already holds the same bytes.
  if $wrangler r2 object get "nyra-images/$key" --local --pipe >/dev/null 2>&1; then
    skipped=$((skipped + 1)); continue
  fi
  $wrangler r2 object put "nyra-images/$key" --local --file "$f" >/dev/null
  uploaded=$((uploaded + 1))
done
echo "blobs: $uploaded uploaded, $skipped already present"

for pair in "$@"; do
  tag="${pair%%=*}" ref="${pair#*=}"
  digest=$(jq -r --arg r "$ref" '.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $r) | .digest' "$layout/index.json")
  [ -n "$digest" ] || { echo "no image named $ref in $layout/index.json" >&2; exit 1; }
  $wrangler kv key put "tag/$repo/$tag" "{\"digest\":\"$digest\"}" --binding TAGS --local >/dev/null
  echo "tag $repo:$tag -> $digest"
done
