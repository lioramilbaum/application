#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq gpg

GPG_COMPONENT="github.com/lioramilbaum/gpg-demo"
GPG_SIGNATURE="gpg"
GPG_DEMO_CTF="${GPG_DEMO_CTF:-$BUILD_DIR/gpg-ctf}"
GPG_DEMO_OUT="${GPG_DEMO_OUT:-$BUILD_DIR/gpg}"
GPG_DEMO_CONSTRUCTOR="$ROOT/components/gpg/component-constructor.yaml"
KEYS="$GPG_DEMO_OUT/keys"

# Bring your own keys: set all or none.
_byo=0
for _v in GPG_PRIVATE_KEY GPG_PUBLIC_KEY; do
  [[ -z "${!_v:-}" ]] || _byo=$((_byo + 1))
done
(( _byo == 0 || _byo == 2 )) || die "set both GPG_PRIVATE_KEY and GPG_PUBLIC_KEY, or neither"
PRIVATE_KEY="${GPG_PRIVATE_KEY:-$KEYS/signer.sec.asc}"
PUBLIC_KEY="${GPG_PUBLIC_KEY:-$KEYS/signer.pub.asc}"

_gpg_ref() {
  echo "ctf::${1:-$GPG_DEMO_CTF}//${GPG_COMPONENT}:${VERSION}"
}

# _gnupg_home — create a throwaway GNUPGHOME and register a cleanup trap.
# Sets global _GNUPG_HOME; callers must pass --homedir "$_GNUPG_HOME" to gpg.
_gnupg_home() {
  _GNUPG_HOME="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  # shellcheck disable=SC2064
  trap "gpgconf --homedir '$_GNUPG_HOME' --kill all 2>/dev/null; rm -rf '$_GNUPG_HOME'" EXIT
  chmod 0700 "$_GNUPG_HOME"
}

# _gpg_batch <homedir> [args...] — run gpg with standard batch flags
_gpg_batch() {
  local h="$1"; shift
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$h" "$@"
}

# _keys_valid <fpr_file> — true if key exists and is not expiring within 86400s
_keys_valid() {
  [[ -f "$KEYS/signer.sec.asc" && -f "$KEYS/signer.pub.asc" && -f "$KEYS/signer.fpr" ]] || return 1
  local h fpr
  h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  # shellcheck disable=SC2064
  trap "gpgconf --homedir '$h' --kill all 2>/dev/null; rm -rf '$h'" RETURN
  chmod 0700 "$h"
  _gpg_batch "$h" --import "$KEYS/signer.sec.asc" 2>/dev/null || return 1
  fpr="$(cat "$KEYS/signer.fpr")"
  # Check signing subkey expiry: field 7 of the 'ssb' colons record is the expiry epoch (0 = never)
  local expiry now
  expiry="$(_gpg_batch "$h" --with-colons --list-secret-keys "$fpr" 2>/dev/null \
    | awk -F: '/^ssb/{print $7; exit}')"
  [[ -n "$expiry" ]] || return 1
  [[ "$expiry" == "0" ]] && return 0
  now="$(date +%s)"
  (( expiry - now > 86400 ))
}

# _fpr_from_key <secret-key-file> — primary fingerprint of the first secret key in the file
_fpr_from_key() {
  local h fpr
  h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  # shellcheck disable=SC2064
  trap "gpgconf --homedir '$h' --kill all 2>/dev/null; rm -rf '$h'" RETURN
  chmod 0700 "$h"
  _gpg_batch "$h" --import "$1" 2>/dev/null
  fpr="$(_gpg_batch "$h" --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  gpgconf --homedir "$h" --kill all 2>/dev/null; rm -rf "$h"
  echo "$fpr"
}

_keys() {
  if ! _keys_valid; then
    rm -rf "${KEYS:?}"
    mkdir -p "$KEYS"
    _gnupg_home
    _gpg_batch "$_GNUPG_HOME" --quick-gen-key \
      "OCM Demo Signer <signer@gpg-demo.lioramilbaum.github.com>" \
      rsa3072 cert 2y
    local fpr
    fpr="$(_gpg_batch "$_GNUPG_HOME" --with-colons --list-keys \
      "OCM Demo Signer" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
    echo "$fpr" > "$KEYS/signer.fpr"
    _gpg_batch "$_GNUPG_HOME" --quick-add-key "$fpr" rsa3072 sign 2y
    _gpg_batch "$_GNUPG_HOME" --armor --export-secret-keys "$fpr" > "$KEYS/signer.sec.asc"
    chmod 0600 "$KEYS/signer.sec.asc"
    _gpg_batch "$_GNUPG_HOME" --armor --export "$fpr" > "$KEYS/signer.pub.asc"
  fi
}

# _write_sign_config <private-key> <public-key> <fpr> <outfile> [passphrase]
_write_sign_config() {
  local priv="$1" pub="$2" fpr="$3" out="$4" pass="${5:-}"
  local pass_line=""
  [[ -z "$pass" ]] || pass_line=$'\n'"            passphrase: $pass"
  cat > "$out" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: GPG/v1alpha1
          signature: ${GPG_SIGNATURE}
        credentials:
          - type: GPGCredentials/v1alpha1
            privateKeyPGPFile: $priv
            publicKeyPGPFile: $pub${pass_line}
  - type: signing.config.ocm.software/v1alpha1
    signer:
      type: GPGSigningConfiguration/v1alpha1
      signature: ${GPG_SIGNATURE}
      keyFingerprint: $fpr
EOF
}

# _write_verify_config <public-key> <outfile> [keyFingerprint]
_write_verify_config() {
  local pub="$1" out="$2" fpr="${3:-}"
  local fpr_line=""
  [[ -z "$fpr" ]] || fpr_line=$'\n'"      keyFingerprint: $fpr"
  cat > "$out" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: GPG/v1alpha1
          signature: ${GPG_SIGNATURE}
        credentials:
          - type: GPGCredentials/v1alpha1
            publicKeyPGPFile: $pub
  - type: signing.config.ocm.software/v1alpha1
    verifier:
      type: GPGSigningConfiguration/v1alpha1
      signature: ${GPG_SIGNATURE}${fpr_line}
EOF
}

_configs() {
  local fpr
  fpr="$(cat "$KEYS/signer.fpr")"
  _write_sign_config "$PRIVATE_KEY" "$PUBLIC_KEY" "$fpr" "$GPG_DEMO_OUT/sign.ocmconfig"
  _write_verify_config "$PUBLIC_KEY" "$GPG_DEMO_OUT/verify.ocmconfig"
}

# _build_into <ctf>
_build_into() {
  "$OCM" add cv \
    --repository "ctf::$1" \
    --constructor "$GPG_DEMO_CONSTRUCTOR" \
    --config "$GPG_DEMO_OUT/verify.ocmconfig" < /dev/null >/dev/null
}

_build() {
  rm -rf "${GPG_DEMO_CTF:?}"
  _build_into "$GPG_DEMO_CTF"
}

# _sign_with <config> <ctf>
_sign_with() {
  "$OCM" sign cv --config "$1" --signature "$GPG_SIGNATURE" \
    "$(_gpg_ref "$2")" < /dev/null >/dev/null
}

# _verify_with <config> <ctf>
_verify_with() {
  "$OCM" verify cv --config "$1" --signature "$GPG_SIGNATURE" \
    "$(_gpg_ref "$2")" < /dev/null
}

_sign() {
  _sign_with "$GPG_DEMO_OUT/sign.ocmconfig" "$GPG_DEMO_CTF"
}

_verify() {
  _verify_with "${VERIFY_CONFIG:-$GPG_DEMO_OUT/verify.ocmconfig}" "$GPG_DEMO_CTF"
}

_download() {
  _verify
  local out="$GPG_DEMO_OUT/download"
  rm -rf "${out:?}"
  mkdir -p "$out"
  "$OCM" download resource --config "$GPG_DEMO_OUT/verify.ocmconfig" \
    --identity "name=release-notes" \
    --output "$out/release-notes" \
    "$(_gpg_ref)" < /dev/null >/dev/null
  # Verify download content
  local content
  content="$(cat "$out/release-notes")"
  [[ "$content" == "github.com/lioramilbaum/gpg-demo ${VERSION}" ]] \
    || die "unexpected download content: $content"
}

# _classify <stderr-file>
_classify() {
  local text
  text="$(cat "$1" 2>/dev/null || true)"
  # OCM 0.19.1
  if grep -q 'signature made by unknown entity' <<<"$text"; then
    echo unknown-key
  # OCM 0.19.1
  elif grep -q 'no key matching fingerprint' <<<"$text"; then
    echo no-matching-key
  # OCM 0.19.1
  elif grep -q 'no valid signing keys' <<<"$text"; then
    echo no-signing-key
  # OCM 0.19.1
  elif grep -q 'key expired' <<<"$text"; then
    echo key-expired
  # OCM 0.19.1
  elif grep -q 'signature made by revoked key' <<<"$text"; then
    echo revoked
  # OCM 0.19.1
  elif grep -q 'passphrase-protected but no passphrase' <<<"$text"; then
    echo passphrase-required
  # OCM 0.19.1
  elif grep -q 'unsupported media type' <<<"$text"; then
    echo media-type
  # OCM 0.19.1
  elif grep -q 'digest mismatch' <<<"$text"; then
    echo digest-mismatch
  else
    echo error
  fi
}

# _crosscheck: verify the detached OpenPGP signature with stock gpg
_crosscheck() {
  local ref sig_json sig_val digest_hex digest_bin sig_file h
  ref="$(_gpg_ref)"
  sig_json="$("$OCM" get cv "$ref" -o json --config "$GPG_DEMO_OUT/verify.ocmconfig" < /dev/null \
    | jq -c --arg s "$GPG_SIGNATURE" '.[0].signatures[]? | select(.name==$s)')"
  [[ -n "$sig_json" ]] || die "no '$GPG_SIGNATURE' signature on $ref"

  sig_val="$(jq -r '.signature.value' <<<"$sig_json")"
  digest_hex="$(jq -r '.digest.value' <<<"$sig_json")"

  # Hex-decode the digest into a binary file
  digest_bin="$(mktemp /tmp/ocm-digest.XXXXXX)"
  printf '%b' "$(echo "$digest_hex" | fold -w2 | while read -r byte; do printf '\\x%s' "$byte"; done)" > "$digest_bin"

  # Write the armored signature to a file
  sig_file="$(mktemp /tmp/ocm-sig.XXXXXX)"
  printf '%s' "$sig_val" > "$sig_file"

  h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  # shellcheck disable=SC2064
  trap "gpgconf --homedir '$h' --kill all 2>/dev/null; rm -rf '$h'; rm -f '$digest_bin' '$sig_file'" RETURN
  chmod 0700 "$h"
  _gpg_batch "$h" --import "$PUBLIC_KEY" 2>/dev/null

  local signing_fpr primary_fpr
  if _gpg_batch "$h" --status-fd 1 --verify "$sig_file" "$digest_bin" 2>/dev/null \
      | grep -q '^\[GNUPG:\] VALIDSIG'; then
    signing_fpr="$(_gpg_batch "$h" --status-fd 1 --verify "$sig_file" "$digest_bin" 2>/dev/null \
      | awk '/^\[GNUPG:\] VALIDSIG/{print $3}')"
    primary_fpr="$(_gpg_batch "$h" --status-fd 1 --verify "$sig_file" "$digest_bin" 2>/dev/null \
      | awk '/^\[GNUPG:\] VALIDSIG/{print $12}')"
    printf 'crosscheck\tgood\t%s\t%s\n' "$signing_fpr" "$primary_fpr"
  else
    die "crosscheck: gpg --verify failed for $ref"
  fi
}

# _multi: sign with both RSA default and GPG, show both signatures
_multi() {
  local dir="$GPG_DEMO_OUT/multi-ctf"
  rm -rf "${dir:?}"
  cp -R "$GPG_DEMO_CTF" "$dir"

  # Sign with RSA default
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_gpg_ref "$dir")" < /dev/null >/dev/null

  # Sign with GPG
  _sign_with "$GPG_DEMO_OUT/sign.ocmconfig" "$dir"

  # Write combined verify config
  local verify_all="$GPG_DEMO_OUT/verify-all.ocmconfig"
  local fpr
  fpr="$(cat "$KEYS/signer.fpr")"
  cat > "$verify_all" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: $BUILD_DIR/keys/public.pem
      - identity:
          type: GPG/v1alpha1
          signature: ${GPG_SIGNATURE}
        credentials:
          - type: GPGCredentials/v1alpha1
            publicKeyPGPFile: $PUBLIC_KEY
  - type: signing.config.ocm.software/v1alpha1
    verifier:
      type: GPGSigningConfiguration/v1alpha1
      signature: ${GPG_SIGNATURE}
EOF

  # Print both signatures
  "$OCM" get cv "$(_gpg_ref "$dir")" -o json --config "$verify_all" < /dev/null \
    | jq -r '.[0].signatures[]? | ["signature", .name, .signature.algorithm, .signature.mediaType, .digest.value] | @tsv'

  # Verify with scoped GPG verifier (--signature gpg; verifies only gpg signature)
  local verify_ok=ok verify_reason=-
  if ! "$OCM" verify cv --config "$verify_all" --signature "$GPG_SIGNATURE" "$(_gpg_ref "$dir")" < /dev/null >/dev/null 2>/dev/null; then
    verify_ok=fail
    local tmpf; tmpf="$(mktemp)"
    "$OCM" verify cv --config "$verify_all" --signature "$GPG_SIGNATURE" "$(_gpg_ref "$dir")" < /dev/null >/dev/null 2>"$tmpf" || true
    verify_reason="$(_classify "$tmpf")"
    rm -f "$tmpf"
  fi
  printf 'verify\tscoped\t%s\t%s\n' "$verify_ok" "$verify_reason"

  # Write unscoped verify config (no signature: gpg scope on the verifier)
  local verify_unscoped="$GPG_DEMO_OUT/verify-unscoped.ocmconfig"
  cat > "$verify_unscoped" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: $BUILD_DIR/keys/public.pem
      - identity:
          type: GPG/v1alpha1
          signature: ${GPG_SIGNATURE}
        credentials:
          - type: GPGCredentials/v1alpha1
            publicKeyPGPFile: $PUBLIC_KEY
  - type: signing.config.ocm.software/v1alpha1
    verifier:
      type: GPGSigningConfiguration/v1alpha1
EOF

  local verify2_ok=ok verify2_reason=-
  if ! "$OCM" verify cv --config "$verify_unscoped" "$(_gpg_ref "$dir")" < /dev/null >/dev/null 2>/dev/null; then
    verify2_ok=fail
    local tmpf2; tmpf2="$(mktemp)"
    "$OCM" verify cv --config "$verify_unscoped" "$(_gpg_ref "$dir")" < /dev/null >/dev/null 2>"$tmpf2" || true
    verify2_reason="$(_classify "$tmpf2")"
    rm -f "$tmpf2"
  fi
  printf 'verify\tunscoped\t%s\t%s\n' "$verify2_ok" "$verify2_reason"
}

_scenario_keys() {
  local h="$1"

  # rotated: another valid signer key
  _gpg_batch "$h" --quick-gen-key "OCM Demo Rotated <rotated@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 2y
  local rot_fpr
  rot_fpr="$(_gpg_batch "$h" --with-colons --list-keys "OCM Demo Rotated" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  echo "$rot_fpr" > "$KEYS/scenarios/rotated.fpr"
  _gpg_batch "$h" --quick-add-key "$rot_fpr" rsa3072 sign 2y
  _gpg_batch "$h" --armor --export-secret-keys "$rot_fpr" > "$KEYS/scenarios/rotated.sec.asc"
  chmod 0600 "$KEYS/scenarios/rotated.sec.asc"
  _gpg_batch "$h" --armor --export "$rot_fpr" > "$KEYS/scenarios/rotated.pub.asc"

  # keyring: both signer and rotated in one export
  local main_fpr
  main_fpr="$(cat "$KEYS/signer.fpr")"
  _gpg_batch "$h" --import "$PRIVATE_KEY" 2>/dev/null
  _gpg_batch "$h" --armor --export "$main_fpr" "$rot_fpr" > "$KEYS/scenarios/keyring.pub.asc"

  # other: a third key not in the verifier's keyring
  _gpg_batch "$h" --quick-gen-key "OCM Demo Other <other@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 2y
  local other_fpr
  other_fpr="$(_gpg_batch "$h" --with-colons --list-keys "OCM Demo Other" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  _gpg_batch "$h" --quick-add-key "$other_fpr" rsa3072 sign 2y
  _gpg_batch "$h" --armor --export-secret-keys "$other_fpr" > "$KEYS/scenarios/other.sec.asc"
  chmod 0600 "$KEYS/scenarios/other.sec.asc"
  _gpg_batch "$h" --armor --export "$other_fpr" > "$KEYS/scenarios/other.pub.asc"

  # locked: a signer key protected by passphrase "secret", created with that passphrase
  # (gpg --passwd in batch mode leaves the key unprotected)
  local locked_h locked_fpr
  locked_h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  chmod 0700 "$locked_h"
  gpg --batch --quiet --pinentry-mode loopback --passphrase 'secret' --homedir "$locked_h" \
    --quick-gen-key "OCM Demo Locked <locked@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 2y
  locked_fpr="$(gpg --batch --quiet --homedir "$locked_h" --with-colons --list-keys \
    "OCM Demo Locked" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  echo "$locked_fpr" > "$KEYS/scenarios/locked.fpr"
  gpg --batch --quiet --pinentry-mode loopback --passphrase 'secret' --homedir "$locked_h" \
    --quick-add-key "$locked_fpr" rsa3072 sign 2y
  gpg --batch --quiet --pinentry-mode loopback --passphrase 'secret' --homedir "$locked_h" \
    --armor --export-secret-keys "$locked_fpr" > "$KEYS/scenarios/locked.sec.asc"
  chmod 0600 "$KEYS/scenarios/locked.sec.asc"
  gpg --batch --quiet --homedir "$locked_h" --armor --export "$locked_fpr" > "$KEYS/scenarios/locked.pub.asc"
  gpgconf --homedir "$locked_h" --kill all 2>/dev/null; rm -rf "$locked_h"

  # expired: key created at 2020-01-01, valid 1 day
  local fake_home
  fake_home="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  chmod 0700 "$fake_home"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$fake_home" \
    --faked-system-time 20200101T000000! \
    --quick-gen-key "OCM Demo Expired <expired@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 1d
  local exp_fpr
  exp_fpr="$(gpg --batch --quiet --homedir "$fake_home" --with-colons --list-keys \
    "OCM Demo Expired" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$fake_home" \
    --faked-system-time 20200101T000000! \
    --quick-add-key "$exp_fpr" rsa3072 sign 1d
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$fake_home" \
    --armor --export-secret-keys "$exp_fpr" > "$KEYS/scenarios/expired.sec.asc"
  chmod 0600 "$KEYS/scenarios/expired.sec.asc"
  gpg --batch --quiet --homedir "$fake_home" --armor --export "$exp_fpr" > "$KEYS/scenarios/expired.pub.asc"
  gpgconf --homedir "$fake_home" --kill all 2>/dev/null; rm -rf "$fake_home"

  # lapsed: created 2025-01-01 with no expiry, then self-sig updated to expire 2025-03-01
  # Secret key exported before the expiry update, public key after.
  local lapsed_h
  lapsed_h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  chmod 0700 "$lapsed_h"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$lapsed_h" \
    --faked-system-time 20250101T000000! \
    --quick-gen-key "OCM Demo Lapsed <lapsed@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 0
  local lapsed_fpr
  lapsed_fpr="$(gpg --batch --quiet --homedir "$lapsed_h" --with-colons --list-keys \
    "OCM Demo Lapsed" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$lapsed_h" \
    --faked-system-time 20250101T000000! \
    --quick-add-key "$lapsed_fpr" rsa3072 sign 0
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$lapsed_h" \
    --armor --export-secret-keys "$lapsed_fpr" > "$KEYS/scenarios/lapsed.sec.asc"
  chmod 0600 "$KEYS/scenarios/lapsed.sec.asc"
  # Update the self-signature to add an expiry of 2025-03-01
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --homedir "$lapsed_h" \
    --faked-system-time 20250201T000000! \
    --quick-set-expire "$lapsed_fpr" 20250301T000000 2>/dev/null || true
  gpg --batch --quiet --homedir "$lapsed_h" --armor --export "$lapsed_fpr" > "$KEYS/scenarios/lapsed.pub.asc"
  gpgconf --homedir "$lapsed_h" --kill all 2>/dev/null; rm -rf "$lapsed_h"

  # revoked: export secret key, then import revocation cert and export updated public key
  _gpg_batch "$h" --quick-gen-key "OCM Demo Revoked <revoked@gpg-demo.lioramilbaum.github.com>" rsa3072 cert 2y
  local rev_fpr
  rev_fpr="$(_gpg_batch "$h" --with-colons --list-keys "OCM Demo Revoked" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  _gpg_batch "$h" --quick-add-key "$rev_fpr" rsa3072 sign 2y
  _gpg_batch "$h" --armor --export-secret-keys "$rev_fpr" > "$KEYS/scenarios/revoked.sec.asc"
  chmod 0600 "$KEYS/scenarios/revoked.sec.asc"
  # Import the auto-generated revocation cert
  local rev_cert="$h/openpgp-revocs.d/${rev_fpr}.rev"
  if [[ -f "$rev_cert" ]]; then
    sed 's/^://' "$rev_cert" | _gpg_batch "$h" --import 2>/dev/null || true
  fi
  _gpg_batch "$h" --armor --export "$rev_fpr" > "$KEYS/scenarios/revoked.pub.asc"
}

_scenarios() {
  [[ -z "${GPG_PRIVATE_KEY:-}" ]] || die "scenarios use the generated demo keys; unset GPG_PRIVATE_KEY and GPG_PUBLIC_KEY"
  mkdir -p "$KEYS/scenarios"

  # Build scenario keys in one shared home (signer key is already at KEYS/)
  local h
  h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  chmod 0700 "$h"
  _scenario_keys "$h"
  # $h is only needed for key generation; clean up here so the EXIT trap set by _keys survives
  gpgconf --homedir "$h" --kill all 2>/dev/null || true
  rm -rf "$h"

  local dir="$GPG_DEMO_OUT/scenarios"
  rm -rf "${dir:?}"
  mkdir -p "$dir"
  _build_into "$dir/base-ctf"

  local main_fpr rot_fpr locked_fpr subkey_fpr
  main_fpr="$(cat "$KEYS/signer.fpr")"
  rot_fpr="$(cat "$KEYS/scenarios/rotated.fpr")"
  locked_fpr="$(cat "$KEYS/scenarios/locked.fpr")"
  # Get the signing subkey fingerprint
  local sub_h
  sub_h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  chmod 0700 "$sub_h"
  _gpg_batch "$sub_h" --import "$PRIVATE_KEY" 2>/dev/null
  subkey_fpr="$(_gpg_batch "$sub_h" --with-colons --list-secret-keys "$main_fpr" 2>/dev/null \
    | awk -F: 'f && /^fpr/{print $10; exit} /^ssb/{f=1}')"
  gpgconf --homedir "$sub_h" --kill all 2>/dev/null; rm -rf "$sub_h"

  # rows: "scenario private_key public_key [sign_fpr_override] [pass]"
  # Special handling for complex scenarios is done inline in the loop
  local rows=(
    "valid $PRIVATE_KEY $KEYS/signer.pub.asc"
    "rotated-key $KEYS/scenarios/rotated.sec.asc $KEYS/scenarios/keyring.pub.asc"
    "concatenated-keyring $KEYS/scenarios/rotated.sec.asc concat"
    "wrong-key $KEYS/scenarios/other.sec.asc $KEYS/signer.pub.asc"
    "verifier-pins-other-key $PRIVATE_KEY $KEYS/scenarios/keyring.pub.asc"
    "pinned-subkey $PRIVATE_KEY $KEYS/signer.pub.asc"
    "expired-key $KEYS/scenarios/expired.sec.asc $KEYS/scenarios/expired.pub.asc"
    "expired-after-signing $KEYS/scenarios/lapsed.sec.asc $KEYS/scenarios/lapsed.pub.asc"
    "revoked-key $KEYS/scenarios/revoked.sec.asc $KEYS/scenarios/revoked.pub.asc"
    "protected-key $KEYS/scenarios/locked.sec.asc $KEYS/scenarios/locked.pub.asc"
    "protected-key-no-passphrase $KEYS/scenarios/locked.sec.asc $KEYS/scenarios/locked.pub.asc"
    "sha512-signature $PRIVATE_KEY $KEYS/signer.pub.asc"
    "default-verifier $PRIVATE_KEY $KEYS/signer.pub.asc"
  )

  local row name priv pub ctf sign_state verify_state reason
  for row in "${rows[@]}"; do
    read -r name priv pub <<<"$row"
    ctf="$dir/$name-ctf"
    rm -rf "${ctf:?}"
    cp -R "$dir/base-ctf" "$ctf"

    local sign_fpr="$main_fpr" pass=""
    case "$name" in
      rotated-key)          sign_fpr="$rot_fpr" ;;
      concatenated-keyring) sign_fpr="$rot_fpr"
                            # concat two armored files (only first key loads)
                            pub="$dir/concatenated.pub.asc"
                            cat "$KEYS/signer.pub.asc" "$KEYS/scenarios/rotated.pub.asc" > "$pub" ;;
      verifier-pins-other-key) ;;  # signer=main, verifier has keyring + pin=rotated
      pinned-subkey)        sign_fpr="$subkey_fpr" ;;
      wrong-key)            sign_fpr="" ;;  # signer is the other key, not the main fpr
      expired-key)          sign_fpr="" ;;  # use whatever fpr is in the key
      expired-after-signing) sign_fpr="" ;;
      revoked-key)          sign_fpr="" ;;
      protected-key)        sign_fpr=""; pass="secret" ;;
      protected-key-no-passphrase) sign_fpr="" ;;
    esac

    # Write sign config
    local sign_cfg="$dir/$name-sign.ocmconfig"
    if [[ -n "$sign_fpr" ]]; then
      _write_sign_config "$priv" "$pub" "$sign_fpr" "$sign_cfg" "$pass"
    else
      # For expired/lapsed/revoked: extract the fpr from the key file itself
      local tmp_h_k
      tmp_h_k="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
      chmod 0700 "$tmp_h_k"
      _gpg_batch "$tmp_h_k" --import "$priv" 2>/dev/null
      local auto_fpr
      auto_fpr="$(_gpg_batch "$tmp_h_k" --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
      gpgconf --homedir "$tmp_h_k" --kill all 2>/dev/null; rm -rf "$tmp_h_k"
      _write_sign_config "$priv" "$pub" "$auto_fpr" "$sign_cfg" "$pass"
    fi

    # Write verify config
    local verify_cfg="$dir/$name-verify.ocmconfig"
    case "$name" in
      verifier-pins-other-key)
        _write_verify_config "$KEYS/scenarios/keyring.pub.asc" "$verify_cfg" "$rot_fpr" ;;
      default-verifier)
        # No GPG verifier entry at all — the signing config still has GPG credentials
        cat > "$verify_cfg" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: GPG/v1alpha1
          signature: ${GPG_SIGNATURE}
        credentials:
          - type: GPGCredentials/v1alpha1
            publicKeyPGPFile: $pub
EOF
        ;;
      sha512-signature)
        # Write a sign config with hashAlgorithm: SHA-512
        cat > "$sign_cfg" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: GPG/v1alpha1
          signature: ${GPG_SIGNATURE}
        credentials:
          - type: GPGCredentials/v1alpha1
            privateKeyPGPFile: $priv
            publicKeyPGPFile: $pub
  - type: signing.config.ocm.software/v1alpha1
    signer:
      type: GPGSigningConfiguration/v1alpha1
      signature: ${GPG_SIGNATURE}
      keyFingerprint: $main_fpr
      hashAlgorithm: SHA-512
EOF
        _write_verify_config "$pub" "$verify_cfg" ;;
      *)
        _write_verify_config "$pub" "$verify_cfg" ;;
    esac

    sign_state=ok verify_state=ok reason=-
    if ! _sign_with "$sign_cfg" "$ctf" 2>"$dir/$name.sign.stderr"; then
      sign_state=fail verify_state=- reason="$(_classify "$dir/$name.sign.stderr")"
    elif ! _verify_with "$verify_cfg" "$ctf" >/dev/null 2>"$dir/$name.verify.stderr"; then
      verify_state=fail reason="$(_classify "$dir/$name.verify.stderr")"
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$sign_state" "$verify_state" "$reason"
  done
}

_show() {
  local ref sig_json signing_fpr primary_fpr alg_name
  ref="$(_gpg_ref)"
  sig_json="$("$OCM" get cv "$ref" -o json --config "$GPG_DEMO_OUT/verify.ocmconfig" < /dev/null \
    | jq -c --arg s "$GPG_SIGNATURE" '.[0].signatures[]? | select(.name==$s)')"
  [[ -n "$sig_json" ]] || die "no '$GPG_SIGNATURE' signature on $ref (run scripts/gpg.sh sign first)"

  jq -r '["signature", .name, .signature.algorithm, .signature.mediaType] | @tsv' <<<"$sig_json"
  jq -r '["digest", .digest.normalisationAlgorithm, .digest.hashAlgorithm, .digest.value] | @tsv' <<<"$sig_json"

  # Cross-check with gpg to get signing key and algorithm info
  local sig_val digest_hex digest_bin sig_file
  sig_val="$(jq -r '.signature.value' <<<"$sig_json")"
  digest_hex="$(jq -r '.digest.value' <<<"$sig_json")"
  digest_bin="$(mktemp /tmp/ocm-digest.XXXXXX)"
  printf '%b' "$(echo "$digest_hex" | fold -w2 | while read -r byte; do printf '\\x%s' "$byte"; done)" > "$digest_bin"
  sig_file="$(mktemp /tmp/ocm-sig.XXXXXX)"
  printf '%s' "$sig_val" > "$sig_file"

  local h
  h="$(mktemp -d /tmp/ocm-gpg.XXXXXX)"
  # shellcheck disable=SC2064
  trap "gpgconf --homedir '$h' --kill all 2>/dev/null; rm -rf '$h'; rm -f '$digest_bin' '$sig_file'" RETURN
  chmod 0700 "$h"
  _gpg_batch "$h" --import "$PUBLIC_KEY" 2>/dev/null

  local status_output
  status_output="$(_gpg_batch "$h" --status-fd 1 --verify "$sig_file" "$digest_bin" 2>/dev/null || true)"
  signing_fpr="$(awk '/^\[GNUPG:\] VALIDSIG/{print $3}' <<<"$status_output")"
  primary_fpr="$(awk '/^\[GNUPG:\] VALIDSIG/{print $12}' <<<"$status_output")"
  local hash_algo_num
  hash_algo_num="$(awk '/^\[GNUPG:\] VALIDSIG/{print $10}' <<<"$status_output")"

  case "$hash_algo_num" in
    8)  alg_name="SHA-256" ;;
    9)  alg_name="SHA-384" ;;
    10) alg_name="SHA-512" ;;
    *)  alg_name="algo-$hash_algo_num" ;;
  esac

  # Get key UID
  local uid
  uid="$(_gpg_batch "$h" --with-colons --list-keys "$primary_fpr" 2>/dev/null \
    | awk -F: '/^uid/{print $10; exit}')"
  printf 'key\t%s\t%s\n' "$primary_fpr" "$uid"
  printf 'signed-by\t%s\t%s\n' "$signing_fpr" "$alg_name"
}

mkdir -p "$GPG_DEMO_OUT"
if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
  mkdir -p "$KEYS"
  _fpr_from_key "$PRIVATE_KEY" > "$KEYS/signer.fpr"
else
  _keys
fi
_configs

case "${1:-}" in
  keys)        ;;
  build)       _build ;;
  sign)        _sign ;;
  verify)      _verify ;;
  download)    _download ;;
  crosscheck)  _crosscheck ;;
  multi)       _multi ;;
  scenarios)   _scenarios ;;
  show)        _show ;;
  *)           _build; _sign; _verify; _download; echo ""; _show ;;
esac
