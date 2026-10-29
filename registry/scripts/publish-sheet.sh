#!/usr/bin/env bash
# Builds the channel sheet from git, signs it and writes it to KV (README.md, "The signed
# channel sheet"). CI runs it on main after every change of channels/ and once a day (so the
# sheet never expires); locally it writes the local KV.
#
#   scripts/publish-sheet.sh [--remote] nyra-base:stable     # --remote: the real KV (CI only)
#
# Remote needs only bash, curl and jq: no Node, npm or wrangler next to the tokens. KV goes
# through curl to the Cloudflare REST API with CLOUDFLARE_KV_TOKEN, as in publish-image.sh. Each
# token reaches only the process that uses it (the KMS token: sign-sheet.sh; the KV token: curl,
# on stdin). Without --remote it writes the local wrangler state (no tokens).
#
# The input is only channels/<repo>/<channel>.json and releases.json, as checked out (dev: only
# releases.json, see below). KV is
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

# Plain shell variables, removed from the environment: a secret reaches only the process that
# uses it (the KMS token: sign-sheet.sh; the KV token: curl).
token="${SHEET_KMS_TOKEN:-}"
kv_token="${CLOUDFLARE_KV_TOKEN:-}"
unset SHEET_KMS_TOKEN CLOUDFLARE_KV_TOKEN

die() { echo "publish-sheet: $*" >&2; exit 1; }
remote=false
if [ "${1:-}" = --remote ]; then remote=true; shift; fi
# An unsigned sheet would replace the signed one in KV: local only.
if $remote && [ "${SHEET_UNSIGNED:-}" = 1 ]; then die "SHEET_UNSIGNED=1 is local only, refusing --remote"; fi
[ $# -eq 1 ] || die "usage: publish-sheet.sh [--remote] <repo>:<dev|beta|stable>"
[[ "$1" =~ ^[a-z0-9]+([._-][a-z0-9]+)*:(dev|beta|stable)$ ]] || die "expected <repo>:dev|beta|stable, got $1"
repo="${1%%:*}" channel="${1##*:}"

releases=$(jq -c . "$channels/$repo/releases.json") || die "cannot read $channels/$repo/releases.json"
jq -e "$rules valid_releases" <<<"$releases" >/dev/null || die "invalid releases.json"
if [ "$channel" = dev ]; then
  # dev has no file: it is always the newest version recorded in releases.json, so a release
  # reaches dev with no promotion commit of its own. The input is still only git on main (what a
  # releases.json commit could do before, a channel-file commit could too). No rollout and no
  # previous version on dev. beta and stable still move only by their own files.
  # A dev.json would look like a pin that nothing reads: refused, so nobody relies on it.
  [ ! -e "$channels/$repo/dev.json" ] || die "$channels/$repo/dev.json exists: dev has no channel file, remove it"
  # A version retracted on beta or stable is retracted on dev too: dev skips it (it serves the newest
  # release that is not retracted), and machines that took it may step back to that one (Retract).
  retracted='[]'
  for other in beta stable; do
    [ -f "$channels/$repo/$other.json" ] || continue
    retracted=$(jq -c --argjson r "$retracted" '$r + .retracted | unique' "$channels/$repo/$other.json") ||
      die "cannot read the retracted versions of $channels/$repo/$other.json"
  done
  state=$(jq -c --argjson x "$retracted" "$rules"' {current: ([keys[] | select(. as $v | $x | index($v) | not)]
    | sort_by(vkey) | last), previous: null, percent: 100, halted: false, retracted: $x}' <<<"$releases")
  [ "$(jq -r .current <<<"$state")" != null ] || die "no release in releases.json that is not retracted: nothing to put on dev"
else
  state=$(jq -c . "$channels/$repo/$channel.json") || die "cannot read $channels/$repo/$channel.json"
fi
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

if $remote && [ -z "${ROLLOUT_KV_DIR:-}" ]; then
  [ -n "$kv_token" ] || die "CLOUDFLARE_KV_TOKEN is not set"
  [[ "$kv_token" =~ ^[A-Za-z0-9_-]+$ ]] || die "CLOUDFLARE_KV_TOKEN has unexpected characters"
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
fi

kv_put() {
  if [ -n "${ROLLOUT_KV_DIR:-}" ]; then
    mkdir -p "$(dirname "$ROLLOUT_KV_DIR/$1")" && printf '%s' "$2" >"$ROLLOUT_KV_DIR/$1"
  elif $remote; then
    # The token is a curl config on stdin (printf is a builtin): it is never in any argv.
    printf 'header = "Authorization: Bearer %s"\n' "$kv_token" |
      curl -K - --silent --show-error --fail --proto =https --max-time 60 -X PUT \
        -H 'Content-Type: text/plain' --data-binary "$2" \
        "$kv_api/values/$(jq -rn --arg s "$1" '$s | @uri')" | jq -e '.success' >/dev/null
  else
    npx --no-install wrangler kv key put "$1" "$2" --binding TAGS --env local --local >/dev/null
  fi
}
kv_put "sheet/$repo/$channel" "$envelope"
kv_put "tag/$repo/$channel" "$pointer"
echo "$1 -> $payload"
