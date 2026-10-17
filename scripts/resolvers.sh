#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

mkdir -p "$BUILD_DIR"

# RESOLVER_PATTERN defaults to everything under this component's namespace.
# A reference's own explicit repository always wins for that specific component;
# this resolver fires only when another component references github.com/lioramilbaum/application.
RESOLVER_PATTERN="${RESOLVER_PATTERN:-${ROOT_COMPONENT%/*}/**}"

cat > "$BUILD_DIR/resolvers.ocmconfig" <<YAML
type: generic.config.ocm.software/v1
configurations:
  - type: resolvers.config.ocm.software/v1alpha1
    resolvers:
      # First match wins; there is no fallback to later entries.
      - repository:
          type: CommonTransportFormat/v1
          filePath: "${CTF}"
          accessMode: readonly
        componentNamePattern: "${RESOLVER_PATTERN}"
YAML

echo "Wrote resolver config: $BUILD_DIR/resolvers.ocmconfig"
