#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require "$OCM"

[[ -n "${OCM_REPO:-}" ]] || die "OCM_REPO must be set (e.g. ghcr.io/lioramilbaum/ocm)"

"$OCM" transfer cv \
  "$(cv_ref "$ROOT_COMPONENT")" \
  "$OCM_REPO" \
  --recursive \
  --copy-resources \
  --upload-as ociArtifact
