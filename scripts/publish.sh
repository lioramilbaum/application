#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=scripts/registry-credentials.sh
source "$(dirname "$0")/registry-credentials.sh"

require "$OCM"

[[ -n "${OCM_REPO:-}" ]] || die "OCM_REPO must be set (e.g. ghcr.io/lioramilbaum/ocm)"

# Each external resource (e.g. the Docker Hub image) is downloaded and re-uploaded
# to the target, making the published component self-contained. uploaders.ocmconfig
# routes images to OCI artifacts, which kubelet can pull; localBlob would bury them
# inside the component version.
transfer_flags=(--recursive)
UPLOADER_CONFIG="$ROOT/uploaders.ocmconfig"

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

# TRANSFER_CONFIG adds an explicit uploader-routing source. Passing --config turns off OCM's merge with the default config, so only the files passed here are loaded. Registry credentials still come from OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD.
global_config_args=()
if [[ -n "${TRANSFER_CONFIG:-}" ]]; then
  [[ -f "${TRANSFER_CONFIG}" ]] || die "TRANSFER_CONFIG file not found: ${TRANSFER_CONFIG}"
  global_config_args=(--config "${TRANSFER_CONFIG}")
fi

run_transfer() {
  if [[ -n "${OCM_REGISTRY_USERNAME:-}" || -n "${OCM_REGISTRY_PASSWORD:-}" ]]; then
    [[ -n "${OCM_REGISTRY_USERNAME:-}" ]] || die "OCM_REGISTRY_USERNAME is required when OCM_REGISTRY_PASSWORD is set"
    [[ -n "${OCM_REGISTRY_PASSWORD:-}" ]] || die "OCM_REGISTRY_PASSWORD is required when OCM_REGISTRY_USERNAME is set"
    # The uploader config goes last: uploader entries are matched in order and the first match wins.
    render_registry_ocmconfig | "$OCM" --config - "${global_config_args[@]}" transfer cv "${transfer_args[@]}" --config "$UPLOADER_CONFIG"
  else
    echo "note: no OCM_REGISTRY_USERNAME/OCM_REGISTRY_PASSWORD set; using OCM config discovery" >&2
    if [[ -n "${OCM_CONFIG:-}" ]]; then
      "$OCM" "${global_config_args[@]}" transfer cv "${transfer_args[@]}" --config "$OCM_CONFIG" --config "$UPLOADER_CONFIG"
    else
      # OCM_CONFIG keeps the default config (~/.ocmconfig) merged in; --config would turn that merge off.
      OCM_CONFIG="$UPLOADER_CONFIG" "$OCM" "${global_config_args[@]}" transfer cv "${transfer_args[@]}"
    fi
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
