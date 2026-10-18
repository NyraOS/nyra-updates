#!/usr/bin/env bash
# Builds the channel sheet from git, signs it and writes it to KV (README.md, "The signed
# channel sheet"). CI runs it on main after every change of channels/ and once a day (so the
# sheet never expires); locally it writes the local KV.
#
#   scripts/publish-sheet.sh [--remote] nyra:stable     # --remote: the real KV (CI only)
#
# The input is only channels/<repo>/<channel>.json and releases.json, as checked out. KV is
# never read: whatever a KV writer puts there is overwritten, never signed. The sequence is the
# Unix time of signing (runs are serialized and take longer than a second).
# Writes: KV sheet/<repo>/<channel> (the envelope) and tag/<repo>/<channel> (the tag pointer of
# the server-side rollout, derived from the same state). ROLLOUT_KV_DIR=<dir> writes
# files instead of the local KV (tests); CHANNELS_DIR overrides the channel directory.
set -euo pipefail
cd "$(dirname "$0")/.."
channels="${CHANNELS_DIR:-../channels}"
rules=$(cat scripts/sheet-rules.jq)
TYPE=application/vnd.nyra.channel-sheet.v1+json
VALIDITY=$((7 * 24 * 60 * 60))

# The KMS token is for sign-sheet.sh only: wrangler and the other commands must not inherit it.
token="${SHEET_KMS_TOKEN:-}"
unset SHEET_KMS_TOKEN

die() { echo "publish-sheet: $*" >&2; exit 1; }
kv_target="--env local --local"
if [ "${1:-}" = --remote ]; then kv_target="--remote"; shift; fi
[ $# -eq 1 ] || die "usage: publish-sheet.sh [--remote] <repo>:<dev|beta|stable>"
[[ "$1" =~ ^[a-z0-9]+([._-][a-z0-9]+)*:(dev|beta|stable)$ ]] || die "expected <repo>:dev|beta|stable, got $1"
repo="${1%%:*}" channel="${1##*:}"

releases=$(jq -c . "$channels/$repo/releases.json") || die "cannot read $channels/$repo/releases.json"
jq -e "$rules valid_releases" <<<"$releases" >/dev/null || die "invalid releases.json"
state=$(jq -c . "$channels/$repo/$channel.json") || die "cannot read $channels/$repo/$channel.json"
jq -e --argjson r "$releases" "$rules valid_state(\$r)" <<<"$state" >/dev/null || die "invalid channel file: $state"

now=$(date +%s)
payload=$(jq -c --argjson r "$releases" --arg repo "$repo" --arg channel "$channel" \
  --argjson now "$now" --argjson validity "$VALIDITY" '
  def image: {digest: $r[.], version: .};
  {schema: 1, repository: $repo, channel: $channel, sequence: $now, issued_at: $now, expires_at: ($now + $validity),
   current: (.current | image), previous: (.previous | if . == null then null else image end),
   percent, halted, retracted: ([.retracted[] | $r[.]] | sort)}' <<<"$state")
jq -e --arg repo "$repo" --arg channel "$channel" "$rules valid_payload(\$repo; \$channel)" <<<"$payload" >/dev/null ||
  die "refusing to sign an invalid sheet: $payload"
envelope=$(jq -cn --arg t "$TYPE" --arg p "$payload" '{payloadType: $t, payload: ($p | @base64), signatures: []}' |
  SHEET_KMS_TOKEN="$token" scripts/sign-sheet.sh)
pointer=$(jq -c 'if .previous == null then {digest: .current.digest}
  else {digest: .current.digest, previous: .previous.digest, percent, halted} end' <<<"$payload")

kv_put() {
  if [ -n "${ROLLOUT_KV_DIR:-}" ]; then
    mkdir -p "$(dirname "$ROLLOUT_KV_DIR/$1")" && printf '%s' "$2" >"$ROLLOUT_KV_DIR/$1"
  else
    # shellcheck disable=SC2086 # kv_target is two words on purpose
    npx wrangler kv key put "$1" "$2" --binding TAGS $kv_target >/dev/null
  fi
}
kv_put "sheet/$repo/$channel" "$envelope"
kv_put "tag/$repo/$channel" "$pointer"
echo "$1 -> $payload"
