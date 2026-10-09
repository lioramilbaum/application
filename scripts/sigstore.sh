#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

export SIGSTORE_SIGNATURE="${SIGSTORE_SIGNATURE:-sigstore}"
SIGSTORE_OIDC_ISSUER="${SIGSTORE_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
SIGSTORE_IDENTITY_REGEXP="${SIGSTORE_IDENTITY_REGEXP:-^https://github\\.com/lioramilbaum/application/\\.github/workflows/release\\.yaml@refs/(heads/main|tags/v.+)$}"

mkdir -p "$BUILD_DIR"

cat > "$BUILD_DIR/sign-sigstore.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: signing.config.ocm.software/v1alpha1
    signature: ${SIGSTORE_SIGNATURE}
    signer:
      type: SigstoreSigningConfiguration/v1alpha1
EOF

cat > "$BUILD_DIR/verify-sigstore.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: signing.config.ocm.software/v1alpha1
    signature: ${SIGSTORE_SIGNATURE}
    verifier:
      type: SigstoreVerificationConfiguration/v1alpha1
      certificateOIDCIssuer: ${SIGSTORE_OIDC_ISSUER}
      certificateIdentityRegexp: '${SIGSTORE_IDENTITY_REGEXP}'
EOF
