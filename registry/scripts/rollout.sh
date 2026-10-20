#!/usr/bin/env bash
# Changes the rollout of a channel (README.md, "Gradual rollout, stop and revert" and "The signed channel sheet").
# Edits the channel file in git, channels/<repo>/<channel>.json; nothing else. The change
# takes effect when it is merged into main: CI then signs the sheet built from main and writes it
# to KV (publish-sheet.sh). An emergency stop is a commit too.
#
#   scripts/rollout.sh set     nyra-base:stable 2026.10.2     # everybody on 2026.10.2; going back retracts the newer served versions
#                                                         # (also creates the channel)
#   scripts/rollout.sh start   nyra-base:stable 2026.10.3 5   # 2026.10.3 to 5% (previous = the current version)
#   scripts/rollout.sh percent nyra-base:stable 25            # raise (or resume a stopped rollout at) 25%
#   scripts/rollout.sh stop    nyra-base:stable               # nobody new gets it; machines on it keep it
#   scripts/rollout.sh revert  nyra-base:stable               # everybody back to the previous version; the current one is retracted
#   scripts/rollout.sh show    nyra-base:stable
#
# Versions must be in channels/<repo>/releases.json (version -> digest, written by the
# publishing job). Only the channels dev, beta and stable. CHANNELS_DIR overrides the directory
# (tests).
set -euo pipefail
cd "$(dirname "$0")/.."
channels="${CHANNELS_DIR:-../channels}"
rules=$(cat scripts/sheet-rules.jq)

die() { echo "rollout: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: rollout.sh set|start|percent|stop|revert|show <repo>:<dev|beta|stable> [args]"
cmd="$1" ref="$2"; shift 2
[[ "$ref" =~ ^[a-z0-9]+([._-][a-z0-9]+)*:(dev|beta|stable)$ ]] || die "expected <repo>:dev|beta|stable, got $ref"
repo="${ref%%:*}" channel="${ref##*:}"
file="$channels/$repo/$channel.json"
releases_file="$channels/$repo/releases.json"

[ -f "$releases_file" ] || die "no $releases_file"
releases=$(jq -c . "$releases_file")
jq -e "$rules valid_releases" <<<"$releases" >/dev/null || die "invalid $releases_file"
valid() { jq -e --argjson r "$releases" "$rules valid_state(\$r)" <<<"$1" >/dev/null 2>&1; }
newer() { jq -en --arg a "$1" --arg b "$2" "$rules (\$a | vkey) > (\$b | vkey)" >/dev/null; } # $1 > $2
release() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "not a version (YYYY.M.N): $1"
  jq -e --arg v "$1" 'has($v)' <<<"$releases" >/dev/null || die "$1 is not in $releases_file (publish it first)"
}

state=""
if [ -f "$file" ]; then
  state=$(jq -c . "$file" 2>/dev/null || true)
  if ! valid "$state"; then
    [ "$cmd" = set ] || die "invalid $file (fix it in git, or: rollout.sh set $ref <version>)"
    echo "rollout: $file is invalid; its retract list is lost" >&2
    state=""
  fi
fi
[ -n "$state" ] || [ "$cmd" = set ] || die "no channel $ref (create it with: rollout.sh set $ref <version>)"
get() { jq -r "$1" <<<"$state"; }

write() {
  valid "$1" || die "refusing to write an invalid state: $1"
  mkdir -p "$(dirname "$file")"
  jq . <<<"$1" >"$file"
  echo "$ref -> $(jq -c . "$file")"
  echo "rollout: wrote $file; commit it (pull request). CI signs and publishes it from main." >&2
}

case "$cmd" in
  set)
    [ $# -eq 1 ] || die "usage: rollout.sh set <repo>:<channel> <version>"
    release "$1"
    # Keep the retract list; going back retracts every served version newer than $1, so machines
    # on them get Retract instead of refusing a downgrade.
    write "$(jq -cn --arg v "$1" --argjson old "${state:-null}" "$rules"'
      {current: $v, previous: null, percent: 100, halted: false,
       retracted: (($old.retracted // []) + [$old.current, $old.previous | values | select(vkey > ($v | vkey))] | unique)}')"
    ;;
  start)
    [ $# -eq 2 ] || die "usage: rollout.sh start <repo>:<channel> <version> <percent>"
    [[ "$2" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || die "percent must be 0-100, got $2"
    release "$1"
    [ "$(get '.previous != null and (.percent < 100 or .halted)')" = false ] ||
      die "a rollout is in progress: finish it (percent 100) or revert it first"
    newer "$1" "$(get .current)" || die "$1 is not newer than $(get .current) (to go back: revert, or set, which retracts)"
    write "$(jq -c --arg v "$1" --argjson p "$2" '.previous = .current | .current = $v | .percent = $p | .halted = false' <<<"$state")"
    ;;
  percent)
    [ $# -eq 1 ] || die "usage: rollout.sh percent <repo>:<channel> <percent>"
    [[ "$1" =~ ^([0-9]|[1-9][0-9]|100)$ ]] || die "percent must be 0-100, got $1"
    [ "$(get '.previous != null')" = true ] || die "no rollout on $ref (start one first)"
    write "$(jq -c --argjson p "$1" '.percent = $p | .halted = false' <<<"$state")"
    ;;
  stop)
    [ "$(get '.previous != null')" = true ] || die "no rollout on $ref"
    write "$(jq -c '.halted = true' <<<"$state")"
    ;;
  revert)
    [ "$(get '.previous != null')" = true ] || die "no previous version recorded for $ref (use: rollout.sh set $ref <version>)"
    write "$(jq -c '.retracted = (.retracted + [.current] | unique) | .current = .previous | .previous = null
      | .percent = 100 | .halted = false' <<<"$state")"
    ;;
  show)
    jq . "$file"
    ;;
  *) die "unknown command $cmd" ;;
esac
