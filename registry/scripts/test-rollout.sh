#!/usr/bin/env bash
# Tests for rollout.sh, publish-sheet.sh and sign-sheet.sh, on a temporary channel directory and
# keys kept as files (ROLLOUT_KV_DIR) instead of KV, with a throwaway signing key. Run in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CHANNELS_DIR="$tmp/channels" ROLLOUT_KV_DIR="$tmp/kv" SHEET_TEST_KEY="$tmp/test.key"
openssl genpkey -algorithm ed25519 -out "$SHEET_TEST_KEY" 2>/dev/null
openssl pkey -in "$SHEET_TEST_KEY" -pubout -out "$tmp/test.pub"

d() { printf 'sha256:%064d' "$1"; } # digest of version 2026.10.<n>
mkdir -p "$CHANNELS_DIR/nyra-base"
{
  echo "{"
  for n in 1 2 3 4; do echo "  \"2026.10.$n\": \"$(d "$n")\","; done
  echo "  \"2026.10.5\": \"$(d 5)\""
  echo "}"
} >"$CHANNELS_DIR/nyra-base/releases.json"

failures=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
run() { scripts/rollout.sh "$@" >/dev/null 2>&1; }
publish() { scripts/publish-sheet.sh nyra-base:stable >/dev/null 2>&1; }
state() { jq -c . "$CHANNELS_DIR/nyra-base/stable.json"; }
signed() { jq -c '.payload | @base64d | fromjson' "$ROLLOUT_KV_DIR/sheet/nyra-base/stable"; }
expect() { # <name> <jq condition> <json>
  if jq -e "$2" <<<"$3" >/dev/null; then ok "$1"; else fail "$1: $3"; fi
}
refused() { # <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name: accepted"; else ok "$name"; fi
}
reset() { rm -f "$CHANNELS_DIR/nyra-base/stable.json"; run set nyra-base:stable 2026.10.1; }

# --- rollout.sh edits the channel file -------------------------------------------------------

# The scenario found in review: revert, start, then set back two versions.
reset
run start nyra-base:stable 2026.10.2 100
run start nyra-base:stable 2026.10.3 50
run revert nyra-base:stable
expect "revert retracts the current version" '.current == "2026.10.2" and .retracted == ["2026.10.3"]' "$(state)"
run start nyra-base:stable 2026.10.4 25
expect "start keeps the retract list" '.retracted == ["2026.10.3"] and .previous == "2026.10.2"' "$(state)"
run set nyra-base:stable 2026.10.2
expect "set back keeps the list and retracts the newer current" \
  '.current == "2026.10.2" and .previous == null and .retracted == ["2026.10.3", "2026.10.4"]' "$(state)"

reset
run start nyra-base:stable 2026.10.3 100
run start nyra-base:stable 2026.10.4 50 # previous 2026.10.3
run set nyra-base:stable 2026.10.2
expect "set back below previous retracts current and previous" '.retracted == ["2026.10.3", "2026.10.4"]' "$(state)"
run set nyra-base:stable 2026.10.5
expect "set forward keeps the list and retracts nothing new" '.current == "2026.10.5" and .retracted == ["2026.10.3", "2026.10.4"]' "$(state)"
refused "set to a retracted version is refused" scripts/rollout.sh set nyra-base:stable 2026.10.4

reset
run start nyra-base:stable 2026.10.2 30
run stop nyra-base:stable
expect "stop halts" '.halted == true and .percent == 30 and .previous == "2026.10.1"' "$(state)"
refused "start during a halted rollout is refused" scripts/rollout.sh start nyra-base:stable 2026.10.3 5
refused "start of an older version is refused" scripts/rollout.sh start nyra-base:stable 2026.10.1 5
refused "percent above 100 is refused" scripts/rollout.sh percent nyra-base:stable 101
refused "a version missing from releases.json is refused" scripts/rollout.sh set nyra-base:stable 2026.10.9

# --- publish-sheet.sh signs the git state ------------------------------------------------------

publish
expect "the signed sheet is built from git" \
  ".current == {digest: \"$(d 2)\", version: \"2026.10.2\"} and .previous == {digest: \"$(d 1)\", version: \"2026.10.1\"}
   and .percent == 30 and .halted == true and .retracted == [] and .sequence == .issued_at
   and .expires_at - .issued_at == 604800 and .repository == \"nyra-base\" and .channel == \"stable\"" "$(signed)"
if [ "$(cat "$ROLLOUT_KV_DIR/tag/nyra-base/stable")" = "{\"digest\":\"$(d 2)\",\"previous\":\"$(d 1)\",\"percent\":30,\"halted\":true}" ]; then
  ok "the tag pointer is derived from the same state"
else
  fail "tag pointer: $(cat "$ROLLOUT_KV_DIR/tag/nyra-base/stable")"
fi
type=application/vnd.nyra.channel-sheet.v1+json
jq -j '.payload | @base64d' "$ROLLOUT_KV_DIR/sheet/nyra-base/stable" >"$tmp/payload"
{ printf 'DSSEv1 %d %s %d ' ${#type} "$type" "$(wc -c <"$tmp/payload" | tr -d ' ')"; cat "$tmp/payload"; } >"$tmp/pae"
jq -r '.signatures[0].sig' "$ROLLOUT_KV_DIR/sheet/nyra-base/stable" | base64 -d >"$tmp/sig"
if openssl pkeyutl -verify -pubin -inkey "$tmp/test.pub" -rawin -in "$tmp/pae" -sigfile "$tmp/sig" >/dev/null 2>&1; then
  ok "the sheet is signed (DSSE, Ed25519)"
else
  fail "signature"
fi

# A KV writer (leaked Cloudflare token) cannot get its state signed: KV is never read.
run revert nyra-base:stable # git: 2026.10.1 current, 2026.10.2 retracted
publish
evil="{\"schema\":1,\"repository\":\"nyra-base\",\"channel\":\"stable\",\"current\":{\"digest\":\"$(d 9)\",\"version\":\"2026.10.9\"},\"previous\":null,\"percent\":100,\"halted\":false,\"retracted\":[]}"
jq -cn --arg p "$evil" '{payloadType: "application/vnd.nyra.channel-sheet.v1+json", payload: ($p | @base64), signatures: []}' \
  >"$ROLLOUT_KV_DIR/sheet/nyra-base/stable"
printf '{"digest":"%s"}' "$(d 9)" >"$ROLLOUT_KV_DIR/tag/nyra-base/stable"
printf '{"digest":"%s"}' "$(d 1)" >"$ROLLOUT_KV_DIR/tag/nyra-base/2026.10.4" # a version tag moved to an old build
publish # the daily re-signing
expect "an injected KV state is overwritten, not signed" \
  ".current == {digest: \"$(d 1)\", version: \"2026.10.1\"} and .retracted == [\"$(d 2)\"]" "$(signed)"
run start nyra-base:stable 2026.10.4 10
publish
expect "a moved version tag in KV does not change the signed digest" \
  ".current == {digest: \"$(d 4)\", version: \"2026.10.4\"}" "$(signed)"

# Invalid input is never signed; nothing unsigned leaves without an explicit local opt-in.
cp "$CHANNELS_DIR/nyra-base/stable.json" "$tmp/good.json"
jq '.previous = null | .halted = true' "$tmp/good.json" >"$CHANNELS_DIR/nyra-base/stable.json"
refused "a halted state without previous is not signed" scripts/publish-sheet.sh nyra-base:stable
printf 'garbage' >"$CHANNELS_DIR/nyra-base/stable.json"
refused "a corrupt channel file is not signed" scripts/publish-sheet.sh nyra-base:stable
refused "rollout.sh refuses a corrupt channel file" scripts/rollout.sh percent nyra-base:stable 50
cp "$tmp/good.json" "$CHANNELS_DIR/nyra-base/stable.json"
refused "no signer configured: refused" env -u SHEET_TEST_KEY scripts/publish-sheet.sh nyra-base:stable
if env -u SHEET_TEST_KEY SHEET_UNSIGNED=1 scripts/publish-sheet.sh nyra-base:stable >/dev/null 2>&1 &&
  [ "$(jq '.signatures | length' "$ROLLOUT_KV_DIR/sheet/nyra-base/stable")" = 0 ]; then
  ok "SHEET_UNSIGNED=1 passes an unsigned sheet (local only)"
else
  fail "SHEET_UNSIGNED=1"
fi
refused "KMS without the trusted public key is refused" \
  env -u SHEET_TEST_KEY SHEET_KMS_KEY=projects/x SHEET_KMS_TOKEN=t scripts/publish-sheet.sh nyra-base:stable

# --remote writes KV through curl (stubbed): the token is only on its stdin, never in an argv or
# in the environment of curl.
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
{ echo "ARGV $*"; echo "ENV ${CLOUDFLARE_KV_TOKEN:-unset}"; echo "STDIN $(cat)"; } >>"$CURL_LOG"
echo '{"success":true}'
STUB
chmod +x "$tmp/bin/curl"
remote() { # <token> [env...]
  local token="$1"; shift
  env -u ROLLOUT_KV_DIR CURL_LOG="$tmp/curl.log" PATH="$tmp/bin:$PATH" \
    CLOUDFLARE_KV_TOKEN="$token" "$@" scripts/publish-sheet.sh --remote nyra-base:stable
}
: >"$tmp/curl.log"
if remote tok-123 >/dev/null 2>&1 && [ "$(grep -c '^ARGV' "$tmp/curl.log")" = 2 ] &&
  grep -q '^STDIN header = "Authorization: Bearer tok-123"$' "$tmp/curl.log" &&
  ! grep -q 'tok-123' <(grep -v '^STDIN' "$tmp/curl.log") && ! grep -q '^ENV tok' "$tmp/curl.log" &&
  grep -q '/storage/kv/namespaces/01b69bd7bf0741fd80c0a3b7e0adf3cd/values/sheet%2Fnyra-base%2Fstable' "$tmp/curl.log"; then
  ok "remote: KV through curl, token only on stdin"
else
  fail "remote KV write: $(cat "$tmp/curl.log")"
fi
refused "remote without the KV token is refused" remote ""
refused "remote with an odd token is refused" remote "a b"
: >"$tmp/curl.log"
refused "--remote with SHEET_UNSIGNED=1 is refused" remote tok-123 SHEET_UNSIGNED=1
[ ! -s "$tmp/curl.log" ] || fail "--remote with SHEET_UNSIGNED=1 reached KV"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
echo "all rollout tests passed"
