#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# Renovate updates KIND_VERSION; update ALL sha256 constants below to match.
KIND_VERSION="v0.33.0"
KIND_SHA256_DARWIN_ARM64="0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f"
KIND_SHA256_LINUX_AMD64="aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d"
KIND_BASE_URL="${KIND_BASE_URL:-https://github.com/kubernetes-sigs/kind/releases/download}"
BIN_DIR="${BIN_DIR:-$ROOT/bin}"

require curl

os="$(host_os)"
arch="$(host_arch)"

case "$os-$arch" in
  darwin-arm64) sha="$KIND_SHA256_DARWIN_ARM64"; binary="kind-darwin-arm64" ;;
  linux-amd64)  sha="$KIND_SHA256_LINUX_AMD64";  binary="kind-linux-amd64"  ;;
  *) die "Unsupported platform: $os/$arch (supported: darwin/arm64, linux/amd64)" ;;
esac

dest="$BIN_DIR/kind"
mkdir -p "$BIN_DIR"

if [[ -f "$dest" ]] && [[ "$(sha256 "$dest")" == "$sha" ]]; then
  echo "kind $KIND_VERSION $os/$arch already cached"
  exit 0
fi

rm -f "$dest"
tmp="$(mktemp "$BIN_DIR/.kind.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "Fetching kind $KIND_VERSION $os/$arch ..."
curl -sSfL "${KIND_BASE_URL}/${KIND_VERSION}/${binary}" -o "$tmp"

actual="$(sha256 "$tmp")"
if [[ "$actual" != "$sha" ]]; then
  die "kind checksum mismatch (expected $sha, got $actual)"
fi

chmod 0755 "$tmp"
mv -f "$tmp" "$dest"
trap - EXIT
echo "kind $KIND_VERSION $os/$arch installed at $dest"
