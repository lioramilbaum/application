#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/registry-credentials.sh
source "$(dirname "$0")/registry-credentials.sh"

require "$OCM"

[[ -n "${OCM_REPO:-}" ]] || die "OCM_REPO must be set (e.g. ghcr.io/lioramilbaum/ocm)"

# --copy-resources downloads each external resource (e.g. the Docker Hub image)
# and re-uploads it to the target, making the published component self-contained.
# ociArtifact keeps the image pullable by kubelet; localBlob would bury it inside
# the component version.
transfer_flags=(--recursive --copy-resources --upload-as ociArtifact)

if [[ -n "${OCM_REGISTRY_USERNAME:-}" || -n "${OCM_REGISTRY_PASSWORD:-}" ]]; then
  [[ -n "${OCM_REGISTRY_USERNAME:-}" ]] || die "OCM_REGISTRY_USERNAME is required when OCM_REGISTRY_PASSWORD is set"
  [[ -n "${OCM_REGISTRY_PASSWORD:-}" ]] || die "OCM_REGISTRY_PASSWORD is required when OCM_REGISTRY_USERNAME is set"
  render_registry_ocmconfig | "$OCM" --config - transfer cv \
    "$(cv_ref "$ROOT_COMPONENT")" \
    "$OCM_REPO" \
    "${transfer_flags[@]}"
else
  echo "note: no OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD set; using OCM config discovery" >&2
  "$OCM" transfer cv \
    "$(cv_ref "$ROOT_COMPONENT")" \
    "$OCM_REPO" \
    "${transfer_flags[@]}"
fi
