#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM" git

SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)}"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || \
  die "SOURCE_COMMIT must be a 40-char git commit SHA (got: '${SOURCE_COMMIT}'); build from a git checkout or set SOURCE_COMMIT"
export SOURCE_COMMIT

mkdir -p "$BUILD_DIR"
rm -rf "$CTF"

# OCM_ADD_FLAGS is a user-supplied, space-separated list of extra flags;
# word splitting is intentional and an unset value must add no argument.
# shellcheck disable=SC2086
# Redirect stdin from /dev/null: OCM v0.19.0 added stdin config reading that
# hangs forever when stdin is an open pipe (devcontainer exec / CI).
"$OCM" add cv \
  --repository "ctf::${CTF}" \
  --constructor "$ROOT/component-constructor.yaml" \
  --blob-cache-directory "$BUILD_DIR/.ocm-cache" \
  ${OCM_ADD_FLAGS:-} < /dev/null

"$OCM" get cv "$(cv_ref "$ROOT_COMPONENT")" --recursive -o tree < /dev/null
