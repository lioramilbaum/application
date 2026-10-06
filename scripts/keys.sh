#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require openssl

KEYS_DIR="$BUILD_DIR/keys"
mkdir -p "$KEYS_DIR"

PRIVATE_KEY="${SIGNING_KEY:-$KEYS_DIR/private.pem}"
PUBLIC_KEY="${VERIFY_KEY:-$KEYS_DIR/public.pem}"

if [[ ! -f "$PRIVATE_KEY" || ! -f "$PUBLIC_KEY" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" 2>/dev/null
  openssl rsa -pubout -in "$PRIVATE_KEY" -out "$PUBLIC_KEY" 2>/dev/null
fi

cat > "$BUILD_DIR/sign.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            privateKeyPEMFile: ${PRIVATE_KEY}
            publicKeyPEMFile: ${PUBLIC_KEY}
EOF

cat > "$BUILD_DIR/verify.ocmconfig" <<EOF
type: generic.config.ocm.software/v1
configurations:
  - type: credentials.config.ocm.software
    consumers:
      - identity:
          type: RSA/v1alpha1
          algorithm: RSASSA-PSS
          signature: default
        credentials:
          - type: RSACredentials/v1
            publicKeyPEMFile: ${PUBLIC_KEY}
EOF
