#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

VERIFY_CONFIG="${VERIFY_CONFIG:-$BUILD_DIR/verify.ocmconfig}"
[[ -f "$VERIFY_CONFIG" ]] || die "Verify config not found: $VERIFY_CONFIG (run build and sign first)"

"$OCM" verify cv \
  --config "$VERIFY_CONFIG" \
  "$(cv_ref "$ROOT_COMPONENT")"
