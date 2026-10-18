#!/usr/bin/env bash
# Signs a channel sheet envelope (README.md, "The signed channel sheet"): reads the unsigned DSSE
# envelope on stdin, writes it signed (Ed25519 over the DSSE encoding of the payload) on stdout.
#
#   SHEET_KMS_KEY=projects/<p>/locations/<l>/keyRings/<r>/cryptoKeys/<k>/cryptoKeyVersions/<n>
#   SHEET_KMS_TOKEN=<Google access token>      CI only: the Ed25519 key lives in Cloud KMS
#   SHEET_PUBLIC_KEY=<public key PEM>          with KMS: the key machines trust; every signature
#                                              is verified with it before it is written out
#   SHEET_TEST_KEY=<Ed25519 private key PEM>   local tests only, with a throwaway key
#   SHEET_UNSIGNED=1                           local only: pass the sheet through unsigned
#                                              (machines refuse it); without a signer, fail
#
# Signing in CI stays off until main is protected (anyone who can commit to main could get a sheet
# signed): nothing sets SHEET_KMS_KEY yet.
set -euo pipefail
type=application/vnd.nyra.channel-sheet.v1+json
die() { echo "sign-sheet: $*" >&2; exit 1; }

envelope=$(cat)
[ "$(jq -r .payloadType <<<"$envelope")" = "$type" ] || die "not a channel sheet envelope"
if [ -z "${SHEET_KMS_KEY:-}" ] && [ -z "${SHEET_TEST_KEY:-}" ]; then
  [ "${SHEET_UNSIGNED:-}" = 1 ] || die "no signer configured (SHEET_KMS_KEY, SHEET_TEST_KEY, or SHEET_UNSIGNED=1 locally)"
  echo "sign-sheet: SHEET_UNSIGNED=1, the sheet stays unsigned (machines refuse it)" >&2
  printf '%s\n' "$envelope"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
jq -j '.payload | @base64d' <<<"$envelope" >"$tmp/payload"
# DSSE PAE: "DSSEv1 <len(type)> <type> <len(payload)> <payload>", lengths in bytes.
printf 'DSSEv1 %d %s %d ' ${#type} "$type" "$(wc -c <"$tmp/payload" | tr -d ' ')" >"$tmp/pae"
cat "$tmp/payload" >>"$tmp/pae"

if [ -n "${SHEET_KMS_KEY:-}" ]; then
  [ -n "${SHEET_KMS_TOKEN:-}" ] || die "SHEET_KMS_KEY needs SHEET_KMS_TOKEN"
  [ -f "${SHEET_PUBLIC_KEY:-}" ] || die "SHEET_KMS_KEY needs SHEET_PUBLIC_KEY (the trusted public key)"
  cp "$SHEET_PUBLIC_KEY" "$tmp/pub"
  # Ed25519 in KMS signs the data itself (no digest); the token goes in a header file, not argv.
  printf 'Authorization: Bearer %s\n' "$SHEET_KMS_TOKEN" >"$tmp/auth"
  jq -cn --arg d "$(base64 <"$tmp/pae" | tr -d '\n')" '{data: $d}' >"$tmp/request"
  sig=$(curl -fsS --retry 3 -H @"$tmp/auth" -H "Content-Type: application/json" --data @"$tmp/request" \
    "https://cloudkms.googleapis.com/v1/$SHEET_KMS_KEY:asymmetricSign" | jq -r .signature)
else
  sig=$(openssl pkeyutl -sign -rawin -inkey "$SHEET_TEST_KEY" -in "$tmp/pae" | base64 | tr -d '\n')
  openssl pkey -in "$SHEET_TEST_KEY" -pubout -out "$tmp/pub"
fi
[[ "$sig" =~ ^[A-Za-z0-9+/]{86}==$ ]] || die "the signer returned no Ed25519 signature"
# Never write out a signature machines would refuse (wrong key, corrupted response).
printf "%s" "$sig" | base64 -d >"$tmp/sig"
openssl pkeyutl -verify -pubin -inkey "$tmp/pub" -rawin -in "$tmp/pae" -sigfile "$tmp/sig" >/dev/null ||
  die "the signature does not verify with the trusted public key"
jq -c --arg s "$sig" '.signatures = [{keyid: "", sig: $s}]' <<<"$envelope"
