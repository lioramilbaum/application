#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM"

"$OCM" sign cv \
  --config "$BUILD_DIR/sign.ocmconfig" \
  "$(cv_ref "$ROOT_COMPONENT")"
