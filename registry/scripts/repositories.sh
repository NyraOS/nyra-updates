# shellcheck shell=bash
# Sourced by publish-image.sh, publish-sheet.sh and rollout.sh: the one list of repositories this
# registry serves, read from REPOSITORIES in wrangler.toml (the Worker's own list), so a script can
# never accept a name the Worker does not serve. Each repository is one image line on one
# architecture (nyra-base, nyra-base-arm64, nyra-desktop, nyra-desktop-arm64) with its own signer.
# Names are matched whole against the list: no prefix, case or path handling, and a name is only
# ever used in a path (channels/<repo>/) after it matched.

# require_served_repository NAME: dies (the caller's `die`) unless NAME is exactly one served name.
require_served_repository() {
  local list name
  list=$(awk '/^\[/ { in_vars = ($0 == "[vars]") } in_vars && /^REPOSITORIES = "[a-z0-9,-]+"$/ { gsub(/"/, "", $3); print $3; exit }' \
    "$(dirname "${BASH_SOURCE[0]}")/../wrangler.toml")
  [ -n "$list" ] || die "cannot read REPOSITORIES from wrangler.toml"
  for name in ${list//,/ }; do
    [ "$name" != "$1" ] || return 0
  done
  die "repository not served (see REPOSITORIES in wrangler.toml): $1"
}

# require_digests_of_one_repository REPO RELEASES_JSON CHANNELS_DIR: a digest in REPO's releases.json
# must not be released under any other repository. The same image under nyra-base-arm64 and
# nyra-desktop-arm64 would be a base image offered as the desktop (or the reverse): refused.
require_digests_of_one_repository() {
  local other
  for other in "$3"/*/; do
    other=$(basename "$other")
    [ "$other" != "$1" ] && [ -f "$3/$other/releases.json" ] || continue
    jq -e --slurpfile o "$3/$other/releases.json" '[.[]] as $mine | [$o[0][]] | all(. as $d | $mine | index($d) | not)' \
      <<<"$2" >/dev/null || die "a digest of $1 is also released as $other: refused"
  done
}
