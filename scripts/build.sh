#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

mkdir -p "$BUILD_DIR"
rm -rf "$CTF"

# OCM_ADD_FLAGS is a user-supplied, space-separated list of extra flags;
# word splitting is intentional and an unset value must add no argument.
# shellcheck disable=SC2086
"$OCM" add cv \
  --repository "ctf::${CTF}" \
  --constructor "$ROOT/component-constructor.yaml" \
  --blob-cache-directory "$BUILD_DIR/.ocm-cache" \
  ${OCM_ADD_FLAGS:-}

"$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" --recursive -o tree
