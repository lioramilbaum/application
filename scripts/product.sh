#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM"

PRODUCT_COMPONENT="github.com/lioramilbaum/product"
PRODUCT_CTF="${PRODUCT_CTF:-$BUILD_DIR/product-ctf}"
PRODUCT_CONSTRUCTOR="$ROOT/components/product/component-constructor.yaml"
RESOLVERS_CONFIG="$BUILD_DIR/resolvers.ocmconfig"

product_ref() {
  echo "ctf::${PRODUCT_CTF}//${PRODUCT_COMPONENT}:${VERSION}"
}

_build() {
  [[ -d "$CTF" ]] || die "Application CTF not found: $CTF (run make build first)"
  bash "$ROOT/scripts/resolvers.sh" >/dev/null
  rm -rf "$PRODUCT_CTF"
  # shellcheck disable=SC2086
  "$OCM" add cv \
    --repository "ctf::$PRODUCT_CTF" \
    --constructor "$PRODUCT_CONSTRUCTOR" \
    --config "$RESOLVERS_CONFIG" \
    --external-component-version-copy-policy skip \
    ${OCM_ADD_FLAGS:-}
  local digest
  digest="$("$OCM" get cv "$(product_ref)" -o json \
    | jq -r '.[0].component.componentReferences[0].digest.value // ""')"
  [[ -n "$digest" ]] || die "reference digest was not set — could not resolve $(cv_ref "$ROOT_COMPONENT")"
}

_sign() {
  # OCM must not hang on interactive stdin: redirect from /dev/null.
  "$OCM" sign cv \
    --config "$BUILD_DIR/sign.ocmconfig" \
    --signature default \
    "$(product_ref)" < /dev/null
}

_verify() {
  # Checks only the product's own signature, NOT the referenced component's content.
  # See docs/component-graphs.md ## Component References — Trust limitation.
  "$OCM" verify cv \
    --config "${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}" \
    --signature default \
    "$(product_ref)" < /dev/null
}

_tree() {
  "$OCM" get cv "$(product_ref)" \
    --recursive --config "$RESOLVERS_CONFIG" -o tree
}

case "${1:-}" in
  build)   _build ;;
  sign)    _sign ;;
  verify)  _verify ;;
  tree)    _tree ;;
  *)       _build; echo ""; _sign; echo ""; _verify; echo ""; _tree ;;
esac
