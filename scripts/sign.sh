#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/keys.sh
source "$(dirname "$0")/keys.sh"

require "$OCM"

# Redirect stdin from /dev/null: OCM v0.19.0 hangs on open stdin pipes.
"$OCM" sign cv \
  --config "$BUILD_DIR/sign.ocmconfig" \
  "$(cv_ref "$ROOT_COMPONENT")" < /dev/null
