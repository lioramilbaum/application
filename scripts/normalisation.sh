#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM" jq

NORM_DEMO_OUT="${NORM_DEMO_OUT:-$BUILD_DIR/normalisation}"
NORM_JQ="$ROOT/components/normalisation/jsonNormalisation-v4alpha1.jq"
CTF="${CTF:-$BUILD_DIR/ctf}"
APP_COMPONENT="github.com/lioramilbaum/application"
APP_REF="ctf::${CTF}//${APP_COMPONENT}:${VERSION}"

_ocm_digest() {
  "$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" \
    --dry-run -o json "$1" </dev/null 2>/dev/null \
    | jq -r '.digest.value'
}

# The file is compact and unterminated: that is the byte sequence OCM hashes.
_jq_digest() {
  local normalised="$NORM_DEMO_OUT/tmp-normalised.json"
  "$OCM" get cv "$1" -o json </dev/null \
    | jq -jcS -f "$NORM_JQ" > "$normalised"
  sha256 "$normalised"
}

_normalise() {
  [[ -d "$CTF" ]] || die "Application CTF not found: $CTF (run make build first)"
  mkdir -p "$NORM_DEMO_OUT"

  local normalised="$NORM_DEMO_OUT/application.normalised.json"
  "$OCM" get cv "$APP_REF" -o json </dev/null \
    | jq -jcS -f "$NORM_JQ" > "$normalised"

  local jq_digest ocm_digest
  jq_digest="$(sha256 "$normalised")"
  ocm_digest="$(_ocm_digest "$APP_REF")"

  jq . "$normalised"
  echo ""
  printf 'sha256\t%s\n' "$jq_digest"
  printf 'ocm\t%s\n' "$ocm_digest"
  [[ "$jq_digest" == "$ocm_digest" ]] || die "normalisation drifted from OCM"
}

# _variant <name> <note> <channel> <payload>
# Builds one variant CTF and prints: name, resource digest, component digest, jq-matches-ocm.
_variant() {
  local name="$1" note="$2" channel="$3" payload="$4"
  local ctf="$NORM_DEMO_OUT/${name}-ctf"
  rm -rf "${ctf:?}"
  NORM_NOTE="$note" NORM_CHANNEL="$channel" NORM_PAYLOAD="$payload" \
    "$OCM" add cv --repository "ctf::$ctf" \
      --constructor "$ROOT/components/normalisation/component-constructor.yaml" \
      </dev/null >/dev/null

  local ref="ctf::${ctf}//github.com/lioramilbaum/normalisation-demo:${VERSION}"
  local r_digest ocm_digest jq_digest jq_ok
  r_digest="$("$OCM" get cv "$ref" -o json </dev/null \
    | jq -r '.[0].component.resources[0].digest.value')"
  ocm_digest="$(_ocm_digest "$ref")"
  jq_digest="$(_jq_digest "$ref")"

  if [[ "$jq_digest" == "$ocm_digest" ]]; then jq_ok="yes"; else jq_ok="no"; fi
  [[ "$jq_ok" == "yes" ]] || die "jq normalisation mismatch for variant $name"

  printf '%s\t%s\t%s\t%s\n' "$name" "$r_digest" "$ocm_digest" "$jq_ok"
}

_compare() {
  mkdir -p "$NORM_DEMO_OUT"
  local rows base_resource base_component name r_digest c_digest jq_ok r_changed c_changed

  rows="$(
    _variant base           "base note"    "stable"  "hello world"
    _variant unsigned-label "new note"     "stable"  "hello world"
    _variant signed-label   "base note"    "changed" "hello world"
    _variant blob           "base note"    "stable"  "different payload"
  )"
  base_resource="$(awk -F'\t' '$1 == "base" { print $2 }' <<<"$rows")"
  base_component="$(awk -F'\t' '$1 == "base" { print $3 }' <<<"$rows")"

  printf 'variant\tresource-digest\tcomponent-digest\tresource-changed\tcomponent-changed\tjq-matches-ocm\n'
  while IFS=$'\t' read -r name r_digest c_digest jq_ok; do
    if [[ "$name" == base ]]; then
      r_changed="-"; c_changed="-"
    else
      if [[ "$r_digest" == "$base_resource" ]]; then r_changed="no"; else r_changed="yes"; fi
      if [[ "$c_digest" == "$base_component" ]]; then c_changed="no"; else c_changed="yes"; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$r_digest" "$c_digest" "$r_changed" "$c_changed" "$jq_ok"
  done <<<"$rows"
}

_algorithms() {
  printf 'jsonNormalisation/v4alpha1\tsupported\n'
  local err
  err="$("$OCM" sign cv --config "$BUILD_DIR/sign.ocmconfig" \
    --dry-run --normalisation "jsonNormalisation/v1" \
    "ctf::$NORM_DEMO_OUT/base-ctf//github.com/lioramilbaum/normalisation-demo:${VERSION}" \
    </dev/null 2>&1 || true)"
  printf 'jsonNormalisation/v1\trejected\t%s\n' "$(echo "$err" | grep -o 'unknown normalisation.*' | head -1)"
}

mkdir -p "$NORM_DEMO_OUT"

case "${1:-}" in
  normalise)   _normalise ;;
  compare)     _compare ;;
  algorithms)  _compare >/dev/null 2>&1; _algorithms ;;
  *)           _normalise; echo ""; _compare; echo ""; _algorithms ;;
esac
