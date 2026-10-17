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

# Validate mutually-exclusive modes
[[ -n "${TRANSFER_PLAN:-}" && -n "${TRANSFER_SPEC:-}" ]] && \
  die "TRANSFER_PLAN and TRANSFER_SPEC are mutually exclusive"

# Build transfer arguments
if [[ -n "${TRANSFER_SPEC:-}" ]]; then
  [[ -f "${TRANSFER_SPEC}" ]] || die "TRANSFER_SPEC file not found: ${TRANSFER_SPEC}"
  transfer_args=(--transfer-spec "${TRANSFER_SPEC}")
else
  transfer_args=("$(cv_ref "$ROOT_COMPONENT")" "$OCM_REPO" "${transfer_flags[@]}")
fi

# Append dry-run flags when planning
if [[ -n "${TRANSFER_PLAN:-}" ]]; then
  transfer_args+=(--dry-run -o json)
fi

# TRANSFER_CONFIG adds an explicit uploader-routing source; OCM merges it with the default config. Registry credentials still come from OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD.
global_config_args=()
if [[ -n "${TRANSFER_CONFIG:-}" ]]; then
  [[ -f "${TRANSFER_CONFIG}" ]] || die "TRANSFER_CONFIG file not found: ${TRANSFER_CONFIG}"
  global_config_args=(--config "${TRANSFER_CONFIG}")
fi

run_transfer() {
  if [[ -n "${OCM_REGISTRY_USERNAME:-}" || -n "${OCM_REGISTRY_PASSWORD:-}" ]]; then
    [[ -n "${OCM_REGISTRY_USERNAME:-}" ]] || die "OCM_REGISTRY_USERNAME is required when OCM_REGISTRY_PASSWORD is set"
    [[ -n "${OCM_REGISTRY_PASSWORD:-}" ]] || die "OCM_REGISTRY_PASSWORD is required when OCM_REGISTRY_USERNAME is set"
    render_registry_ocmconfig | "$OCM" --config - "${global_config_args[@]}" transfer cv "${transfer_args[@]}"
  else
    echo "note: no OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD set; using OCM config discovery" >&2
    "$OCM" "${global_config_args[@]}" transfer cv "${transfer_args[@]}"
  fi
}

if [[ -n "${TRANSFER_PLAN:-}" ]]; then
  mkdir -p "$BUILD_DIR"
  plan_file="${TRANSFER_PLAN_FILE:-$BUILD_DIR/transfer-plan.json}"
  run_transfer > "$plan_file"
  jq -r '.transformations[] | "\(.type)\t\(.label // "")"' < "$plan_file"
  echo "Run with: make publish OCM_REPO=$OCM_REPO TRANSFER_SPEC=$plan_file"
else
  run_transfer
fi
