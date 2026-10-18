#!/usr/bin/env bash
# Tests for publish-image.sh (local mode): publishes a tiny hand-made OCI layout into a temporary
# wrangler state and reads it back through `wrangler dev`, the way a client pulls it. Corrupt and
# incomplete layouts must be refused with nothing written. Needs no secrets: run in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
dev_pid=
# wrangler dev starts children: kill its whole process group, or workerd keeps the port.
trap '[ -z "$dev_pid" ] || kill -- "-$dev_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
export LOCAL_STATE_DIR="$tmp/state"
port=8793 registry="http://127.0.0.1:8793"
! curl -s -o /dev/null "$registry/" || { echo "port $port is busy" >&2; exit 1; }

failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
refused() { # <name> <command...>: refused, and nothing written to the local state
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name: accepted"
  elif [ -e "$LOCAL_STATE_DIR" ]; then fail "$name: something was written"
  else ok "$name"; fi
}

# blob <layout> <content>: stores the content under its digest, prints "sha256:<hex> <size>"
blob() {
  local hex
  hex=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)
  printf '%s' "$2" >"$1/blobs/sha256/$hex"
  echo "sha256:$hex ${#2}"
}
make_layout() { # <dir>: config + one layer + manifest, as skopeo writes them
  mkdir -p "$1/blobs/sha256"
  read -r cfg cfg_size < <(blob "$1" '{"architecture":"arm64","os":"linux"}')
  read -r layer layer_size < <(blob "$1" "layer of $1")
  local m
  m=$(jq -cn --arg c "$cfg" --argjson cs "$cfg_size" --arg l "$layer" --argjson ls "$layer_size" '{
    schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $c, size: $cs},
    layers: [{mediaType: "application/vnd.oci.image.layer.v1.tar", digest: $l, size: $ls}]}')
  read -r manifest manifest_size < <(blob "$1" "$m")
  jq -cn --arg d "$manifest" --argjson s "$manifest_size" \
    '{schemaVersion: 2, manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $d, size: $s}]}' \
    >"$1/index.json"
}
publish() { scripts/publish-image.sh "$@"; }

make_layout "$tmp/good"
make_layout "$tmp/corrupt"
printf 'x' >>"$tmp/corrupt/blobs/sha256/${layer#sha256:}"
make_layout "$tmp/missing"
rm "$tmp/missing/blobs/sha256/${layer#sha256:}"
# The layouts differ (the layer text has the directory), so read the good one's digests again.
read -r manifest < <(jq -r '.manifests[0].digest' "$tmp/good/index.json")
layer=$(jq -r '.layers[0].digest' "$tmp/good/blobs/sha256/${manifest#sha256:}")

refused "corrupted blob" publish "$tmp/corrupt" nyra 2026.10.3
refused "missing layer" publish "$tmp/missing" nyra 2026.10.3
refused "bad repository" publish "$tmp/good" "Nyra" 2026.10.3
refused "bad repository path" publish "$tmp/good" "../nyra" 2026.10.3
refused "bad version" publish "$tmp/good" nyra 2026.10
refused "bad version (tag-like)" publish "$tmp/good" nyra latest
refused "not a layout" publish "$tmp" nyra 2026.10.3

out=$(publish "$tmp/good" nyra 2026.10.3) && ok "publish" || fail "publish"
grep -qx 'blobs: 3 uploaded, 0 already present' <<<"$out" && ok "three blobs uploaded" || fail "blobs: $out"
grep -qx "add to channels/nyra/releases.json:  \"2026.10.3\": \"$manifest\"" <<<"$out" && ok "releases.json line" || fail "releases line: $out"
out=$(publish "$tmp/good" nyra 2026.10.4)
grep -qx 'blobs: 0 uploaded, 3 already present' <<<"$out" && ok "existing blobs are not uploaded again" || fail "second publish: $out"

setsid npx wrangler dev --env local --ip 127.0.0.1 --port "$port" --persist-to "$LOCAL_STATE_DIR" >"$tmp/dev.log" 2>&1 &
dev_pid=$!
for _ in $(seq 60); do curl -sf -o /dev/null "$registry/v2/" -H 'Authorization: Basic Og==' && break; sleep 1; done

pulled=$(curl -sf "$registry/v2/nyra/manifests/2026.10.3" -H 'Authorization: Basic Og==' | sha256sum | cut -d' ' -f1) || pulled=
[ "sha256:$pulled" = "$manifest" ] && ok "the Worker serves the manifest by version" || fail "manifest by version: $pulled"
pulled=$(curl -sfL "$registry/v2/nyra/blobs/$layer" | sha256sum | cut -d' ' -f1) || pulled=
[ "sha256:$pulled" = "$layer" ] && ok "the Worker serves the layer" || fail "layer: $pulled"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
echo "all passed"
