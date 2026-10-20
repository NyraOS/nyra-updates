#!/usr/bin/env bash
# Tests for publish-image.sh (local mode): publishes a tiny hand-made OCI layout into a temporary
# wrangler state and reads it back through `wrangler dev`, the way a client pulls it. Corrupt and
# incomplete layouts must be refused with nothing written. Remote mode runs against stub curl and
# aws programs (no network): the tag rules and "signature before version tag". Needs no secrets.
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
make_layout "$tmp/symlink-blob"
manifest_file="$tmp/symlink-blob/blobs/sha256/$(jq -r '.manifests[0].digest[7:]' "$tmp/symlink-blob/index.json")"
layer_file="$tmp/symlink-blob/blobs/sha256/$(jq -r '.layers[0].digest[7:]' "$manifest_file")"
mv "$layer_file" "$tmp/moved-layer" && ln -s "$tmp/moved-layer" "$layer_file"
make_layout "$tmp/symlink-index"
mv "$tmp/symlink-index/index.json" "$tmp/moved-index.json" && ln -s "$tmp/moved-index.json" "$tmp/symlink-index/index.json"
make_layout "$tmp/missing"
rm "$tmp/missing/blobs/sha256/${layer#sha256:}"
# The layouts differ (the layer text has the directory), so read the good one's digests again.
read -r manifest < <(jq -r '.manifests[0].digest' "$tmp/good/index.json")
layer=$(jq -r '.layers[0].digest' "$tmp/good/blobs/sha256/${manifest#sha256:}")

refused "corrupted blob" publish "$tmp/corrupt" nyra-base 2026.10.3
refused "missing layer" publish "$tmp/missing" nyra-base 2026.10.3
refused "symlinked blob" publish "$tmp/symlink-blob" nyra-base 2026.10.3
refused "symlinked index.json" publish "$tmp/symlink-index" nyra-base 2026.10.3
refused "bad repository" publish "$tmp/good" "Nyra" 2026.10.3
refused "bad repository path" publish "$tmp/good" "../nyra-base" 2026.10.3
refused "bad version" publish "$tmp/good" nyra-base 2026.10
refused "bad version (tag-like)" publish "$tmp/good" nyra-base latest
refused "not a layout" publish "$tmp" nyra-base 2026.10.3
refused "channel name as a tag" publish "$tmp/good" nyra-base stable
refused "channel name as a tag (dev)" publish "$tmp/good" nyra-base dev
refused "sig tag with uppercase hex" publish "$tmp/good" nyra-base "sha256-$(printf 'A%.0s' $(seq 64)).sig"
refused "sig tag too short" publish "$tmp/good" nyra-base "sha256-$(printf 'a%.0s' $(seq 63)).sig"
refused "sig tag too long" publish "$tmp/good" nyra-base "sha256-$(printf 'a%.0s' $(seq 65)).sig"
refused "sig tag without .sig" publish "$tmp/good" nyra-base "sha256-$(printf 'a%.0s' $(seq 64))"

out=$(publish "$tmp/good" nyra-base 2026.10.3) && ok "publish" || fail "publish"
grep -qx 'blobs: 3 uploaded, 0 already present' <<<"$out" && ok "three blobs uploaded" || fail "blobs: $out"
grep -qx "add to channels/nyra-base/releases.json:  \"2026.10.3\": \"$manifest\"" <<<"$out" && ok "releases.json line" || fail "releases line: $out"
repo_root=$PWD
(cd "$tmp" && "$repo_root/scripts/publish-image.sh" good nyra-base 2026.10.3) | grep -q 'nothing to do' &&
  ok "same layout, same version: no-op (relative OCI_DIR)" || fail "second publish of the same version"
make_layout "$tmp/other"
state_hash() { find "$LOCAL_STATE_DIR" -type f -exec sha256sum {} + | sort | sha256sum; }
state_before=$(state_hash)
if publish "$tmp/other" nyra-base 2026.10.3 >/dev/null 2>&1; then fail "re-pointing a version: accepted"
elif [ "$state_before" != "$(state_hash)" ]; then fail "re-pointing a version: something was written"
else ok "another layout under a released version is refused, nothing written"; fi
make_layout "$tmp/stray"
printf 'not in the manifest' >"$tmp/stray/blobs/sha256/$(printf 'not in the manifest' | sha256sum | cut -d' ' -f1)"
out=$(publish "$tmp/stray" nyra-base 2026.10.5)
grep -qx 'blobs: 2 uploaded, 1 already present' <<<"$out" && ok "a blob outside the manifest is not uploaded" || fail "stray blob: $out"
read -r manifest < <(jq -r '.manifests[0].digest' "$tmp/good/index.json") # make_layout overwrote these
layer=$(jq -r '.layers[0].digest' "$tmp/good/blobs/sha256/${manifest#sha256:}")
out=$(publish "$tmp/good" nyra-base 2026.10.4)
grep -qx 'blobs: 0 uploaded, 3 already present' <<<"$out" && ok "existing blobs are not uploaded again" || fail "second publish: $out"

# --- Remote mode, with stub curl and aws in front of PATH: files in $stub are the KV and R2 ------
stub="$tmp/stub"
mkdir -p "$stub/bin" "$stub/r2"
: >"$stub/kv.tsv"
cat >"$stub/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stub of the Cloudflare KV REST API: $STUB/kv.tsv holds "key<TAB>value" lines.
config=$(cat) # the `-K -` config
printf '%s\n' "$*" >>"$STUB/curl.argv"
env >>"$STUB/curl.env"
decode() { printf '%b' "${1//%/\\x}"; }
method=GET value= url=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    --data-binary) value=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
grep -qx 'header = "Authorization: Bearer test-kv-token"' <<<"$config" || exit 22
case "$url" in
  */keys\?prefix=*)
    prefix=$(decode "${url#*prefix=}")
    jq -Rn --arg p "$prefix" '{success: true, result: [inputs | split("\t")[0] | select(startswith($p)) | {name: .}]}' <"$STUB/kv.tsv" ;;
  */values/*)
    key=$(decode "${url##*/values/}")
    if [ "$method" = PUT ]; then
      printf '%s\t%s\n' "$key" "$value" >>"$STUB/kv.tsv"; echo '{"success":true}'
    else
      line=$(grep -F "$key"$'\t' "$STUB/kv.tsv") || exit 22
      printf '%s' "${line#*$'\t'}"
    fi ;;
  *) exit 22 ;;
esac
STUB
cat >"$stub/bin/aws" <<'STUB'
#!/usr/bin/env bash
# Stub of `aws s3api head-object` and `aws s3 cp` over the files in $STUB/r2.
env >>"$STUB/aws.env"
[ "$AWS_ACCESS_KEY_ID" = test-key-id ] && [ "$AWS_SECRET_ACCESS_KEY" = test-secret ] || exit 1
args=("$@")
if [ "$1 $2" = "s3api head-object" ]; then
  for i in "${!args[@]}"; do [ "${args[i]}" = --key ] && key=${args[i + 1]}; done
  stat -c %s "$STUB/r2/$(basename "$key")"
else
  cp "${args[-2]}" "$STUB/r2/$(basename "${args[-1]}")"
fi
STUB
chmod +x "$stub/bin/curl" "$stub/bin/aws"
remote() { # the three secrets are given only here, as the CI job has them
  STUB="$stub" PATH="$stub/bin:$PATH" R2_ACCESS_KEY_ID=test-key-id R2_SECRET_ACCESS_KEY=test-secret \
    CLOUDFLARE_KV_TOKEN=test-kv-token scripts/publish-image.sh --remote "$@"
}
manifest_of() { jq -r '.manifests[0].digest' "$1/index.json"; }
stub_state() { echo "$(wc -l <"$stub/kv.tsv") $(find "$stub/r2" -type f | wc -l)"; }
remote_refused() { # <name> <command...>: refused, and neither KV nor R2 changed
  local name="$1" before
  shift
  before=$(stub_state)
  if "$@" >/dev/null 2>&1; then fail "$name: accepted"
  elif [ "$before" != "$(stub_state)" ]; then fail "$name: something was written"
  else ok "$name"; fi
}

make_layout "$tmp/signed"
make_layout "$tmp/signature"
signed=$(manifest_of "$tmp/signed")
sig_tag="sha256-${signed#sha256:}.sig"
remote_refused "remote: a version without its signature tag" remote "$tmp/signed" nyra-base 2026.11.1
remote_refused "remote: a channel name" remote "$tmp/signed" nyra-base beta
remote_refused "remote: a sig tag with uppercase hex" remote "$tmp/signature" nyra-base "sha256-$(printf 'A%.0s' $(seq 64)).sig"
remote "$tmp/signature" nyra-base "$sig_tag" >/dev/null && ok "remote: the signature tag is published like an image" || fail "remote: sig tag"
grep -q "^tag/nyra-base/$sig_tag"$'\t' "$stub/kv.tsv" && ok "remote: the signature tag is in KV" || fail "remote: sig tag not in KV"
out=$(remote "$tmp/signed" nyra-base 2026.11.1) && grep -qx "tag nyra-base:2026.11.1 -> $signed" <<<"$out" &&
  ok "remote: a version with its signature is published" || fail "remote: version with signature: $out"
remote "$tmp/signed" nyra-base 2026.11.1 | grep -q 'nothing to do' && ok "remote: same digest is a no-op" || fail "remote: no-op"

# A signature tag whose manifest is not in R2 does not count.
make_layout "$tmp/dangling"
dangling=$(manifest_of "$tmp/dangling")
printf 'tag/nyra-base/sha256-%s.sig\t{"digest":"sha256:%s"}\n' "${dangling#sha256:}" "$(printf 'b%.0s' $(seq 64))" >>"$stub/kv.tsv"
remote_refused "remote: a signature whose manifest is not in R2" remote "$tmp/dangling" nyra-base 2026.11.2

# Each secret reaches only its own program, and none is in an argument list.
! grep -q '^AWS_\|^R2_\|^CLOUDFLARE_' "$stub/curl.env" && ok "curl gets no R2 or AWS variable" || fail "curl got a secret in its environment"
! grep -q '^CLOUDFLARE_\|^R2_' "$stub/aws.env" && ok "aws gets no KV token" || fail "aws got the KV token"
! grep -q 'test-kv-token' "$stub/curl.argv" && ok "the KV token is not in curl's arguments" || fail "KV token in curl argv"

setsid npx wrangler dev --env local --ip 127.0.0.1 --port "$port" --persist-to "$LOCAL_STATE_DIR" >"$tmp/dev.log" 2>&1 &
dev_pid=$!
for _ in $(seq 60); do curl -sf -o /dev/null "$registry/v2/" -H 'Authorization: Basic Og==' && break; sleep 1; done

pulled=$(curl -sf "$registry/v2/nyra-base/manifests/2026.10.3" -H 'Authorization: Basic Og==' | sha256sum | cut -d' ' -f1) || pulled=
[ "sha256:$pulled" = "$manifest" ] && ok "the Worker serves the manifest by version" || fail "manifest by version: $pulled"
pulled=$(curl -sfL "$registry/v2/nyra-base/blobs/$layer" | sha256sum | cut -d' ' -f1) || pulled=
[ "sha256:$pulled" = "$layer" ] && ok "the Worker serves the layer" || fail "layer: $pulled"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
echo "all passed"
