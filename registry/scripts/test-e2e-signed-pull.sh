#!/usr/bin/env bash
# End to end: a signed image is published with publish-image.sh (local mode) and pulled by skopeo
# through `wrangler dev`, under a key-based sigstoreSigned policy with use-sigstore-attachments
# (what a Nyra install does, with a throwaway key instead of the release identity):
#   - the signed version tag is accepted;
#   - an unsigned version tag is refused;
#   - the image and its signature under another repository name are refused (matchRepository);
#   - the Worker serves the signature manifest with its mediaType (it answers 404 without one).
# The signed image is first pushed (and signed) to a throwaway local registry, because skopeo
# writes signature attachments only to a registry; both layouts are then exported from it.
# Needs skopeo and the `registry` program (Ubuntu: skopeo, docker-registry), jq, curl, npm ci.
# The key is generated here and never leaves the temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
pids=()
# wrangler dev starts children: kill its whole process group, or workerd keeps the port.
trap 'for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null || true; done; rm -rf "$tmp"' EXIT
export LOCAL_STATE_DIR="$tmp/state"
worker=127.0.0.1:8794 local_registry=127.0.0.1:5001
for hostport in $worker $local_registry; do
  ! curl -s -o /dev/null "http://$hostport/v2/" || { echo "$hostport is busy" >&2; exit 1; }
done

failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

# --- skopeo configuration, only in this test's own directory ---------------------------------
cfg="$tmp/containers"
mkdir -p "$cfg/registries.d"
printf '[[registry]]\nlocation = "%s"\ninsecure = true\n\n[[registry]]\nlocation = "%s"\ninsecure = true\n' \
  "$worker" "$local_registry" >"$cfg/registries.conf"
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n  %s:\n    use-sigstore-attachments: true\n' \
  "$worker" "$local_registry" >"$cfg/registries.d/test.yaml"
echo test-passphrase >"$tmp/pass"
skopeo generate-sigstore-key --output-prefix "$tmp/test" --passphrase-file "$tmp/pass" >/dev/null
# Only the Worker's host requires a signature; the throwaway registry takes anything.
jq -n --arg host "$worker" --arg key "$tmp/test.pub" '{
  default: [{type: "insecureAcceptAnything"}],
  transports: {docker: {($host): [{type: "sigstoreSigned", keyPath: $key,
    signedIdentity: {type: "matchRepository"}}]}}}' >"$cfg/policy.json"
sk() { skopeo --registries-conf "$cfg/registries.conf" --registries.d "$cfg/registries.d" --policy "$cfg/policy.json" "$@"; }

# --- A tiny image as an OCI layout: make_image DIR TAG TEXT (the text makes the digest unique) ---
blob() { # <layout> <file>: moves the file to its digest name, prints "sha256:<hex> <size>"
  local hex
  hex=$(sha256sum <"$2" | cut -d' ' -f1)
  mv "$2" "$1/blobs/sha256/$hex"
  echo "sha256:$hex $(stat -c %s "$1/blobs/sha256/$hex")"
}
make_image() {
  mkdir -p "$1/blobs/sha256" "$tmp/layer-$3"
  printf '%s\n' "$3" >"$tmp/layer-$3/text"
  tar -C "$tmp/layer-$3" -cf "$tmp/layer-$3.tar" text
  local layer layer_size cfg cfg_size manifest manifest_size
  read -r layer layer_size < <(blob "$1" "$tmp/layer-$3.tar")
  jq -cn --arg l "$layer" '{architecture: "amd64", os: "linux", rootfs: {type: "layers", diff_ids: [$l]}}' >"$tmp/config"
  read -r cfg cfg_size < <(blob "$1" "$tmp/config")
  jq -cn --arg c "$cfg" --argjson cs "$cfg_size" --arg l "$layer" --argjson ls "$layer_size" '{
    schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: $c, size: $cs},
    layers: [{mediaType: "application/vnd.oci.image.layer.v1.tar", digest: $l, size: $ls}]}' >"$tmp/manifest"
  read -r manifest manifest_size < <(blob "$1" "$tmp/manifest")
  echo '{"imageLayoutVersion":"1.0.0"}' >"$1/oci-layout"
  jq -cn --arg d "$manifest" --argjson s "$manifest_size" --arg t "$2" '{schemaVersion: 2, manifests: [{
    mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $d, size: $s,
    annotations: {"org.opencontainers.image.ref.name": $t}}]}' >"$1/index.json"
}

# --- Sign: push the signed image to the throwaway registry, then export it and its signature ---
cat >"$tmp/registry.yml" <<EOF
version: 0.1
storage:
  filesystem:
    rootdirectory: $tmp/registry
http:
  addr: $local_registry
EOF
setsid registry serve "$tmp/registry.yml" >"$tmp/registry.log" 2>&1 &
pids+=($!)
for _ in $(seq 30); do curl -sf -o /dev/null "http://$local_registry/v2/" && break; sleep 1; done
curl -sf -o /dev/null "http://$local_registry/v2/" || { cat "$tmp/registry.log" >&2; exit 1; }

make_image "$tmp/signed" 1.0.0 signed
make_image "$tmp/unsigned" 2.0.0 unsigned
sk copy --sign-by-sigstore-private-key "$tmp/test.private" --sign-passphrase-file "$tmp/pass" \
  "oci:$tmp/signed:1.0.0" "docker://$local_registry/nyra-base:1.0.0" >/dev/null
digest=$(sk inspect --format '{{.Digest}}' "docker://$local_registry/nyra-base:1.0.0")
sig_tag="${digest/:/-}.sig"
sk copy --remove-signatures --preserve-digests "docker://$local_registry/nyra-base:1.0.0" "oci:$tmp/pub-image:1.0.0" >/dev/null
sk copy --remove-signatures --preserve-digests "docker://$local_registry/nyra-base:$sig_tag" "oci:$tmp/pub-sig:$sig_tag" >/dev/null

# --- Publish: the signed image and its signature under nyra-base and elsewhere; unsigned only nyra-base ---
for repo in nyra-base elsewhere; do
  scripts/publish-image.sh "$tmp/pub-image" $repo 1.0.0 >/dev/null
  scripts/publish-image.sh "$tmp/pub-sig" $repo "$sig_tag" >/dev/null
done
scripts/publish-image.sh "$tmp/unsigned" nyra-base 2.0.0 >/dev/null

setsid npx --no-install wrangler dev --env local --ip "${worker%:*}" --port "${worker#*:}" \
  --var REPOSITORIES:nyra-base,elsewhere --persist-to "$LOCAL_STATE_DIR" >"$tmp/dev.log" 2>&1 &
pids+=($!)
for _ in $(seq 60); do curl -sf -o /dev/null "http://$worker/v2/" && break; sleep 1; done
curl -sf -o /dev/null "http://$worker/v2/" || { cat "$tmp/dev.log" >&2; exit 1; }

# --- Pull through the Worker ------------------------------------------------------------------
n=0
accepted() { # <name> <image>
  n=$((n + 1))
  if sk copy "docker://$worker/$2" "dir:$tmp/pull-$n" >"$tmp/out" 2>&1; then ok "$1"
  else cat "$tmp/out" >&2; fail "$1: refused"; fi
}
refused() { # <name> <image> <the reason skopeo must give>
  n=$((n + 1))
  if sk copy "docker://$worker/$2" "dir:$tmp/pull-$n" >"$tmp/out" 2>&1; then fail "$1: accepted"
  elif grep -qF -- "$3" "$tmp/out"; then ok "$1"
  else cat "$tmp/out" >&2; fail "$1: refused for another reason than \"$3\""; fi
}
accepted "signed version tag is accepted" nyra-base:1.0.0
refused "unsigned version tag is refused" nyra-base:2.0.0 "A signature was required, but no signature exists"
refused "signed image under another repository is refused" elsewhere:1.0.0 "is not accepted"

# --- The Worker serves the signature manifest with its mediaType --------------------------------
curl -s -D "$tmp/headers" -o "$tmp/sig-manifest" "http://$worker/v2/nyra-base/manifests/$sig_tag" \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json'
body_type=$(jq -r '.mediaType // empty' "$tmp/sig-manifest")
status=$(head -1 "$tmp/headers" | cut -d' ' -f2)
type=$(grep -i '^content-type:' "$tmp/headers" | cut -d' ' -f2- | tr -d '\r')
if [ "$status" = 200 ] && [ -n "$body_type" ] && [ "$type" = "$body_type" ]; then
  ok "signature manifest served with its mediaType ($type)"
else
  fail "signature manifest: status '$status', Content-Type '$type', mediaType in body '$body_type'"
fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed" >&2; exit 1; }
echo "all checks passed"
