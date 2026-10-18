#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export SBOM_RESOURCE="hello-world-sbom"
# File/v1 inputs are confined to the constructor directory (os.OpenInRoot),
# so the SBOM must live under $ROOT, not $BUILD_DIR.
export SBOM_FILE="$ROOT/build/sbom/hello-world.cdx.json"

export OCM="${OCM:-ocm}"
export VERSION="${VERSION:-0.1.0}"
export BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
export CTF="${CTF:-$BUILD_DIR/ctf}"
export ROOT_COMPONENT="github.com/lioramilbaum/application"
export DEPLOY_DIR="${DEPLOY_DIR:-$BUILD_DIR/deploy}"
export APP_NAME="hello-world"
export APP_NAMESPACE="hello-world"
export IMAGE_PLACEHOLDER="HELLO_WORLD_IMAGE"
export MANIFESTS_RESOURCE="hello-world-manifests"
export LOCALIZATION_RESOURCE="hello-world-localization"
export CONFIG_RESOURCE="hello-world-config"
export PLACEHOLDER_PATTERN='HELLO_WORLD_[A-Z0-9_]+'
export KUBECTL="${KUBECTL:-kubectl}"

host_os() {
  uname -s | tr '[:upper:]' '[:lower:]'
}

host_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64)          echo amd64 ;;
    aarch64|arm64)   echo arm64 ;;
    *)               echo "$m"  ;;
  esac
}

TARGET_ARCH="${TARGET_ARCH:-$(host_arch)}"
export TARGET_ARCH

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "No sha256 tool found (shasum or sha256sum)"
  fi
}

require_darwin_arm64() {
  [[ "$(host_os)" == "darwin" && "$(host_arch)" == "arm64" ]] || \
    die "This target only works on darwin/arm64 (detected: $(host_os)/$(host_arch))"
}

cv_ref() {
  local component="${1:-$ROOT_COMPONENT}"
  # OCM_COMPONENT_REPO overrides the CTF for registry-sourced components,
  # e.g. OCM_COMPONENT_REPO=oci::http://localhost:5001
  echo "${OCM_COMPONENT_REPO:-ctf::${CTF}}//${component}:${VERSION}"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "Required tool not found: $bin"
  done
}
