#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

SIGNING_METHOD="${SIGNING_METHOD:-rsa}"

case "$SIGNING_METHOD" in
  rsa)
    VERIFY_CONFIG="${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}"
    VERIFY_SIGNATURE="${VERIFY_SIGNATURE:-default}"
    ;;
  sigstore)
    VERIFY_CONFIG="${VERIFY_CONFIG:-$BUILD_DIR/verify-sigstore.ocmconfig}"
    VERIFY_SIGNATURE="${VERIFY_SIGNATURE:-${SIGSTORE_SIGNATURE:-sigstore}}"
    ;;
  *)
    die "unknown SIGNING_METHOD: ${SIGNING_METHOD}"
    ;;
esac

[[ -f "$VERIFY_CONFIG" ]] || die "Verify config not found: $VERIFY_CONFIG (run build and sign first)"

# Redirect stdin from /dev/null: OCM v0.19.0 hangs on open stdin pipes.
"$OCM" verify cv \
  --config "$VERIFY_CONFIG" \
  --signature "$VERIFY_SIGNATURE" \
  "$(cv_ref "$ROOT_COMPONENT")" < /dev/null
