#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# Renovate updates OCM_CLI_VERSION; update ALL sha256 constants below to match.
OCM_CLI_VERSION="v0.17.0"
OCM_SHA256_DARWIN_ARM64="ae87ac4943e81396054367315395787fb7b71a697d946f8bb62de67bcb93e544"
OCM_SHA256_LINUX_AMD64="d942e2d5d024e9a5a82f1484ba4303b458d84c0dc9767125bd61cfa96120268f"
OCM_CLI_BASE_URL="${OCM_CLI_BASE_URL:-https://github.com/open-component-model/open-component-model/releases/download}"
BIN_DIR="${BIN_DIR:-$ROOT/bin}"

require curl

os="$(host_os)"
arch="$(host_arch)"

case "$os-$arch" in
  darwin-arm64) sha="$OCM_SHA256_DARWIN_ARM64"; binary="ocm-darwin-arm64" ;;
  linux-amd64)  sha="$OCM_SHA256_LINUX_AMD64";  binary="ocm-linux-amd64"  ;;
  *) die "Unsupported platform: $os/$arch (supported: darwin/arm64, linux/amd64)" ;;
esac

dest="$BIN_DIR/ocm"
mkdir -p "$BIN_DIR"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$sha" ]]; then
  echo "ocm $OCM_CLI_VERSION $os/$arch already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$BIN_DIR/.ocm.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Fetching ocm $OCM_CLI_VERSION $os/$arch ..."
curl -sSfL "${OCM_CLI_BASE_URL}/${OCM_CLI_VERSION}/${binary}" -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$sha" ]]; then
  die "ocm checksum mismatch (expected $sha, got $actual)"
fi

chmod 0755 "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT
echo "ocm $OCM_CLI_VERSION $os/$arch installed at $dest"
