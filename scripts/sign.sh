#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

SIGNING_METHOD="${SIGNING_METHOD:-rsa}"

case "$SIGNING_METHOD" in
  rsa)
    # shellcheck source=scripts/keys.sh
    source "$(dirname "$0")/keys.sh"
    cfg="$BUILD_DIR/sign.ocmconfig"
    sig="default"
    ;;
  sigstore)
    # shellcheck source=scripts/sigstore.sh
    source "$(dirname "$0")/sigstore.sh"
    # Check OIDC token is available
    if [[ -z "${SIGSTORE_ID_TOKEN:-}${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
      die "OIDC token not available for Sigstore signing; set SIGSTORE_ID_TOKEN or run in GitHub Actions with id-token: write"
    fi
    cfg="$BUILD_DIR/sign-sigstore.ocmconfig"
    sig="${SIGSTORE_SIGNATURE:-sigstore}"
    ;;
  *)
    die "unknown SIGNING_METHOD: ${SIGNING_METHOD}"
    ;;
esac

# Redirect stdin from /dev/null: OCM v0.19.0 hangs on open stdin pipes.
"$OCM" sign cv \
  --config "$cfg" \
  --signature "$sig" \
  "$(cv_ref "$ROOT_COMPONENT")" < /dev/null
