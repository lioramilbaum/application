#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# Renovate updates KIND_VERSION; update KIND_SHA256_DARWIN_ARM64 to match.
KIND_VERSION="v0.33.0"
KIND_SHA256_DARWIN_ARM64="0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f"
KIND_BASE_URL="${KIND_BASE_URL:-https://github.com/kubernetes-sigs/kind/releases/download}"
BIN_DIR="${BIN_DIR:-$ROOT/bin}"

require_darwin_arm64
require curl

dest="$BIN_DIR/kind"
mkdir -p "$BIN_DIR"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$KIND_SHA256_DARWIN_ARM64" ]]; then
  echo "kind $KIND_VERSION darwin/arm64 already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$BIN_DIR/.kind.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Fetching kind $KIND_VERSION darwin/arm64 ..."
curl -sSfL "${KIND_BASE_URL}/${KIND_VERSION}/kind-darwin-arm64" -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$KIND_SHA256_DARWIN_ARM64" ]]; then
  die "kind checksum mismatch (expected $KIND_SHA256_DARWIN_ARM64, got $actual)"
fi

chmod 0755 "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT
echo "kind $KIND_VERSION darwin/arm64 installed at $dest"
