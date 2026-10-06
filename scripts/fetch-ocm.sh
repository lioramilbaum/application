#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# Renovate updates OCM_CLI_VERSION; update OCM_CLI_SHA256_DARWIN_ARM64 to match.
OCM_CLI_VERSION="v0.17.0"
OCM_CLI_SHA256_DARWIN_ARM64="ae87ac4943e81396054367315395787fb7b71a697d946f8bb62de67bcb93e544"
OCM_CLI_BASE_URL="${OCM_CLI_BASE_URL:-https://github.com/open-component-model/open-component-model/releases/download}"
BIN_DIR="${BIN_DIR:-$ROOT/bin}"

require_darwin_arm64
require curl

dest="$BIN_DIR/ocm"
mkdir -p "$BIN_DIR"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$OCM_CLI_SHA256_DARWIN_ARM64" ]]; then
  echo "ocm $OCM_CLI_VERSION darwin/arm64 already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$BIN_DIR/.ocm.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Fetching ocm $OCM_CLI_VERSION darwin/arm64 ..."
curl -sSfL "${OCM_CLI_BASE_URL}/${OCM_CLI_VERSION}/ocm-darwin-arm64" -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$OCM_CLI_SHA256_DARWIN_ARM64" ]]; then
  die "ocm checksum mismatch (expected $OCM_CLI_SHA256_DARWIN_ARM64, got $actual)"
fi

chmod 0755 "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT
echo "ocm $OCM_CLI_VERSION darwin/arm64 installed at $dest"
