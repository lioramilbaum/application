#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/registry-credentials.sh
source "$(dirname "$0")/registry-credentials.sh"

require "$OCM"

[[ -n "${OCM_REPO:-}" ]] || die "OCM_REPO must be set (e.g. ghcr.io/lioramilbaum/ocm)"

if [[ -n "${OCM_REGISTRY_USERNAME:-}" || -n "${OCM_REGISTRY_PASSWORD:-}" ]]; then
  [[ -n "${OCM_REGISTRY_USERNAME:-}" ]] || die "OCM_REGISTRY_USERNAME is required when OCM_REGISTRY_PASSWORD is set"
  [[ -n "${OCM_REGISTRY_PASSWORD:-}" ]] || die "OCM_REGISTRY_PASSWORD is required when OCM_REGISTRY_USERNAME is set"
  render_registry_ocmconfig | "$OCM" --config - transfer cv \
    "$(cv_ref "$ROOT_COMPONENT")" \
    "$OCM_REPO" \
    --recursive \
    --copy-resources \
    --upload-as ociArtifact
else
  echo "note: no OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD set; using OCM config discovery" >&2
  "$OCM" transfer cv \
    "$(cv_ref "$ROOT_COMPONENT")" \
    "$OCM_REPO" \
    --recursive \
    --copy-resources \
    --upload-as ociArtifact
fi
