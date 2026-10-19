#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq

NONE_DEMO_CTF="${NONE_DEMO_CTF:-$BUILD_DIR/none-access-ctf}"
NONE_DEMO_OUT="${NONE_DEMO_OUT:-$BUILD_DIR/none-access}"
NONE_PROVENANCE_FILE="${NONE_PROVENANCE_FILE:-$ROOT/components/none-access/provenance.json}"
NONE_COMPONENT="github.com/lioramilbaum/none-access-demo"

_component_ref() {
  echo "ctf::${NONE_DEMO_CTF}//${NONE_COMPONENT}:${VERSION}"
}

_ocm_digest() {
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" \
    --dry-run -o json "$1" </dev/null 2>/dev/null \
    | jq -r '.digest.value'
}

_build() {
  rm -rf "${NONE_DEMO_CTF:?}"
  "$OCM" add cv --repository "ctf::$NONE_DEMO_CTF" \
    --constructor "$ROOT/components/none-access/component-constructor.yaml" \
    </dev/null 2>&1 | tee "$NONE_DEMO_OUT/build.log"
}

_sign() {
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --signature default \
    "$(_component_ref)" </dev/null 2>&1 | tee "$NONE_DEMO_OUT/sign.log"
}

_verify() {
  "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
    "$(_component_ref)" </dev/null
}

_download() {
  printf 'resource\tresult\n'
  # release-notes: downloadable
  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  if "$OCM" download resource \
      --identity "name=release-notes" \
      --output "$stage/release-notes" \
      "$(_component_ref)" </dev/null >/dev/null 2>&1; then
    printf 'release-notes\tok\n'
  else
    printf 'release-notes\tfailed\n'
  fi
  # provenance: no access plugin
  local err
  err="$("$OCM" download resource \
    --identity "name=provenance" \
    --output "$stage/provenance" \
    "$(_component_ref)" </dev/null 2>&1 || true)"
  rm -f "$stage/provenance"
  if echo "$err" | grep -q "failed to get plugin\|no downloader\|access.*None\|plugin.*None"; then
    printf 'provenance\tno-access\n'
  else
    printf 'provenance\tunexpected: %s\n' "$(echo "$err" | head -1)"
  fi
}

_audit() {
  _verify >/dev/null
  local label_value actual_sha
  label_value="$("$OCM" get cv "$(_component_ref)" -o json </dev/null \
    | jq -r '.[0].component.resources[] | select(.name=="provenance") |
              .labels[] | select(.name=="none-access.lioramilbaum.github.com/sha256") | .value')"
  actual_sha="$(sha256 "$NONE_PROVENANCE_FILE")"
  if [[ "$label_value" == "$actual_sha" ]]; then
    printf 'audit\tpassed\t%s\n' "$actual_sha"
  else
    die "audit failed: label=$label_value file=$actual_sha"
  fi
}

# _variant_row <name> <constructor> <base-digest>
# Builds one variant and prints: name, access type, has digest, component digest,
# same as the base digest ("-" for the base itself), and the first sign warning.
_variant_row() {
  local name="$1" constructor="$2" base="$3"
  local ctf="$NONE_DEMO_OUT/variants/${name}-ctf"
  local ref="ctf::${ctf}//${NONE_COMPONENT}:${VERSION}"
  rm -rf "${ctf:?}"
  "$OCM" add cv --repository "ctf::$ctf" --constructor "$constructor" </dev/null >/dev/null 2>&1

  local descriptor access has_digest digest warn same warning
  descriptor="$("$OCM" get cv "$ref" -o json </dev/null)"
  # Every variant has a single resource, so the first one is the None resource.
  access="$(jq -r '.[0].component.resources[0].access.type' <<<"$descriptor")"
  has_digest="$(jq -r '.[0].component.resources[0] | if .digest then "yes" else "no" end' <<<"$descriptor")"
  digest="$(_ocm_digest "$ref")"
  warn="$("$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" --dry-run "$ref" </dev/null 2>&1 >/dev/null || true)"
  warning="$(sed -n 's/.*level=WARN .*error="\([^"]*\)".*/\1/p' <<<"$warn" | head -n1)"
  [[ -n "$warning" ]] || warning="none"

  same="-"
  if [[ -n "$base" && "$name" != base ]]; then
    same="no"
    if [[ "$digest" == "$base" ]]; then same="yes"; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$access" "$has_digest" "$digest" "$same" "$warning"
}

# _digest_block <value>: an explicit digest on the resource, as the constructor writes it.
_digest_block() {
  printf '    digest:\n      hashAlgorithm: SHA-256\n      normalisationAlgorithm: genericBlobDigest/v1\n      value: "%s"\n' "$1"
}

# _base_constructor <file> <access-type> <name> <label-value> [extra-yaml]
_base_constructor() {
  local file="$1" access_type="$2" name="$3" label="$4" extra="${5:-}"
  if [[ -n "$extra" ]]; then extra="$extra"$'\n'; fi
  cat > "$file" <<EOF
name: ${NONE_COMPONENT}
version: ${VERSION}
provider:
  name: github.com/lioramilbaum
resources:
  - name: ${name}
    type: blob
    version: ${VERSION}
    relation: external
    access:
      type: ${access_type}
${extra}    labels:
      - name: none-access.lioramilbaum.github.com/sha256
        value: "${label}"
        signing: true
EOF
}

_variants() {
  mkdir -p "$NONE_DEMO_OUT/variants"
  local prov_sha; prov_sha="$(sha256 "$ROOT/components/none-access/provenance.json")"
  local vdir="$NONE_DEMO_OUT/variants"

  printf 'variant\taccess-type\thas-digest\tcomponent-digest\tsame-as-base\tsign-warning\n'

  # base: plain None, no digest
  _base_constructor "$vdir/base-constructor.yaml" None provenance "$prov_sha"
  local base_row base_digest
  base_row="$(_variant_row base "$vdir/base-constructor.yaml" "")"
  printf '%s\n' "$base_row"
  base_digest="$(cut -f4 <<<"$base_row")"

  # digest-a: None + an explicit digest
  _base_constructor "$vdir/digest-a-constructor.yaml" None provenance "$prov_sha" \
    "$(_digest_block "$(printf 'a%.0s' {1..64})")"
  _variant_row digest-a "$vdir/digest-a-constructor.yaml" "$base_digest"

  # digest-b: a different explicit digest
  _base_constructor "$vdir/digest-b-constructor.yaml" None provenance "$prov_sha" \
    "$(_digest_block "$(printf 'b%.0s' {1..64})")"
  _variant_row digest-b "$vdir/digest-b-constructor.yaml" "$base_digest"

  # lowercase: type "none" (lowercase)
  _base_constructor "$vdir/lowercase-constructor.yaml" none provenance "$prov_sha"
  _variant_row lowercase "$vdir/lowercase-constructor.yaml" "$base_digest"

  # versioned-type: None/v1 (treated as unknown, digest IS signed)
  _base_constructor "$vdir/v1-constructor.yaml" "None/v1" provenance "$prov_sha" \
    "$(_digest_block "$(printf 'a%.0s' {1..64})")"
  _variant_row versioned-type "$vdir/v1-constructor.yaml" "$base_digest"

  # renamed: different resource name -> different component digest
  _base_constructor "$vdir/renamed-constructor.yaml" None attestation "$prov_sha"
  _variant_row renamed "$vdir/renamed-constructor.yaml" "$base_digest"

  # label-changed: different label value -> different component digest
  _base_constructor "$vdir/label-constructor.yaml" None provenance "$(printf '0%.0s' {1..64})"
  _variant_row label-changed "$vdir/label-constructor.yaml" "$base_digest"
}

_transfer() {
  printf 'mode\taccess-after-transfer\tverify\n'
  local plain_ctf="$NONE_DEMO_OUT/plain-ctf"
  rm -rf "${plain_ctf:?}"
  "$OCM" transfer cv "$(_component_ref)" "ctf::$plain_ctf" </dev/null >/dev/null
  local plain_access
  plain_access="$("$OCM" get cv "ctf::${plain_ctf}//${NONE_COMPONENT}:${VERSION}" \
    -o json </dev/null | jq -r '.[0].component.resources[] | select(.name=="provenance") | .access.type')"
  local plain_verify
  if "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
      "ctf::${plain_ctf}//${NONE_COMPONENT}:${VERSION}" </dev/null >/dev/null 2>&1; then
    plain_verify="ok"
  else
    plain_verify="failed"
  fi
  printf 'plain\t%s\t%s\n' "$plain_access" "$plain_verify"

  local copy_ctf="$NONE_DEMO_OUT/copy-ctf"
  rm -rf "${copy_ctf:?}"
  "$OCM" transfer cv --copy-resources "$(_component_ref)" "ctf::$copy_ctf" </dev/null >/dev/null
  local copy_access
  copy_access="$("$OCM" get cv "ctf::${copy_ctf}//${NONE_COMPONENT}:${VERSION}" \
    -o json </dev/null | jq -r '.[0].component.resources[] | select(.name=="provenance") | .access.type')"
  local copy_verify
  if "$OCM" verify cv --config "$BUILD_DIR/verify.ocmconfig" --signature default \
      "ctf::${copy_ctf}//${NONE_COMPONENT}:${VERSION}" </dev/null >/dev/null 2>&1; then
    copy_verify="ok"
  else
    copy_verify="failed"
  fi
  printf 'copy-resources\t%s\t%s\n' "$copy_access" "$copy_verify"
}

_show() {
  "$OCM" get cv "$(_component_ref)" -o json </dev/null | jq -r '
    .[0].component.resources[] |
    [.name, .access.type, (.digest.value // "none"),
     ((.labels // [])[] | select(.name | contains("sha256")) | .value) // "-"]
    | @tsv'
}

mkdir -p "$NONE_DEMO_OUT"

case "${1:-}" in
  build)    _build ;;
  sign)     _sign ;;
  verify)   _verify ;;
  download) _download ;;
  audit)    _audit ;;
  variants) _variants ;;
  transfer) _transfer ;;
  show)     _show ;;
  *)        _build; _sign; _verify; echo ""; _show; echo ""; _download; echo ""; _audit; echo ""; _variants; echo ""; _transfer ;;
esac
